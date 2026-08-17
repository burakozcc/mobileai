//
//  AudioRecorderService.swift
//  AuraVoice
//
//  AVAudioEngine tabanlı kayıt servisi — 16 kHz / 16-bit / Mono PCM WAV.
//
//  Şablona göre yapılan kritik düzeltmeler:
//   1. Donanım giriş formatı (genelde 44.1/48 kHz Float32) doğrudan 16 kHz Int16
//      dosyaya yazılamaz; `AVAudioConverter` ile gerçek zamanlı dönüştürme eklendi.
//   2. `floatChannelData` yalnızca Float32 buffer'da doludur; seviye ölçümü
//      dönüştürmeden ÖNCE, giriş buffer'ı üzerinden vDSP ile RMS olarak alınır.
//   3. Swift 6 strict concurrency: tap callback gerçek zamanlı ses thread'inde
//      çalışır. `@MainActor` sınıfa dokunmaz; kilitle korunan `RecordingSink`
//      (`@unchecked Sendable`) üzerinden ilerler, UI güncellemesi 40 ms'lik
//      MainActor döngüsüyle yapılır (buffer başına `DispatchQueue.main.async` yok).
//   4. Süre, duvar saati yerine yazılan frame sayısından hesaplanır → duraklatma
//      ve kesinti durumlarında da doğru kalır (kota bu değere göre düşülür).
//

import Foundation
import AVFoundation
import Accelerate
import Combine

@MainActor
public final class AudioRecorderService: NSObject, ObservableObject {

    // MARK: - Yayınlanan Durum

    @Published public private(set) var isRecording = false
    @Published public private(set) var isPaused = false
    /// Yazılan ses verisinden türetilen gerçek kayıt süresi (saniye).
    @Published public private(set) var currentDuration: TimeInterval = 0
    /// Dalga formu için normalize edilmiş (0...1) kayan seviye penceresi.
    @Published public private(set) var audioLevels: [Float]
    /// Anlık tepe seviye — kayıt butonunun nabız animasyonunu besler.
    @Published public private(set) var peakLevel: Float = 0

    // MARK: - Yapılandırma

    public static let targetSampleRate: Double = 16_000
    public static let waveformResolution = 56

    private let levelRefreshInterval: Duration = .milliseconds(40)

    // MARK: - Özel

    private var engine: AVAudioEngine?
    private var sink: RecordingSink?
    private var meterTask: Task<Void, Never>?
    /// `deinit` nonisolated'dır ve `NSObjectProtocol` Sendable değildir;
    /// bu yüzden token bilinçli olarak izolasyon dışında tutulur.
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    private var currentFileURL: URL?

