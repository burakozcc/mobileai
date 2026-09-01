//
//  DatabaseManager.swift
//  AuraVoice
//
//  SwiftData kalıcılık katmanı. `@ModelActor` sayesinde tüm veritabanı işleri
//  tek bir aktör üzerinde seri çalışır; `ModelContext` hiçbir zaman aktör
//  dışına sızmaz ve dışarıya yalnızca Sendable DTO'lar döner.
//

import Foundation
import SwiftData

// MARK: - Repository Sözleşmesi

/// Görünüm modelleri bu protokole bağlanır; böylece testte SwiftData yerine
/// bellek içi bir sahte (`NoteStore`) takılabilir.
public protocol NoteRepository: Sendable {
    func all() async throws -> [NoteSummary]
    @discardableResult func insert(_ note: NoteSummary) async throws -> [NoteSummary]
    @discardableResult func delete(id: UUID) async throws -> [NoteSummary]
    func minutesUsedThisMonth() async throws -> Double
    func segments(forNote noteID: UUID) async throws -> [TranscriptSegment]
    func replaceSegments(_ segments: [TranscriptSegment], forNote noteID: UUID) async throws
}

// MARK: - Konteyner

public enum AuraModelContainer {

    public static let schema = Schema([
        NoteEntity.self,
        TranscriptSegmentEntity.self
    ])

    /// Uygulama genelinde tek konteyner. Disk açılamazsa (bozuk store, dolu
    /// disk) uygulamayı çökertmek yerine bellek içi moda düşeriz: kullanıcı
    /// kaydını yine yapabilir, yalnızca kalıcılık kaybolur.
    public static let shared: ModelContainer = {
        // Temiz kurulumda `Library/Application Support` klasörü henüz yoktur ve
        // store oluşturma "No such file or directory" ile düşer. CI loglarında
        // bu hatayı gördük; ilk açılışta kullanıcı da sessizce kalıcılığı
        // kaybederdi.
        ensureApplicationSupportExists()

        // Konteyner AÇIKÇA sabitleniyor.
        //
        // `groupContainer` varsayılanı `.automatic` ve uygulamanın App Group
        // yetkisi var; store'un nereye açılacağını tesadüfe bırakmak, bir
        // güncellemede tüm notların "kaybolması" demek. `cloudKitDatabase` de
        // aynı sebeple `.none`: bu uygulamanın vaadi verinin cihazdan
        // çıkmaması, sessizce iCloud'a senkronlanması değil.
        let diskConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [diskConfig])
        } catch {
            print("[AuraVoice] Kalıcı store açılamadı, bellek içi moda düşülüyor: \(error)")
            isEphemeral = true
            let memoryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
            // Bellek içi konteyner da açılamıyorsa kurtarılacak bir durum yok.
            return try! ModelContainer(for: schema, configurations: [memoryConfig])
        }
    }()

    /// Kalıcı store açılamadı ve bellek içi konteynere düşüldü.
    ///
    /// Bu durumda uygulama ÇALIŞIYOR görünüyor ama her not uygulama kapanınca
    /// yok oluyor. Sessiz bırakmak kabul edilemez; ayrıca yetim temizliği bu
    /// bayrağa bakıp hiçbir şey silmemeli — boş bir veritabanında diskteki TÜM
    /// kayıtlar yetim görünür.
    public nonisolated(unsafe) private(set) static var isEphemeral = false

    private static func ensureApplicationSupportExists() {
        let fm = FileManager.default
        guard let directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              !fm.fileExists(atPath: directory.path)
        else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Testler ve önizlemeler için izole, diske dokunmayan konteyner.
    public static func inMemory() throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}

// MARK: - Yönetici

