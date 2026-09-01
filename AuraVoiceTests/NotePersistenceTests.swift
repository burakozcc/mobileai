//
//  NotePersistenceTests.swift
//  AuraVoiceTests
//
//  Kaydın işleme başarısız olduğunda kaybolmaması.
//
//  Eskiden ses dosyası "kullanıcı tekrar denesin diye" korunuyordu ama hiçbir
//  NoteEntity onu referans etmediği için bir sonraki açılışta yetim temizliği
//  siliyordu. Uçakta işleme patlayan kullanıcı uygulamayı kapatıp açtığında
//  kaydını bulamıyordu.
//

import Testing
import Foundation
import SwiftData
@testable import AuraVoice

// MARK: - İşleme durumu

@Suite("Not işleme durumu")
struct NoteProcessingStateTests {

    private func note(
        state: NoteProcessingState,
        reason: String? = nil,
        summary: String = "### Başlık\n- Gerçek özet maddesi"
    ) -> NoteSummary {
        NoteSummary(
            title: "Toplantı",
            durationSeconds: 600,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: summary,
            rawTranscript: "metin",
            processingState: state,
            failureReason: reason
        )
    }

    @Test("Yalnızca hazır not tamamlanmış sayılır", arguments: zip(
        [NoteProcessingState.processing, .failed, .ready],
        [true, true, false]
    ))
    func pendingFlag(state: NoteProcessingState, isPending: Bool) {
        #expect(state.isPending == isPending)
    }

    @Test("İşlenen notun önizlemesi durumu anlatıyor")
    func processingPreview() {
        #expect(note(state: .processing).previewLine.contains("hazırlanıyor"))
    }

    @Test("Başarısız notun önizlemesi sebebi gösteriyor")
    func failedPreviewShowsReason() {
        let preview = note(state: .failed, reason: "Cihaz içi model indirilmemiş").previewLine
        #expect(preview == "Cihaz içi model indirilmemiş")
    }

    @Test("Sebep yoksa yine de eyleme dönük bir metin var")
    func failedPreviewFallsBack() {
        #expect(!note(state: .failed).previewLine.isEmpty)
    }

    @Test("Hazır notun önizlemesi özetten geliyor")
    func readyPreviewUsesSummary() {
        // Boş özet metnine düşmemeli: durum alanı önizlemeyi ele geçirmiyor.
        #expect(note(state: .ready).previewLine == "Gerçek özet maddesi")
    }

    @Test("Varsayılan durum hazır — eski çağrı noktaları bozulmuyor")
    func defaultStateIsReady() {
        let legacy = NoteSummary(
            title: "Eski not",
            durationSeconds: 60,
            mode: .onlineCloudFast,
            template: .quickNotes,
            summaryMarkdown: "### X\n- y",
            rawTranscript: "z"
        )
        #expect(legacy.processingState == .ready)
        #expect(legacy.failureReason == nil)
    }
}

// MARK: - Kalıcılık

@Suite("Durum kalıcılığı", .serialized)
struct NoteStatePersistenceTests {

    private func makeManager() throws -> DatabaseManager {
        DatabaseManager(modelContainer: try AuraModelContainer.inMemory())
    }

    private func pendingNote(fileName: String) -> NoteSummary {
        NoteSummary(
            title: "Yarım kalan toplantı",
            durationSeconds: 2_700,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: "",
            rawTranscript: "",
            audioFileName: fileName,
            processingState: .processing
        )
    }

    @Test("İşleme durumu ve sebebi diskten geri okunuyor")
    func stateSurvivesRoundTrip() async throws {
        let manager = try makeManager()
        var note = pendingNote(fileName: "rec_a.wav")
        note.processingState = .failed
        note.failureReason = "Bağlantı yok"

        _ = try await manager.insert(note)
        let stored = try await manager.all().first

        #expect(stored?.processingState == .failed)
        #expect(stored?.failureReason == "Bağlantı yok")
    }

    @Test("Aynı kimlikle ikinci yazma yeni not üretmiyor")
    func retryUpsertsRatherThanDuplicating() async throws {
        // Kayıt ekranı notu önce `.processing` olarak yazıyor, sonra sonucu
        // aynı kimlikle üzerine yazıyor. Bu upsert olmasaydı her kayıt iki not
        // bırakırdı.
        let manager = try makeManager()
        var note = pendingNote(fileName: "rec_b.wav")

        _ = try await manager.insert(note)
        note.processingState = .ready
        note.summaryMarkdown = "### Özet\n- madde"
        _ = try await manager.insert(note)

        let all = try await manager.all()
        #expect(all.count == 1)
        #expect(all.first?.processingState == .ready)
    }

