//
//  WhisperKitEngine.swift
//  AuraVoice
//
//  Cihaz içi ASR — WhisperKit (Core ML / Apple Neural Engine).
//  Ses ve metin cihazdan hiç çıkmaz; uçuş modunda çalışır.
//
//  WhisperKit'e dokunan TEK dosya burasıdır. Paket API'si değişirse
//  düzeltme yüzeyi bu dosyayla sınırlıdır (bkz. SpeechTranscriber).
//

import Foundation
import WhisperKit

public actor WhisperKitEngine: SpeechTranscriber {

    /// Model varyantları. Küçük cihazlarda `base`, yeni cihazlarda `small`
    /// makul kalite/hız dengesi verir.
    public enum Variant: String, Sendable, CaseIterable {
        case tiny = "openai_whisper-tiny"
        case base = "openai_whisper-base"
        case small = "openai_whisper-small"

        /// Yaklaşık indirme boyutu (kullanıcıya gösterilir).
        public var approximateMegabytes: Int {
            switch self {
            case .tiny:  return 78
            case .base:  return 145
            case .small: return 480
            }
        }

        public var displayName: String {
            switch self {
            case .tiny:  return "Hızlı (küçük)"
            case .base:  return "Dengeli"
            case .small: return "Yüksek doğruluk"
            }
        }
    }

    private let variant: Variant
    private let modelsDirectory: URL
    private var pipeline: WhisperKit?

    public init(
        variant: Variant = .base,
        modelsDirectory: URL = OfflineModelManager.modelsDirectory
    ) {
        self.variant = variant
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - SpeechTranscriber

    public var isAvailable: Bool {
        get async {
            OfflineModelManager.isDownloaded(variant: variant, in: modelsDirectory)
        }
    }

    public func prepare() async throws {
        _ = try await loadedPipeline()
    }

    public func transcribe(
        audioURL: URL,
        languageHint: String?,
        progress: TranscriptionProgress?
    ) async throws -> TranscriptionOutput {

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AuraError.engineFailure("Ses dosyası bulunamadı: \(audioURL.lastPathComponent)")
        }

        let pipeline = try await loadedPipeline()
        progress?(0.1)

        let options = DecodingOptions(
            task: .transcribe,
            language: languageHint,
            // Dil ipucu yoksa Whisper kendi tespit etsin.
            detectLanguage: languageHint == nil,
            // Varsayılan `false`; kapalı bırakılırsa metinde <|startoftranscript|>
            // gibi kontrol jetonları kalır.
            skipSpecialTokens: true,
            wordTimestamps: false
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipeline.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )
        } catch {
            throw AuraError.engineFailure("Cihaz içi transkripsiyon başarısız: \(error.localizedDescription)")
        }

        progress?(0.95)

        let segments: [TranscriptSegment] = results
            .flatMap(\.segments)
            .map { segment in
                TranscriptSegment(
                    startSeconds: Double(segment.start),
                    endSeconds: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.startSeconds < $1.startSeconds }

        let joinedText = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let detectedLanguage = results.first?.language ?? languageHint ?? ""

        progress?(1.0)

        // Bazı varyantlarda birleşik metin boş gelebiliyor; segmentlerden kur.
        guard !joinedText.isEmpty else {
            return .joining(segments: segments, language: detectedLanguage)
        }
        return TranscriptionOutput(
            text: joinedText,
            segments: segments,
            language: detectedLanguage
        )
    }

    // MARK: - Model yükleme

    private func loadedPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }

        guard let folder = OfflineModelManager.installedFolder(variant: variant, in: modelsDirectory) else {
            throw AuraError.offlineModelMissing
        }

        // Klasör yolu kurulum kaydından geliyor; WhisperKit'in iç disk şemasına
        // bağımlı değiliz (bkz. OfflineModelManager).
        let config = WhisperKitConfig(
            model: variant.rawValue,
            modelFolder: folder.path,
            // İndirme ayrı bir akış (OfflineModelManager); burada ağ kullanmıyoruz.
            download: false
        )

        do {
            let pipeline = try await WhisperKit(config)
            self.pipeline = pipeline
            return pipeline
        } catch {
            throw AuraError.engineFailure("Model yüklenemedi: \(error.localizedDescription)")
        }
    }

    /// Bellek baskısı altında modeli boşaltır (kayıt bittikten sonra çağrılabilir).
    public func unload() {
        pipeline = nil
    }
}
