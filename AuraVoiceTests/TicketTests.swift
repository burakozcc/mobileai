//
//  TicketTests.swift
//  AuraVoiceTests
//
//  İmzalı dakika biletleri: imza doğrulama, tekrar kullanım engeli ve saat
//  geri alma savunması.
//

import Testing
import Foundation
import CryptoKit
@testable import AuraVoice

// MARK: - Ortak yardımcılar

private let anchor = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09

private func makeTicket(
    id: String = UUID().uuidString,
    subject: String = "device-1",
    plan: String = "pro",
    minutes: Double = 60,
    issuedAt: Date = anchor,
    validFor: TimeInterval = 3_600
) -> MinuteTicket {
    MinuteTicket(
        id: id,
        subject: subject,
        plan: plan,
        minutes: minutes,
        issuedAt: issuedAt,
        expiresAt: issuedAt.addingTimeInterval(validFor)
    )
}

private func makeStore(
    signer: TicketSigner,
    quota: QuotaManager,
    storage: InMemoryTicketLedgerStorage = InMemoryTicketLedgerStorage(),
    subject: String = "device-1"
) -> SecureTicketStore {
    SecureTicketStore(verifier: signer.verifier, storage: storage, quota: quota, subject: subject)
}

private func makeQuota(seconds: Double = 0) -> QuotaManager {
    QuotaManager(storage: InMemoryQuotaStorage(initialSeconds: seconds, bootstrapped: true))
}

// MARK: - İmza

@Suite("Bilet imzası")
struct MinuteTicketSignatureTests {

    private let signer = TicketSigner()

    @Test("Geçerli bilet doğrulanır")
    func validTicketPasses() throws {
        let ticket = makeTicket()
        let signed = try signer.sign(ticket)

        let verified = try signer.verifier.verify(signed, subject: "device-1", now: anchor)
        #expect(verified == ticket)
    }

    @Test("Dakika değiştirilirse imza tutmaz")
    func tamperedMinutesRejected() throws {
        let signed = try signer.sign(makeTicket(minutes: 60))
        // Saldırgan 60 dakikayı 6000'e çeviriyor, imzayı olduğu gibi bırakıyor.
        let forged = SignedTicket(
            ticket: makeTicket(id: signed.ticket.id, minutes: 6_000),
            signature: signed.signature
        )

        #expect(throws: TicketError.invalidSignature) {
            try signer.verifier.verify(forged, subject: "device-1", now: anchor)
        }
    }

    @Test("Kimlik değiştirilirse imza tutmaz")
    func tamperedIdentifierRejected() throws {
        let signed = try signer.sign(makeTicket(id: "ticket-a"))
        let forged = SignedTicket(
            ticket: makeTicket(id: "ticket-b"),
            signature: signed.signature
        )

        #expect(throws: TicketError.invalidSignature) {
            try signer.verifier.verify(forged, subject: "device-1", now: anchor)
        }
    }

    @Test("Başka anahtarla imzalanmış bilet reddedilir")
    func foreignKeyRejected() throws {
        let attacker = TicketSigner()
        let signed = try attacker.sign(makeTicket())

        #expect(throws: TicketError.invalidSignature) {
            try signer.verifier.verify(signed, subject: "device-1", now: anchor)
        }
    }

    @Test("Süresi dolmuş bilet reddedilir")
    func expiredRejected() throws {
        let ticket = makeTicket(validFor: 60)
        let signed = try signer.sign(ticket)

        #expect(throws: TicketError.expired(at: ticket.expiresAt)) {
            try signer.verifier.verify(signed, subject: "device-1", now: anchor.addingTimeInterval(120))
        }
    }

    @Test("Başka cihazın bileti reddedilir")
    func wrongDeviceRejected() throws {
        let signed = try signer.sign(makeTicket(subject: "device-2"))

        #expect(throws: TicketError.wrongDevice) {
            try signer.verifier.verify(signed, subject: "device-1", now: anchor)
        }
    }

    @Test("Joker konu her cihazda geçerli")
    func wildcardSubjectPasses() throws {
        let signed = try signer.sign(makeTicket(subject: "*"))
        let verified = try signer.verifier.verify(signed, subject: "başka-cihaz", now: anchor)
        #expect(verified.subject == "*")
    }

    @Test("Sıfır veya negatif dakika reddedilir", arguments: [0.0, -30.0])
    func nonPositiveMinutesRejected(minutes: Double) throws {
        let signed = try signer.sign(makeTicket(minutes: minutes))

        #expect(throws: TicketError.nonPositiveMinutes) {
            try signer.verifier.verify(signed, subject: "device-1", now: anchor)
        }
    }

    @Test("Bozuk imza base64'ü biçim hatası verir")
    func malformedSignature() {
        let forged = SignedTicket(ticket: makeTicket(), signature: "bu-base64-degil!!")

        #expect(throws: TicketError.malformed) {
            try signer.verifier.verify(forged, subject: "device-1", now: anchor)
        }
    }

    @Test("Bitiş başlangıçtan önceyse bilet bozuk sayılır")
    func inconsistentDatesRejected() throws {
        let signed = try signer.sign(makeTicket(validFor: -60))

        #expect(throws: TicketError.malformed) {
            try signer.verifier.verify(signed, subject: "device-1", now: anchor.addingTimeInterval(-3_600))
        }
    }

    @Test("JSON gidiş-dönüşü imzayı bozmaz")
    func jsonRoundTripKeepsSignature() throws {
        let signed = try signer.sign(makeTicket())
        let decoded = try SignedTicket.decode(try signed.encoded())

        #expect(decoded == signed)
        #expect(decoded.ticket.canonicalPayload == signed.ticket.canonicalPayload)
        _ = try signer.verifier.verify(decoded, subject: "device-1", now: anchor)
    }

    @Test("Bozuk JSON okunamaz")
    func malformedJSON() {
        #expect(throws: TicketError.malformed) {
            _ = try SignedTicket.decode(Data("{bu json degil".utf8))
        }
    }

    @Test("Kanonik gövde alanları karıştırılamaz")
    func canonicalPayloadIsFieldOrdered() {
        // id ve subject yer değiştirdiğinde imzalanan baytlar değişmeli;
        // aksi halde "a|b" ile "ab|" gibi çakışmalar imza taklidine yol açardı.
        let first = makeTicket(id: "abc", subject: "device-1")
        let second = makeTicket(id: "device-1", subject: "abc")
        #expect(first.canonicalPayload != second.canonicalPayload)
    }

    @Test("Kanonik gövde sürüm etiketiyle başlar")
    func canonicalPayloadIsVersioned() {
        let payload = String(decoding: makeTicket().canonicalPayload, as: UTF8.self)
        #expect(payload.hasPrefix("aura.ticket.v1|"))
    }
}