    public override init() {
        self.audioLevels = AudioWaveformProcessor.emptyWindow(resolution: Self.waveformResolution)
        super.init()
        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - İzin

    public static var microphonePermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    @discardableResult
    public static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Kayıt Kontrolü

    @discardableResult
    public func startRecording() throws -> URL {
        guard !isRecording else {
            guard let url = currentFileURL else { throw AuraError.audioEngineFailure("Aktif dosya yok.") }
            return url
        }
        guard Self.microphonePermission == .granted else {
            throw AuraError.microphonePermissionDenied
        }

        try configureSession()

        let fileURL = Self.makeRecordingURL()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AuraError.audioEngineFailure("Giriş formatı hazır değil (rota bulunamadı).")
        }

        let sink: RecordingSink
        do {
            sink = try RecordingSink(url: fileURL, inputFormat: inputFormat)
        } catch {
            throw AuraError.audioEngineFailure(error.localizedDescription)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            // Gerçek zamanlı ses thread'i: yalnızca kilitli/lock-free işler.
            sink.consume(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            sink.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw AuraError.audioEngineFailure(error.localizedDescription)
        }

        self.engine = engine
        self.sink = sink
        self.currentFileURL = fileURL
        self.isRecording = true
        self.isPaused = false
        self.currentDuration = 0
        self.audioLevels = AudioWaveformProcessor.emptyWindow(resolution: Self.waveformResolution)
        self.peakLevel = 0

        startMeterLoop()
        return fileURL
    }

    public func pauseRecording() {
        guard isRecording, !isPaused, let engine else { return }
        engine.pause()
        sink?.setPaused(true)
        isPaused = true
    }

    public func resumeRecording() {
        guard isRecording, isPaused, let engine else { return }
        do {
            try engine.start()
            sink?.setPaused(false)
            isPaused = false
        } catch {
            // Motor geri gelmezse kaydı kapatmak yerine duraklatılmış bırakıyoruz;
            // kullanıcı durdurup mevcut sesi işleyebilir.
            print("[AuraVoice] Kayıt devam ettirilemedi: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func stopRecording() -> (fileURL: URL?, duration: TimeInterval) {
        guard isRecording else { return (nil, 0) }

        meterTask?.cancel()
        meterTask = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        let duration = sink?.recordedSeconds ?? currentDuration
        sink?.close()
        sink = nil

        let file = currentFileURL
        currentFileURL = nil
        isRecording = false
        isPaused = false
        currentDuration = duration
        peakLevel = 0

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (file, duration)
    }

    /// Kaydı iptal eder ve ses dosyasını diskten siler (kota düşülmez).
    public func cancelRecording() {
        let result = stopRecording()
        if let url = result.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentDuration = 0
        audioLevels = AudioWaveformProcessor.emptyWindow(resolution: Self.waveformResolution)
    }

    // MARK: - Oturum

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.voiceChat` modu donanımsal yankı bastırmayı (AEC) devreye alır —
        // hoparlörden gelen karşı taraf sesi kaydı bozmaz.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try? session.setPreferredSampleRate(Self.targetSampleRate)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: raw)
            }
        }
    }

    private func handleInterruption(rawType: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            // Gelen arama / Siri: motoru duraklat, dosyayı koru.
            pauseRecording()
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            resumeRecording()
        @unknown default:
            break
        }
    }

    // MARK: - Ölçüm Döngüsü

    private func startMeterLoop() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.levelRefreshInterval ?? .milliseconds(40))
                guard let self, let sink = self.sink else { return }
                self.ingest(level: sink.currentLevel, seconds: sink.recordedSeconds)
            }
        }
    }

    private func ingest(level: Float, seconds: Double) {
        // Duraklatmada çubuklar sıfıra doğru sönümlenir, sıfırlanmaz.
        let target = isPaused ? AudioWaveformProcessor.silenceFloor : max(AudioWaveformProcessor.silenceFloor, level)
        let previous = audioLevels.last ?? AudioWaveformProcessor.silenceFloor
        let smoothed = AudioWaveformProcessor.smooth(previous: previous, target: target)

        audioLevels = AudioWaveformProcessor.advance(window: audioLevels, with: smoothed)
        peakLevel = min(1.0, target)
        currentDuration = seconds
    }

    // MARK: - Dosya

    private static func makeRecordingURL() -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("rec_\(UUID().uuidString).wav")
    }
}

// MARK: - RecordingSink

/// Ses render thread'i ile MainActor arasındaki sınırı yöneten yardımcı.
/// Tüm mutable durum `NSLock` ile korunur; dosya yazımı ayrı bir seri kuyruğa
/// devredilir ki render thread'i disk I/O nedeniyle takılmasın.
private final class RecordingSink: @unchecked Sendable {

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.auravoice.audio.write", qos: .userInitiated)

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let ratio: Double

    private var _level: Float = 0
    private var _writtenFrames: AVAudioFramePosition = 0
    private var _isPaused = false
    private var _isClosed = false

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioRecorderService.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AuraError.audioEngineFailure("Hedef ses formatı oluşturulamadı.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AuraError.audioEngineFailure("Format dönüştürücü oluşturulamadı.")
        }

        // `commonFormat`/`interleaved` verilerek dosyanın processingFormat'ı
        // hedef formatla birebir eşitlenir; aksi halde `write(from:)` exception atar.
        self.file = try AVAudioFile(
            forWriting: url,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.converter = converter
        self.targetFormat = target
        self.ratio = target.sampleRate / inputFormat.sampleRate
    }

    // MARK: Render thread

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let paused = _isPaused, closed = _isClosed
        lock.unlock()
        guard !paused, !closed else { return }

        updateLevel(from: buffer)

        guard let converted = convert(buffer) else { return }
        let frames = AVAudioFramePosition(converted.frameLength)
        guard frames > 0 else { return }

        lock.lock()
        _writtenFrames += frames
        lock.unlock()

        let box = BufferBox(buffer: converted)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isClosed = self._isClosed
            self.lock.unlock()
            guard !isClosed else { return }
            do {
                try self.file.write(from: box.buffer)
            } catch {
                print("[AuraVoice] Ses yazma hatası: \(error.localizedDescription)")
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream:
            return nil
        case .error:
            print("[AuraVoice] Dönüştürme hatası: \(conversionError?.localizedDescription ?? "bilinmiyor")")
            return nil
        @unknown default:
            return nil
        }
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return }

        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, frameCount)

        let shaped = AudioWaveformProcessor.normalize(rms: rms)

        lock.lock()
        _level = shaped
        lock.unlock()
    }

    // MARK: MainActor tarafı

    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    var recordedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(_writtenFrames) / targetFormat.sampleRate
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        _isPaused = paused
        if paused { _level = 0 }
        lock.unlock()
    }

    func close() {
        lock.lock()
        _isClosed = true
        lock.unlock()
        // Kuyruktaki son buffer'lar diske inene kadar bekle.
        writeQueue.sync {}
    }

    /// `AVAudioPCMBuffer` Sendable değil; dönüştürülmüş buffer'ın tek sahibi
    /// bu kutu olduğu için kuyruğa taşınması güvenlidir.
    private struct BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }
}
