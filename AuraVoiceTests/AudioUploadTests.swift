//
//  AudioUploadTests.swift
//  AuraVoiceTests
//
//  Uzun kayıtların bulut yüklemesi: parçalama planı ve parça transkriptlerinin
//  tek zaman eksenine dikilmesi.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Yükleme parçalama planı")
struct AudioUploadPlannerTests {

    /// 25 MB, AAC mono 16 kHz @ 32 kbps.
    private let limit = 25 * 1024 * 1024
    private let bytesPerSecond: Double = 4_096

    @Test("Sığan kayıt bölünmez")
    func shortRecordingStaysWhole() {
        let chunks = AudioUploadPlanner.plan(
            totalSeconds: 1_800,
            bytesPerSecond: bytesPerSecond,
            limitBytes: limit
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].startSeconds == 0)
        #expect(chunks[0].durationSeconds == 1_800)
    }

    @Test("Uzun kayıt bölünür ve tamamı kapsanır")
    func longRecordingIsCovered() {
        let total: Double = 7_200 // 2 saat
        let chunks = AudioUploadPlanner.plan(
            totalSeconds: total,
            bytesPerSecond: bytesPerSecond,
            limitBytes: limit
        )

        #expect(chunks.count > 1)
        #expect(chunks.first?.startSeconds == 0)
        #expect(abs((chunks.last?.endSeconds ?? 0) - total) < 0.01)

        // Aralarda boşluk kalmamalı: her parça bir öncekinin bitişinden önce başlar.
        for (previous, current) in zip(chunks, chunks.dropFirst()) {
            #expect(current.startSeconds < previous.endSeconds)
            #expect(current.index == previous.index + 1)
        }
    }

    @Test("Her parça sınırın altında kalır")
    func everyChunkFitsTheLimit() {
        let chunks = AudioUploadPlanner.plan(
            totalSeconds: 18_000, // 5 saat
            bytesPerSecond: bytesPerSecond,
            limitBytes: limit
        )
        for chunk in chunks {
            #expect(chunk.durationSeconds * bytesPerSecond <= Double(limit))
        }
    }

    @Test("Komşu parçalar bindirmeli")
    func chunksOverlap() {
        let chunks = AudioUploadPlanner.plan(
            totalSeconds: 12_000,
            bytesPerSecond: bytesPerSecond,
            limitBytes: limit
        )
        #expect(chunks.count > 1)
        for (previous, current) in zip(chunks, chunks.dropFirst()) {
            let overlap = previous.endSeconds - current.startSeconds
            #expect(overlap >= AudioUploadPlanner.overlapSeconds - 0.01)
        }
    }

    @Test("Anlamsız girdide tek parça döner")
    func degenerateInputs() {
        // Süre yok, bit hızı yok, sınır yok — hiçbirinde bölme denenmemeli.
        #expect(AudioUploadPlanner.plan(totalSeconds: 0, bytesPerSecond: bytesPerSecond, limitBytes: limit).count == 1)
        #expect(AudioUploadPlanner.plan(totalSeconds: 600, bytesPerSecond: 0, limitBytes: limit).count == 1)
        #expect(AudioUploadPlanner.plan(totalSeconds: 600, bytesPerSecond: bytesPerSecond, limitBytes: 0).count == 1)
    }

    @Test("Parça sayısı sınır büyüdükçe azalır")
    func biggerLimitMeansFewerChunks() {
        let small = AudioUploadPlanner.plan(totalSeconds: 20_000, bytesPerSecond: bytesPerSecond, limitBytes: limit)
        let large = AudioUploadPlanner.plan(totalSeconds: 20_000, bytesPerSecond: bytesPerSecond, limitBytes: limit * 4)
        #expect(large.count < small.count)
    }
}

@Suite("Parça transkriptlerini birleştirme")
struct TranscriptStitchingTests {

