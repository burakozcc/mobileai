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

    /// Modeli bellekten bırakır.
    ///
    /// Boru hattının bir sonraki adımı (konuşmacı ayrıştırma) kendi modelini
    /// yüklüyor ve tüm sesi belleğe alıyor. 45 dakikalık 16 kHz mono kayıt
    /// tek başına ~86 MB tampon + ~173 MB Float demek; üstüne Whisper `small`
    /// varyantının ~480 MB'ı resident kalırsa iOS uygulamayı öldürüyor ve not
    /// hiç yazılmıyordu.
    func unload() async
}

public extension SpeechTranscriber {

    func transcribe(audioURL: URL, languageHint: String? = nil) async throws -> TranscriptionOutput {
        try await transcribe(audioURL: audioURL, languageHint: languageHint, progress: nil)
    }

    /// Model tutmayan uygulamalar (testler, sahte motorlar) için no-op.
    func unload() async {}
}
