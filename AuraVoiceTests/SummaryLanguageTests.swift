//
//  SummaryLanguageTests.swift
//  AuraVoiceTests
//
//  Özet boru hattının Türkçe/İngilizce ikilisinden çıkıp bütün dillere
//  hizmet ettiğini doğrular. Eski kurgu `isTurkish: Bool` idi: Türkçe
//  değilse İngilizce varsayıyordu, yani Almanca bir toplantı İngilizce
//  başlık alıyor ve tek bir kararı yakalanamıyordu.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Dil profilleri")
struct SummaryLanguageProfileTests {

    @Test("Bölge ekli kodlar da doğru profile düşüyor", arguments: zip(
        ["tr", "tr-TR", "TR", "", "en", "en-US", "de", "ja", "fr-CA", "ar"],
        [SummaryLanguage.Profile.turkish, .turkish, .turkish, .turkish,
         .english, .english, .generic, .generic, .generic, .generic]
    ))
    func mapsCodeToProfile(code: String, expected: SummaryLanguage.Profile) {
        #expect(SummaryLanguage(code: code).profile == expected)
    }

    @Test("Boş kod Türkçeye düşüyor ama kodu boş kalıyor")
    func emptyCodeKeepsEmptyIdentifier() {
        let language = SummaryLanguage(code: "")
        #expect(language.profile == .turkish)
        #expect(language.code.isEmpty)
        // Model istemine yine de bir dil adı gitmeli.
        #expect(language.englishName == "Turkish")
    }

    @Test("Hedef dil modele İngilizce adıyla söyleniyor", arguments: zip(
        ["de", "ja", "es", "ru", "de-DE", "pt-BR"],
        ["German", "Japanese", "Spanish", "Russian", "German", "Portuguese"]
    ))
    func namesLanguageInEnglish(code: String, name: String) {
        #expect(SummaryLanguage(code: code).englishName == name)
    }

    @Test("Tanınmayan kod çökmüyor, kodun kendisine düşüyor")
    func unknownCodeFallsBackToItself() {
        let language = SummaryLanguage(code: "zzz")
        #expect(language.profile == .generic)
        #expect(!language.englishName.isEmpty)
    }
}

@Suite("Profili olmayan dilde temiz düşüş")
struct GenericLanguageFallbackTests {

    @Test("İpucu listesi olmayan dilde karar/aksiyon ipucu uydurulmuyor")
    func genericHasNoCues() {
        let de = SummaryLanguage(code: "de")
        #expect(de.decisionCues.isEmpty)
        #expect(de.actionCues.isEmpty)
        #expect(de.negationPrefixes.isEmpty)
        #expect(de.negationExact.isEmpty)
        #expect(de.negationPhrases.isEmpty)
        // Durak kelimeler de boş: YANLIŞ bir dilin durak listesini uygulamak
        // gerçek içeriği eleyebilirdi.
        #expect(de.stopwords.isEmpty)
    }

    @Test("Türkçe ve İngilizce listeleri dolu kalıyor")
    func supportedLanguagesKeepCues() {
        #expect(!SummaryLanguage(code: "tr").decisionCues.isEmpty)
        #expect(!SummaryLanguage(code: "tr").stopwords.isEmpty)
        #expect(!SummaryLanguage(code: "en").decisionCues.isEmpty)
        #expect(!SummaryLanguage(code: "en").stopwords.isEmpty)
    }

    @Test("Profili olmayan dilde başlıklar İngilizce'ye düşüyor, Türkçeye değil")
    func genericHeadingsFallBackToEnglish() {
        let de = SummaryLanguage(code: "de")
        #expect(de.heading(for: .meetingNotes) == "Meeting Summary")
        #expect(de.decisionsTitle == "Decisions")
        #expect(de.actionsTitle == "Action Items")
        #expect(!de.metaLine(durationSeconds: 600).contains("dk"))
    }

    @Test("Türkçe başlıklar korunuyor")
    func turkishHeadingsIntact() {
        let tr = SummaryLanguage(code: "tr")
        #expect(tr.heading(for: .meetingNotes) == "Toplantı Özeti")
        #expect(tr.decisionsTitle == "Kararlar")
        #expect(tr.metaLine(durationSeconds: 600) == "Cihaz içi · 10 dk")
    }
}

@Suite("Almanca özet uçtan uca")
struct GermanSummaryTests {

    /// Kararı ve aksiyonu olan gerçekçi bir Almanca toplantı parçası.
    private static let transcript = """
    Wir haben heute über den Produktstart gesprochen. Das Team hat \
    entschieden, den Termin auf März zu verschieben. Anna wird die \
    Präsentation bis Freitag vorbereiten. Die Kosten bleiben unverändert \
    und das Budget wurde bereits genehmigt.
    """