    private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(startSeconds: start, endSeconds: end, text: text)
    }

    private func piece(
        index: Int,
        start: Double,
        duration: Double,
        segments: [TranscriptSegment],
        language: String = "tr"
    ) -> TranscribedChunk {
        TranscribedChunk(
            chunk: AudioUploadChunk(index: index, startSeconds: start, durationSeconds: duration),
            output: TranscriptionOutput(
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                language: language
            )
        )
    }

    @Test("Tek parça olduğu gibi geçer")
    func singleChunkIsUnchanged() {
        let merged = AudioUploadPlanner.merge([
            piece(index: 0, start: 0, duration: 60, segments: [
                segment(0, 5, "Merhaba"),
                segment(5, 9, "Başlıyoruz")
            ])
        ])
        #expect(merged.segments.count == 2)
        #expect(merged.segments[0].startSeconds == 0)
        #expect(merged.segments[1].endSeconds == 9)
        #expect(merged.text == "Merhaba Başlıyoruz")
    }

    @Test("İkinci parçanın zamanları kayıtdaki yerine taşınır")
    func laterChunkTimesAreShifted() {
        let merged = AudioUploadPlanner.merge([
            piece(index: 0, start: 0, duration: 100, segments: [segment(10, 20, "birinci")]),
            piece(index: 1, start: 98.5, duration: 100, segments: [segment(10, 20, "ikinci")])
        ])

        #expect(merged.segments.count == 2)
        #expect(merged.segments[1].startSeconds == 108.5)
        #expect(merged.segments[1].endSeconds == 118.5)
    }

    @Test("Bindirme bölgesindeki tekrar atılır")
    func overlapDuplicatesAreDropped() {
        // İkinci parça 98.5'te başlıyor, ilk 1.5 saniyesi birinciyle ortak.
        let merged = AudioUploadPlanner.merge([
            piece(index: 0, start: 0, duration: 100, segments: [
                segment(90, 99.5, "sınırdaki cümle")
            ]),
            piece(index: 1, start: 98.5, duration: 100, segments: [
                segment(0, 1.0, "sınırdaki cümle"),   // bindirme artığı
                segment(2, 8, "yeni cümle")
            ])
        ])

        #expect(merged.segments.map(\.text) == ["sınırdaki cümle", "yeni cümle"])
        #expect(merged.text == "sınırdaki cümle yeni cümle")
    }

    @Test("Birleştirilmiş segmentler zaman sırasında")
    func mergedSegmentsAreSorted() {
        let merged = AudioUploadPlanner.merge([
            piece(index: 1, start: 98.5, duration: 100, segments: [segment(20, 25, "sonra")]),
            piece(index: 0, start: 0, duration: 100, segments: [segment(5, 10, "önce")])
        ])
        #expect(merged.segments.map(\.text) == ["önce", "sonra"])
        #expect(merged.segments[0].startSeconds < merged.segments[1].startSeconds)
    }

    @Test("Sessiz parça toplantıyı çöpe atmaz")
    func silentChunkIsSkipped() {
        let merged = AudioUploadPlanner.merge([
            piece(index: 0, start: 0, duration: 100, segments: [segment(0, 5, "konuşma var")]),
            piece(index: 1, start: 98.5, duration: 100, segments: [], language: ""),
            piece(index: 2, start: 197, duration: 100, segments: [segment(3, 8, "devam")])
        ])
        #expect(merged.segments.count == 2)
        #expect(merged.text == "konuşma var devam")
        #expect(merged.language == "tr")
    }

    @Test("Boş girdi boş çıktı üretir")
    func emptyInput() {
        let merged = AudioUploadPlanner.merge([])
        #expect(merged.segments.isEmpty)
        #expect(merged.text.isEmpty)
    }

    @Test("Segmentsiz parçanın düz metni korunur")
    func plainTextChunkSurvives() {
        let chunk = AudioUploadChunk(index: 0, startSeconds: 0, durationSeconds: 30)
        let merged = AudioUploadPlanner.merge([
            TranscribedChunk(
                chunk: chunk,
                output: TranscriptionOutput(text: "segmentsiz metin", segments: [], language: "en")
            )
        ])
        #expect(merged.text == "segmentsiz metin")
        #expect(merged.language == "en")
    }
}

@Suite("Yükleme hazırlığı", .serialized)
struct AudioUploadPreparerTests {

    private func makeFile(bytes: Int, ext: String = "wav") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-upload-test-\(UUID().uuidString).\(ext)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("Sınırın altındaki kayıt sıkıştırılmadan geçer")
    func smallFilePassesThrough() async throws {
        let url = try makeFile(bytes: 4_096)
        defer { try? FileManager.default.removeItem(at: url) }

        let upload = try await AudioUploadPreparer().prepare(audioURL: url, limitBytes: 25 * 1024 * 1024)

        #expect(upload.parts.count == 1)
        #expect(upload.parts[0].fileURL == url)
        #expect(upload.parts[0].mimeType == "audio/wav")
        // Geçici dizin üretilmediyse temizlenecek bir şey de yok.
        #expect(upload.temporaryDirectory == nil)
        #expect(!upload.isChunked)
    }

    @Test("Çözülemeyen büyük dosya boyut hatası verir")
    func oversizedUndecodableFileFails() async throws {
        let limit = 64 * 1024
        let url = try makeFile(bytes: limit + 1)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: AuraError.self) {
            _ = try await AudioUploadPreparer().prepare(audioURL: url, limitBytes: limit)
        }
    }

    @Test("Olmayan dosya açık hata verir")
    func missingFileFails() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-yok-\(UUID().uuidString).wav")

        await #expect(throws: AuraError.self) {
            _ = try await AudioUploadPreparer().prepare(audioURL: url, limitBytes: 1024)
        }
    }

    @Test("Geçici dosya temizliği kaynak kaydı silmez")
    func cleanupSpareSourceFile() async throws {
        let url = try makeFile(bytes: 1_024)
        defer { try? FileManager.default.removeItem(at: url) }

        let upload = try await AudioUploadPreparer().prepare(audioURL: url, limitBytes: 25 * 1024 * 1024)
        upload.discardTemporaryFiles()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Uzantıdan MIME türü çıkarılır", arguments: zip(
        ["kayit.wav", "kayit.m4a", "kayit.mp3", "kayit.flac", "kayit.bilinmeyen"],
        ["audio/wav", "audio/mp4", "audio/mpeg", "audio/flac", "audio/wav"]
    ))
    func mimeTypes(name: String, expected: String) {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        #expect(AudioUploadPreparer.mimeType(for: url) == expected)
    }
}
