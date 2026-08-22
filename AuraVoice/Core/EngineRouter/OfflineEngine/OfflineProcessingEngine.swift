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

    public init(
        transcriber: any SpeechTranscriber = WhisperKitEngine(),
        summarizer: any LocalSummarizer = ExtractiveSummarizer(),
        speakerLabeler: SpeakerLabeler = .makeDefault()
    ) {
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.speakerLabeler = speakerLabeler
    }

    public func process(request: ProcessingRequest) async throws -> ProcessingResult {

        let transcription = try await transcriber.transcribe(
            audioURL: request.audioFileURL,
            languageHint: nil,
            progress: nil
        )

        // Konuşmacı etiketleme başarısız olursa segmentler etiketsiz döner.
        let segments = await speakerLabeler.label(
            transcription.segments,
            audioURL: request.audioFileURL
        )

        let summary = try await summarizer.summarize(
            SummarizationInput(
                transcript: transcription.text,
                segments: segments,
                template: request.summaryTemplate,
                language: transcription.language,
                durationSeconds: request.durationSeconds
            )
        )

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
