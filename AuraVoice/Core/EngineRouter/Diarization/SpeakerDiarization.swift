//
//  SpeakerDiarization.swift
//  AuraVoice
//
//  Konuşmacı ayrıştırma sınırı ve birleştirme algoritması.
//
//  TASARIM KARARI: Ayrıştırıcı bize yalnızca "şu aralıkta şu konuşmacı vardı"
//  bilgisini verir; transkript segmentleriyle EŞLEŞTİRMEYİ kendimiz yaparız.
//  Sağlayıcının kendi hizalama yardımcısını kullanmak yerine böyle yapmanın
//  iki nedeni var:
//
//   1. Bağımlılık yüzeyi küçülür — paket API'si değişirse yalnızca adaptör
//      dosyası etkilenir, birleştirme mantığı sabit kalır.
//   2. Birleştirme saf bir fonksiyon olur ve model indirmeden test edilebilir.
//
//  Ayrıca ayrıştırma her iki modda da CİHAZDA çalışır: ses dosyası zaten
//  telefonda olduğu için online modda bile konuşmacıları buluta göndermeye
//  gerek yok.
//

import Foundation

/// Ayrıştırıcının döndürdüğü ham konuşmacı aralığı.
public struct SpeakerTurn: Sendable, Hashable {
    public let startSeconds: Double
    public let endSeconds: Double
    /// Modelin verdiği küme kimliği ("SPEAKER_00" gibi) — kullanıcıya
    /// gösterilmez, önce kararlı bir sıraya çevrilir.
    public let rawSpeakerID: String

    public init(startSeconds: Double, endSeconds: Double, rawSpeakerID: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.rawSpeakerID = rawSpeakerID
    }

    public var duration: Double { max(0, endSeconds - startSeconds) }
}

public struct DiarizationOutput: Sendable {
    public let turns: [SpeakerTurn]
    public let speakerCount: Int

    public init(turns: [SpeakerTurn], speakerCount: Int) {
        self.turns = turns
        self.speakerCount = speakerCount
    }

    public static let empty = DiarizationOutput(turns: [], speakerCount: 0)
}

public typealias DiarizationProgress = @Sendable (Double) -> Void

public protocol SpeakerDiarizer: Sendable {
    /// Model indirilmiş ve kullanıma hazır mı?
    var isAvailable: Bool { get async }
    func diarize(audioURL: URL, progress: DiarizationProgress?) async throws -> DiarizationOutput
}

public extension SpeakerDiarizer {
    func diarize(audioURL: URL) async throws -> DiarizationOutput {
        try await diarize(audioURL: audioURL, progress: nil)
    }
}

// MARK: - Birleştirme

/// Konuşmacı aralıklarını transkript segmentleriyle eşleştirir.
public enum SpeakerAssignment {

    /// Bir segmente konuşmacı atamak için gereken en az örtüşme oranı.
    /// Çok küçük kesişmeler (segment sınırında 50 ms) yanlış atama üretir.
    public static let minimumOverlapRatio: Double = 0.15

    /// Her transkript segmentine, en çok zaman örtüşmesi olan konuşmacıyı atar.
    ///
    /// Etiketler konuşma sırasına göre numaralandırılır: ilk konuşan
    /// "Konuşmacı 1" olur. Modelin küme kimlikleri (`SPEAKER_03` gibi)
    /// rastgele sırada geldiği için doğrudan gösterilemez.
    public static func apply(
        turns: [SpeakerTurn],
        to segments: [TranscriptSegment],
        labelPrefix: String = "Konuşmacı"
    ) -> [TranscriptSegment] {

        guard !turns.isEmpty, !segments.isEmpty else { return segments }

        let ordering = speakerOrdering(turns: turns, segments: segments)

        return segments.map { segment in
            guard let rawID = dominantSpeaker(for: segment, in: turns),
                  let index = ordering[rawID]
            else { return segment }

            return TranscriptSegment(
                id: segment.id,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: segment.text,
                speakerLabel: "\(labelPrefix) \(index)"
            )
        }
    }

    /// Segmentle en çok örtüşen konuşmacının ham kimliği.
    static func dominantSpeaker(for segment: TranscriptSegment, in turns: [SpeakerTurn]) -> String? {
        let segmentDuration = max(segment.duration, 0.001)

        var totals: [String: Double] = [:]
        for turn in turns {
            let overlap = overlapSeconds(
                aStart: segment.startSeconds, aEnd: segment.endSeconds,
                bStart: turn.startSeconds, bEnd: turn.endSeconds
            )
            if overlap > 0 {
                totals[turn.rawSpeakerID, default: 0] += overlap
            }
        }

        guard let best = totals.max(by: { lhs, rhs in
            // Eşit örtüşmede kimlik sırasına göre karar ver: sonuç
            // sözlük sırasına bağlı kalmasın, tekrarlanabilir olsun.
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) else { return nil }

        guard best.value / segmentDuration >= minimumOverlapRatio else { return nil }
        return best.key
    }

    /// Ham kimlik → 1 tabanlı sıra numarası (ilk konuşan 1).
    static func speakerOrdering(turns: [SpeakerTurn], segments: [TranscriptSegment]) -> [String: Int] {
        // Sıralamayı segment akışına göre kuruyoruz: kullanıcı transkripti
        // yukarıdan aşağı okur, ilk gördüğü etiket "1" olmalı.
        var ordering: [String: Int] = [:]
        var next = 1

        for segment in segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            guard let rawID = dominantSpeaker(for: segment, in: turns),
                  ordering[rawID] == nil
            else { continue }
            ordering[rawID] = next
            next += 1
        }

        // Hiçbir segmente düşmeyen konuşmacılar da kararlı bir numara alsın.
        for turn in turns.sorted(by: { $0.startSeconds < $1.startSeconds })
        where ordering[turn.rawSpeakerID] == nil {
            ordering[turn.rawSpeakerID] = next
            next += 1
        }

        return ordering
    }

    static func overlapSeconds(aStart: Double, aEnd: Double, bStart: Double, bEnd: Double) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }
}

// MARK: - Devre dışı ayrıştırıcı

/// Konuşmacı ayrıştırma kapalıyken kullanılan boş uygulama.
public struct DisabledDiarizer: SpeakerDiarizer {
    public init() {}
    public var isAvailable: Bool { get async { false } }
    public func diarize(audioURL: URL, progress: DiarizationProgress?) async throws -> DiarizationOutput {
        .empty
    }
}
