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
//  Kota İKİ HAVUZLU olduktan sonra buradaki testlerin çoğu iki soruya birden
//  cevap vermek zorunda: doğru havuzdan düştü mü VE ötekine dokunmadı mı.
//  İkincisi olmadan, tek havuza geri dönmüş bir kod da testleri geçerdi.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Kota yöneticisi")
struct QuotaManagerTests {

    private func makeManager(seconds: Double) -> QuotaManager {
        QuotaManager(storage: InMemoryQuotaStorage(initialSeconds: seconds, bootstrapped: true))
    }

    @Test("İlk açılışta her havuz kendi ücretsiz dakikasını alır")
    func bootstrapGrantsFreeTierPerLane() {
        let manager = QuotaManager(storage: InMemoryQuotaStorage())
        #expect(manager.getRemainingMinutes(.offline) == QuotaManager.freeOfflineMinutes)
        #expect(manager.getRemainingMinutes(.online) == QuotaManager.freeOnlineMinutes)
    }

    @Test("Ücretsiz cihaz içi dakika buluttan fazla")
    func freeOfflineExceedsOnline() {
        // Ayrımın SEBEBİ bu: cihaz içi işlemenin bize marjinal maliyeti yok.
        // İki sayı eşitlenirse havuzları ayırmanın ürün gerekçesi kalmaz ve
        // bunu fark ettirecek başka bir test yok.
        #expect(QuotaManager.freeOfflineMinutes > QuotaManager.freeOnlineMinutes)
    }

    @Test("Hediye yalnızca bir kez verilir")
    func bootstrapIsOneShot() {
        // Bu testin ÖNCEKİ hâli hiçbir şey sınamıyordu: bakiyeyi sıfıra
        // indirip "hâlâ sıfır" diyordu. `bootstrapIfNeeded` zaten yalnızca
        // bakiye YAZILMAMIŞSA (nil) yazıyor, sıfır bakiye onu tetiklemiyor —
        // yani bayrak tamamen kırık olsa bile iddia doğru çıkardı.
        //
        // Bayrağın işini gerçekten sınayan kurulum: kurulmuş işaretli ama
        // bakiyesi hiç yazılmamış depo. Bayrak yok sayılsaydı burada hediye
        // ikinci kez verilirdi.
        let storage = InMemoryQuotaStorage(bootstrapped: true)
        let manager = QuotaManager(storage: storage)

        #expect(manager.getRemainingSeconds(.online) == 0)
        #expect(manager.getRemainingSeconds(.offline) == 0)
    }

    @Test("Bir havuzun tükenmesi ötekine dokunmuyor")
    func lanesAreIndependent() throws {
        let manager = QuotaManager(storage: InMemoryQuotaStorage())
        let offlineBefore = manager.getRemainingSeconds(.offline)

        try manager.deductUsage(durationSeconds: QuotaManager.freeOnlineMinutes * 60, lane: .online)

        #expect(manager.getRemainingSeconds(.online) == 0)
        #expect(manager.getRemainingSeconds(.offline) == offlineBefore)
    }

    @Test("Bozuk negatif bakiye sıfıra kırpılıyor", arguments: QuotaLane.allCases)
    func negativeBalanceIsClampedToZero(lane: QuotaLane) {
        // Önceki hâli sıfır bakiyeyle kuruyordu; `max(0, ...)` kırpmasına
        // negatif bir değer hiç ULAŞMIYORDU, yani kırpma silinse bile test
        // geçerdi. Depo kurucusu kırpma yapmadığı için negatif değer buradan
        // enjekte edilebiliyor — Keychain'de bozulmuş bir kayıt bunu üretir.
        let storage = InMemoryQuotaStorage(
            offlineSeconds: -500, onlineSeconds: -500, bootstrapped: true
        )
        let manager = QuotaManager(storage: storage)

        #expect(manager.getRemainingSeconds(lane) == 0)
        #expect(manager.getRemainingMinutes(lane) == 0)
    }

    @Test("Bakiyeden büyük istek reddedilir")
    func rejectsOversizedRequest() {
        let manager = makeManager(seconds: 60)
        #expect(!manager.canProcess(durationSeconds: 61, lane: .online))
        #expect(manager.canProcess(durationSeconds: 60, lane: .online))
    }

