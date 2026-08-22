//
//  NoteEntity.swift
//  AuraVoice
//
//  SwiftData kalıcı modeli. Model sınıfları Sendable DEĞİLDİR ve yalnızca
//  kendi ModelContext'i içinde yaşar; dışarıya her zaman `NoteSummary` DTO'su
//  verilir. Bu sınır Swift 6'da veri yarışını derleyici seviyesinde engeller.
//

import Foundation
import SwiftData

@Model
public final class NoteEntity {

    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var durationSeconds: Double

    /// Enum'lar ham string olarak saklanır: ileride yeni bir mod eklendiğinde
    /// eski kayıtlar çözümlenemez hale gelmesin.
    public var modeRaw: String
    public var templateRaw: String
    public var sourceTriggerRaw: String

    public var summaryMarkdown: String
    public var rawTranscript: String
    public var detectedLanguage: String

    /// Dalga formu önizlemesi ham Float dizisi olarak değil, `Data` olarak
    /// saklanır — SwiftData'nın `[Float]` desteği sürümler arası oynak.
    public var waveformData: Data

    /// Documents/Recordings altındaki dosya adı (tam yol saklanmaz; sandbox
    /// yolu uygulama güncellemelerinde değişir).
    public var audioFileName: String?

    /// Varsayılan değeri olan yeni alanlar SwiftData'nın hafif göçünü
    /// tetikliyor; eski kayıtlar `.ready` olarak açılıyor.
    public var processingStateRaw: String = NoteProcessingState.ready.rawValue
    public var failureReason: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegmentEntity.note)
    public var segments: [TranscriptSegmentEntity]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        durationSeconds: Double,
        modeRaw: String,
        templateRaw: String,
        sourceTriggerRaw: String,
        summaryMarkdown: String,
        rawTranscript: String,
        detectedLanguage: String,
        waveformData: Data,
        audioFileName: String?,
        processingStateRaw: String = NoteProcessingState.ready.rawValue,
        failureReason: String? = nil,
        segments: [TranscriptSegmentEntity] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.modeRaw = modeRaw
        self.templateRaw = templateRaw
        self.sourceTriggerRaw = sourceTriggerRaw
        self.summaryMarkdown = summaryMarkdown
        self.rawTranscript = rawTranscript
        self.detectedLanguage = detectedLanguage
        self.waveformData = waveformData
        self.audioFileName = audioFileName
        self.processingStateRaw = processingStateRaw
        self.failureReason = failureReason
        self.segments = segments
    }
}

// MARK: - DTO Dönüşümü

public extension NoteEntity {

    convenience init(summary: NoteSummary) {
        self.init(
            id: summary.id,
            title: summary.title,
            createdAt: summary.createdAt,
            durationSeconds: summary.durationSeconds,
            modeRaw: summary.mode.rawValue,
            templateRaw: summary.template.rawValue,
            sourceTriggerRaw: summary.sourceTrigger.rawValue,
            summaryMarkdown: summary.summaryMarkdown,
            rawTranscript: summary.rawTranscript,
            detectedLanguage: summary.detectedLanguage,
            waveformData: WaveformCodec.encode(summary.waveformPreview),
            audioFileName: summary.audioFileName,
            processingStateRaw: summary.processingState.rawValue,
            failureReason: summary.failureReason
        )
    }

    /// Aktör sınırını geçebilen Sendable görünüm.
    var summary: NoteSummary {
        NoteSummary(
            id: id,
            title: title,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            mode: ProcessingMode(rawValue: modeRaw) ?? .offlineZeroCloud,
            template: SummaryTemplate(rawValue: templateRaw) ?? .quickNotes,
            summaryMarkdown: summaryMarkdown,
            rawTranscript: rawTranscript,
            detectedLanguage: detectedLanguage,
            waveformPreview: WaveformCodec.decode(waveformData),
            audioFileName: audioFileName,
            sourceTrigger: RecordingTriggerSource(rawValue: sourceTriggerRaw) ?? .manual,
            processingState: NoteProcessingState(rawValue: processingStateRaw) ?? .ready,
            failureReason: failureReason
        )
    }

    /// Var olan kaydı DTO'dan günceller (yeniden ekleme yerine).
    func apply(_ summary: NoteSummary) {
        title = summary.title
        createdAt = summary.createdAt
        durationSeconds = summary.durationSeconds
        modeRaw = summary.mode.rawValue
        templateRaw = summary.template.rawValue
        sourceTriggerRaw = summary.sourceTrigger.rawValue
        summaryMarkdown = summary.summaryMarkdown
        rawTranscript = summary.rawTranscript
        detectedLanguage = summary.detectedLanguage
        waveformData = WaveformCodec.encode(summary.waveformPreview)
        audioFileName = summary.audioFileName
        processingStateRaw = summary.processingState.rawValue
        failureReason = summary.failureReason
    }
}

// MARK: - Dalga Formu Kodlaması

/// `[Float]` ↔ `Data` dönüşümü. Hizalama sorunlarına karşı `copyBytes`
/// kullanılır — `bindMemory` hizalanmamış `Data` üzerinde tanımsız davranıştır.
public enum WaveformCodec {

    public static func encode(_ levels: [Float]) -> Data {
        levels.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return result
    }
}
