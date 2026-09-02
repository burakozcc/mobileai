//
//  ProcessingRouter.swift
//  AuraVoice
//
//  Kota kontrolü → motor seçimi → kota düşümü zinciri.
//
//  Şablona göre düzeltmeler:
//   • `processingTimeSeconds` artık gerçekten ölçülüyor (şablonda
//     `CFAbsoluteTimeGetCurrent() - CFAbsoluteTimeGetCurrent()` daima 0 dönüyordu).
//   • Motorlar protokol üzerinden enjekte ediliyor → WhisperKit/ExecuTorch
//     entegrasyonu bu dosyaya dokunmadan takılabilir, testte sahte motor verilebilir.
//   • Kota yalnızca başarılı işlemede düşülüyor; hata durumunda kullanıcı
//     dakikasını kaybetmiyor.
//

import Foundation

public final class ProcessingRouter: Sendable {

    /// Kota dolduğunda kaydı BİZ kapatıyoruz, ama ses o ana kadar yazılmaya
    /// devam ediyor: durdurmayı tetikleyen örneklenmiş süre ile dosyaya yazılan
    /// gerçek süre arasında birkaç yüz milisaniye fark oluşuyor. Bu fark, tam
    /// olarak kotayı doldurduğu için durdurulmuş 45 dakikalık bir toplantıyı
    /// "yetersiz kota" diye çöpe atıyordu. Tolerans o yüzden var; faturalanan
    /// süre yine de bakiyeye kırpılıyor, yani kullanıcı sahip olmadığı dakikayı
    /// hiçbir koşulda harcamıyor.
    ///
    /// 2 saniye bilinçli olarak dar: gerçek aşım ses tamponu boyutu (16 kHz'de
    /// birkaç yüz ms) artı durdurma gecikmesi kadar. Daha geniş bir tolerans,
    /// "bakiyesi yetmeyen kayıt reddedilir" kuralını anlamsızlaştırırdı.
    public static let overrunToleranceSeconds: Double = 2

    /// Faturalandırma artışı: 6 saniye (0,1 dakika).
    ///
    /// Saniye saniye faturalamak kullanıcıya anlamsız kesirler gösteriyor
    /// ("12,37 dakika kullandın"); dakikaya yuvarlamak ise 61 saniyelik bir
    /// kayıt için iki dakika almak demek. 6 saniye ikisinin ortası ve
    /// telekomda yerleşik bir birim: 55 saniyelik kayıt tam 1 dakika düşüyor.
    public static let billingIncrementSeconds: Double = 6

    /// Faturalanacak süre: yukarı yuvarlanmış, bakiyeye kırpılmış.
    static func billableSeconds(for duration: Double, available: Double) -> Double {
        guard duration > 0 else { return 0 }
        let increments = (duration / billingIncrementSeconds).rounded(.up)
        return min(increments * billingIncrementSeconds, max(0, available))
    }

    private let offlineEngine: any ProcessingEngineProtocol
    private let onlineEngine: any ProcessingEngineProtocol
    private let quotaManager: QuotaManager
    /// Cihaz içi motorun gerçekten çalışabileceği (ASR modeli kurulu) mu.
    private let isOfflineUsable: @Sendable () -> Bool
    /// Ağın kesinlikle olmadığı durum. `NWPathMonitor` bir garanti değil ipucu.
    private let isNetworkOffline: @Sendable () -> Bool

    public init(
        offlineEngine: any ProcessingEngineProtocol = OfflineProcessingEngine(),
        onlineEngine: any ProcessingEngineProtocol = OnlineProcessingEngine.makeDefault(),
        quotaManager: QuotaManager = .shared,
        isOfflineUsable: @escaping @Sendable () -> Bool = { OfflineModelManager.activeVariant() != nil },
        isNetworkOffline: @escaping @Sendable () -> Bool = { NetworkMonitor.shared.isDefinitelyOffline }
    ) {
        self.offlineEngine = offlineEngine
        self.onlineEngine = onlineEngine
        self.quotaManager = quotaManager
        self.isOfflineUsable = isOfflineUsable
        self.isNetworkOffline = isNetworkOffline
    }

    public func execute(request: ProcessingRequest) async throws -> ProcessingResult {
        try await execute(request: request, progress: nil)
    }

