//
//  StorageTests.swift
//  AuraVoiceTests
//
//  SwiftData katmanı bellek içi konteynerle test edilir — diske hiç dokunulmaz,
//  testler birbirinden tamamen izoledir.
//

import Testing
import Foundation
import SwiftData
@testable import AuraVoice

@Suite("Dalga formu kodlaması")
struct WaveformCodecTests {

    @Test("Kodla-çöz turu değerleri korur")
    func roundTrip() {
        let levels: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        #expect(WaveformCodec.decode(WaveformCodec.encode(levels)) == levels)
    }

    @Test("Boş dizi boş döner")
    func emptyRoundTrip() {
        #expect(WaveformCodec.decode(WaveformCodec.encode([])).isEmpty)
        #expect(WaveformCodec.decode(Data()).isEmpty)
    }

    @Test("Bozuk/eksik veri çökmeden kırpılır")
    func handlesTruncatedData() {
        // 4 baytın katı olmayan veri: tam Float sayısı kadarı okunur.
        let broken = Data([1, 2, 3, 4, 5, 6])
        #expect(WaveformCodec.decode(broken).count == 1)
    }
}

@Suite("Not varlığı dönüşümü")
struct NoteEntityMappingTests {

    @Test("DTO → Entity → DTO turu tüm alanları korur")
    func roundTripPreservesFields() {
        let original = NoteSummary(
            title: "Ürün Sync",
            durationSeconds: 1840,
            mode: .onlineCloudFast,
            template: .phoneCallSummary,
            summaryMarkdown: "### Özet\n- Madde",
            rawTranscript: "ham metin",
            detectedLanguage: "en",
            waveformPreview: [0.1, 0.9, 0.4],
            audioFileName: "rec_abc.wav",
            sourceTrigger: .calendar
        )

        let restored = NoteEntity(summary: original).summary

        #expect(restored.id == original.id)
        #expect(restored.title == original.title)
        #expect(restored.durationSeconds == original.durationSeconds)
        #expect(restored.mode == original.mode)
        #expect(restored.template == original.template)
        #expect(restored.summaryMarkdown == original.summaryMarkdown)
        #expect(restored.rawTranscript == original.rawTranscript)
        #expect(restored.detectedLanguage == original.detectedLanguage)
        #expect(restored.waveformPreview == original.waveformPreview)
        #expect(restored.audioFileName == original.audioFileName)
        #expect(restored.sourceTrigger == original.sourceTrigger)
    }

    @Test("Tanınmayan ham değerler güvenli varsayılana düşer")
    func unknownRawValuesFallBack() {
        let entity = NoteEntity(
            title: "Bozuk kayıt",
            durationSeconds: 10,
            modeRaw: "GELECEKTEKI_MOD",
            templateRaw: "BILINMEYEN_SABLON",
            sourceTriggerRaw: "uzaydan",
            summaryMarkdown: "",
            rawTranscript: "",
            detectedLanguage: "tr",
            waveformData: Data(),
            audioFileName: nil
        )

        // Eski sürümden gelen kayıt uygulamayı çökertmemeli.
        #expect(entity.summary.mode == .offlineZeroCloud)
        #expect(entity.summary.template == .quickNotes)
        #expect(entity.summary.sourceTrigger == .manual)
    }
}

@Suite("Veritabanı yöneticisi", .serialized)
struct DatabaseManagerTests {

    private func makeDatabase() throws -> DatabaseManager {
        DatabaseManager(modelContainer: try AuraModelContainer.inMemory())
    }

    private func makeNote(
        title: String = "Test",
        seconds: Double = 120,
        createdAt: Date = Date()
    ) -> NoteSummary {
        NoteSummary(
            title: title,
            createdAt: createdAt,
            durationSeconds: seconds,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: "- Karar",
            rawTranscript: "…",
            waveformPreview: [0.2, 0.6]
        )
    }

    @Test("Boş veritabanı boş liste döner")
    func startsEmpty() async throws {
        let db = try makeDatabase()
        #expect(try await db.all().isEmpty)
        #expect(try await db.minutesUsedThisMonth() == 0)
    }

    @Test("Eklenen not geri okunur")
    func insertAndFetch() async throws {
        let db = try makeDatabase()
        let note = makeNote(title: "Haftalık Sync")

        let all = try await db.insert(note)

        #expect(all.count == 1)
        #expect(all.first?.title == "Haftalık Sync")
        #expect(all.first?.waveformPreview == [0.2, 0.6])
    }