@ModelActor
public actor DatabaseManager: NoteRepository {

    public static let shared = DatabaseManager(modelContainer: AuraModelContainer.shared)

    // MARK: Okuma

    public func all() throws -> [NoteSummary] {
        var descriptor = FetchDescriptor<NoteEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Dashboard yalnızca son kayıtları gösteriyor; tüm geçmişi belleğe
        // çekmenin anlamı yok.
        descriptor.fetchLimit = 500
        return try modelContext.fetch(descriptor).map(\.summary)
    }

    public func note(id: UUID) throws -> NoteSummary? {
        try fetchEntity(id: id)?.summary
    }

    public func minutesUsedThisMonth() throws -> Double {
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        let descriptor = FetchDescriptor<NoteEntity>(
            predicate: #Predicate { $0.createdAt >= monthStart }
        )
        let total = try modelContext.fetch(descriptor).reduce(0) { $0 + $1.durationSeconds }
        return total / 60.0
    }

    public func segments(forNote noteID: UUID) throws -> [TranscriptSegment] {
        guard let entity = try fetchEntity(id: noteID) else { return [] }
        return entity.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map(\.segment)
    }

    // MARK: Yazma

    @discardableResult
    public func insert(_ note: NoteSummary) throws -> [NoteSummary] {
        if let existing = try fetchEntity(id: note.id) {
            existing.apply(note)
        } else {
            modelContext.insert(NoteEntity(summary: note))
        }
        try modelContext.save()
        return try all()
    }

    @discardableResult
    public func delete(id: UUID) throws -> [NoteSummary] {
        if let entity = try fetchEntity(id: id) {
            // Ses dosyası da gitmeli; aksi halde sandbox sessizce şişer.
            if let fileName = entity.audioFileName {
                try? FileManager.default.removeItem(at: Self.audioURL(for: fileName))
            }
            modelContext.delete(entity) // segments cascade ile silinir
            try modelContext.save()
        }
        return try all()
    }

    public func replaceSegments(_ segments: [TranscriptSegment], forNote noteID: UUID) throws {
        guard let entity = try fetchEntity(id: noteID) else { return }
        for old in entity.segments {
            modelContext.delete(old)
        }
        entity.segments = segments.map { TranscriptSegmentEntity(segment: $0, note: entity) }
        try modelContext.save()
    }

    // MARK: Bakım

    /// Geçici JSON deposundaki (`NoteStore`) kayıtları SwiftData'ya taşır ve
    /// dosyayı siler. Birden çok kez çağrılabilir; taşınacak kayıt yoksa
    /// hiçbir şey yapmaz.
    @discardableResult
    public func migrateLegacyNotesIfNeeded() throws -> Int {
        let legacyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aura_notes.json")

        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL)
        else { return 0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyNotes = (try? decoder.decode([NoteSummary].self, from: data)) ?? []

        for note in legacyNotes {
            // Aynı notu iki kez eklememek için kimlik kontrolü.
            if try fetchEntity(id: note.id) == nil {
                modelContext.insert(NoteEntity(summary: note))
            }
        }
        if !legacyNotes.isEmpty {
            try modelContext.save()
        }
        try? FileManager.default.removeItem(at: legacyURL)
        return legacyNotes.count
    }

    /// Veritabanında karşılığı kalmamış ses dosyalarını temizler.
    @discardableResult
    public func pruneOrphanedRecordings() throws -> Int {
        // Bellek içi konteynere düşüldüyse veritabanı BOŞ. O durumda her dosya
        // yetim görünür ve temizlik kullanıcının bütün kayıtlarını siler.
        guard !AuraModelContainer.isEphemeral else { return 0 }

        let directory = Self.recordingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return 0 }

        var referenced = Set(
            try modelContext.fetch(FetchDescriptor<NoteEntity>()).compactMap(\.audioFileName)
        )

        // Şu anda yazılmakta olan dosya henüz hiçbir notta görünmüyor: dosya
        // kayıt başlar başlamaz oluşuyor, not ise kayıt bitince yazılıyor.
        // Widget/Siri yolunda kayıt açılıştan birkaç yüz ms sonra başlıyor ve
        // tam bu temizlikle çakışabiliyordu — dosya unlink edilirken recorder
        // açık inode'a yazmaya devam ediyor, sonuçta WAV yok oluyordu.
        if let active = AudioRecorderService.activeRecordingFileName() {
            referenced.insert(active)
        }

        var removed = 0
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }

    /// Açılışta `.processing` durumunda kalmış notları `.failed` yapar.
    ///
    /// Uygulama açılırken hiçbir işleme sürüyor olamaz; bu durumda kalmış bir
    /// not, önceki oturumun ortasında öldürüldüğü (jetsam, çökme, kullanıcı)
    /// anlamına geliyor. Öyle bırakılırsa not listede sonsuza kadar
    /// "İşleniyor" görünür ve kullanıcı tekrar deneyemez.
    @discardableResult
    public func recoverInterruptedProcessing(
        reason: String = "İşleme yarıda kesildi. Ses duruyor, tekrar deneyebilirsin."
    ) throws -> Int {

        let pending = NoteProcessingState.processing.rawValue
        let descriptor = FetchDescriptor<NoteEntity>(
            predicate: #Predicate { $0.processingStateRaw == pending }
        )

        let stuck = try modelContext.fetch(descriptor)
        guard !stuck.isEmpty else { return 0 }

        for note in stuck {
            note.processingStateRaw = NoteProcessingState.failed.rawValue
            note.failureReason = reason
        }
        try modelContext.save()
        return stuck.count
    }

    // MARK: Yardımcılar

    /// Parametre adı bilerek `id` değil: `#Predicate` içinde `$0.id` ile
    /// karışmasın ve makro doğru sembolü yakalasın.
    private func fetchEntity(id target: UUID) throws -> NoteEntity? {
        var descriptor = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.id == target })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func audioURL(for fileName: String) -> URL {
        recordingsDirectory.appendingPathComponent(fileName)
    }
}
