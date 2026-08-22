//
//  OfflineProcessingEngine.swift
//  AuraVoice
//
//  Zero-Cloud boru hattı: ses → cihaz içi ASR → cihaz içi özetleme.
//  Hiçbir adımda ağ kullanılmaz.
//

import Foundation

public struct OfflineProcessingEngine: ProcessingEngineProtocol {

    private let transcriber: any SpeechTranscriber
    private let summarizer: any LocalSummarizer
    private let speakerLabeler: SpeakerLabeler

    /// Varsayılan transcriber KURULU varyantı kullanıyor; hiçbiri kurulu
    /// değilse `.base` ile kuruluyor ve `offlineModelMissing` fırlatıyor —
    /// hazırlık kontrolü zaten kaydın başında yapılıyor.
    public init(
        transcriber: any SpeechTranscriber = WhisperKitEngine(
            variant: OfflineModelManager.activeVariant() ?? .base
        ),
        summarizer: any LocalSummarizer = ExtractiveSummarizer(),
        speakerLabeler: SpeakerLabeler = .makeDefault()
    ) {
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.speakerLabeler = speakerLabeler
    }

    public func process(request: ProcessingRequest) async throws -> ProcessingResult {
        try await process(request: request, progress: nil)
    }

    public func process(
        request: ProcessingRequest,
        progress: ProcessingProgress?
    ) async throws -> ProcessingResult {

        progress?(.transcribing, 0)
        let transcription = try await transcriber.transcribe(
            audioURL: request.audioFileURL,
            languageHint: nil,
            progress: { value in progress?(.transcribing, value) }
        )
        try Task.checkCancellation()

        // ASR modelini burada bırakıyoruz. Sıradaki adım kendi modelini
        // yüklüyor ve tüm sesi belleğe alıyor; ikisi aynı anda resident
        // olduğunda uzun kayıtlarda iOS uygulamayı öldürüyordu.
        await transcriber.unload()

        progress?(.diarizing, 0)
        // Konuşmacı etiketleme başarısız olursa segmentler etiketsiz döner.
        let segments = await speakerLabeler.label(
            transcription.segments,
            audioURL: request.audioFileURL
        )
        progress?(.diarizing, 1)
        try Task.checkCancellation()

        progress?(.summarizing, 0)
        let summary = try await summarizer.summarize(
            SummarizationInput(
                transcript: transcription.text,
                segments: segments,
                template: request.summaryTemplate,
                language: transcription.language,
                durationSeconds: request.durationSeconds
            )
        )
        progress?(.summarizing, 1)

        return ProcessingResult(
            rawTranscript: transcription.text,
            summaryMarkdown: summary,
            detectedLanguage: transcription.language.isEmpty ? "tr" : transcription.language,
            usedMinutes: request.durationSeconds / 60.0,
            processingTimeSeconds: 0, // ProcessingRouter gerçek süreyi ölçüp yazar
            segments: segments
        )
    }
}