    @Test("Aynı kimlikle ekleme kopya oluşturmaz, günceller")
    func insertIsIdempotent() async throws {
        let db = try makeDatabase()
        var note = makeNote(title: "İlk hâli")
        try await db.insert(note)

        note.title = "Düzeltilmiş başlık"
        let all = try await db.insert(note)

        #expect(all.count == 1)
        #expect(all.first?.title == "Düzeltilmiş başlık")
    }

    @Test("Notlar en yeniden eskiye sıralanır")
    func notesAreSortedNewestFirst() async throws {
        let db = try makeDatabase()
        let old = makeNote(title: "Eski", createdAt: Date().addingTimeInterval(-7200))
        let new = makeNote(title: "Yeni", createdAt: Date())

        try await db.insert(old)
        let all = try await db.insert(new)

        #expect(all.map(\.title) == ["Yeni", "Eski"])
    }

    @Test("Silme kaydı kaldırır")
    func deleteRemovesNote() async throws {
        let db = try makeDatabase()
        let note = makeNote()
        try await db.insert(note)

        let remaining = try await db.delete(id: note.id)
        #expect(remaining.isEmpty)
    }

    @Test("Olmayan kimliği silmek hata vermez")
    func deleteMissingIsNoOp() async throws {
        let db = try makeDatabase()
        try await db.insert(makeNote())
        let remaining = try await db.delete(id: UUID())
        #expect(remaining.count == 1)
    }

    @Test("Aylık kullanım yalnızca bu ayın kayıtlarını sayar")
    func monthlyUsageIgnoresOlderNotes() async throws {
        let db = try makeDatabase()
        try await db.insert(makeNote(title: "Bu ay", seconds: 120))
        try await db.insert(makeNote(
            title: "Geçen ay",
            seconds: 600,
            createdAt: Date().addingTimeInterval(-40 * 24 * 3600)
        ))

        #expect(abs(try await db.minutesUsedThisMonth() - 2.0) < 0.001)
    }

    @Test("Transkript parçaları saklanır ve zamana göre sıralanır")
    func segmentsAreStoredSorted() async throws {
        let db = try makeDatabase()
        let note = makeNote()
        try await db.insert(note)

        try await db.replaceSegments([
            TranscriptSegment(startSeconds: 10, endSeconds: 14, text: "İkinci"),
            TranscriptSegment(startSeconds: 0, endSeconds: 4, text: "Birinci")
        ], forNote: note.id)

        let segments = try await db.segments(forNote: note.id)
        #expect(segments.map(\.text) == ["Birinci", "İkinci"])
    }

    @Test("Parça değiştirme eskileri bırakmaz")
    func replaceSegmentsClearsPrevious() async throws {
        let db = try makeDatabase()
        let note = makeNote()
        try await db.insert(note)

        try await db.replaceSegments(
            [TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "eski")],
            forNote: note.id
        )
        try await db.replaceSegments(
            [TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "yeni")],
            forNote: note.id
        )

        let segments = try await db.segments(forNote: note.id)
        #expect(segments.count == 1)
        #expect(segments.first?.text == "yeni")
    }

    @Test("Not silinince parçaları da silinir")
    func deletingNoteCascadesSegments() async throws {
        let db = try makeDatabase()
        let note = makeNote()
        try await db.insert(note)
        try await db.replaceSegments(
            [TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "parça")],
            forNote: note.id
        )

        try await db.delete(id: note.id)
        #expect(try await db.segments(forNote: note.id).isEmpty)
    }
}

@Suite("Bellek içi depo")
struct InMemoryNoteRepositoryTests {

    @Test("Repository sözleşmesini karşılar")
    func satisfiesRepositoryContract() async throws {
        let repository: any NoteRepository = InMemoryNoteRepository()
        let note = NoteSummary(
            title: "Sahte",
            durationSeconds: 60,
            mode: .onlineCloudFast,
            template: .quickNotes,
            summaryMarkdown: "- x",
            rawTranscript: ""
        )

        #expect(try await repository.all().isEmpty)
        #expect(try await repository.insert(note).count == 1)
        #expect(abs(try await repository.minutesUsedThisMonth() - 1.0) < 0.001)
        #expect(try await repository.delete(id: note.id).isEmpty)
    }
}
