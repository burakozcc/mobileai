//
//  QuotaAndRouterTests.swift
//  AuraVoiceTests
//
//  Kota testleri artık gerçek Keychain'e dokunmuyor: `InMemoryQuotaStorage`
//  enjekte ediliyor. Eski sürüm CI'da "available: 0.0" ile düşüyordu çünkü
//  imzasız simülatör derlemesinde Keychain yazma reddediliyor — ve o hata
//  sessizce yutuluyordu. Bu düzeltme hem testleri deterministik yapıyor hem de
//  üretimdeki sessiz veri kaybını ortaya çıkardı.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Kota yöneticisi")
struct QuotaManagerTests {

    private func makeManager(seconds: Double) -> QuotaManager {
        QuotaManager(storage: InMemoryQuotaStorage(initialSeconds: seconds, bootstrapped: true))
    }

    @Test("İlk açılışta 30 ücretsiz dakika yüklenir")
    func bootstrapGrantsFreeTier() {
        let manager = QuotaManager(storage: InMemoryQuotaStorage())
        #expect(manager.getRemainingSeconds() == QuotaManager.freeTierSeconds)
        #expect(abs(manager.getRemainingMinutes() - 30) < 0.001)
    }

    @Test("Hediye yalnızca bir kez verilir")
    func bootstrapIsOneShot() throws {
        let storage = InMemoryQuotaStorage()
        let manager = QuotaManager(storage: storage)

        try manager.deductUsage(durationSeconds: QuotaManager.freeTierSeconds)
        #expect(manager.getRemainingSeconds() == 0)

        // Bakiye bitti diye hediye tekrar yüklenmemeli.
        #expect(manager.getRemainingSeconds() == 0)
    }

    @Test("Bakiye hiçbir zaman negatif değil")
    func balanceIsNeverNegative() {
        let manager = makeManager(seconds: 0)
        #expect(manager.getRemainingSeconds() >= 0)
        #expect(manager.getRemainingMinutes() >= 0)
    }

    @Test("Bakiyeden büyük istek reddedilir")
    func rejectsOversizedRequest() {
        let manager = makeManager(seconds: 60)
        #expect(!manager.canProcess(durationSeconds: 61))
        #expect(manager.canProcess(durationSeconds: 60))
    }

    @Test("Yetersiz bakiyede insufficientQuota fırlatır")
    func deductThrowsWhenInsufficient() {
        let manager = makeManager(seconds: 10)
        #expect(throws: AuraError.insufficientQuota(requiredSeconds: 30, availableSeconds: 10)) {
            try manager.deductUsage(durationSeconds: 30)
        }
    }

    @Test("Düşüm bakiyeyi tam olarak azaltır")
    func deductReducesBalanceExactly() throws {
        let manager = makeManager(seconds: 600)
        try manager.deductUsage(durationSeconds: 30)
        #expect(abs(manager.getRemainingSeconds() - 570) < 0.001)
    }

    @Test("Abonelik dakikası bakiyeye eklenir")
    func subscriptionAddsMinutes() {
        let manager = makeManager(seconds: 60)
        manager.addMinutesFromSubscription(10)
        #expect(abs(manager.getRemainingSeconds() - 660) < 0.001)
    }

    @Test("Plan yenilemesi bakiyeyi eşitler")
    func resetOverwritesBalance() {
        let manager = makeManager(seconds: 5)
        manager.resetBalance(toMinutes: 600)
        #expect(abs(manager.getRemainingMinutes() - 600) < 0.001)
    }

    // MARK: Depolama arızası

    @Test("Depo yazamıyorsa düşüm sessizce başarılı sayılmaz")
    func failingStorageSurfacesError() {
        let manager = QuotaManager(storage: FailingWriteStorage(balance: 600))
        #expect(throws: AuraError.quotaStorageUnavailable) {
            try manager.deductUsage(durationSeconds: 30)
        }
    }
}

/// Okuyabilen ama yazamayan depo — Keychain'in reddettiği durumu taklit eder.
private struct FailingWriteStorage: QuotaStorage {
    let balance: Double

    func readBalanceSeconds() -> Double? { balance }
    func writeBalanceSeconds(_ seconds: Double) -> Bool { false }
    func isBootstrapped() -> Bool { true }
    func markBootstrapped() -> Bool { false }

    // Dönem yazılamıyor: yenileme mantığının bunu sessizce yutmadığını
    // `QuotaRenewalTests.failedWriteKeepsPeriod` doğruluyor.
    func readPeriodStart() -> Date? { nil }
    func writePeriodStart(_ date: Date) -> Bool { false }
    func readPlanMinutes() -> Double? { nil }
    func writePlanMinutes(_ minutes: Double) -> Bool { false }
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

@Suite("İşleme yönlendiricisi")
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

    private func makeRouter(
        balanceSeconds: Double,
        engineOutput: ProcessingResult?
    ) -> (ProcessingRouter, QuotaManager) {
        let quota = QuotaManager(
            storage: InMemoryQuotaStorage(initialSeconds: balanceSeconds, bootstrapped: true)
        )
        let router = ProcessingRouter(
            offlineEngine: StubEngine(output: engineOutput),
            onlineEngine: StubEngine(output: engineOutput),
            quotaManager: quota
        )
        return (router, quota)
    }

    @Test("Motor hata verirse kota düşülmez")
    func failedEngineDoesNotConsumeQuota() async {
        let (router, quota) = makeRouter(balanceSeconds: 600, engineOutput: nil)

        await #expect(throws: AuraError.engineFailure("stub başarısız")) {
            _ = try await router.execute(request: dummyRequest)
        }

        #expect(abs(quota.getRemainingSeconds() - 600) < 0.001)
    }

    @Test("Başarılı işlem kotayı kayıt süresi kadar düşer")
    func successConsumesExactDuration() async throws {
        let (router, quota) = makeRouter(balanceSeconds: 600, engineOutput: stubResult)

        let result = try await router.execute(request: dummyRequest)

        #expect(abs(quota.getRemainingSeconds() - 590) < 0.001)
        #expect(abs(result.usedMinutes - (10.0 / 60.0)) < 0.0001)
        // Şablondaki `now - now` hatasının geri gelmediğini doğrular.
        #expect(result.processingTimeSeconds > 0)
    }

    @Test("Bakiye yetersizse motor hiç çağrılmaz")
    func insufficientQuotaShortCircuits() async {
        let (router, quota) = makeRouter(balanceSeconds: 5, engineOutput: stubResult)

        await #expect(throws: AuraError.insufficientQuota(requiredSeconds: 10, availableSeconds: 5)) {
            _ = try await router.execute(request: dummyRequest)
        }

        #expect(abs(quota.getRemainingSeconds() - 5) < 0.001)
    }

    @Test("Seçilen mod doğru motora yönlenir")
    func routesToSelectedEngine() async throws {
        let quota = QuotaManager(
            storage: InMemoryQuotaStorage(initialSeconds: 600, bootstrapped: true)
        )
        let onlineOnly = ProcessingResult(
            rawTranscript: "bulut",
            summaryMarkdown: "bulut",
            detectedLanguage: "tr",
            usedMinutes: 0,
            processingTimeSeconds: 0
        )
        let router = ProcessingRouter(
            offlineEngine: StubEngine(output: nil),      // offline seçilirse hata verir
            onlineEngine: StubEngine(output: onlineOnly),
            quotaManager: quota
        )

        let request = ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura-test.wav"),
            durationSeconds: 10,
            mode: .onlineCloudFast,
            summaryTemplate: .quickNotes
        )

        let result = try await router.execute(request: request)
        #expect(result.rawTranscript == "bulut")
    }
}
