//
//  QuotaAndRouterTests.swift
//  AuraVoiceTests
//
//  Bu testler gerçek Keychain'e dokunuyor (simülatörde izole). Bakiyeyi
//  değiştiren testler değişikliği kendileri geri alıyor, bu yüzden suite
//  seri çalıştırılıyor.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Kota yöneticisi", .serialized)
struct QuotaManagerTests {

    @Test("Bakiye hiçbir zaman negatif değil")
    func balanceIsNeverNegative() {
        #expect(QuotaManager.shared.getRemainingSeconds() >= 0)
        #expect(QuotaManager.shared.getRemainingMinutes() >= 0)
    }

    @Test("Bakiyeden büyük istek reddedilir")
    func rejectsOversizedRequest() {
        #expect(!QuotaManager.shared.canProcess(durationSeconds: 1_000_000))
    }

    @Test("Yetersiz bakiyede insufficientQuota fırlatır")
    func deductThrowsWhenInsufficient() {
        #expect(throws: AuraError.self) {
            try QuotaManager.shared.deductUsage(durationSeconds: 1_000_000)
        }
    }

    @Test("Düşüm bakiyeyi tam olarak azaltır")
    func deductReducesBalanceExactly() throws {
        let manager = QuotaManager.shared
        // Testin bakiyeden bağımsız çalışması için önce küçük bir tampon ekle.
        manager.addMinutesFromSubscription(1)
        let before = manager.getRemainingSeconds()

        try manager.deductUsage(durationSeconds: 30)
        let after = manager.getRemainingSeconds()

        #expect(abs((before - 30) - after) < 0.01)

        // Testin yan etkisini geri al: 60 sn eklenmiş, 30 sn düşülmüştü.
        try? manager.deductUsage(durationSeconds: 30)
    }
}

// MARK: - Router

private struct StubEngine: ProcessingEngineProtocol {
    let output: ProcessingResult?

    func process(request: ProcessingRequest) async throws -> ProcessingResult {
        guard let output else { throw AuraError.engineFailure("stub başarısız") }
        // Ölçülebilir bir işlem süresi oluşsun.
        try await Task.sleep(for: .milliseconds(20))
        return output
    }
}

@Suite("İşleme yönlendiricisi", .serialized)
struct ProcessingRouterTests {

    private var dummyRequest: ProcessingRequest {
        ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura-test.wav"),
            durationSeconds: 10,
            mode: .offlineZeroCloud,
            summaryTemplate: .meetingNotes
        )
    }

    private var stubResult: ProcessingResult {
        ProcessingResult(
            rawTranscript: "transkript",
            summaryMarkdown: "### Özet\n- Madde",
            detectedLanguage: "tr",
            usedMinutes: 0,
            processingTimeSeconds: 0
        )
    }

    @Test("Motor hata verirse kota düşülmez")
    func failedEngineDoesNotConsumeQuota() async {
        QuotaManager.shared.addMinutesFromSubscription(1)
        let before = QuotaManager.shared.getRemainingSeconds()

        let router = ProcessingRouter(
            offlineEngine: StubEngine(output: nil),
            onlineEngine: StubEngine(output: nil)
        )

        await #expect(throws: AuraError.self) {
            _ = try await router.execute(request: dummyRequest)
        }

        #expect(abs(QuotaManager.shared.getRemainingSeconds() - before) < 0.01)
        try? QuotaManager.shared.deductUsage(durationSeconds: 60)
    }

    @Test("Başarılı işlem kotayı kayıt süresi kadar düşer")
    func successConsumesExactDuration() async throws {
        QuotaManager.shared.addMinutesFromSubscription(1)
        let before = QuotaManager.shared.getRemainingSeconds()

        let router = ProcessingRouter(
            offlineEngine: StubEngine(output: stubResult),
            onlineEngine: StubEngine(output: stubResult)
        )

        let result = try await router.execute(request: dummyRequest)

        #expect(abs(QuotaManager.shared.getRemainingSeconds() - (before - 10)) < 0.01)
        #expect(abs(result.usedMinutes - (10.0 / 60.0)) < 0.0001)
        // Şablondaki `now - now` hatasının geri gelmediğini doğrular.
        #expect(result.processingTimeSeconds > 0)

        try? QuotaManager.shared.deductUsage(durationSeconds: 50)
    }

    @Test("Bakiye yetersizse motor hiç çağrılmaz")
    func insufficientQuotaShortCircuits() async {
        let request = ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura-test.wav"),
            durationSeconds: 10_000_000,
            mode: .onlineCloudFast,
            summaryTemplate: .quickNotes
        )
        let router = ProcessingRouter(
            offlineEngine: StubEngine(output: stubResult),
            onlineEngine: StubEngine(output: stubResult)
        )

        await #expect(throws: AuraError.self) {
            _ = try await router.execute(request: request)
        }
    }
}
