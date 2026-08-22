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

    private let offlineEngine: any ProcessingEngineProtocol
    private let onlineEngine: any ProcessingEngineProtocol
    private let quotaManager: QuotaManager

    public init(
        offlineEngine: any ProcessingEngineProtocol = OfflineProcessingEngine(),
        onlineEngine: any ProcessingEngineProtocol = OnlineProcessingEngine.makeDefault(),
        quotaManager: QuotaManager = .shared
    ) {
        self.offlineEngine = offlineEngine
        self.onlineEngine = onlineEngine
        self.quotaManager = quotaManager
    }

    public func execute(request: ProcessingRequest) async throws -> ProcessingResult {
        let available = quotaManager.getRemainingSeconds()
        guard available + Self.overrunToleranceSeconds >= request.durationSeconds else {
            throw AuraError.insufficientQuota(
                requiredSeconds: request.durationSeconds,
                availableSeconds: available
            )
        }

        // Faturalanabilir süre asla bakiyeyi aşmıyor.
        let billableSeconds = min(request.durationSeconds, available)

        let startTime = CFAbsoluteTimeGetCurrent()
        let engine: any ProcessingEngineProtocol = switch request.mode {
        case .offlineZeroCloud: offlineEngine
        case .onlineCloudFast:  onlineEngine
        }

        let raw = try await engine.process(request: request)
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
}

// Her iki motor da artık gerçek: OfflineProcessingEngine (WhisperKit + cihaz
// içi özetleme) ve OnlineProcessingEngine (Groq + Anthropic).
