//
//  CloudASRClient.swift
//  AuraVoice
//
//  Bulut transkripsiyon — Groq (OpenAI uyumlu `audio/transcriptions` uç noktası).
//  Whisper-large-v3, cihaz içi çıkarımdan belirgin şekilde hızlı.
//
//  BOYUT SINIRI: Uç nokta yüklemeyi sınırlar ve kaydımız sıkıştırılmamış PCM
//  WAV (16 kHz mono ≈ 32 KB/sn). Yani ~13 dakikadan uzun kayıtlar sınırı aşar.
//  Şimdilik açık bir hata veriyoruz; parçalama (chunking) ve yükleme öncesi
//  sıkıştırma bir sonraki adımda eklenecek — sessizce başarısız olmasın.
//

import Foundation

public struct CloudASRClient: Sendable {

    public enum Model: String, Sendable {
        case whisperLargeV3 = "whisper-large-v3"
        case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    }

    /// Sağlayıcı yükleme sınırı.
    public static let maxUploadBytes = 25 * 1024 * 1024

    private let builder: CloudRequestBuilder
    private let session: URLSession
    private let model: Model

    public init(
        builder: CloudRequestBuilder,
        model: Model = .whisperLargeV3,
        session: URLSession = .shared
    ) {
        self.builder = builder
        self.model = model
        self.session = session
    }

    public var isConfigured: Bool {
        builder.hasCredentials(for: .groq)
    }

    // MARK: Transkripsiyon

    public func transcribe(
        audioURL: URL,
        languageHint: String?
    ) async throws -> TranscriptionOutput {

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AuraError.engineFailure("Ses dosyası bulunamadı: \(audioURL.lastPathComponent)")
        }

        let audioData = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        guard audioData.count <= Self.maxUploadBytes else {
            throw AuraError.audioTooLargeForCloud(
                megabytes: Double(audioData.count) / 1_048_576,
                limitMegabytes: Double(Self.maxUploadBytes) / 1_048_576
            )
        }

        var fields: [String: String] = [
            "model": model.rawValue,
            // Segment ve zaman damgası almak için düz metin yerine verbose_json.
            "response_format": "verbose_json"
        ]
        if let languageHint, !languageHint.isEmpty {
            fields["language"] = languageHint
        }

        let boundary = "AuraVoice-\(UUID().uuidString)"
        let body = Self.multipartBody(
            boundary: boundary,
            fields: fields,
            fileField: "file",
            fileName: audioURL.lastPathComponent,
            mimeType: "audio/wav",
            fileData: audioData
        )

        let request = try builder.makeRequest(
            provider: .groq,
            path: "v1/audio/transcriptions",
            body: body,
            extraHeaders: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        )

        let data = try await CloudHTTP.perform(request, session: session, provider: "Groq")
        return try Self.parse(data)
    }

    // MARK: Yanıt çözümleme

    private struct VerboseTranscription: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
        }
        let text: String?
        let language: String?
        let segments: [Segment]?
    }

    static func parse(_ data: Data) throws -> TranscriptionOutput {
        let decoded: VerboseTranscription
        do {
            decoded = try JSONDecoder().decode(VerboseTranscription.self, from: data)
        } catch {
            throw AuraError.engineFailure("Groq yanıtı çözümlenemedi: \(error.localizedDescription)")
        }

        let segments: [TranscriptSegment] = (decoded.segments ?? []).compactMap { segment in
            let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                startSeconds: segment.start ?? 0,
                endSeconds: segment.end ?? (segment.start ?? 0),
                text: text
            )
        }
        .sorted { $0.startSeconds < $1.startSeconds }

        let language = Self.normalizeLanguage(decoded.language)
        let text = (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            guard !segments.isEmpty else {
                throw AuraError.engineFailure("Transkript boş döndü — kayıtta konuşma algılanmadı.")
            }
            return .joining(segments: segments, language: language)
        }
        return TranscriptionOutput(text: text, segments: segments, language: language)
    }

    /// Whisper dili bazen tam adıyla döner ("turkish"); ISO 639-1'e indirger.
    static func normalizeLanguage(_ raw: String?) -> String {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return "" }
        if raw.count == 2 { return raw }
        let names: [String: String] = [
            "turkish": "tr", "english": "en", "german": "de", "french": "fr",
            "spanish": "es", "italian": "it", "russian": "ru", "arabic": "ar",
            "dutch": "nl", "portuguese": "pt"
        ]
        return names[raw] ?? String(raw.prefix(2))
    }

    // MARK: Multipart

    static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileField: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        let newline = "\r\n"

        // Alan sırası deterministik olsun (test edilebilirlik).
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            body.append("--\(boundary)\(newline)")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(newline)\(newline)")
            body.append("\(value)\(newline)")
        }

        body.append("--\(boundary)\(newline)")
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\(newline)")
        body.append("Content-Type: \(mimeType)\(newline)\(newline)")
        body.append(fileData)
        body.append(newline)
        body.append("--\(boundary)--\(newline)")

        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