    @Test("Yetersiz bakiyede insufficientQuota fırlatır ve havuzu bildirir")
    func deductThrowsWhenInsufficient() {
        let manager = makeManager(seconds: 10)
        // Havuz hatanın PARÇASI: kullanıcıya hangi dakikanın bittiğini
        // söylemeyen bir mesaj, öteki havuzda kayda devam edebileceğini gizler.
        #expect(throws: AuraError.insufficientQuota(
            requiredSeconds: 30, availableSeconds: 10, lane: .online
        )) {
            try manager.deductUsage(durationSeconds: 30, lane: .online)
        }
    }

    @Test("Düşüm yalnızca kendi havuzunu azaltır")
    func deductReducesOnlyItsLane() throws {
        let manager = makeManager(seconds: 600)
        try manager.deductUsage(durationSeconds: 30, lane: .offline)
        #expect(abs(manager.getRemainingSeconds(.offline) - 570) < 0.001)
        #expect(abs(manager.getRemainingSeconds(.online) - 600) < 0.001)
    }

    @Test("Eklenen dakika yalnızca hedef havuza gider")
    func addMinutesTargetsOneLane() {
        let manager = makeManager(seconds: 60)
        manager.addMinutes(10, lane: .online)
        #expect(abs(manager.getRemainingSeconds(.online) - 660) < 0.001)
        #expect(abs(manager.getRemainingSeconds(.offline) - 60) < 0.001)
    }

    @Test("Plan yenilemesi iki havuzu da kendi değerine eşitler")
    func setPlanOverwritesBothLanes() {
        let manager = makeManager(seconds: 5)
        #expect(manager.setPlan(offlineMinutes: 3_000, onlineMinutes: 600))
        #expect(abs(manager.getRemainingMinutes(.offline) - 3_000) < 0.001)
        #expect(abs(manager.getRemainingMinutes(.online) - 600) < 0.001)
        #expect(manager.planMonthlyMinutes(.offline) == 3_000)
        #expect(manager.planMonthlyMinutes(.online) == 600)
    }

    // MARK: Depolama arızası

    @Test("Depo yazamıyorsa düşüm sessizce başarılı sayılmaz")
    func failingStorageSurfacesError() {
        let manager = QuotaManager(storage: FailingWriteStorage(balance: 600))
        #expect(throws: AuraError.quotaStorageUnavailable) {
            try manager.deductUsage(durationSeconds: 30, lane: .online)
        }
    }
}

/// Okuyabilen ama yazamayan depo — Keychain'in reddettiği durumu taklit eder.
private struct FailingWriteStorage: QuotaStorage {
    let balance: Double

    func readBalanceSeconds(_ lane: QuotaLane) -> Double? { balance }
    func writeBalanceSeconds(_ seconds: Double, lane: QuotaLane) -> Bool { false }
    func isBootstrapped() -> Bool { true }
    func markBootstrapped() -> Bool { false }

    // Dönem yazılamıyor: yenileme mantığının bunu sessizce yutmadığını
    // `QuotaRenewalTests.failedWriteKeepsPeriod` doğruluyor.
    func readPeriodStart() -> Date? { nil }
    func writePeriodStart(_ date: Date) -> Bool { false }
    func readPlanMinutes(_ lane: QuotaLane) -> Double? { nil }
    func writePlanMinutes(_ minutes: Double, lane: QuotaLane) -> Bool { false }
}

// MARK: - Router

private struct StubEngine: ProcessingEngineProtocol {
    let output: ProcessingResult?
    /// Çıktı yoksa fırlatılacak hata. Yedeğe düşme kuralları hatanın TÜRÜNE
    /// bakıyor, bu yüzden testin onu seçebilmesi gerekiyor.
    ///
    /// Tipi `AuraError`, `any Error` değil: motor protokolü `Sendable` ve
    /// varoluşsal `any Error` o uyumu kırıyor.
    var error: AuraError = .engineFailure("stub başarısız")

    func process(request: ProcessingRequest) async throws -> ProcessingResult {
        guard let output else { throw error }
        // Ölçülebilir bir işlem süresi oluşsun.
        try await Task.sleep(for: .milliseconds(20))
        return output
    }
}

