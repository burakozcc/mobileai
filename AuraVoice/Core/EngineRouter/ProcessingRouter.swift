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
        offlineEngine: any ProcessingEngineProtocol = PlaceholderOfflineEngine(),
        onlineEngine: any ProcessingEngineProtocol = PlaceholderOnlineEngine(),
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
            processingTimeSeconds: elapsed
        )
    }
}

// MARK: - Geçici Motorlar
// WhisperKitEngine / LocalLLMEngine / CloudASRClient / CloudLLMClient devreye
// girene kadar arayüzün uçtan uca çalışmasını sağlayan yer tutucular.

public struct PlaceholderOfflineEngine: ProcessingEngineProtocol {
    public init() {}

    public func process(request: ProcessingRequest) async throws -> ProcessingResult {
        try await Task.sleep(for: .seconds(1.2))
        return ProcessingResult(
            rawTranscript: "[Yerel Transkript] WhisperKit (Core ML / ANE) çıkarımı bu noktada çalışacak.",
            summaryMarkdown: """
            ### \(request.summaryTemplate.rawValue)
            _Offline · Zero-Cloud · \(AuraFormatSeconds.minutes(request.durationSeconds))_

            - Karar 1
            - Karar 2

            **Aksiyonlar**
            - [ ] Görev 1
            """,
            detectedLanguage: "tr",
            usedMinutes: request.durationSeconds / 60.0,
            processingTimeSeconds: 0
        )
    }
}

public struct PlaceholderOnlineEngine: ProcessingEngineProtocol {
    public init() {}

    public func process(request: ProcessingRequest) async throws -> ProcessingResult {
        try await Task.sleep(for: .seconds(0.8))
        return ProcessingResult(
            rawTranscript: "[Bulut Transkript] Groq whisper-large-v3 çıktısı bu noktada gelecek.",
            summaryMarkdown: """
            ### \(request.summaryTemplate.rawValue)
            _Online · Bulut · \(AuraFormatSeconds.minutes(request.durationSeconds))_

            - Stratejik nokta 1
            - Kritik çıkarım 2

            **Aksiyonlar**
            - [ ] Görev 1
            """,
            detectedLanguage: "tr",
            usedMinutes: request.durationSeconds / 60.0,
            processingTimeSeconds: 0
        )
    }
}
