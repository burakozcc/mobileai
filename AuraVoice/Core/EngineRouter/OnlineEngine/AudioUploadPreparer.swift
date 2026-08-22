//
//  AudioUploadPreparer.swift
//  AuraVoice
//
//  Kaydı bulut ASR'ye yüklenebilir hale getirir.
//
//  NEDEN GEREKLİ: Kayıt 16 kHz / 16-bit mono sıkıştırılmamış PCM WAV, yani
//  saniyede ~32 KB. Sağlayıcı sınırı 25 MB olduğu için ~13 dakikadan uzun her
//  toplantı online modda reddedilirdi — ki toplantıların çoğu 13 dakikadan
//  uzun. Çözüm iki katmanlı:
//
//    1. Yüklemeden önce AAC'ye kodla (mono 16 kHz @ 32 kbps ≈ 4 KB/sn).
//       Tek başına sınırı ~13 dakikadan ~100 dakikaya çıkarıyor.
//    2. O da yetmezse `AudioUploadPlanner` ile bindirmeli parçalara böl.
//
//  Kısa kayıtlarda (sınırın altındaki WAV) hiç kodlama yapılmıyor: hem hızlı
//  hem de kayıpsız yol korunuyor.
//

import Foundation
import AVFoundation

// MARK: - Sonuç

public struct PreparedUpload: Sendable {

    public struct Part: Sendable {
        public let chunk: AudioUploadChunk
        public let fileURL: URL
        public let mimeType: String

        public init(chunk: AudioUploadChunk, fileURL: URL, mimeType: String) {
            self.chunk = chunk
            self.fileURL = fileURL
            self.mimeType = mimeType
        }
    }

    public let parts: [Part]
    /// Üretilen geçici dosyaların dizini. Kaynak dosya doğrudan kullanıldıysa nil.
    public let temporaryDirectory: URL?

    public init(parts: [Part], temporaryDirectory: URL? = nil) {
        self.parts = parts
        self.temporaryDirectory = temporaryDirectory
    }

    public var isChunked: Bool { parts.count > 1 }

    /// Yükleme bittikten sonra çağrılmalı. Kaynak kaydı ASLA silmez.
    public func discardTemporaryFiles() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

// MARK: - Sınır

public protocol AudioUploadPreparing: Sendable {
    func prepare(audioURL: URL, limitBytes: Int) async throws -> PreparedUpload
}

// MARK: - Gerçek uygulama

public struct AudioUploadPreparer: AudioUploadPreparing {

    /// Konuşma için mono 16 kHz'de fazlasıyla yeterli; Whisper bu bit hızında
    /// ölçülebilir bir doğruluk kaybı yaşamıyor.
    public static let bitRate = 32_000

    public init() {}

    public func prepare(audioURL: URL, limitBytes: Int) async throws -> PreparedUpload {

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw AuraError.engineFailure("Ses dosyası bulunamadı: \(audioURL.lastPathComponent)")
        }

        let sourceBytes = Self.byteSize(of: audioURL)