@Suite("İşleme yönlendiricisi")
struct ProcessingRouterTests {

    private func request(
        mode: ProcessingMode = .offlineZeroCloud,
        durationSeconds: Double = 10
    ) -> ProcessingRequest {
        ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura-test.wav"),
            durationSeconds: durationSeconds,
            mode: mode,
            summaryTemplate: .meetingNotes
        )
    }

    private func result(_ transcript: String = "transkript") -> ProcessingResult {
        ProcessingResult(
            rawTranscript: transcript,
            summaryMarkdown: "### Özet\n- Madde",
            detectedLanguage: "tr",
            usedMinutes: 0,
            processingTimeSeconds: 0
        )
    }

    private func makeRouter(
        offlineSeconds: Double,
        onlineSeconds: Double,
        offlineEngine: StubEngine,
        onlineEngine: StubEngine,
        isOfflineUsable: Bool = true,
        isNetworkOffline: Bool = false
    ) -> (ProcessingRouter, QuotaManager) {
        let quota = QuotaManager(storage: InMemoryQuotaStorage(
            offlineSeconds: offlineSeconds,
            onlineSeconds: onlineSeconds,
            bootstrapped: true
        ))
        let router = ProcessingRouter(
            offlineEngine: offlineEngine,
            onlineEngine: onlineEngine,
            quotaManager: quota,
            isOfflineUsable: { isOfflineUsable },
            isNetworkOffline: { isNetworkOffline }
        )
        return (router, quota)
    }

    @Test("Motor hata verirse kota düşülmez")
    func failedEngineDoesNotConsumeQuota() async {
        let (router, quota) = makeRouter(
            offlineSeconds: 600, onlineSeconds: 600,
            offlineEngine: StubEngine(output: nil),
            onlineEngine: StubEngine(output: nil)
        )

        await #expect(throws: AuraError.engineFailure("stub başarısız")) {
            _ = try await router.execute(request: request())
        }

        #expect(abs(quota.getRemainingSeconds(.offline) - 600) < 0.001)
    }

    @Test("Başarılı işlem kotayı faturalandırma artışına yuvarlayarak düşer")
    func successConsumesBillableDuration() async throws {
        let (router, quota) = makeRouter(
            offlineSeconds: 600, onlineSeconds: 600,
            offlineEngine: StubEngine(output: result()),
            onlineEngine: StubEngine(output: nil)
        )

        let outcome = try await router.execute(request: request())

        // 10 saniyelik kayıt 6 saniyelik artışa yukarı yuvarlanıyor: 12 saniye.
        // Saniye saniye faturalamak kullanıcıya anlamsız kesirler gösteriyor,
        // dakikaya yuvarlamak ise 61 saniye için iki dakika almak demek.
        #expect(abs(quota.getRemainingSeconds(.offline) - 588) < 0.001)
        // Bulut havuzu hiç kıpırdamıyor: cihaz içi iş bize para harcatmadı.
        #expect(abs(quota.getRemainingSeconds(.online) - 600) < 0.001)
        #expect(abs(outcome.usedMinutes - (12.0 / 60.0)) < 0.0001)
        // Şablondaki `now - now` hatasının geri gelmediğini doğrular.
        #expect(outcome.processingTimeSeconds > 0)
    }

    @Test("Bulut işleme yalnızca bulut havuzundan düşer")
    func cloudRunBillsOnlineLane() async throws {
        let (router, quota) = makeRouter(
            offlineSeconds: 600, onlineSeconds: 600,
            offlineEngine: StubEngine(output: nil),
            onlineEngine: StubEngine(output: result("bulut"))
        )

        let outcome = try await router.execute(request: request(mode: .onlineCloudFast))

        #expect(outcome.rawTranscript == "bulut")
        #expect(abs(quota.getRemainingSeconds(.online) - 588) < 0.001)
        #expect(abs(quota.getRemainingSeconds(.offline) - 600) < 0.001)
    }

    @Test("Bulut havuzu boşken cihaz içi dolu olsa da bulut isteği reddedilir")
    func emptyOnlineLaneBlocksCloudRequest() async {
        // Tek havuzluyken bu ayrım yoktu; havuzları ayırdıktan sonra sızabilecek
        // en kolay hata, kapının "herhangi bir havuzda dakika var mı" diye
        // sorması olurdu.
        let (router, quota) = makeRouter(
            offlineSeconds: 6_000, onlineSeconds: 5,
            offlineEngine: StubEngine(output: result()),
            onlineEngine: StubEngine(output: result("bulut"))
        )

        await #expect(throws: AuraError.insufficientQuota(
            requiredSeconds: 10, availableSeconds: 5, lane: .online
        )) {
            _ = try await router.execute(request: request(mode: .onlineCloudFast))
        }

        #expect(abs(quota.getRemainingSeconds(.offline) - 6_000) < 0.001)
    }

    @Test("Cihaz içi havuz boşken bulut dolu olsa da Zero-Cloud isteği reddedilir")
    func emptyOfflineLaneBlocksZeroCloudRequest() async {
        let (router, _) = makeRouter(
            offlineSeconds: 5, onlineSeconds: 6_000,
            offlineEngine: StubEngine(output: result()),
            onlineEngine: StubEngine(output: result("bulut"))
        )

        await #expect(throws: AuraError.insufficientQuota(
            requiredSeconds: 10, availableSeconds: 5, lane: .offline
        )) {
            _ = try await router.execute(request: request(mode: .offlineZeroCloud))
        }
    }

    // MARK: Yedeğe düşme faturası

    @Test("Cihaz içi motora düşen bulut isteği CİHAZ İÇİ havuzdan düşer")
    func fallbackBillsOfflineLane() async throws {
        // İşin bize maliyeti sağlayıcıya gitmediyse sıfır; bulut dakikasını
        // almak kullanıcıdan yapılmamış bir masrafı tahsil etmek olurdu.
        let (router, quota) = makeRouter(
            offlineSeconds: 600, onlineSeconds: 600,
            offlineEngine: StubEngine(output: result("cihaz içi")),
            onlineEngine: StubEngine(output: nil, error: AuraError.cloudRateLimited(provider: "Groq"))
        )

        let outcome = try await router.execute(request: request(mode: .onlineCloudFast))

        #expect(outcome.rawTranscript == "cihaz içi")
        #expect(abs(quota.getRemainingSeconds(.offline) - 588) < 0.001)
        #expect(abs(quota.getRemainingSeconds(.online) - 600) < 0.001)
    }

    @Test("Cihaz içi havuz boşsa yedeğe düşülmez, bulut hatası yükselir")
    func emptyOfflineLaneBlocksFallback() async {
        // Kullanıcının GÖRDÜĞÜ sebep, isteğini gerçekten başarısız kılan sebep
        // olmalı; sessizce cihaz içi havuzu eksiye götürmek ya da alakasız bir
        // kota hatası göstermek ikisi de yanlış olurdu.
        let (router, quota) = makeRouter(
            offlineSeconds: 3, onlineSeconds: 600,
            offlineEngine: StubEngine(output: result("cihaz içi")),
            onlineEngine: StubEngine(output: nil, error: AuraError.cloudRateLimited(provider: "Groq"))
        )

        await #expect(throws: AuraError.cloudRateLimited(provider: "Groq")) {
            _ = try await router.execute(request: request(mode: .onlineCloudFast))
        }

        #expect(abs(quota.getRemainingSeconds(.offline) - 3) < 0.001)
        #expect(abs(quota.getRemainingSeconds(.online) - 600) < 0.001)
    }

    @Test("Ağ yokken cihaz içi havuz boşsa networkUnavailable dönüyor")
    func offlineNetworkWithEmptyOfflineLane() async {
        // Bulut dakikası duruyor: ağ geldiğinde istek olduğu gibi çalışacak,
        // yani kullanıcının önündeki gerçek engel ağ. `insufficientQuota`
        // demek, çözümü kota satın almak sanmasına yol açardı.
        let (router, _) = makeRouter(
            offlineSeconds: 3, onlineSeconds: 600,
            offlineEngine: StubEngine(output: result("cihaz içi")),
            onlineEngine: StubEngine(output: result("bulut")),
            isNetworkOffline: true
        )

        await #expect(throws: AuraError.networkUnavailable) {
            _ = try await router.execute(request: request(mode: .onlineCloudFast))
        }
    }
}
