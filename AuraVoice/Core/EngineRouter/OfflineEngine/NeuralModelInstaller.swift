//
//  NeuralModelInstaller.swift
//  AuraVoice
//
//  Nöral özetleyici modelinin (1,11 GB GGUF) indirilmesi.
//
//  NEDEN ARKA PLAN OTURUMU: Dosya 1,11 GB. Ön plandaki bir `URLSession`
//  görevi, kullanıcı uygulamadan çıktığı anda ölüyor — 1 GB'ın yarısında
//  ölmesi hem kullanıcının veri paketini hem de sabrını yakıyor. Arka plan
//  oturumu indirmeyi sistem devralıyor ve gerekirse uygulamayı yeniden
//  başlatarak dosyayı teslim ediyor.
//
//  Bunun sonucu şu: dosyayı YERİNE TAŞIMAK, bekleyen bir `async` çağrısına
//  bağlı OLAMAZ. Uygulama arada öldürülmüş olabilir. Bu yüzden taşıma işi
//  delegate geri çağrısında, herhangi bir continuation'dan bağımsız yapılıyor;
//  `install()` yalnızca arayüze ilerleme göstermek için bekliyor.
//

import Foundation

/// UIKit'in `handleEventsForBackgroundURLSession` ile verdiği geri çağrı
/// `@Sendable` DEĞİL, ama aktör sınırını geçmesi ve ana iş parçacığında
/// çağrılması gerekiyor. Kutu bu sözü açıkça üstleniyor: içindeki kapanış
/// yalnızca ana aktörde, yalnızca bir kez çalıştırılıyor.
public struct SystemCompletionBox: @unchecked Sendable {

    let handler: () -> Void

    public init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

// MARK: - İndirici

public final class NeuralModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public static let shared = NeuralModelDownloader()

    public static let sessionIdentifier = "com.auravoice.neural-model-download"

    private let lock = NSLock()
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var completionHandler: (@Sendable (Result<Void, any Error>) -> Void)?
    private var task: URLSessionDownloadTask?

    /// Uygulama arka planda uyandırıldığında sistemin verdiği geri çağrı.
    private var systemCompletionHandler: SystemCompletionBox?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Kullanıcı 1 GB'ı hücresel veriden indirmek istemiyor olabilir; bunu
        // varsayım yapmak yerine sistem ayarına bırakıyoruz.
        configuration.allowsCellularAccess = false
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() { super.init() }

    // MARK: Genel yüzey

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != nil
    }

    /// Sistem arka plan olaylarını teslim ettiğinde AppDelegate'ten çağrılır.
    public func attachSystemCompletionHandler(_ handler: SystemCompletionBox) {
        lock.lock(); defer { lock.unlock() }
        systemCompletionHandler = handler
    }

    public func start(
        from url: URL,
        progress: (@Sendable (Double) -> Void)?,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            completion(.failure(AuraError.engineFailure("İndirme zaten sürüyor.")))
            return
        }
        progressHandler = progress
        completionHandler = completion

        let downloadTask = session.downloadTask(with: url)
        task = downloadTask
        lock.unlock()

        downloadTask.resume()
    }

    public func cancel() {
        lock.lock()
        let running = task
        task = nil
        let completion = completionHandler
        completionHandler = nil
        progressHandler = nil
        lock.unlock()

        running?.cancel()
        completion?(.failure(CancellationError()))
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Sunucu uzunluk bildirmezse bilinmeyen ilerleme yerine beklenen
        // boyutu kullanıyoruz; dosya boyutunu zaten biliyoruz.
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : Int64(OfflineModelManager.NeuralModel.expectedBytes)

        lock.lock()
        let handler = progressHandler
        lock.unlock()

        handler?(min(1, max(0, Double(totalBytesWritten) / Double(expected))))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // BU GERİ ÇAĞRI DÖNER DÖNMEZ geçici dosya siliniyor. Taşımayı burada,
        // senkron olarak yapmak zorundayız — bekleyen bir continuation'a
        // bırakılamaz, çünkü uygulama arada öldürülmüş olabilir.
        let result = Self.installDownloadedFile(at: location)

        lock.lock()
        let completion = completionHandler
        completionHandler = nil
        progressHandler = nil
        task = nil
        lock.unlock()

        completion?(result)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return } // Başarı yolu didFinishDownloadingTo'da.

        lock.lock()
        let completion = completionHandler
        completionHandler = nil
        progressHandler = nil
        self.task = nil
        lock.unlock()

        completion?(.failure(error))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        lock.unlock()

        // Sistem geri çağrısı ana iş parçacığında beklenir.
        if let handler {
            Task { @MainActor in handler.handler() }
        }
    }

    // MARK: Dosya yerleştirme

    static func installDownloadedFile(at location: URL) -> Result<Void, any Error> {
        let fileManager = FileManager.default
        let folder = OfflineModelManager.neuralModelFolder
        let destination = OfflineModelManager.neuralModelURL

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            // 1,11 GB yeniden indirilebilir veri; App Store kuralı gereği
            // iCloud yedeğine girmemeli.
            OfflineModelManager.excludeFromBackup(folder)

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)

            // Boyut tutmuyorsa "kurulu" saymıyoruz: yarım dosya her özetlemede
            // model yüklemeyi patlatıp sessizce çıkarımsala düşürürdü.
            guard OfflineModelManager.isNeuralSummarizerReady() else {
                try? fileManager.removeItem(at: destination)
                return .failure(AuraError.engineFailure("İndirilen model dosyası eksik ya da bozuk."))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Kurulum yüzeyi

public actor NeuralModelInstaller {

    public static let shared = NeuralModelInstaller()

    private let downloader: NeuralModelDownloader

    public init(downloader: NeuralModelDownloader = .shared) {
        self.downloader = downloader
    }

    public nonisolated var isInstalled: Bool {
        OfflineModelManager.isNeuralSummarizerReady()
    }

    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {

        if OfflineModelManager.isNeuralSummarizerReady() {
            progress?(1.0)
            return
        }

        // Önceki yarım kalmış deneme varsa temizle: aksi halde taşıma
        // "dosya zaten var" ile takılırdı.
        OfflineModelManager.discardIncompleteNeuralModel()

        guard let url = OfflineModelManager.NeuralModel.downloadURL else {
            throw AuraError.engineFailure("Model indirme adresi geçersiz.")
        }

        let downloader = self.downloader
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                downloader.start(from: url, progress: progress) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    public func remove() throws {
        let url = OfflineModelManager.neuralModelURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public nonisolated func diskUsageBytes() -> Int64 {
        let url = OfflineModelManager.neuralModelURL
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
