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


    // MARK: - İndirme artıkları

    /// WhisperKit'in kullandığı Hugging Face deposu.
    nonisolated static var speechRepositoryID: String { "argmaxinc/whisperkit-coreml" }

    /// Anlık görüntülerin indiği kök.
    ///
    /// KAYNAKTAN DOĞRULANDI, tahmin değil: `WhisperKit.download` bir
    /// `HubApi(downloadBase:)` kurup `snapshot(from:matching:)` çağırıyor;
    /// `HubApi.localRepoLocation` ise `downloadBase/<repo.type>/<repo.id>`
    /// döndürüyor (swift-transformers 573e5c9, HubApi.swift:618-620:
    /// https://github.com/huggingface/swift-transformers/blob/573e5c9036c2f136b3a8a071da8e8907322403d0/Sources/Hub/HubApi.swift#L618-L620).
    nonisolated static func speechRepositoryRoot(in directory: URL = modelsDirectory) -> URL {
        directory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(speechRepositoryID, isDirectory: true)
    }

    /// Bir varyantın diskteki BÜTÜN izleri.
    ///
    /// İki klasör yetiyor çünkü yarım dosyalar ve metadata, anlık görüntüyle
    /// AYNI göreli yolu izliyor: `<kök>/.cache/huggingface/download/<varyant>/…`
    /// (HubApi.swift:895-900, `metadataDestination` ve `incompleteDestination`:
    /// https://github.com/huggingface/swift-transformers/blob/573e5c9036c2f136b3a8a071da8e8907322403d0/Sources/Hub/HubApi.swift#L895-L900).
    /// Bu yüzden temizlik varyantla sınırlı kalıyor ve komşu bir modeli
    /// bozamıyor — kör bir `.cache` silme öyle olmazdı.
    nonisolated static func speechArtifacts(
        for variant: WhisperKitEngine.Variant,
        in directory: URL = modelsDirectory
    ) -> [URL] {
        let root = speechRepositoryRoot(in: directory)
        return [
            root.appendingPathComponent(variant.rawValue, isDirectory: true),
            root
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("download", isDirectory: true)
                .appendingPathComponent(variant.rawValue, isDirectory: true)
        ]
    }

    /// İptal ya da hata sonrası yarım kalmış indirmeyi siler.
    ///
    /// KURULU varyanta asla dokunmuyor: sicilde kaydı varsa dosyalar çalışan
    /// bir modele ait ve silmek kullanıcının indirdiği 627 MB'ı çöpe atardı.
    @discardableResult
    nonisolated static func discardIncompleteSpeechDownload(
        variant: WhisperKitEngine.Variant,
        in directory: URL = modelsDirectory
    ) -> Int64 {
        guard !isDownloaded(variant: variant, in: directory) else { return 0 }

        let fileManager = FileManager.default
        var freed: Int64 = 0

        for url in speechArtifacts(for: variant, in: directory) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            freed += directorySize(at: url)
            try? fileManager.removeItem(at: url)
        }
        return freed
    }

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
            // Yarım kalan dosyaları BURADA siliyoruz. `remove(variant:)`
            // yalnızca sicile yazılmış klasörleri siliyor, iptal edilen
            // indirme ise hiç sicile girmiyor — o baytlar sonsuza kadar
            // diskte kalıyordu.
            Self.discardIncompleteSpeechDownload(variant: variant)

            // İptal kullanıcının kararı; sarmalanırsa çağıran onu hatadan
            // ayırt edemiyor ve satırda kalıcı kırmızı bir uyarı bırakıyor.
            if error is CancellationError { throw error }
            throw AuraError.engineFailure(String(localized: "Model indirilemedi: \(error.localizedDescription)"))
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

    /// İndirilen modelin gerçekten YÜKLENEBİLDİĞİNİ doğrular.
    ///
    /// NEDEN İNDİRME ANINDA: yükleme ilk kez kayıt sonunda deneniyordu ve
    /// orada başarısız olması, kullanıcının 45 dakikalık toplantıyı
    /// kaydettikten sonra "Model yüklenemedi" duyması demekti. Ağ HÂLÂ
    /// varken denemek, sorunu kullanıcı uçağa binmeden önce yüzeye çıkarıyor.
    ///
    /// Başarısızlıkta kurulum kaydı ve dosyalar siliniyor: "kurulu ama
    /// açılmıyor" diye bir ara durum kalmamalı — Ayarlar yeşil "KURULU"
    /// gösterirken her kayıt patlardı.
    public func verifyInstallation(variant: WhisperKitEngine.Variant) async throws {
        do {
            try await WhisperKitEngine(variant: variant).prepare()
        } catch {
            try? remove(variant: variant)
            Self.discardIncompleteSpeechDownload(variant: variant)
            throw AuraError.engineFailure(
                String(localized: "Model indirildi ama açılamadı, dosyalar temizlendi. Tekrar deneyin.")
            )
        }
    }

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

    /// Konuşma modellerinin diskte GERÇEKTEN kapladığı yer.
    ///
    /// Eskiden sicildeki kayıtların `sizeBytes` toplamıydı; iptal edilen bir
    /// indirmenin yarım dosyaları hiç sicile girmediği için Ayarlar'daki
    /// toplamda görünmüyordu bile. Kullanıcı 300 MB'ın nereye gittiğini
    /// göremiyordu. Artık ağaç geziliyor.
    public func diskUsageBytes() -> Int64 {
        Self.directorySize(at: Self.speechRepositoryRoot())
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