    public func execute(
        request: ProcessingRequest,
        progress: ProcessingProgress?
    ) async throws -> ProcessingResult {
        let available = quotaManager.getRemainingSeconds()
        guard available + Self.overrunToleranceSeconds >= request.durationSeconds else {
            throw AuraError.insufficientQuota(
                requiredSeconds: request.durationSeconds,
                availableSeconds: available
            )
        }

        // Yukarı yuvarlanıyor ve asla bakiyeyi aşmıyor.
        let billableSeconds = Self.billableSeconds(
            for: request.durationSeconds,
            available: available
        )

        let startTime = CFAbsoluteTimeGetCurrent()
        let raw = try await run(request: request, progress: progress)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Dakika yalnızca sonuç üretildikten sonra düşülür.
        try quotaManager.deductUsage(durationSeconds: billableSeconds)

        return ProcessingResult(
            rawTranscript: raw.rawTranscript,
            summaryMarkdown: raw.summaryMarkdown,
            detectedLanguage: raw.detectedLanguage,
            usedMinutes: billableSeconds / 60.0,
            processingTimeSeconds: elapsed,
            segments: raw.segments
        )
    }

    // MARK: Motor seçimi

    /// Bulut yolu çalışmazsa cihaz içi motora düşer.
    ///
    /// Neden burada: kayıt zaten alınmış ve kullanıcı sonucu bekliyor. Bulut
    /// erişilemiyorken diskte çalışır bir model dururken kaydı hataya
    /// göndermek, ürünün asıl vaadini boşa çıkarmak olurdu.
    private func run(
        request: ProcessingRequest,
        progress: ProcessingProgress?
    ) async throws -> ProcessingResult {

        guard request.mode == .onlineCloudFast else {
            return try await offlineEngine.process(request: request, progress: progress)
        }

        // Ağ kesinlikle yoksa buluta hiç uğramıyoruz: zaman aşımlarını
        // beklemenin tek sonucu kullanıcıyı yarım dakika oyalamak olurdu.
        // Bu kural KOŞULSUZ — cihaz içi model de yoksa buluta gitmek yine
        // boşuna, kullanıcının görmesi gereken şey gerçek sebep.
        if isNetworkOffline() {
            guard isOfflineUsable() else { throw AuraError.networkUnavailable }
            let result = try await offlineEngine.process(request: request, progress: progress)
            return result.appendingEngineNote(Self.offlineFallbackNote)
        }

        do {
            return try await onlineEngine.process(request: request, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Kota ve kimlik hataları yedeklenmiyor: ikisi de cihaz içi
            // motorun çözemeyeceği, kullanıcının görmesi gereken durumlar.
            guard Self.isRecoverableCloudFailure(error), isOfflineUsable() else { throw error }

            let result = try await offlineEngine.process(request: request, progress: progress)
            return result.appendingEngineNote(Self.offlineFallbackNote)
        }
    }

    static let offlineFallbackNote =
        "Buluta ulaşılamadı, bu özet cihaz içinde üretildi. Ses ve metin cihazdan çıkmadı."

    /// Cihaz içi motora düşmenin anlamlı olduğu hatalar.
    static func isRecoverableCloudFailure(_ error: any Error) -> Bool {
        if let aura = error as? AuraError {
            // `default` BİLEREK yok: yeni bir hata türü eklendiğinde bu
            // switch derleme hatası versin. Eskiden `default: return true`
            // vardı ve sayılmayan altı case'in hepsi sessizce "yedeklenebilir"
            // sayılıyordu — en kötüsü `.offlineModelMissing`, çünkü bulut yolu
            // onu bildirdiğinde router "modelim yok" diyen motoru çağırıyordu.
            switch aura {
            case .networkUnavailable, .cloudRateLimited, .audioTooLargeForCloud, .engineFailure:
                return true
            case .cloudCredentialsMissing, .cloudAuthenticationFailed, .cloudRefused,
                 .insufficientQuota, .quotaStorageUnavailable, .offlineModelMissing,
                 .diarizationModelMissing, .microphonePermissionDenied,
                 .calendarPermissionDenied, .notificationPermissionDenied,
                 .audioEngineFailure:
                // Bunlar cihaz içi motorun çözebileceği şeyler değil; yedeğe
                // düşmek kullanıcıdan gerçek sebebi saklardı.
                return false
            }
        }
        // URLError ve benzeri taşıma hataları.
        return error is URLError
    }
}

// Her iki motor da artık gerçek: OfflineProcessingEngine (WhisperKit + cihaz
// içi özetleme) ve OnlineProcessingEngine (Groq + Anthropic).
