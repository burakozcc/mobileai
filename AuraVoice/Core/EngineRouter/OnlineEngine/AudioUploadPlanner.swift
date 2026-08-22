//
//  AudioUploadPlanner.swift
//  AuraVoice
//
//  Uzun kayıtların bulut yüklemesi için parçalama planı ve parça
//  transkriptlerinin zaman ekseninde birleştirilmesi.
//
//  Buradaki her şey SAF: dosya sistemi ve AVFoundation'a dokunmaz. Böylece
//  sınır davranışı (kelime kesilmesi, bindirme temizliği, zaman kaydırma)
//  gerçek ses dosyası olmadan test edilebiliyor. Asıl kodlama ve kesme işini
//  `AudioUploadPreparer` yapıyor.
//

import Foundation

public struct AudioUploadChunk: Sendable, Equatable {

    public let index: Int
    /// Parçanın orijinal kayıttaki başlangıcı.
    public let startSeconds: Double
    /// Bindirme kuyruğu dahil parça uzunluğu.
    public let durationSeconds: Double

    public init(index: Int, startSeconds: Double, durationSeconds: Double) {
        self.index = index
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    public var endSeconds: Double { startSeconds + durationSeconds }
}

public struct TranscribedChunk: Sendable {

    public let chunk: AudioUploadChunk
    public let output: TranscriptionOutput

    public init(chunk: AudioUploadChunk, output: TranscriptionOutput) {
        self.chunk = chunk
        self.output = output
    }
}

public enum AudioUploadPlanner {

    /// Komşu parçalar bu kadar saniye üst üste biner ki kesme noktasına denk
    /// gelen kelime iki parçadan en az birinde tam duyulsun. Birleştirmede
    /// fazlalık atılıyor.
    public static let overlapSeconds: Double = 1.5

    /// Sınırın tamamını doldurmuyoruz: AAC bit hızı anlık olarak hedefin
    /// üstüne çıkabiliyor, kenardan dönen 413 tüm işi çöpe atardı.
    public static let safetyFactor: Double = 0.85

    /// Bundan kısa parçalar üretmenin anlamı yok; sınır bu kadar dar geliyorsa
    /// sorun boyut değil, girdi bozukluğudur.
    public static let minimumChunkSeconds: Double = 30

    // MARK: Planlama

    /// Kaydı sınırın altında kalan parçalara böler.
    ///
    /// - Parameters:
    ///   - totalSeconds: Kaydın toplam süresi.
    ///   - bytesPerSecond: Yüklenecek (sıkıştırılmış) biçimin saniyedeki boyutu.
    ///   - limitBytes: Sağlayıcının yükleme sınırı.
    /// - Returns: En az bir parça. Bölmeye gerek yoksa tüm kaydı kapsayan tek parça.
    public static func plan(
        totalSeconds: Double,
        bytesPerSecond: Double,
        limitBytes: Int
    ) -> [AudioUploadChunk] {

        let whole = [AudioUploadChunk(index: 0, startSeconds: 0, durationSeconds: max(0, totalSeconds))]

        guard totalSeconds > 0, bytesPerSecond > 0, limitBytes > 0 else { return whole }

        let budget = Double(limitBytes) * safetyFactor
        var maxChunkSeconds = budget / bytesPerSecond

        // Tek parçaya sığıyorsa hiç bölme.
        if maxChunkSeconds >= totalSeconds { return whole }

        maxChunkSeconds = max(maxChunkSeconds, minimumChunkSeconds)
        let step = maxChunkSeconds - overlapSeconds
        guard step > 0 else { return whole }

        var chunks: [AudioUploadChunk] = []
        var start: Double = 0
        var index = 0

        while start < totalSeconds - 0.001 {
            let duration = min(maxChunkSeconds, totalSeconds - start)
            chunks.append(AudioUploadChunk(index: index, startSeconds: start, durationSeconds: duration))

            // Bu parça kaydın sonuna vardıysa dur.
            if start + duration >= totalSeconds - 0.001 { break }

            start += step
            index += 1
        }

        return chunks.isEmpty ? whole : chunks
    }

    // MARK: Birleştirme

    /// Parça transkriptlerini tek bir transkripte dönüştürür.
    ///
    /// Segment zamanları parçanın kayıttaki başlangıcıyla kaydırılır ve
    /// bindirme bölgesinde ikinci kez duyulan segmentler atılır.
    public static func merge(_ pieces: [TranscribedChunk]) -> TranscriptionOutput {

        let ordered = pieces.sorted { $0.chunk.index < $1.chunk.index }
        guard let first = ordered.first else {
            return TranscriptionOutput(text: "", segments: [], language: "")
        }
        guard ordered.count > 1 else {
            return shifted(first, isFirst: true)
        }

        var segments: [TranscriptSegment] = []
        var texts: [String] = []
        var language = ""

        for (position, piece) in ordered.enumerated() {
            let merged = shifted(piece, isFirst: position == 0)
            segments.append(contentsOf: merged.segments)

            let text = merged.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            if language.isEmpty { language = merged.language }
        }

        return TranscriptionOutput(
            text: texts.joined(separator: " "),
            segments: segments.sorted { $0.startSeconds < $1.startSeconds },
            language: language
        )
    }

    /// Tek parçayı mutlak zamana taşır ve bindirme artığını temizler.
    private static func shifted(_ piece: TranscribedChunk, isFirst: Bool) -> TranscriptionOutput {

        let base = piece.chunk.startSeconds

        // İlk parçanın başında bindirme yok; sonrakilerin ilk `overlapSeconds`
        // saniyesi bir öncekinin kuyruğunda zaten geçti.
        let cutoff = isFirst ? -Double.infinity : base + overlapSeconds

        let kept = piece.output.segments.compactMap { segment -> TranscriptSegment? in
            let start = base + segment.startSeconds
            let end = base + max(segment.startSeconds, segment.endSeconds)
            // Orta noktaya bakıyoruz: sınırı yalayan segment iki parçadan
            // ağırlığı hangisindeyse orada kalsın.
            guard (start + end) / 2 >= cutoff else { return nil }
            return TranscriptSegment(
                id: segment.id,
                startSeconds: start,
                endSeconds: end,
                text: segment.text,
                speakerLabel: segment.speakerLabel
            )
        }

        // Segment varsa metni onlardan kuruyoruz — yoksa bindirmede tekrarlanan
        // cümleler düz metne iki kez girerdi.
        if !piece.output.segments.isEmpty {
            let text = kept
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return TranscriptionOutput(text: text, segments: kept, language: piece.output.language)
        }

        return TranscriptionOutput(
            text: piece.output.text,
            segments: kept,
            language: piece.output.language
        )
    }
}
