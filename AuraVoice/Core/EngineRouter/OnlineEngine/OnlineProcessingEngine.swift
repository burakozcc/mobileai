//
//  OnlineProcessingEngine.swift
//  AuraVoice
//
//  Bulut boru hattı: ses → Groq Whisper → Anthropic özetleme.
//
//  Offline motorla aynı `ProcessingEngineProtocol` yüzeyini uygular, böylece
//  ProcessingRouter ikisini ayırt etmek zorunda kalmaz.
//

import Foundation

public struct OnlineProcessingEngine: ProcessingEngineProtocol {

    private let asr: CloudASRClient
    private let llm: CloudLLMClient
    /// Bulut özetleme başarısız olursa cihaz içi çıkarımsal özetleyiciye düş.
    private let fallbackSummarizer: (any LocalSummarizer)?

    public init(
        asr: CloudASRClient,
        llm: CloudLLMClient,
        fallbackSummarizer: (any LocalSummarizer)? = ExtractiveSummarizer()
    ) {
        self.asr = asr
        self.llm = llm
        self.fallbackSummarizer = fallbackSummarizer
    }

    /// Varsayılan kurulum: proxy rotası + Keychain deposu.
    public init(route: CloudRoute, store: any CloudCredentialStore = KeychainCredentialStore()) {
        let builder = CloudRequestBuilder(route: route, store: store)
        self.init(
            asr: CloudASRClient(builder: builder),
            llm: CloudLLMClient(builder: builder)
        )
    }

    public var isConfigured: Bool {
        asr.isConfigured && llm.isConfigured
    }

    /// Uygulamanın varsayılan kurulumu.
    ///
    /// Info.plist içinde `AuraCloudProxyBaseURL` tanımlıysa proxy rotası
    /// kullanılır (üretim: anahtarlar sunucuda, kota sunucuda doğrulanır).
    /// Tanımlı değilse kullanıcının kendi anahtarına (BYOK) düşer — geliştirme
    /// ve güçlü kullanıcı senaryosu.
    public static func makeDefault(
        store: any CloudCredentialStore = KeychainCredentialStore(),
        bundle: Bundle = .main
    ) -> OnlineProcessingEngine {
        OnlineProcessingEngine(route: .makeDefault(bundle: bundle), store: store)
    }

    public func process(request: ProcessingRequest) async throws -> ProcessingResult {

        let transcription = try await asr.transcribe(
            audioURL: request.audioFileURL,
            languageHint: nil
        )

        let language = transcription.language.isEmpty ? "tr" : transcription.language

        let summary: String
        do {
            summary = try await llm.summarize(
                transcript: transcription.text,
                template: request.summaryTemplate,
                language: language,
                durationSeconds: request.durationSeconds
            )
        } catch {
            // Transkript elde edildiyse özetleme hatası yüzünden kullanıcının
            // dakikasını ve kaydını kaybetmesi kabul edilemez: cihaz içi
            // özetleyiciye düşüp notu kurtarıyoruz.
            guard let fallbackSummarizer else { throw error }

            let fallback = try await fallbackSummarizer.summarize(
                SummarizationInput(
                    transcript: transcription.text,
                    segments: transcription.segments,
                    template: request.summaryTemplate,
                    language: language,
                    durationSeconds: request.durationSeconds
                )
            )
            let reason = (error as? AuraError)?.errorDescription ?? error.localizedDescription
            summary = fallback + "\n\n_(Bulut özetleme başarısız oldu, cihaz içi özet kullanıldı: \(reason))_"
        }

        return ProcessingResult(
            rawTranscript: transcription.text,
            summaryMarkdown: summary,
            detectedLanguage: language,
            usedMinutes: request.durationSeconds / 60.0,
            processingTimeSeconds: 0, // ProcessingRouter gerçek süreyi ölçüp yazar
            segments: transcription.segments
        )
    }
}
