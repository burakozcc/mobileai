//
//  FormattingAndModelTests.swift
//  AuraVoiceTests
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Biçimlendirme")
struct FormattingTests {

    // NOT: Swift Testing'de eşleşmiş parametreler `zip` ile verilir; iki ayrı
    // koleksiyon yazmak Kartezyen çarpım üretir, tuple dizisi ise derlenmez.
    @Test("Saat biçimi dakika:saniye üretir", arguments: zip(
        [0.0, 5.0, 59.9, 60.0, 125.0, 599.0],
        ["00:00", "00:05", "00:59", "01:00", "02:05", "09:59"]
    ))
    func clockUnderAnHour(seconds: Double, expected: String) {
        #expect(AuraFormat.clock(seconds) == expected)
    }

    @Test("Bir saati aşınca saat alanı eklenir", arguments: zip(
        [3600.0, 3661.0, 7325.0],
        ["1:00:00", "1:01:01", "2:02:05"]
    ))
    func clockOverAnHour(seconds: Double, expected: String) {
        #expect(AuraFormat.clock(seconds) == expected)
    }

    @Test("Negatif süre sıfıra kırpılır")
    func clockClampsNegative() {
        #expect(AuraFormat.clock(-42) == "00:00")
    }

    @Test("Dakika biçimlendirmesi boş string dönmez")
    func minutesIsNeverEmpty() {
        #expect(!AuraFormat.minutes(0).isEmpty)
        #expect(!AuraFormat.minutes(12.4).isEmpty)
        #expect(!AuraFormat.minutes(-5).isEmpty)
    }
}

@Suite("Not modeli")
struct NoteSummaryTests {

    @Test("Önizleme satırı başlık ve meta satırlarını atlar")
    func previewLineSkipsHeadings() {
        let note = makeNote(markdown: """
        ### Toplantı Özeti
        _Offline · Zero-Cloud_
        - Q3 lansmanı öne çekildi
        - İkinci karar
        """)
        #expect(note.previewLine == "Q3 lansmanı öne çekildi")
    }

    @Test("Görev kutusu işaretleri temizlenir")
    func previewLineStripsCheckbox() {
        let note = makeNote(markdown: """
        ### Aksiyonlar
        - [ ] Pazarlama metnini güncelle
        """)
        #expect(note.previewLine == "Pazarlama metnini güncelle")
    }

    @Test("Boş özet için yer tutucu döner")
    func previewLineFallback() {
        #expect(makeNote(markdown: "").previewLine == "Özet hazırlanıyor…")
        #expect(makeNote(markdown: "### Sadece başlık").previewLine == "Özet hazırlanıyor…")
    }

    @Test("Not JSON'a yazılıp geri okunabilir")
    func noteRoundTripsThroughCodable() throws {
        let note = makeNote(markdown: "- Karar")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(NoteSummary.self, from: try encoder.encode(note))

        #expect(decoded.id == note.id)
        #expect(decoded.mode == note.mode)
        #expect(decoded.template == note.template)
        #expect(decoded.waveformPreview == note.waveformPreview)
    }

    private func makeNote(markdown: String) -> NoteSummary {
        NoteSummary(
            title: "Test",
            durationSeconds: 120,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: markdown,
            rawTranscript: "…",
            waveformPreview: [0.1, 0.5, 0.9]
        )
    }
}

@Suite("İşleme modu")
struct ProcessingModeTests {

    @Test("Her modun renk ve gizlilik metni tanımlı")
    func everyModeHasCopy() {
        for mode in ProcessingMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.subtitle.isEmpty)
            #expect(!mode.privacyStatement.isEmpty)
            #expect(!mode.systemImage.isEmpty)
        }
    }

    @Test("Ham değerler kalıcı — UserDefaults uyumluluğu bozulmasın")
    func rawValuesAreStable() {
        #expect(ProcessingMode.offlineZeroCloud.rawValue == "OFFLINE_ZERO_CLOUD")
        #expect(ProcessingMode.onlineCloudFast.rawValue == "ONLINE_CLOUD_FAST")
    }
}
