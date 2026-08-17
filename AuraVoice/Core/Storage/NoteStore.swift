//
//  NoteStore.swift
//  AuraVoice
//
//  GEÇİCİ depolama katmanı. SwiftData tabanlı `DatabaseManager` + `NoteEntity`
//  devreye girene kadar Dashboard ve Recording akışlarının uçtan uca çalışmasını
//  sağlar. API yüzeyi (`all/insert/delete`) bilerek repository biçiminde tutuldu;
//  SwiftData'ya geçişte yalnızca bu dosyanın gövdesi değişir.
//

import Foundation

public struct NoteSummary: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var durationSeconds: Double
    public var mode: ProcessingMode
    public var template: SummaryTemplate
    public var summaryMarkdown: String
    public var rawTranscript: String
    public var detectedLanguage: String
    /// Kart üzerindeki minik dalga formu için örneklenmiş seviyeler.
    public var waveformPreview: [Float]
    /// Documents/Recordings altındaki dosya adı (tam yol saklanmaz — sandbox yolu
    /// uygulama güncellemelerinde değişir).
    public var audioFileName: String?
    public var sourceTrigger: RecordingTriggerSource

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        durationSeconds: Double,
        mode: ProcessingMode,
        template: SummaryTemplate,
        summaryMarkdown: String,
        rawTranscript: String,
        detectedLanguage: String = "tr",
        waveformPreview: [Float] = [],
        audioFileName: String? = nil,
        sourceTrigger: RecordingTriggerSource = .manual
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.mode = mode
        self.template = template
        self.summaryMarkdown = summaryMarkdown
        self.rawTranscript = rawTranscript
        self.detectedLanguage = detectedLanguage
        self.waveformPreview = waveformPreview
        self.audioFileName = audioFileName
        self.sourceTrigger = sourceTrigger
    }

    /// Kart üzerinde gösterilecek tek satırlık özet.
    public var previewLine: String {
        summaryMarkdown
            .split(separator: "\n")
            .first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("_")
            }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-*[] ")) }
            ?? "Özet hazırlanıyor…"
    }
}

public actor NoteStore {

    public static let shared = NoteStore()

    private var cache: [NoteSummary]?
    private let fileURL: URL

    public init(fileName: String = "aura_notes.json") {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    public func all() -> [NoteSummary] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    @discardableResult
    public func insert(_ note: NoteSummary) -> [NoteSummary] {
        var notes = all()
        notes.removeAll { $0.id == note.id }
        notes.insert(note, at: 0)
        persist(notes)
        return notes
    }

    @discardableResult
    public func delete(id: UUID) -> [NoteSummary] {
        var notes = all()
        if let removed = notes.first(where: { $0.id == id }), let fileName = removed.audioFileName {
            let audioURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Recordings", isDirectory: true)
                .appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: audioURL)
        }
        notes.removeAll { $0.id == id }
        persist(notes)
        return notes
    }

    /// Bu ay kullanılan toplam dakika (Dashboard istatistiği).
    public func minutesUsedThisMonth() -> Double {
        let calendar = Calendar.current
        let now = Date()
        return all()
            .filter { calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.durationSeconds } / 60.0
    }

    // MARK: Disk

    private func load() -> [NoteSummary] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NoteSummary].self, from: data)) ?? []
    }

    private func persist(_ notes: [NoteSummary]) {
        cache = notes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
