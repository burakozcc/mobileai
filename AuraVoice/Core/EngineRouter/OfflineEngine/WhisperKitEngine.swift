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
// WhisperKit henüz strict concurrency benimsemedi: `WhisperKit` sınıfı Sendable
// değil, dolayısıyla aktörde tutulan örneği nonisolated bir async metoda
// göndermek hata veriyor. `@preconcurrency`, bu modülden gelen Sendable
// kaynaklı hataları uyarıya indirir. Erişim zaten aktörle serileştirildiği için
// gerçek bir yarış riski yok — aynı anda tek transkripsiyon çalışır.
@preconcurrency import WhisperKit

public actor WhisperKitEngine: SpeechTranscriber {

    /// Model varyantları.
    ///
    /// Boyutlar Hugging Face API'sinin bildirdiği GERÇEK dosya toplamlarıdır,
    /// tahmin değil (`argmaxinc/whisperkit-coreml` ağaç uç noktası).
    ///
    /// Türkçe için varsayılan `largeV3Turbo`. Whisper makalesindeki (arXiv
    /// 2212.04356) Türkçe WER'leri bu tercihi taşıyor — Fleurs: base 27,5 /
    /// small 15,9 / large-v2 8,4. `small`'dan large sınıfına geçiş Türkçe
    /// hatayı yarıdan fazla düşürüyor, ki şive ve özel isim yoğun toplantı
    /// kaydında fark birebir hissediliyor.
    public enum Variant: String, Sendable, CaseIterable {

        case tiny = "openai_whisper-tiny"
        case base = "openai_whisper-base"
        case small = "openai_whisper-small"
        /// OpenAI large-v3-turbo (2024-09-30), Argmax'ın sıkıştırdığı Core ML
        /// sürümü. rawValue TAM klasör adı olmak zorunda: `WhisperKit.download`
        /// `"*\(variant)/*"` glob'uyla arıyor ve birden çok eşleşmede hata veriyor.
        case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"

        /// Yaklaşık indirme boyutu (kullanıcıya gösterilir).
        public var approximateMegabytes: Int {
            switch self {
            case .tiny:         return 77
            case .base:         return 147
            case .small:        return 487
            case .largeV3Turbo: return 627
            }
        }

        public var displayName: String {
            switch self {
            case .tiny:         return String(localized: "Hızlı (küçük)")
            case .base:         return String(localized: "Dengeli")
            case .small:        return String(localized: "Yüksek doğruluk")
            case .largeV3Turbo: return String(localized: "En yüksek doğruluk")
            }
        }

        public var subtitle: String {
            switch self {
            // DİL-NÖTR: eskiden "İyi Türkçe" / "Türkçe için önerilen" diyordu.
            // Uygulama sekiz dilde yayınlanıyor; o iddia diğer yedide yanlış
            // olurdu. Doğruluk farkı zaten dilden bağımsız geçerli.
            case .tiny:         return String(localized: "En hızlı, en düşük doğruluk")
            case .base:         return String(localized: "Küçük cihazlar için denge")
            case .small:        return String(localized: "Dengeli doğruluk, orta boyut")
            case .largeV3Turbo: return String(localized: "Önerilen — şive ve özel isimlerde belirgin fark")
            }
        }

        /// WhisperKit'in vocab boyutundan tespit ettiği tokenizer deposu.
        /// large-v3 ailesi 51866 vocab kullanıyor, diğerleri 51865.
        public var tokenizerRepoID: String {
            switch self {
            case .tiny:         return "openai/whisper-tiny"
            case .base:         return "openai/whisper-base"
            case .small:        return "openai/whisper-small"
            case .largeV3Turbo: return "openai/whisper-large-v3"
            }
        }

        // MARK: Seçim politikası

        /// Verilen kümedeki en iyi varyant.
        ///
        /// Saf fonksiyon — testler bunu çağırıyor, cihaz sorgusunu değil:
        /// simülatörde WhisperKit host Mac'i bildiriyor ve eşleşmeyen cihaz
        /// kimliğinde TÜM modelleri "destekleniyor" sayıyor, dolayısıyla
        /// gerçek cihaz kapısı CI'da hiç sınanamıyor.
        public static func best(from candidates: Set<String>) -> Variant {
            [Variant.largeV3Turbo, .small, .base, .tiny]
                .first { candidates.contains($0.rawValue) } ?? .base
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
            throw AuraError.engineFailure(String(localized: "Ses dosyası bulunamadı: \(audioURL.lastPathComponent)"))
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
            throw AuraError.engineFailure(String(localized: "Cihaz içi transkripsiyon başarısız: \(error.localizedDescription)"))
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

        // `download: false` YALNIZCA Core ML ağırlıklarını kapsıyor. Tokenizer
        // yükleme anında ayrı bir yoldan Hugging Face'ten çekiliyor ve
        // `tokenizerFolder` verilmezse `?? downloadBase` de nil olduğu için
        // HubApi varsayılanına düşüyor — yani model diskte dururken bile uçak
        // modunda yükleme patlıyordu. Asıl düzeltme bu satır.
        guard let tokenizerRoot = BundledTokenizers.root else {
            // BİLEREK ÇEVRİLMİYOR: bu bir derleme yapılandırması hatası, kullanıcı
            // durumu değil. Doğru paketlenmiş bir uygulamada hiç oluşamaz ve
            // içeriği (dosya yolu + project.yml direktifi) geliştiriciye hitap
            // ediyor. Sekiz dile çevirmek anlamsız olurdu.
            throw AuraError.engineFailure(
                "Paketlenmiş tokenizer bulunamadı: AuraVoice/Resources/Tokenizers "
                + "uygulama paketine kopyalanmamış (project.yml'de type: folder olmalı)."
            )
        }

        // Klasör yolu kurulum kaydından geliyor; WhisperKit'in iç disk şemasına
        // bağımlı değiliz (bkz. OfflineModelManager).
        let config = WhisperKitConfig(
            model: variant.rawValue,
            modelFolder: folder.path,
            tokenizerFolder: tokenizerRoot,
            // İndirme ayrı bir akış (OfflineModelManager); burada ağ kullanmıyoruz.
            download: false
        )

        do {
            let pipeline = try await WhisperKit(config)
            self.pipeline = pipeline
            return pipeline
        } catch {
            throw AuraError.engineFailure(String(localized: "Model yüklenemedi: \(error.localizedDescription)"))
        }
    }

    /// Bellek baskısı altında modeli boşaltır (kayıt bittikten sonra çağrılabilir).
    public func unload() {
        pipeline = nil
    }
}