        // Zaten sığıyorsa dokunma: kodlama yok, geçici dosya yok, kayıp yok.
        if sourceBytes <= limitBytes {
            return PreparedUpload(parts: [
                PreparedUpload.Part(
                    chunk: AudioUploadChunk(index: 0, startSeconds: 0, durationSeconds: 0),
                    fileURL: audioURL,
                    mimeType: Self.mimeType(for: audioURL)
                )
            ])
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("aura-upload-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        do {
            let upload = try Self.compressAndSplit(
                audioURL: audioURL,
                limitBytes: limitBytes,
                workDirectory: workDirectory
            )
            return upload
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    // MARK: Sıkıştır, gerekirse böl

    private static func compressAndSplit(
        audioURL: URL,
        limitBytes: Int,
        workDirectory: URL
    ) throws -> PreparedUpload {

        let totalSeconds: Double
        do {
            totalSeconds = try duration(of: audioURL)
        } catch {
            // Dosya sınırın üstünde VE çözülemiyor: kullanıcının bilmesi
            // gereken şey boyut sınırı, kodek ayrıntısı değil.
            throw tooLarge(bytes: byteSize(of: audioURL), limitBytes: limitBytes)
        }

        guard totalSeconds > 0 else {
            throw AuraError.engineFailure("Kayıt boş görünüyor, yüklenecek ses yok.")
        }

        // 1. Deneme: tüm kaydı tek parça olarak sıkıştır.
        let wholeURL = workDirectory.appendingPathComponent("aura-0.m4a")
        try encodeM4A(
            source: audioURL,
            startSeconds: 0,
            durationSeconds: totalSeconds,
            destination: wholeURL
        )

        let compressedBytes = byteSize(of: wholeURL)
        if compressedBytes > 0, compressedBytes <= limitBytes {
            return PreparedUpload(
                parts: [
                    PreparedUpload.Part(
                        chunk: AudioUploadChunk(index: 0, startSeconds: 0, durationSeconds: totalSeconds),
                        fileURL: wholeURL,
                        mimeType: "audio/mp4"
                    )
                ],
                temporaryDirectory: workDirectory
            )
        }

        guard compressedBytes > 0 else {
            throw AuraError.engineFailure("Ses sıkıştırılamadı, bulut yüklemesi yapılamıyor.")
        }

        // 2. Deneme: ölçülen gerçek bit hızına göre böl. Tahmin değil, ilk
        // geçişte ölçtüğümüz değer kullanılıyor.
        try? FileManager.default.removeItem(at: wholeURL)
        let bytesPerSecond = Double(compressedBytes) / totalSeconds

        let chunks = AudioUploadPlanner.plan(
            totalSeconds: totalSeconds,
            bytesPerSecond: bytesPerSecond,
            limitBytes: limitBytes
        )

        var parts: [PreparedUpload.Part] = []
        for chunk in chunks {
            let url = workDirectory.appendingPathComponent("aura-\(chunk.index).m4a")
            try encodeM4A(
                source: audioURL,
                startSeconds: chunk.startSeconds,
                durationSeconds: chunk.durationSeconds,
                destination: url
            )

            let size = byteSize(of: url)
            guard size > 0 else {
                throw AuraError.engineFailure("Ses parçası \(chunk.index + 1) kodlanamadı.")
            }
            guard size <= limitBytes else {
                // Planlayıcının güvenlik payına rağmen aşıldıysa kodlayıcı
                // beklenmedik davranıyor; sessizce 413 yemektense açık söyle.
                throw tooLarge(bytes: size, limitBytes: limitBytes)
            }

            parts.append(PreparedUpload.Part(chunk: chunk, fileURL: url, mimeType: "audio/mp4"))
        }

        return PreparedUpload(parts: parts, temporaryDirectory: workDirectory)
    }

    // MARK: AAC kodlama

    /// Kaynağın verilen zaman aralığını AAC/m4a olarak yazar.
    static func encodeM4A(
        source: URL,
        startSeconds: Double,
        durationSeconds: Double,
        destination: URL,
        bitRate: Int = AudioUploadPreparer.bitRate
    ) throws {

        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate > 0, input.length > 0 else {
            throw AuraError.engineFailure("Ses dosyası okunamadı: \(source.lastPathComponent)")
        }

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: bitRate
        ]

        // `output` bu kapsamdan çıkınca dosyayı sonlandırıyor; boyutu okumadan
        // önce kapsamın bitmesi gerekiyor, o yüzden yazma işi burada bitiyor.
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings)
        } catch {
            // Bazı örnekleme hızlarında kodlayıcı hedef bit hızını reddediyor;
            // kendi seçtiğiyle devam etmesi, hiç yükleyememekten iyi.
            settings.removeValue(forKey: AVEncoderBitRateKey)
            output = try AVAudioFile(forWriting: destination, settings: settings)
        }

        let startFrame = AVAudioFramePosition((startSeconds * format.sampleRate).rounded())
        guard startFrame < input.length else { return }
        input.framePosition = startFrame

        let requested = AVAudioFramePosition((durationSeconds * format.sampleRate).rounded())
        var remaining = AVAudioFrameCount(max(0, min(requested, input.length - startFrame)))
        let capacity: AVAudioFrameCount = 16_384

        while remaining > 0 {
            let count = min(capacity, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw AuraError.engineFailure("Ses arabelleği ayrılamadı.")
            }
            try input.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }
    }

    // MARK: Yardımcılar

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func byteSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "audio/wav"
        }
    }

    static func tooLarge(bytes: Int, limitBytes: Int) -> AuraError {
        .audioTooLargeForCloud(
            megabytes: Double(bytes) / 1_048_576,
            limitMegabytes: Double(limitBytes) / 1_048_576
        )
    }
}

// MARK: - Test ve yedek yolu

/// Kaydı olduğu gibi geçirir; yalnızca sınırı aşarsa hata verir.
/// Testlerde ve sıkıştırmanın istenmediği durumlarda kullanılıyor.
public struct PassthroughUploadPreparer: AudioUploadPreparing {

    public init() {}

    public func prepare(audioURL: URL, limitBytes: Int) async throws -> PreparedUpload {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AuraError.engineFailure("Ses dosyası bulunamadı: \(audioURL.lastPathComponent)")
        }

        let bytes = AudioUploadPreparer.byteSize(of: audioURL)
        guard bytes <= limitBytes else {
            throw AudioUploadPreparer.tooLarge(bytes: bytes, limitBytes: limitBytes)
        }

        return PreparedUpload(parts: [
            PreparedUpload.Part(
                chunk: AudioUploadChunk(index: 0, startSeconds: 0, durationSeconds: 0),
                fileURL: audioURL,
                mimeType: AudioUploadPreparer.mimeType(for: audioURL)
            )
        ])
    }
}
