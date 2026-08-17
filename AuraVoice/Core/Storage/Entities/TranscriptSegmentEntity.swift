//
//  TranscriptSegmentEntity.swift
//  AuraVoice
//
//  Zaman damgalı transkript parçaları. WhisperKit segment bazlı çıktı verdiği
//  için ham metni tek bloktan ayrı saklıyoruz: kullanıcı bir cümleye dokunup
//  sesin o anına atlayabilsin ve konuşmacı ayrıştırması eklenebilsin.
//

import Foundation
import SwiftData

// MARK: - Sendable DTO

public struct TranscriptSegment: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    /// Konuşmacı ayrıştırma (diarization) eklendiğinde dolar: "Konuşmacı 1" vb.
    public let speakerLabel: String?

    public init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        speakerLabel: String? = nil
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speakerLabel = speakerLabel
    }

    public var duration: Double { max(0, endSeconds - startSeconds) }
}

// MARK: - Kalıcı Model

@Model
public final class TranscriptSegmentEntity {

    @Attribute(.unique) public var id: UUID
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var speakerLabel: String?

    /// Ters ilişki `NoteEntity.segments` üzerinde tanımlı (cascade silme).
    public var note: NoteEntity?

    public init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        speakerLabel: String? = nil,
        note: NoteEntity? = nil
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speakerLabel = speakerLabel
        self.note = note
    }
}

public extension TranscriptSegmentEntity {

    convenience init(segment: TranscriptSegment, note: NoteEntity? = nil) {
        self.init(
            id: segment.id,
            startSeconds: segment.startSeconds,
            endSeconds: segment.endSeconds,
            text: segment.text,
            speakerLabel: segment.speakerLabel,
            note: note
        )
    }

    var segment: TranscriptSegment {
        TranscriptSegment(
            id: id,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            speakerLabel: speakerLabel
        )
    }
}
