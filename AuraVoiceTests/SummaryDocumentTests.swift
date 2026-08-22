//
//  SummaryDocumentTests.swift
//  AuraVoiceTests
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Özet ayrıştırma")
struct SummaryDocumentParsingTests {

    private let sample = """
    ### Toplantı Özeti
    _Cihaz içi · Zero-Cloud · 45 dk_

    **Ana Başlıklar**
    - Lansman iki hafta öne çekildi.
    - Tasarım sistemi %80 tamamlandı.

    **Kararlar**
    - Bütçe artışı onaylandı.

    **Aksiyonlar**
    - [ ] App Store metinlerini güncelle
    - [x] TestFlight build'i yayınla
    """

    @Test("Başlık ve meta satırı ayrılır")
    func extractsTitleAndMeta() {
        let document = SummaryDocument.parse(sample)
        #expect(document.title == "Toplantı Özeti")
        #expect(document.meta?.contains("Zero-Cloud") == true)
    }

    @Test("Kalın başlıklar bölüme dönüşür")
    func extractsSections() {
        let document = SummaryDocument.parse(sample)
        #expect(document.sections.map(\.title) == ["Ana Başlıklar", "Kararlar", "Aksiyonlar"])
        #expect(document.sections[0].items.count == 2)
        #expect(document.sections[1].items.count == 1)
    }

    @Test("Görev kutuları durumuyla ayrıştırılır")
    func parsesTasks() {
        let document = SummaryDocument.parse(sample)
        let actions = document.sections.first { $0.title == "Aksiyonlar" }

        #expect(actions?.containsTasks == true)
        #expect(actions?.items == [
            .task(text: "App Store metinlerini güncelle", isDone: false),
            .task(text: "TestFlight build'i yayınla", isDone: true)
        ])
    }

    @Test("Bölümsüz maddeler kaybolmaz")
    func looseItemsSurvive() {
        let document = SummaryDocument.parse("""
        ### Hızlı Not
        - İlk madde
        - İkinci madde
        """)
        #expect(document.sections.isEmpty)
        #expect(document.looseItems.count == 2)
        #expect(!document.isEmpty)
    }

    @Test("Bozuk biçimde de içerik ekranda kalır")
    func malformedContentIsKept() {
        // Ne başlık ne madde — düz paragraf.
        let document = SummaryDocument.parse("Model biçimi tutturamadı ama metin bu.")
        #expect(document.looseItems == [.bullet("Model biçimi tutturamadı ama metin bu.")])
    }

    @Test("Boş girdi boş belge üretir")
    func emptyInput() {
        #expect(SummaryDocument.parse("").isEmpty)
        #expect(SummaryDocument.parse("\n\n   \n").isEmpty)
    }

    @Test("Yıldızlı madde işareti de tanınır")
    func asteriskBullets() {
        let document = SummaryDocument.parse("* birinci\n* ikinci")
        #expect(document.looseItems.count == 2)
    }

    @Test("Büyük harfli [X] de tamamlanmış sayılır")
    func uppercaseCheckmark() {
        #expect(SummaryDocument.parseTask("- [X] bitti") == .task(text: "bitti", isDone: true))
    }
}

@Suite("Görev işaretleme")
struct SummaryTaskToggleTests {

    private let markdown = """
    **Aksiyonlar**
    - [ ] Birinci görev
    - [x] İkinci görev
    """

    @Test("İşaretlenmemiş görev işaretlenir")
    func togglesUnchecked() {
        let updated = SummaryDocument.toggleTask(withText: "Birinci görev", in: markdown)
        #expect(updated.contains("- [x] Birinci görev"))
        // Diğer görev etkilenmemeli.
        #expect(updated.contains("- [x] İkinci görev"))
    }

    @Test("İşaretli görev geri alınır")
    func togglesChecked() {
        let updated = SummaryDocument.toggleTask(withText: "İkinci görev", in: markdown)
        #expect(updated.contains("- [ ] İkinci görev"))
        #expect(updated.contains("- [ ] Birinci görev"))
    }

    @Test("Eşleşmeyen metin markdown'ı değiştirmez")
    func unknownTaskIsNoOp() {
        #expect(SummaryDocument.toggleTask(withText: "olmayan görev", in: markdown) == markdown)
    }

    @Test("Görev dışı satırlar korunur")
    func preservesSurroundingLines() {
        let updated = SummaryDocument.toggleTask(withText: "Birinci görev", in: markdown)
        #expect(updated.hasPrefix("**Aksiyonlar**"))
        #expect(updated.components(separatedBy: .newlines).count == markdown.components(separatedBy: .newlines).count)
    }

    @Test("İlerleme sayacı doğru")
    func progressCount() {
        let progress = SummaryDocument.taskProgress(in: markdown)
        #expect(progress.done == 1)
        #expect(progress.total == 2)
    }

    @Test("Görev yoksa ilerleme sıfır")
    func noTasksMeansZero() {
        let progress = SummaryDocument.taskProgress(in: "- sadece madde\n- başka madde")
        #expect(progress.total == 0)
        #expect(progress.done == 0)
    }

    @Test("İki kez çevirmek başlangıca döner")
    func toggleIsReversible() {
        let once = SummaryDocument.toggleTask(withText: "Birinci görev", in: markdown)
        let twice = SummaryDocument.toggleTask(withText: "Birinci görev", in: once)
        #expect(twice == markdown)
    }
}

@Suite("Bölüm ikonu")
struct SummarySectionIconTests {

    @Test("Başlık anahtar kelimesine göre ikon seçilir", arguments: zip(
        ["Aksiyonlar", "Action Items", "Kararlar", "Decisions", "Konuşulanlar", "Ana Başlıklar"],
        ["checklist", "checklist", "checkmark.seal.fill", "checkmark.seal.fill",
         "bubble.left.and.bubble.right.fill", "sparkles"]
    ))
    func mapsTitleToIcon(title: String, expected: String) {
        #expect(NoteDetailView.icon(for: title) == expected)
    }
}
