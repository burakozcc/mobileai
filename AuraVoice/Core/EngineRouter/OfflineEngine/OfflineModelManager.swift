//
//  OfflineModelManager.swift
//  AuraVoice
//
//  Cihaz içi modellerin indirilmesi, kurulum kaydı ve silinmesi.
//
//  WhisperKit'in disk yerleşimine bağımlı kalmamak için `download` çağrısının
//  döndürdüğü klasör yolu bir kurulum kaydına yazılır; motor da modeli bu
//  kayıttaki yoldan yükler. Paket kendi klasör şemasını değiştirse bile
//  uygulama bozulmaz.
//

import Foundation
// Bkz. WhisperKitEngine.swift — paket Sendable benimsemedi.
@preconcurrency import WhisperKit

public actor OfflineModelManager {

    public static let shared = OfflineModelManager()

    // MARK: - Kurulum kaydı

    public struct Installation: Codable, Sendable, Identifiable, Hashable {
        public let variant: String
        public let folderPath: String
        public let installedAt: Date
        public let sizeBytes: Int64

        public var id: String { variant }
        public var folderURL: URL { URL(fileURLWithPath: folderPath) }
    }

    public enum DownloadState: Sendable, Equatable {
        case idle
        case downloading(fraction: Double)
        case installed
        case failed(String)
    }

    // MARK: - Yollar

    public nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Model klasörünü iCloud yedeğinden çıkarır.
    ///
    /// App Store inceleme kuralı: yeniden indirilebilir veri yedeklenmemeli.
    /// Bugün 627 MB, nöral özetleyici geldiğinde 1,9 GB — kullanıcının iCloud
    /// alanını bununla doldurmak hem ret sebebi hem de düpedüz kabalık.
    /// Klasör bir kez işaretlenince altındaki her şey kapsanıyor.
    nonisolated static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            // Yedekleme bayrağı yazılamadıysa uygulama çalışmaya devam etmeli;
            // sessiz kalmasın diye kaydediliyor.
            print("[AuraVoice] Model klasörü yedekten çıkarılamadı: \(error.localizedDescription)")
        }
    }

    private nonisolated static var registryURL: URL {
        modelsDirectory.appendingPathComponent("installed_models.json")
    }

    // MARK: - Sorgu (senkron, aktör dışından okunabilir)

    public nonisolated static func installations(in directory: URL = modelsDirectory) -> [Installation] {
        let url = directory.appendingPathComponent("installed_models.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([Installation].self, from: data)) ?? []
        // Kayıt var ama klasör silinmişse (kullanıcı depolamayı temizledi)
        // kurulu saymayız.
        return records.filter { FileManager.default.fileExists(atPath: $0.folderPath) }
    }

    public nonisolated static func isDownloaded(
        variant: WhisperKitEngine.Variant,
        in directory: URL = modelsDirectory
    ) -> Bool {
        installations(in: directory).contains { $0.variant == variant.rawValue }
    }

    public nonisolated static func installedFolder(
        variant: WhisperKitEngine.Variant,
        in directory: URL = modelsDirectory
    ) -> URL? {
        installations(in: directory).first { $0.variant == variant.rawValue }?.folderURL
    }

    /// Offline mod için gereken her şey hazır mı? (ASR modeli; özetleyici
    /// çıkarımsal olduğu için ek model gerektirmez.)
    public nonisolated static func isOfflineReady(in directory: URL = modelsDirectory) -> Bool {
        !installations(in: directory).isEmpty
    }

    /// Motorun kullanacağı varyant: KURULU olanların en iyisi.
    ///
    /// Eskiden `isOfflineReady` herhangi bir kurulu varyantta true dönüyordu
    /// ama motor `.base`'e sabitti. Yalnızca "Hızlı (küçük)" ya da yalnızca
    /// "Yüksek doğruluk" indiren kullanıcı yeşil "Kurulu" rozetini görüyor,
    /// mod seçimi kabul ediliyor ve kayıt sonunda `offlineModelMissing`
    /// alıyordu — cihazda düzeltmenin yolu da yoktu.
    public nonisolated static func activeVariant(
        in directory: URL = modelsDirectory
    ) -> WhisperKitEngine.Variant? {
        let installed = Set(installations(in: directory).map(\.variant))
        guard !installed.isEmpty else { return nil }
        return WhisperKitEngine.Variant.best(from: installed)
    }

    // MARK: - Kurulum

    /// Modeli indirir ve kurulum kaydına yazar. Zaten kuruluysa doğrudan döner.
    @discardableResult
    public func install(
        variant: WhisperKitEngine.Variant,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Installation {

        if let existing = Self.installations().first(where: { $0.variant == variant.rawValue }) {
            progress?(1.0)
            return existing
        }

        let directory = Self.modelsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)

        let folderURL: URL
        do {
            folderURL = try await WhisperKit.download(
                variant: variant.rawValue,
                downloadBase: directory,
                useBackgroundSession: false,
                progressCallback: { fileProgress in
                    progress?(fileProgress.fractionCompleted)
                }
            )
        } catch {
            // İptal kullanıcının kararı; sarmalanırsa çağıran onu hatadan
            // ayırt edemiyor ve satırda kalıcı kırmızı bir uyarı bırakıyor.
            if error is CancellationError { throw error }
            throw AuraError.engineFailure("Model indirilemedi: \(error.localizedDescription)")
        }

        let record = Installation(
            variant: variant.rawValue,
            folderPath: folderURL.path,
            installedAt: Date(),
            sizeBytes: Self.directorySize(at: folderURL)
        )

        var records = Self.installations().filter { $0.variant != variant.rawValue }
        records.append(record)
        try persist(records)

        progress?(1.0)
        return record
    }

    // MARK: - Kaldırma

    public func remove(variant: WhisperKitEngine.Variant) throws {
        let records = Self.installations()
        if let record = records.first(where: { $0.variant == variant.rawValue }) {
            try? FileManager.default.removeItem(at: record.folderURL)
        }
        try persist(records.filter { $0.variant != variant.rawValue })
    }

    public func removeAll() throws {
        for record in Self.installations() {
            try? FileManager.default.removeItem(at: record.folderURL)
        }
        try persist([])
    }

    public func diskUsageBytes() -> Int64 {
        Self.installations().reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Yardımcılar

    private func persist(_ records: [Installation]) throws {
        let directory = Self.modelsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(records)
        try data.write(to: Self.registryURL, options: .atomic)
    }

    nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// "480 MB" biçiminde okunabilir boyut.
    public nonisolated static func formatted(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
