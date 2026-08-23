//
//  NetworkFallbackTests.swift
//  AuraVoiceTests
//
//  Bulut yolu çalışmadığında cihaz içi motora düşme.
//
//  Eskiden bulut hatası kaydı doğrudan `.failed` yapıyordu — diskte çalışır
//  bir model dururken. Uçak modundaki kullanıcı 45 dakika kaydedip hiçbir şey
//  alamıyordu.
//

import Testing
import Foundation
@testable import AuraVoice

// MARK: - Sahte motorlar

private struct RecordingEngine: ProcessingEngineProtocol {

    let summary: String
    /// `any Error` yerine somut tip: protokol `Sendable` ve `Error`'ın
    /// Sendable'a rafine edilip edilmediği derleyici sürümüne göre değişiyor.
    let failure: AuraError?
    let calls: CallCounter

    init(summary: String, failure: AuraError? = nil, calls: CallCounter = CallCounter()) {
        self.summary = summary
        self.failure = failure
        self.calls = calls
    }

    func process(request: ProcessingRequest) async throws -> ProcessingResult {
        calls.increment()
        if let failure { throw failure }
        return ProcessingResult(
            rawTranscript: "metin",
            summaryMarkdown: summary,
            detectedLanguage: "tr",
            usedMinutes: 0,
            processingTimeSeconds: 0
        )
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private func makeRequest(mode: ProcessingMode = .onlineCloudFast) -> ProcessingRequest {
    ProcessingRequest(
        audioFileURL: URL(fileURLWithPath: "/tmp/aura-fallback.wav"),
        durationSeconds: 300,
        mode: mode,
        summaryTemplate: .meetingNotes
    )
}

private func makeQuota() -> QuotaManager {
    QuotaManager(storage: InMemoryQuotaStorage(initialSeconds: 3_600, bootstrapped: true))
}

// MARK: - Erişilebilirlik

@Suite("Ağ durumu")
struct NetworkReachabilityTests {

    @Test("Yalnızca ulaşılamaz durum kesin offline sayılıyor", arguments: zip(
        [NetworkReachability.reachable, .unreachable, .unknown],
        [false, true, false]
    ))
    func definiteOffline(state: NetworkReachability, expected: Bool) {
        // `.unknown` engellemiyor: ilk yol raporu gelmeden kullanıcıyı
        // "bağlantı yok" diye durdurmak yanlış olurdu.
        #expect(state.isDefinitelyOffline == expected)
    }
}

// MARK: - Yedeğe düşme

@Suite("Bulut yedeği", .serialized)
struct CloudFallbackTests {

    private func makeRouter(
        online: RecordingEngine,
        offline: RecordingEngine,
        offlineUsable: Bool = true,
        networkOffline: Bool = false
    ) -> (ProcessingRouter, QuotaManager) {
        let quota = makeQuota()
        let router = ProcessingRouter(
            offlineEngine: offline,
            onlineEngine: online,
            quotaManager: quota,
            isOfflineUsable: { offlineUsable },
            isNetworkOffline: { networkOffline }
        )
        return (router, quota)
    }

    @Test("Ağ kesinlikle yokken buluta hiç gidilmiyor")
    func skipsCloudWhenDefinitelyOffline() async throws {
        // Zaman aşımını beklemenin tek sonucu kullanıcıyı oyalamak olurdu.
        let cloudCalls = CallCounter()
        let online = RecordingEngine(summary: "### Bulut\n- madde", calls: cloudCalls)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline, networkOffline: true)

        let result = try await router.execute(request: makeRequest())

        #expect(cloudCalls.count == 0)
        #expect(result.summaryMarkdown.contains("Cihaz"))
        #expect(result.summaryMarkdown.contains("**Not**"))
    }

    @Test("Taşıma hatasında cihaz içine düşülüyor")
    func fallsBackOnTransportFailure() async throws {
        let online = RecordingEngine(summary: "", failure: AuraError.networkUnavailable)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline)

        let result = try await router.execute(request: makeRequest())
        #expect(result.summaryMarkdown.contains("Cihaz"))
    }

    @Test("Yedeğe düşüldüğü kullanıcıdan gizlenmiyor")
    func fallbackIsVisibleToUser() async throws {
        let online = RecordingEngine(summary: "", failure: AuraError.networkUnavailable)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline)

        let result = try await router.execute(request: makeRequest())
        let document = SummaryDocument.parse(result.summaryMarkdown)

