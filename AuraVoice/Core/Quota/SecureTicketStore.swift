//
//  SecureTicketStore.swift
//  AuraVoice
//
//  İmzalı dakika biletlerinin bozdurulması ve tekrar kullanımının engellenmesi.
//
//  İki saldırıya karşı savunma var:
//
//  1. TEKRAR KULLANIM (replay) — aynı bilet iki kez bozdurulamaz. Bozdurulan
//     biletlerin kimlikleri deftere yazılıyor. Defter sonsuza kadar büyümesin
//     diye süresi geçmiş kayıtlar temizleniyor; süresi geçmiş bilet zaten
//     doğrulamadan geçemediği için bu güvenliği zayıflatmıyor.
//
//  2. SAAT GERİ ALMA — kullanıcı cihaz saatini geriye çekip süresi dolmuş bir
//     bileti tekrar geçerli hale getiremesin diye defterde bir "en ileri
//     görülen zaman" tutuluyor. Bu değer YALNIZCA imzalı biletin `issuedAt`
//     alanından ilerliyor; cihaz saatinden ilerleseydi, saati 2030'a alan bir
//     kullanıcı kendi uygulamasını kalıcı olarak kilitlerdi.
//

import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Defter

public struct TicketLedger: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let expiresAtMillis: Int64

        public init(id: String, expiresAtMillis: Int64) {
            self.id = id
            self.expiresAtMillis = expiresAtMillis
        }
    }

    /// Bozdurulmuş ve henüz süresi dolmamış bilet kimlikleri.
    public var redeemed: [Entry]
    /// Sunucunun vouch ettiği en ileri zaman (ms).
    public var highWaterMillis: Int64
    /// Toplam kazanılmış dakika — destek ve teşhis için.
    public var grantedMinutes: Double

    public init(redeemed: [Entry] = [], highWaterMillis: Int64 = 0, grantedMinutes: Double = 0) {
        self.redeemed = redeemed
        self.highWaterMillis = highWaterMillis
        self.grantedMinutes = grantedMinutes
    }

    public func contains(_ id: String) -> Bool {
        redeemed.contains { $0.id == id }
    }

    /// Süresi geçmiş kayıtları atar.
    public func pruned(before millis: Int64) -> TicketLedger {
        var copy = self
        copy.redeemed = redeemed.filter { $0.expiresAtMillis >= millis }
        return copy
    }
}

// MARK: - Depolama

public protocol TicketLedgerStorage: Sendable {
    func readLedger() -> Data?
    @discardableResult func writeLedger(_ data: Data) -> Bool
}

public final class KeychainTicketLedgerStorage: TicketLedgerStorage {

    private let service: String
    private let account = "minute_ticket_ledger_v1"

    public init(service: String = "com.auravoice.tickets") {
        self.service = service
    }

    public func readLedger() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            print("[AuraVoice] Bilet defteri okunamadı: \(Self.describe(status))")
            return nil
        }
    }

    @discardableResult
    public func writeLedger(_ data: Data) -> Bool {
        let query = baseQuery()
        let existing = SecItemCopyMatching(query as CFDictionary, nil)

        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            status = SecItemAdd(insert as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            print("[AuraVoice] Bilet defteri yazılamadı: \(Self.describe(status))")
            return false
        }
        return true
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Yedekten başka cihaza taşınmamalı: defter cihaza özgü.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "bilinmeyen"
        return "\(status) (\(message))"
    }
}

public final class InMemoryTicketLedgerStorage: TicketLedgerStorage, @unchecked Sendable {

    private let lock = NSLock()
    private var payload: Data?
    /// Testlerde yazma hatasını taklit etmek için.
    private var writesFail: Bool

    public init(payload: Data? = nil, writesFail: Bool = false) {
        self.payload = payload
        self.writesFail = writesFail
    }

    public func readLedger() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return payload
    }

    @discardableResult
    public func writeLedger(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !writesFail else { return false }
        payload = data
        return true
    }

    public func setWritesFail(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        writesFail = value
    }
}

// MARK: - Bozdurma

