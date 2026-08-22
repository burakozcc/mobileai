//
//  SpeakerKitDiarizer.swift
//  AuraVoice
//
//  Cihaz içi konuşmacı ayrıştırma — SpeakerKit (Pyannote v4, Core ML / ANE).
//
//  SpeakerKit zaten bağımlı olduğumuz `argmax-oss-swift` paketinin bir ürünü,
//  yani yeni bir bağımlılık eklemiyoruz.
//
//  Bu dosya SpeakerKit'e dokunan TEK yerdir. Birleştirme mantığı
//  `SpeakerAssignment` içinde ve paketten bağımsız; paket API'si değişirse
//  düzeltme yüzeyi buradan ibaret kalır.
//
//  Ses okuma da kasıtlı olarak kendi kodumuz: kaydımız zaten 16 kHz mono
//  (Pyannote'un beklediği format), dolayısıyla paketin yükleyicisine bağımlı
//  olmaya gerek yok.
//

import Foundation
import AVFoundation
// Bkz. WhisperKitEngine.swift — paket strict concurrency benimsemedi.
@preconcurrency import SpeakerKit

public actor SpeakerKitDiarizer: SpeakerDiarizer {

    private var engine: SpeakerKit?
    private let expectedSpeakerCount: Int?

    /// - Parameter expectedSpeakerCount: Biliniyorsa konuşmacı sayısı
    ///   (örneğin telefon görüşmesi = 2). `nil` ise model kendi belirler.
    public init(expectedSpeakerCount: Int? = nil) {
        self.expectedSpeakerCount = expectedSpeakerCount
    }

    public var isAvailable: Bool {
        get async { OfflineModelManager.isDiarizationInstalled() }
    }

    public func diarize(
        audioURL: URL,
        progress: DiarizationProgress?
    ) async throws -> DiarizationOutput {

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AuraError.engineFailure("Ses dosyası bulunamadı: \(audioURL.lastPathComponent)")
        }
        guard OfflineModelManager.isDiarizationInstalled() else {
            throw AuraError.diarizationModelMissing
        }

        let samples = try Self.loadMonoSamples(from: audioURL)
        guard samples.count > 16_000 else {
            // 1 saniyeden kısa ses için ayrıştırma anlamsız.
            return .empty
        }
        progress?(0.1)

        let engine = try await loadedEngine()

        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: expectedSpeakerCount,
            clusterDistanceThreshold: 0.6,
            useExclusiveReconciliation: false
        )

        let result: DiarizationResult
        do {
            result = try await engine.diarize(audioArray: samples, options: options)
        } catch {
            throw AuraError.engineFailure("Konuşmacı ayrıştırma başarısız: \(error.localizedDescription)")
        }

        progress?(1.0)

        // `SpeakerInfo` bir enum: .speakerId(Int) / .multiple([Int]) / .noMatch.
        // `.multiple` üst üste binen konuşma demek — tek kişiye atfetmek yerine
        // atlıyoruz, `.noMatch` zaten kimliksiz.
        let turns = result.segments.compactMap { segment -> SpeakerTurn? in
            guard let speakerID = segment.speaker.speakerId else { return nil }
            return SpeakerTurn(
                startSeconds: Double(segment.startTime),
                endSeconds: Double(segment.endTime),
                rawSpeakerID: "S\(speakerID)"
            )
        }
        .filter { $0.duration > 0 }
        .sorted { $0.startSeconds < $1.startSeconds }

        return DiarizationOutput(turns: turns, speakerCount: result.speakerCount)
    }

    // MARK: - Model

    private func loadedEngine() async throws -> SpeakerKit {
        if let engine { return engine }
        do {
            let config = PyannoteConfig(
                modelFolder: OfflineModelManager.diarizationFolder.path
            )
            let engine = try await SpeakerKit(config)
            self.engine = engine
            return engine
        } catch {
            throw AuraError.engineFailure("Ayrıştırma modeli yüklenemedi: \(error.localizedDescription)")
        }
    }

    /// Bellek baskısı altında modeli boşaltır.
    public func unload() {
        engine = nil
    }

    /// Ayrıştırma modelini indirir ve kurulumu kaydeder.
    ///
    /// SpeakerKit, `modelFolder` verilen bir yapılandırmayla ilk kez
    /// kurulduğunda modeli kendisi indirir; ayrı bir indirme API'si yok.
    /// Bu yüzden kurulum = motoru bir kez ayağa kaldırmak.
    public func install(progress: DiarizationProgress? = nil) async throws {
        progress?(0.05)
        do {
            try FileManager.default.createDirectory(
                at: OfflineModelManager.diarizationFolder,
                withIntermediateDirectories: true
            )
            let config = PyannoteConfig(modelFolder: OfflineModelManager.diarizationFolder.path)
            let engine = try await SpeakerKit(config)
            self.engine = engine
        } catch {
            throw AuraError.engineFailure("Ayrıştırma modeli indirilemedi: \(error.localizedDescription)")
        }
        await OfflineModelManager.shared.markDiarizationInstalled()
        progress?(1.0)
    }

    // MARK: - Ses okuma

    /// WAV dosyasını tek kanal Float dizisine okur.
    ///
    /// Kaydımız zaten 16 kHz mono; farklı bir format gelirse dönüştürülür.
    static func loadMonoSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AuraError.engineFailure("Ses dosyası açılamadı: \(error.localizedDescription)")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AuraError.engineFailure("Hedef ses formatı oluşturulamadı.")
        }

        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AuraError.engineFailure("Ses arabelleği ayrılamadı.")
        }
        try file.read(into: sourceBuffer)

        // Zaten hedef formattaysa dönüştürmeye gerek yok.
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channel = sourceBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(sourceBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AuraError.engineFailure("Ses dönüştürücü oluşturulamadı.")
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AuraError.engineFailure("Çıkış arabelleği ayrılamadı.")
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw AuraError.engineFailure("Ses dönüştürülemedi: \(conversionError.localizedDescription)")
        }
        guard let channel = outputBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}
