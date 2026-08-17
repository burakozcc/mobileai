//
//  SpeechTranscriber.swift
//  AuraVoice
//
//  ASR sınırı. WhisperKit'e özgü hiçbir tip bu protokolden dışarı sızmaz;
//  böylece paket API'si değiştiğinde yalnızca `WhisperKitEngine.swift`
//  güncellenir, geri kalan boru hattı ve testler etkilenmez.
//

import Foundation

public struct TranscriptionOutput: Sendable {

    public let text: String
    public let segments: [TranscriptSegment]
    /// ISO 639-1 kodu ("tr", "en"). Tespit edilemezse boş string.
    public let language: String

    public init(text: String, segments: [TranscriptSegment], language: String) {
        self.text = text
        self.segments = segments
        self.language = language
    }

    /// Segmentlerden düz metin üretir (motor tam metni vermediğinde yedek).
    public static func joining(segments: [TranscriptSegment], language: String) -> TranscriptionOutput {
        let text = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return TranscriptionOutput(text: text, segments: segments, language: language)
    }
}

/// İlerleme bildirimi 0...1 aralığında gelir.
public typealias TranscriptionProgress = @Sendable (Double) -> Void

public protocol SpeechTranscriber: Sendable {

    /// Modelin kullanıma hazır olup olmadığı (indirilmiş + yüklenebilir).
    var isAvailable: Bool { get async }

    /// Modeli belleğe yükler. Kayıt başlamadan çağrılırsa ilk transkripsiyon
    /// gecikmesi ortadan kalkar.
    func prepare() async throws

    func transcribe(
        audioURL: URL,
        languageHint: String?,
        progress: TranscriptionProgress?
    ) async throws -> TranscriptionOutput
}

public extension SpeechTranscriber {
    func transcribe(audioURL: URL, languageHint: String? = nil) async throws -> TranscriptionOutput {
        try await transcribe(audioURL: audioURL, languageHint: languageHint, progress: nil)
    }
}
