//
//  NoteSummary.swift
//  AuraVoice
//
//  Depolama katmanının Sendable dış yüzü. SwiftData model sınıfları
//  (`NoteEntity`) aktör sınırını geçemez; görünümler ve view model'ler daima
//  bu DTO ile çalışır.
//
//  Ayrıca testler ve SwiftUI önizlemeleri için diske dokunmayan bir
//  `InMemoryNoteRepository` içerir.
//

import Foundation

/// Notun işleme durumu.
///
/// Kayıt, motor çalışmadan ÖNCE `.processing` durumuyla kalıcılaştırılıyor.
/// Sebep: eskiden işleme başarısız olduğunda ses dosyası "kullanıcı tekrar
/// denesin diye" korunuyordu ama hiçbir not onu referans etmediği için bir
/// sonraki açılışta prune siliyordu. Uçakta işleme patlayan kullanıcı
/// uygulamayı kapatıp açtığında kaydını bulamıyordu.
public enum NoteProcessingState: String, Sendable, Codable, CaseIterable {

    /// Ses kaydedildi, transkript/özet henüz üretilmedi.
    case processing
    case ready
    /// İşleme başarısız oldu; ses duruyor, tekrar denenebilir.
    case failed

    public var isPending: Bool { self != .ready }

    public var label: String {
        switch self {
        case .processing: return "İşleniyor"
        case .ready:      return "Hazır"
        case .failed:     return "İşlenemedi"
        }
    }
}

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
    /// Documents/Recordings altındaki dosya adı (tam yol saklanmaz — sandbox
    /// yolu uygulama güncellemelerinde değişir).
    public var audioFileName: String?
    public var sourceTrigger: RecordingTriggerSource
    public var processingState: NoteProcessingState
    /// `.failed` durumunda kullanıcıya gösterilecek sebep.
    public var failureReason: String?

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
        sourceTrigger: RecordingTriggerSource = .manual,
        processingState: NoteProcessingState = .ready,
        failureReason: String? = nil
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
        self.processingState = processingState
        self.failureReason = failureReason
    }

    /// Kart üzerinde gösterilecek tek satırlık özet.
    public var previewLine: String {
        switch processingState {
        case .processing:
            return "Transkript ve özet hazırlanıyor…"
        case .failed:
            return failureReason ?? "İşleme tamamlanamadı — tekrar denenebilir."
        case .ready:
            break
        }
        return summaryMarkdown
            .split(separator: "\n")
            .first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("_")
            }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-*[] ")) }
            ?? "Özet hazırlanıyor…"
    }
}

// MARK: - Bellek İçi Depo (test / önizleme)

/// Diske dokunmayan `NoteRepository` uygulaması. Üretimde `DatabaseManager`
/// kullanılır; bu tip yalnızca birim testlerde ve SwiftUI önizlemelerinde
/// gerçek veritabanının yerine geçer.
public actor InMemoryNoteRepository: NoteRepository {

    private var notes: [NoteSummary]
    private var segmentsByNote: [UUID: [TranscriptSegment]] = [:]

    public init(seed: [NoteSummary] = []) {
        self.notes = seed.sorted { $0.createdAt > $1.createdAt }
    }

    public func all() -> [NoteSummary] { notes }

    @discardableResult
    public func insert(_ note: NoteSummary) -> [NoteSummary] {
        notes.removeAll { $0.id == note.id }
        notes.insert(note, at: 0)
        notes.sort { $0.createdAt > $1.createdAt }
        return notes
    }

    @discardableResult
    public func delete(id: UUID) -> [NoteSummary] {
        notes.removeAll { $0.id == id }
        segmentsByNote[id] = nil
        return notes
    }

    public func minutesUsedThisMonth() -> Double {
        let calendar = Calendar.current
        let now = Date()
        return notes
            .filter { calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.durationSeconds } / 60.0
    }

    public func segments(forNote noteID: UUID) -> [TranscriptSegment] {
        segmentsByNote[noteID] ?? []
    }

    public func replaceSegments(_ segments: [TranscriptSegment], forNote noteID: UUID) {
        segmentsByNote[noteID] = segments.sorted { $0.startSeconds < $1.startSeconds }
    }
}