public actor SecureTicketStore {

    private let verifier: TicketVerifier
    private let storage: any TicketLedgerStorage
    private let quota: QuotaManager
    private let subject: String

    public init(
        verifier: TicketVerifier,
        storage: any TicketLedgerStorage,
        quota: QuotaManager,
        subject: String
    ) {
        self.verifier = verifier
        self.storage = storage
        self.quota = quota
        self.subject = subject
    }

    /// Uygulamanın varsayılan kurulumu. Info.plist'te açık anahtar yoksa nil
    /// döner — bilet özelliği kapalı demektir, uygulama çalışmaya devam eder.
    @MainActor
    public static func makeDefault(
        bundle: Bundle = .main,
        quota: QuotaManager = .shared,
        subject: String = DeviceSubject.current()
    ) -> SecureTicketStore? {
        guard let verifier = TicketVerifier.makeDefault(bundle: bundle) else { return nil }
        return SecureTicketStore(
            verifier: verifier,
            storage: KeychainTicketLedgerStorage(),
            quota: quota,
            subject: subject
        )
    }

    // MARK: Okuma

    public func ledger() -> TicketLedger {
        loadLedger()
    }

    /// Cihaz saati geriye alınmış olsa bile güvenilebilecek zaman.
    public func trustedNow(deviceNow: Date = Date()) -> Date {
        let highWater = MinuteTicket.date(fromMillis: loadLedger().highWaterMillis)
        return max(deviceNow, highWater)
    }

    // MARK: Yazma

    /// Bileti doğrular, deftere işler ve dakikaları bakiyeye ekler.
    @discardableResult
    public func redeem(_ signed: SignedTicket, deviceNow: Date = Date()) throws -> MinuteTicket {

        var ledger = loadLedger()
        let now = max(deviceNow, MinuteTicket.date(fromMillis: ledger.highWaterMillis))

        let ticket = try verifier.verify(signed, subject: subject, now: now)

        guard !ledger.contains(ticket.id) else { throw TicketError.alreadyRedeemed }

        ledger = ledger.pruned(before: MinuteTicket.millis(from: now))
        ledger.redeemed.append(TicketLedger.Entry(id: ticket.id, expiresAtMillis: ticket.expiresAtMillis))
        // Yalnızca imzalı `issuedAt` ile ilerliyor — cihaz saatiyle değil.
        ledger.highWaterMillis = max(ledger.highWaterMillis, ticket.issuedAtMillis)
        ledger.grantedMinutes += ticket.minutes

        // Önce defter, sonra bakiye. Ters sırada olsaydı defter yazımı
        // başarısız olduğunda aynı bilet tekrar tekrar bozdurulabilirdi.
        guard let data = try? JSONEncoder().encode(ledger), storage.writeLedger(data) else {
            throw TicketError.storageUnavailable
        }

        guard quota.addMinutesFromSubscription(ticket.minutes) else {
            // Defter işlendi ama bakiye yazılamadı: kullanıcı dakikayı
            // kaybediyor. Sessizce başarılı dönmektense söylüyoruz; sunucu
            // yeniden bilet düzenleyebilir.
            throw AuraError.quotaStorageUnavailable
        }

        return ticket
    }

    /// Ham JSON yükünü (sunucu yanıtı, derin bağlantı, QR) bozdurur.
    @discardableResult
    public func redeem(payload: Data, deviceNow: Date = Date()) throws -> MinuteTicket {
        try redeem(SignedTicket.decode(payload), deviceNow: deviceNow)
    }

    // MARK: Yardımcı

    private func loadLedger() -> TicketLedger {
        guard let data = storage.readLedger(),
              let ledger = try? JSONDecoder().decode(TicketLedger.self, from: data)
        else { return TicketLedger() }
        return ledger
    }
}

// MARK: - Cihaz kimliği

public enum DeviceSubject {

    /// Biletin bağlandığı cihaz kimliği.
    ///
    /// `identifierForVendor` uygulama kaldırılıp yeniden kurulduğunda
    /// değişebiliyor; bu kabul edilebilir çünkü o durumda sunucu zaten yeni
    /// bilet düzenliyor. Kalıcı bir donanım kimliği kullanmak ise hem App
    /// Store kurallarına hem de gizlilik duruşumuza aykırı olurdu.
    ///
    /// `UIDevice` ana aktöre bağlı olduğu için bu çağrı da öyle — kurulum
    /// zaten uygulama açılışında ana aktörde yapılıyor.
    @MainActor
    public static func current() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        #else
        return "unknown-device"
        #endif
    }
}