// MARK: - Bozdurma ve defter

@Suite("Bilet bozdurma", .serialized)
struct SecureTicketStoreTests {

    private let signer = TicketSigner()

    @Test("Bilet bozdurulunca bakiye artar")
    func redeemAddsMinutes() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)

        let ticket = try await store.redeem(signer.sign(makeTicket(minutes: 45)), deviceNow: anchor)

        #expect(ticket.minutes == 45)
        #expect(quota.getRemainingMinutes() == 45)
        #expect(await store.ledger().grantedMinutes == 45)
    }

    @Test("Aynı bilet ikinci kez bozdurulamaz")
    func replayIsRejected() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)
        let signed = try signer.sign(makeTicket(minutes: 45))

        _ = try await store.redeem(signed, deviceNow: anchor)

        await #expect(throws: TicketError.alreadyRedeemed) {
            _ = try await store.redeem(signed, deviceNow: anchor)
        }
        // Bakiye tek bozdurma kadar kalmalı.
        #expect(quota.getRemainingMinutes() == 45)
    }

    @Test("Farklı biletler birikir")
    func multipleTicketsAccumulate() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)

        _ = try await store.redeem(signer.sign(makeTicket(minutes: 30)), deviceNow: anchor)
        _ = try await store.redeem(signer.sign(makeTicket(minutes: 20)), deviceNow: anchor)

        #expect(quota.getRemainingMinutes() == 50)
        #expect(await store.ledger().redeemed.count == 2)
    }

    @Test("Saat geriye alınsa da süresi dolmuş bilet kabul edilmez")
    func clockRollbackDoesNotRevivePastTickets() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)

        // Kullanıcı bugünkü bileti bozduruyor: en ileri görülen zaman = anchor.
        _ = try await store.redeem(signer.sign(makeTicket(minutes: 10)), deviceNow: anchor)

        // Sonra saati 10 gün geriye alıyor ve 5 gün önce süresi dolmuş bir
        // bileti bozdurmaya çalışıyor. Cihaz saatine bakılsaydı geçerdi.
        let stale = makeTicket(
            minutes: 500,
            issuedAt: anchor.addingTimeInterval(-6 * 86_400),
            validFor: 86_400
        )
        let signedStale = try signer.sign(stale)

        await #expect(throws: TicketError.expired(at: stale.expiresAt)) {
            _ = try await store.redeem(signedStale, deviceNow: anchor.addingTimeInterval(-10 * 86_400))
        }
        #expect(quota.getRemainingMinutes() == 10)
    }

    @Test("Güvenilir zaman yalnızca imzalı issuedAt ile ilerler")
    func highWaterOnlyFollowsSignedTime() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)

        // Kullanıcı saati 100 gün ileri almış olsa bile defter oraya taşınmamalı;
        // taşınsaydı ileride gelen gerçek biletler "süresi dolmuş" sayılırdı.
        _ = try await store.redeem(
            signer.sign(makeTicket(minutes: 10, validFor: 200 * 86_400)),
            deviceNow: anchor.addingTimeInterval(100 * 86_400)
        )

        #expect(await store.ledger().highWaterMillis == MinuteTicket.millis(from: anchor))

        // Saat düzeltildikten sonra bir sonraki bilet hâlâ bozdurulabiliyor.
        _ = try await store.redeem(
            signer.sign(makeTicket(minutes: 5, issuedAt: anchor.addingTimeInterval(3_600))),
            deviceNow: anchor.addingTimeInterval(3_700)
        )
        #expect(quota.getRemainingMinutes() == 15)
    }

    @Test("Defter yazılamazsa dakika eklenmez")
    func ledgerWriteFailureBlocksCredit() async throws {
        let quota = makeQuota()
        let storage = InMemoryTicketLedgerStorage(writesFail: true)
        let store = makeStore(signer: signer, quota: quota, storage: storage)

        await #expect(throws: TicketError.storageUnavailable) {
            _ = try await store.redeem(signer.sign(makeTicket(minutes: 45)), deviceNow: anchor)
        }
        #expect(quota.getRemainingMinutes() == 0)
    }

    @Test("Süresi geçmiş defter kayıtları temizlenir")
    func expiredLedgerEntriesArePruned() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)

        let old = makeTicket(minutes: 10, issuedAt: anchor, validFor: 3_600)
        _ = try await store.redeem(signer.sign(old), deviceNow: anchor)

        let fresh = makeTicket(minutes: 10, issuedAt: anchor.addingTimeInterval(7_200), validFor: 3_600)
        _ = try await store.redeem(signer.sign(fresh), deviceNow: anchor.addingTimeInterval(7_200))

        let ledger = await store.ledger()
        #expect(!ledger.contains(old.id))
        #expect(ledger.contains(fresh.id))
        #expect(ledger.grantedMinutes == 20)
    }

    @Test("Ham JSON yükü doğrudan bozdurulabilir")
    func redeemsRawPayload() async throws {
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)
        let payload = try signer.sign(makeTicket(minutes: 25)).encoded()

        _ = try await store.redeem(payload: payload, deviceNow: anchor)
        #expect(quota.getRemainingMinutes() == 25)
    }

    @Test("Başka cihazın bileti bakiyeye dokunmaz")
    func foreignTicketLeavesBalanceAlone() async throws {
        let quota = makeQuota(seconds: 600)
        let store = makeStore(signer: signer, quota: quota)

        await #expect(throws: TicketError.wrongDevice) {
            _ = try await store.redeem(signer.sign(makeTicket(subject: "device-9")), deviceNow: anchor)
        }
        #expect(quota.getRemainingMinutes() == 10)
        #expect(await store.ledger().redeemed.isEmpty)
    }
}