    @Test("Bekleyen notun sesi yetim sayılmıyor")
    func pendingNoteProtectsItsAudio() async throws {
        let manager = try makeManager()
        let directory = DatabaseManager.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "rec_pending_\(UUID().uuidString).wav"
        let url = directory.appendingPathComponent(fileName)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await manager.insert(pendingNote(fileName: fileName))
        _ = try await manager.pruneOrphanedRecordings(allowEphemeralStore: true)

        // İşleme henüz bitmedi ama not var: dosya durmalı.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Yazılmakta olan dosya temizlikten korunuyor")
    func activeRecordingSurvivesPrune() async throws {
        // Widget/Siri yolunda kayıt, açılıştaki temizlikten birkaç yüz ms
        // sonra başlıyor. Dosya kayıt başlar başlamaz oluşuyor, notu ise ancak
        // kayıt bitince yazılıyor — aradaki pencerede temizlik onu siliyordu.
        let manager = try makeManager()
        let directory = DatabaseManager.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "rec_active_\(UUID().uuidString).wav"
        let url = directory.appendingPathComponent(fileName)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        defer {
            AudioRecorderService.clearActive()
            try? FileManager.default.removeItem(at: url)
        }

        AudioRecorderService.markActive(url)
        _ = try await manager.pruneOrphanedRecordings(allowEphemeralStore: true)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(AudioRecorderService.activeRecordingFileName() == fileName)
    }

    @Test("Bellek içi konteynerde temizlik hiç çalışmıyor")
    func ephemeralStoreNeverPrunes() async throws {
        // Kalıcı store açılamadığında veritabanı BOŞ oluyor ve diskteki her
        // dosya yetim görünüyor. Koruma olmasaydı tek bir açılış kullanıcının
        // bütün kayıtlarını silerdi. (Diğer testler `allowEphemeralStore: true`
        // ile temizlik mantığının kendisini sınıyor; bu test korumayı sınıyor.)
        let manager = try makeManager()
        let directory = DatabaseManager.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("rec_guard_\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        AudioRecorderService.clearActive()
        let removed = try await manager.pruneOrphanedRecordings()

        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Gerçek yetim dosya hâlâ siliniyor")
    func genuineOrphanIsStillRemoved() async throws {
        let manager = try makeManager()
        let directory = DatabaseManager.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("rec_orphan_\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        AudioRecorderService.clearActive()
        _ = try await manager.pruneOrphanedRecordings(allowEphemeralStore: true)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Yarım kalmış işleme kurtarma

@Suite("Yarım kalmış işleme", .serialized)
struct InterruptedProcessingTests {

    private func makeManager() throws -> DatabaseManager {
        DatabaseManager(modelContainer: try AuraModelContainer.inMemory())
    }

    private func note(state: NoteProcessingState, title: String) -> NoteSummary {
        NoteSummary(
            title: title,
            durationSeconds: 900,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: state == .ready ? "### X\n- y" : "",
            rawTranscript: "",
            processingState: state
        )
    }

    @Test("Takılı kalan not tekrar denenebilir hale geliyor")
    func stuckNoteBecomesFailed() async throws {
        let manager = try makeManager()
        _ = try await manager.insert(note(state: .processing, title: "Yarım toplantı"))

        let recovered = try await manager.recoverInterruptedProcessing()

        #expect(recovered == 1)
        let stored = try await manager.all().first
        #expect(stored?.processingState == .failed)
        #expect(stored?.failureReason?.isEmpty == false)
    }

    @Test("Hazır ve başarısız notlara dokunulmuyor")
    func onlyProcessingNotesAreTouched() async throws {
        let manager = try makeManager()
        _ = try await manager.insert(note(state: .ready, title: "Tamamlanmış"))

        var failed = note(state: .failed, title: "Zaten başarısız")
        failed.failureReason = "Bağlantı yok"
        _ = try await manager.insert(failed)

        let recovered = try await manager.recoverInterruptedProcessing()

        #expect(recovered == 0)
        let states = try await manager.all().map(\.processingState)
        #expect(Set(states) == Set([.ready, .failed]))
        let reason = try await manager.all().first { $0.title == "Zaten başarısız" }?.failureReason
        #expect(reason == "Bağlantı yok")
    }

    @Test("Kurtarılacak not yoksa iş yapılmıyor")
    func noOpWhenNothingStuck() async throws {
        let manager = try makeManager()
        #expect(try await manager.recoverInterruptedProcessing() == 0)
    }

    @Test("Birden fazla takılı not birlikte kurtarılıyor")
    func recoversAllStuckNotes() async throws {
        let manager = try makeManager()
        _ = try await manager.insert(note(state: .processing, title: "Bir"))
        _ = try await manager.insert(note(state: .processing, title: "İki"))

        #expect(try await manager.recoverInterruptedProcessing() == 2)
        let states = try await manager.all().map(\.processingState)
        #expect(states.allSatisfy { $0 == .failed })
    }
}