    @Test("Almanca deşifre Türkçe başlık almıyor")
    func germanSummaryHasNoTurkishHeadings() {
        let summary = ExtractiveSummarizer.buildSummary(
            SummarizationInput(
                transcript: Self.transcript,
                template: .meetingNotes,
                language: "de",
                durationSeconds: 600
            )
        )

        #expect(summary.contains("Meeting Summary"))
        #expect(!summary.contains("Toplantı Özeti"))
        #expect(!summary.contains("Ana Başlıklar"))
        #expect(!summary.contains("Cihaz içi"))
    }

    @Test("Almanca özet metnin kendi cümlelerini taşıyor")
    func germanSummaryKeepsSourceSentences() {
        let summary = ExtractiveSummarizer.buildSummary(
            SummarizationInput(
                transcript: Self.transcript,
                template: .meetingNotes,
                language: "de",
                durationSeconds: 600
            )
        )
        // Uydurma yok: çıktının gövdesi kaynaktan gelen Almanca cümleler.
        #expect(summary.contains("Produktstart") || summary.contains("Präsentation")
                || summary.contains("Budget"))
    }

    @Test("İpucu olmadığı için boş karar/aksiyon başlığı basılmıyor")
    func genericSummaryOmitsEmptySections() {
        let summary = ExtractiveSummarizer.buildSummary(
            SummarizationInput(
                transcript: Self.transcript,
                template: .meetingNotes,
                language: "de",
                durationSeconds: 600
            )
        )
        // Almanca ipucu listemiz yok; bu yüzden karar/aksiyon AYIRMIYORUZ.
        // Yanlış bölüm basmaktansa bölümü hiç basmamak doğru davranış —
        // `render` içeriği olmayan başlığı zaten atlıyor.
        let lines = summary.split(separator: "\n").map(String.init)
        for title in ["**Decisions**", "**Action Items**"] {
            if let index = lines.firstIndex(of: title) {
                let next = lines[(index + 1)...].first ?? ""
                #expect(next.hasPrefix("- "), "\(title) başlığı içeriksiz basıldı")
            }
        }
    }

    @Test("Aynı metin Türkçe işaretlenirse Türkçe başlık alıyor")
    func sameTranscriptWithTurkishTagUsesTurkishHeadings() {
        // Dilin çıktıyı GERÇEKTEN sürüklediğini gösteriyor: değişen tek şey kod.
        let summary = ExtractiveSummarizer.buildSummary(
            SummarizationInput(
                transcript: Self.transcript,
                template: .meetingNotes,
                language: "tr",
                durationSeconds: 600
            )
        )
        #expect(summary.contains("Toplantı Özeti"))
    }
}

@Suite("Nöral istem çok dilli")
struct NeuralPromptLanguageTests {

    @Test("Türkçe dışındaki dilde istem hedef dili adıyla söylüyor")
    func namesTargetLanguage() {
        let de = SummaryPrompt.system(language: "de")
        #expect(de.contains("German"))
        #expect(de.contains("K: "))
        #expect(!de.contains("Türkçe"))

        let ko = SummaryPrompt.system(language: "ko")
        #expect(ko.contains("Korean"))
    }

    @Test("Türkçe istemi olduğu gibi kalıyor")
    func turkishPromptUnchanged() {
        let tr = SummaryPrompt.system(language: "tr")
        #expect(tr.contains("Türkçe toplantı özetleyicisisin"))
        #expect(tr.contains("Uydurma"))
    }

    @Test("Biçim önekleri her dilde ASCII kalıyor")
    func prefixesStayASCII() {
        // Dilbilgisi `K:`/`D:`/`A:` dayatıyor ve ayrıştırıcı bunları bekliyor;
        // önekler çevrilirse çıktı sessizce ayrıştırılamaz hâle gelir.
        for code in ["tr", "en", "de", "ja", "ar"] {
            let prompt = SummaryPrompt.system(language: code)
            #expect(prompt.contains("K: "))
            #expect(prompt.contains("D: "))
            #expect(prompt.contains("A: "))
        }
    }

    @Test("Birleştirme istemi de hedef dili taşıyor")
    func reduceCarriesLanguage() {
        let de = SummaryPrompt.reduce(points: "K: Punkt", language: "de")
        #expect(de.contains("German"))
        #expect(de.contains("K: Punkt"))

        let tr = SummaryPrompt.reduce(points: "K: Madde", language: "tr")
        #expect(tr.contains("Tekrarları birleştir"))
    }
}
