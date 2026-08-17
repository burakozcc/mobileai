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
        guard available >= request.durationSeconds else {
            throw AuraError.insufficientQuota(
                requiredSeconds: request.durationSeconds,
                availableSeconds: available
            )
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let engine: any ProcessingEngineProtocol = switch request.mode {
        case .offlineZeroCloud: offlineEngine
        case .onlineCloudFast:  onlineEngine
        }

        let raw = try await engine.process(request: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Dakika yalnızca sonuç üretildikten sonra düşülür.
        try quotaManager.deductUsage(durationSeconds: request.durationSeconds)

        return ProcessingResult(
            rawTranscript: raw.rawTranscript,
            summaryMarkdown: raw.summaryMarkdown,
            detectedLanguage: raw.detectedLanguage,
            usedMinutes: request.durationSeconds / 60.0,
            processingTimeSeconds: elapsed,
            segments: raw.segments
        )
    }
}

// Her iki motor da artık gerçek: OfflineProcessingEngine (WhisperKit + cihaz
// içi özetleme) ve OnlineProcessingEngine (Groq + Anthropic).