// MARK: - Doğrulayıcı kurulumu

@Suite("Doğrulayıcı kurulumu")
struct TicketVerifierSetupTests {

    @Test("Base64 açık anahtardan doğrulayıcı kurulur")
    func buildsFromBase64() throws {
        let signer = TicketSigner()
        let verifier = try TicketVerifier(base64PublicKey: signer.publicKeyBase64)
        let signed = try signer.sign(makeTicket())

        _ = try verifier.verify(signed, subject: "device-1", now: anchor)
    }

    @Test("Geçersiz anahtar açık hata verir", arguments: ["", "base64-degil!!", "aGVsbG8="])
    func rejectsInvalidKeys(value: String) {
        #expect(throws: TicketError.verifierUnavailable) {
            _ = try TicketVerifier(base64PublicKey: value)
        }
    }

    @Test("Info.plist'te anahtar yoksa doğrulayıcı kurulmaz")
    func missingInfoKeyYieldsNil() {
        #expect(TicketVerifier.makeDefault(bundle: Bundle(for: TicketBundleMarker.self)) == nil)
    }
}

/// Test paketinin bundle'ına erişmek için işaretçi sınıf.
private final class TicketBundleMarker {}

// MARK: - Bozdurma ekranı

@MainActor
@Suite("Bilet ekranı", .serialized)
struct TicketRedemptionViewModelTests {

