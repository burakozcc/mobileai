//
//  MeetingKeywordMatcherTests.swift
//  AuraVoiceTests
//
//  Takvim tetikleyicisinin kalbi: yanlış eşleşme kullanıcıya alakasız bildirim
//  gönderir, kaçırılan eşleşme ise ürünün ana vaadini boşa çıkarır.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Toplantı anahtar kelime eşleştirmesi")
struct MeetingKeywordMatcherTests {

    @Test("Türkçe başlıklar aksan ve büyük harften bağımsız eşleşir", arguments: [
        "Haftalık Toplantı",
        "haftalık toplanti",
        "HAFTALIK TOPLANTI",
        "Pazartesi Görüşme",
        "musteri gorusme"
    ])
    func matchesTurkishTitles(title: String) {
        #expect(MeetingKeywordMatcher.matchedKeyword(inTitle: title) != nil)
    }

    @Test("İngilizce başlıklar eşleşir", arguments: [
        "Weekly Sync",
        "1-on-1 with Ayşe",
        "Product Review",
        "Zoom Call - Design",
        "Sprint Standup"
    ])
    func matchesEnglishTitles(title: String) {
        #expect(MeetingKeywordMatcher.matchedKeyword(inTitle: title) != nil)
    }

    @Test("Toplantı olmayan başlıklar eşleşmez", arguments: [
        "Doktor randevusu",
        "Spor salonu",
        "Anne doğum günü",
        "Uçuş TK1982",
        ""
    ])
    func ignoresNonMeetingTitles(title: String) {
        #expect(MeetingKeywordMatcher.matchedKeyword(inTitle: title) == nil)
    }

    @Test("Eşleşen kelime hangisiyse o döner")
    func returnsMatchedKeyword() {
        #expect(MeetingKeywordMatcher.matchedKeyword(inTitle: "Q3 Kickoff") == "kickoff")
    }

    // MARK: Video bağlantısı

    @Test("URL alanındaki video bağlantısı bulunur")
    func detectsVirtualHostFromURL() {
        let host = MeetingKeywordMatcher.virtualHost(in: [
            "https://acme.zoom.us/j/123456", nil, nil
        ])
        #expect(host == "zoom.us")
    }

    @Test("Notlar alanındaki bağlantı da bulunur")
    func detectsVirtualHostFromNotes() {
        let host = MeetingKeywordMatcher.virtualHost(in: [
            nil, "Ofis - 3. kat", "Katıl: https://meet.google.com/abc-defg-hij"
        ])
        #expect(host == "meet.google.com")
    }

    @Test("Bağlantı yoksa nil döner")
    func returnsNilWhenNoVirtualHost() {
        #expect(MeetingKeywordMatcher.virtualHost(in: [nil, "Kadıköy ofis", "Yüz yüze"]) == nil)
        #expect(MeetingKeywordMatcher.virtualHost(in: []) == nil)
    }

    // MARK: MeetingCandidate

    @Test("Süre dakika olarak doğru hesaplanır")
    func candidateDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = makeCandidate(start: start, end: start.addingTimeInterval(45 * 60))
        #expect(candidate.durationMinutes == 45)
    }

    @Test("Sıfır uzunluklu etkinlik en az 1 dakika gösterir")
    func candidateMinimumDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(makeCandidate(start: start, end: start).durationMinutes == 1)
    }

    @Test("Devam eden toplantı isOngoing döner, isImminent dönmez")
    func candidateOngoing() {
        let candidate = makeCandidate(
            start: Date().addingTimeInterval(-600),
            end: Date().addingTimeInterval(600)
        )
        #expect(candidate.isOngoing)
        // Başlamış bir toplantı "birazdan başlıyor" değildir; Dashboard'da
        // iki rozet aynı anda görünmemeli.
        #expect(!candidate.isImminent)
    }

    @Test("3 dakika sonra başlayan toplantı isImminent döner")
    func candidateImminent() {
        let candidate = makeCandidate(
            start: Date().addingTimeInterval(180),
            end: Date().addingTimeInterval(180 + 1800)
        )
        #expect(candidate.isImminent)
        #expect(!candidate.isOngoing)
    }

    @Test("Uzak gelecekteki toplantı ne devam ediyor ne de birazdan")
    func candidateFuture() {
        let candidate = makeCandidate(
            start: Date().addingTimeInterval(3600),
            end: Date().addingTimeInterval(5400)
        )
        #expect(!candidate.isOngoing)
        #expect(!candidate.isImminent)
    }

    // MARK: normalize

    @Test("Türkçe harfler ASCII'ye indirgenir")
    func normalizeFoldsTurkishCharacters() {
        #expect(MeetingKeywordMatcher.normalize("TOPLANTI") == "toplanti")
        #expect(MeetingKeywordMatcher.normalize("toplantı") == "toplanti")
        #expect(MeetingKeywordMatcher.normalize("Görüşme") == "gorusme")
        #expect(MeetingKeywordMatcher.normalize("İŞ ÇAĞRISI") == "is cagrisi")
    }

    private func makeCandidate(start: Date, end: Date) -> MeetingCandidate {
        MeetingCandidate(
            id: "test#\(Int(start.timeIntervalSince1970))",
            eventIdentifier: "test",
            title: "Test Toplantısı",
            startDate: start,
            endDate: end,
            isVirtual: false,
            locationHint: nil,
            matchedKeyword: "toplantı"
        )
    }
}