        // Not gerçek bir bölüm olarak görünüyor; meta satırı hiçbir görünümde
        // render edilmiyor, oraya yazmak gizlemek olurdu.
        #expect(document.sections.contains { $0.title == "Not" })
    }

    @Test("Kimlik hatası yedeklenmiyor")
    func authenticationFailureIsNotMasked() async {
        // Cihaz içi motorun çözemeyeceği bir durum; sessizce yedeğe düşmek
        // kullanıcıdan gerçek sebebi saklardı.
        let online = RecordingEngine(summary: "", failure: AuraError.cloudAuthenticationFailed(provider: "Groq"))
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline)

        await #expect(throws: AuraError.cloudAuthenticationFailed(provider: "Groq")) {
            _ = try await router.execute(request: makeRequest())
        }
    }

    @Test("Anahtar eksikse yedeklenmiyor")
    func missingCredentialsAreNotMasked() async {
        let online = RecordingEngine(summary: "", failure: AuraError.cloudCredentialsMissing(provider: "Groq"))
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline)

        await #expect(throws: AuraError.cloudCredentialsMissing(provider: "Groq")) {
            _ = try await router.execute(request: makeRequest())
        }
    }

    @Test("Cihaz içi model yoksa gerçek hata yukarı çıkıyor")
    func withoutLocalModelErrorSurfaces() async {
        let online = RecordingEngine(summary: "", failure: AuraError.networkUnavailable)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline, offlineUsable: false)

        await #expect(throws: AuraError.networkUnavailable) {
            _ = try await router.execute(request: makeRequest())
        }
    }

    @Test("Ağ yok ve model yoksa buluta hiç gidilmiyor")
    func offlineWithoutModelSkipsCloudEntirely() async {
        // Eskiden bu köşe buluta düşüyordu: kural `isNetworkOffline() &&
        // isOfflineUsable()` ile VE'liydi ve kullanıcı, ortadan kaldırmak için
        // yazılan 30 saniyelik zaman aşımını yine bekliyordu.
        let cloudCalls = CallCounter()
        let online = RecordingEngine(summary: "### Bulut", calls: cloudCalls)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(
            online: online, offline: offline,
            offlineUsable: false, networkOffline: true
        )

        await #expect(throws: AuraError.networkUnavailable) {
            _ = try await router.execute(request: makeRequest())
        }
        #expect(cloudCalls.count == 0)
    }

    @Test("Offline mod buluta hiç uğramıyor")
    func offlineModeNeverTouchesCloud() async throws {
        let cloudCalls = CallCounter()
        let online = RecordingEngine(summary: "### Bulut", calls: cloudCalls)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline)

        let result = try await router.execute(request: makeRequest(mode: .offlineZeroCloud))

        #expect(cloudCalls.count == 0)
        // Zaten cihaz içi seçilmişken "cihaz içine düşüldü" notu gürültü olurdu.
        #expect(!result.summaryMarkdown.contains("**Not**"))
    }

    @Test("Bulut çalışıyorsa not eklenmiyor")
    func successfulCloudRunIsUnannotated() async throws {
        let online = RecordingEngine(summary: "### Bulut\n- madde")
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, _) = makeRouter(online: online, offline: offline)

        let result = try await router.execute(request: makeRequest())
        #expect(result.summaryMarkdown == "### Bulut\n- madde")
    }

    @Test("Yedek yolunda da kota düşülüyor")
    func fallbackStillConsumesQuota() async throws {
        let online = RecordingEngine(summary: "", failure: AuraError.networkUnavailable)
        let offline = RecordingEngine(summary: "### Cihaz\n- madde")
        let (router, quota) = makeRouter(online: online, offline: offline)

        _ = try await router.execute(request: makeRequest())
        #expect(quota.getRemainingSeconds() == 3_300)
    }
}

// MARK: - Hata sınıflandırma

@Suite("Yedeklenebilir bulut hataları")
struct RecoverableCloudFailureTests {

    @Test("Taşıma ve geçici hatalar yedeklenebilir")
    func transientFailuresAreRecoverable() {
        #expect(ProcessingRouter.isRecoverableCloudFailure(AuraError.networkUnavailable))
        #expect(ProcessingRouter.isRecoverableCloudFailure(AuraError.cloudRateLimited(provider: "Groq")))
        #expect(ProcessingRouter.isRecoverableCloudFailure(URLError(.notConnectedToInternet)))
    }

    @Test("Sınırı aşan ses cihaz içinde işlenebilir")
    func oversizedAudioIsRecoverable() {
        // Bulut 25 MB'ı reddediyor ama cihaz içi motorun böyle bir sınırı yok.
        #expect(ProcessingRouter.isRecoverableCloudFailure(
            AuraError.audioTooLargeForCloud(megabytes: 40, limitMegabytes: 25)
        ))
    }

    @Test("Kimlik ve kota hataları yedeklenemez")
    func permanentFailuresAreNotRecoverable() {
        #expect(!ProcessingRouter.isRecoverableCloudFailure(AuraError.cloudCredentialsMissing(provider: "Groq")))
        #expect(!ProcessingRouter.isRecoverableCloudFailure(AuraError.cloudAuthenticationFailed(provider: "Groq")))
        #expect(!ProcessingRouter.isRecoverableCloudFailure(AuraError.insufficientQuota(requiredSeconds: 60, availableSeconds: 0)))
    }

    @Test("Cihaz içi model eksikliği yedeklenemez")
    func missingLocalModelIsNotRecoverable() {
        // Eskiden `default: return true` vardı ve bulut yolu bunu
        // bildirdiğinde router "modelim yok" diyen motoru çağırıyordu.
        #expect(!ProcessingRouter.isRecoverableCloudFailure(AuraError.offlineModelMissing))
    }

    @Test("Sağlayıcı reddi yedeklenemez")
    func refusalIsNotRecoverable() {
        // Cihaz içi motor bunu "çözmüyor"; kullanıcının sebebi bilmesi gerek.
        #expect(!ProcessingRouter.isRecoverableCloudFailure(AuraError.cloudRefused(category: "policy")))
    }
}