    private func makeViewModel(store: SecureTicketStore?) -> TicketRedemptionViewModel {
        TicketRedemptionViewModel(makeStore: { store })
    }

    @Test("Anahtar yoksa özellik kapalı görünüyor")
    func unavailableWithoutKey() {
        // `Info.plist`'te AuraTicketPublicKey boş; `makeDefault` nil dönüyor
        // ve uygulama çalışmaya devam ediyor.
        let viewModel = makeViewModel(store: nil)
        viewModel.prepare()
        #expect(!viewModel.isAvailable)
    }

    @Test("Anahtar yokken bozdurma açık hata veriyor")
    func redeemWithoutStoreFails() async {
        let viewModel = makeViewModel(store: nil)
        viewModel.prepare()
        viewModel.payload = "{}"

        await viewModel.redeem()

        guard case let .failure(reason) = viewModel.outcome else {
            Issue.record("Anahtar yokken başarı dönemez: \(viewModel.outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("Boş girdi sunucuya hiç gitmiyor")
    func emptyPayloadIsRejectedLocally() async {
        let signer = TicketSigner()
        let quota = makeQuota()
        let viewModel = makeViewModel(store: makeStore(signer: signer, quota: quota))
        viewModel.prepare()
        viewModel.payload = "   \n  "

        await viewModel.redeem()

        #expect(viewModel.outcome != .idle)
        #expect(quota.getRemainingMinutes() == 0)
    }

    @Test("Geçerli bilet bakiyeye ekleniyor ve alan temizleniyor")
    func validTicketIsRedeemed() async throws {
        let signer = TicketSigner()
        let quota = makeQuota()
        let viewModel = makeViewModel(store: makeStore(signer: signer, quota: quota))
        viewModel.prepare()

        // Ekran `redeem(payload:)`'i cihaz saatiyle çağırıyor; sabit `anchor`
        // tarihli bilet süresi dolmuş gelirdi.
        let signed = try signer.sign(makeTicket(minutes: 45, issuedAt: Date()))
        viewModel.payload = String(decoding: try signed.encoded(), as: UTF8.self)

        await viewModel.redeem()

        #expect(viewModel.outcome == .success(minutes: 45))
        // Alan temizlenmezse kullanıcı aynı bileti tekrar göndermeye çalışır.
        #expect(viewModel.payload.isEmpty)
        #expect(quota.getRemainingMinutes() == 45)
    }

    @Test("Aynı bilet ikinci kez kabul edilmiyor")
    func replayIsRejectedInUI() async throws {
        let signer = TicketSigner()
        let quota = makeQuota()
        let store = makeStore(signer: signer, quota: quota)
        let viewModel = makeViewModel(store: store)
        viewModel.prepare()

        let signed = try signer.sign(makeTicket(minutes: 45, issuedAt: Date()))
        let text = String(decoding: try signed.encoded(), as: UTF8.self)

        viewModel.payload = text
        await viewModel.redeem()

        viewModel.payload = text
        await viewModel.redeem()

        guard case let .failure(reason) = viewModel.outcome else {
            Issue.record("Tekrar kullanım kabul edilemez: \(viewModel.outcome)")
            return
        }
        #expect(reason == TicketError.alreadyRedeemed.errorDescription)
        #expect(quota.getRemainingMinutes() == 45)
    }

    @Test("Bozuk metin okunabilir hata veriyor")
    func malformedPayloadIsReported() async {
        let signer = TicketSigner()
        let viewModel = makeViewModel(store: makeStore(signer: signer, quota: makeQuota()))
        viewModel.prepare()
        viewModel.payload = "bu bir bilet değil"

        await viewModel.redeem()
        #expect(viewModel.outcome == .failure(TicketError.malformed.errorDescription ?? ""))
    }
}
