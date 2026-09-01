//
//  SummarizerQualityTests.swift
//  AuraVoiceTests
//
//  Çıkarımsal özetleyicinin kalite paketi.
//
//  Buradaki her test denetimde bulunmuş GERÇEK bir hataya karşılık geliyor;
//  hiçbiri varsayımsal değil.
//

import Testing
import Foundation
@testable import AuraVoice

private typealias Summarizer = ExtractiveSummarizer
private let turkish = Summarizer.Language(code: "tr")

private func summary(_ transcript: String, seconds: Double = 600) -> String {
    Summarizer.buildSummary(SummarizationInput(
        transcript: transcript,
        template: .meetingNotes,
        language: "tr",
        durationSeconds: seconds
    ))
}

// MARK: - Sınıflandırma

@Suite("Cümle sınıflandırma")
struct SentenceClassificationTests {

    @Test("Kararsızlık karar sayılmıyor")
    func indecisionIsNotADecision() {
        // Normalize edilince "kararsizim" oluyor ve ham `contains` bunu
        // "karar" ipucuyla eşleştirip Kararlar bölümüne sokuyordu.
        #expect(Summarizer.classify("Bu konuda hâlâ kararsızım.", language: turkish) == .keyPoint)
        #expect(Summarizer.classify("Ekip kararsız kaldı.", language: turkish) == .keyPoint)
    }

    @Test("Gerçek kararlar hâlâ yakalanıyor", arguments: [
        "Lansmanı öne çekmeye karar verdik.",
        "Bütçe artışı onaylandı.",
        "Tasarım diliyle ilgili anlaştık.",
        "Konu karara bağlandı."
    ])
    func realDecisionsAreCaught(sentence: String) {
        #expect(Summarizer.classify(sentence, language: turkish) == .decision)
    }

    @Test("Olumsuzlanan karar cümlesi karar değil")
    func negatedDecisionIsNotADecision() {
        // "Karar veremedik" bir karar değil; eskiden Kararlar bölümüne giriyordu.
        #expect(Summarizer.classify("Bu konuda karar veremedik.", language: turkish) == .keyPoint)
    }

    @Test("Görüş bildirimi görev sayılmıyor")
    func opinionIsNotATask() {
        // Çıplak "gerekiyor" ipucu yüzünden bu cümle tikleyebilir bir göreve
        // dönüşüyor ve kullanıcı "0/8 aksiyon tamamlandı" görüyordu.
        #expect(Summarizer.classify("Bence buna sonra bakmamız gerekiyor.", language: turkish) == .keyPoint)
    }

    @Test("Gerçek aksiyonlar hâlâ yakalanıyor", arguments: [
        "Pazarlama takvimi güncelleyecek.",
        "Ahmet raporu hazırlayacak.",
        "Dosyayı yarın göndereceğim.",
        "Son tarih cuma."
    ])
    func realActionsAreCaught(sentence: String) {
        #expect(Summarizer.classify(sentence, language: turkish) == .action)
    }

    @Test("Olumsuz gelecek zaman görev üretmiyor")
    func negatedFutureIsNotATask() {
        #expect(Summarizer.classify("Cuma yayına almayacağız değil mi.", language: turkish) == .keyPoint)
    }

    @Test("İpucu eşleşmesi kelime sınırında")
    func cueMatchingRespectsTokenBoundary() {
        let tokens = Summarizer.allTokens(in: "hala kararsizim")
        #expect(!Summarizer.matchesCue(["kararlastir"], tokens: tokens, sentence: "hala kararsizim"))
    }

    @Test("Türkçe çekimler önek eşleşmesiyle yakalanıyor")
    func turkishInflectionsMatch() {
        let tokens = Summarizer.allTokens(in: "dosyayi gonderecegim")
        #expect(Summarizer.matchesCue(["gonderec"], tokens: tokens, sentence: "dosyayi gonderecegim"))
    }
}

// MARK: - Bütçeler

@Suite("Madde bütçeleri")
struct SummaryBudgetTests {

    @Test("Uzun toplantı daha çok madde alıyor")
    func longerMeetingsGetMoreItems() {
        // Üst sınır 7'ydi: 45 dakikalık toplantı da 7 dakikalık da aynı
        // sayıda madde alıyordu.
        let short = Summarizer.keyPointCount(forSeconds: 420, available: 50)
        let long = Summarizer.keyPointCount(forSeconds: 2_700, available: 50)
        #expect(long > short)
        #expect(long <= 12)
    }

    @Test("Kısa kayıtta da en az üç madde hedefleniyor")
    func shortRecordingsStillGetMinimum() {
        #expect(Summarizer.keyPointCount(forSeconds: 60, available: 50) == 3)
    }

    @Test("Mevcut cümle sayısı aşılmıyor")
    func neverExceedsAvailable() {
        #expect(Summarizer.keyPointCount(forSeconds: 3_600, available: 2) == 2)
    }

    @Test("Karar ve aksiyon bütçeleri de süreye ölçekli")
    func sectionBudgetsScale() {
        #expect(Summarizer.sectionCount(forSeconds: 300, cap: 8) == 3)
        #expect(Summarizer.sectionCount(forSeconds: 3_600, cap: 8) == 8)
    }
}

// MARK: - Kısa cümleler

@Suite("Kısa cümle eşiği")
struct ShortSentenceTests {

    @Test("Toplantının en net kararları kaybolmuyor", arguments: [
        "Onaylandı.", "Anlaştık.", "Kabul edildi."
    ])
    func shortDecisionsSurvive(sentence: String) {
        // 12 karakter eşiği bunları sessizce atıyordu.
        #expect(Summarizer.isCompleteShortSentence(sentence))
    }

    @Test("Kısaltmalar cümle sayılmıyor", arguments: ["Dr.", "vs.", "bkz."])
    func abbreviationsAreNotSentences(text: String) {
        #expect(!Summarizer.isCompleteShortSentence(text))
    }

    @Test("Sonlandırıcısız kısa parça cümle değil")
    func unterminatedFragmentIsNotASentence() {
        #expect(!Summarizer.isCompleteShortSentence("Kabul"))
    }

    @Test("Kısa karar cümlesi özete giriyor")
    func shortDecisionReachesSummary() {
        let markdown = summary("Uzun uzun lansman takvimini konuştuk bugün. Onaylandı.")
        #expect(markdown.contains("Onaylandı"))
    }
}

// MARK: - Tekrar

@Suite("Tekrar eleme")
struct SummaryDeduplicationTests {

    @Test("Aynı cümle iki kez madde olmuyor")
    func identicalItemsAppearOnce() {
        let markdown = Summarizer.render(
            template: .meetingNotes,
            language: turkish,
            durationSeconds: 600,
            keyPoints: [],
            decisions: [],
            actions: ["Takvimi güncelle.", "Takvimi güncelle."]
        )
        let boxes = markdown.components(separatedBy: "- [ ]").count - 1
        #expect(boxes == 1)
    }

    @Test("Aynı cümle iki bölümde birden görünmüyor")
    func itemDoesNotRepeatAcrossSections() {
        let markdown = Summarizer.render(
            template: .meetingNotes,
            language: turkish,
            durationSeconds: 600,
            keyPoints: ["Lansman öne çekildi."],
            decisions: ["Lansman öne çekildi."],
            actions: []
        )
        #expect(markdown.components(separatedBy: "Lansman öne çekildi").count - 1 == 1)
    }

    @Test("Farklı maddeler korunuyor")
    func distinctItemsSurvive() {
        let markdown = Summarizer.render(
            template: .meetingNotes,
            language: turkish,
            durationSeconds: 600,
            keyPoints: ["Birinci konu.", "İkinci konu."],
            decisions: [],
            actions: []
        )
        #expect(markdown.contains("Birinci konu"))
        #expect(markdown.contains("İkinci konu"))
    }
}

// MARK: - Boş özet

@Suite("Boş özet")
struct EmptySummaryTests {

    @Test("Sebep kullanıcıya ulaşıyor")
    func reasonReachesTheUser() {
        // Açıklama meta satırındaydı ve hiçbir görünüm meta'yı render etmiyor;
        // kullanıcı jenerik "özet üretilmemiş" kartı görüyordu.
        let markdown = Summarizer.emptySummary(for: .meetingNotes, language: turkish)
        let document = SummaryDocument.parse(markdown)

        #expect(!document.looseItems.isEmpty)
        #expect(!document.isEmpty)
    }
}

// MARK: - Görev kutuları

@Suite("Özdeş görev kutuları")
struct DuplicateTaskToggleTests {

    private let markdown = """
    **Aksiyonlar**
    - [ ] Takvimi güncelle
    - [ ] Takvimi güncelle
    """

    @Test("Özdeş kutular birlikte çevriliyor")
    func duplicatesToggleTogether() {
        // Eskiden yalnızca ilki çevriliyordu: ikinci kutuya dokunan kullanıcı
        // birincisinin işaretlendiğini görüyordu.
        let updated = SummaryDocument.toggleTask(withText: "Takvimi güncelle", in: markdown)
        #expect(updated.components(separatedBy: "- [x]").count - 1 == 2)
    }

    @Test("Karışık durumda hepsi ilk kutuya göre hizalanıyor")
    func mixedStateAlignsToFirst() {
        let mixed = """
        - [ ] Takvimi güncelle
        - [x] Takvimi güncelle
        """
        let updated = SummaryDocument.toggleTask(withText: "Takvimi güncelle", in: mixed)
        // İlk kutu kapalıydı → hedef açık; ikisi de açık olmalı.
        #expect(updated.components(separatedBy: "- [x]").count - 1 == 2)
    }

    @Test("İki kez çevirmek başlangıca dönüyor")
    func toggleIsReversible() {
        let once = SummaryDocument.toggleTask(withText: "Takvimi güncelle", in: markdown)
        let twice = SummaryDocument.toggleTask(withText: "Takvimi güncelle", in: once)
        #expect(twice == markdown)
    }

    @Test("Diğer görevler etkilenmiyor")
    func otherTasksAreUntouched() {
        let mixed = """
        - [ ] Takvimi güncelle
        - [ ] Raporu gönder
        """
        let updated = SummaryDocument.toggleTask(withText: "Takvimi güncelle", in: mixed)
        #expect(updated.contains("- [ ] Raporu gönder"))
    }
}

// MARK: - Uçtan uca

@Suite("Özet akışı")
struct SummaryFlowTests {

    private let transcript = """
    Bugün lansman takvimini konuştuk ve iki hafta öne çekmeye karar verdik. \
    Pazarlama ekibi takvimi güncelleyecek. Bütçe konusunda hâlâ kararsızım. \
    Tasarım sistemi neredeyse tamamlandı ve ekip memnun görünüyor. \
    Test otomasyonu için yeni bir araç değerlendiriliyor. Onaylandı.
    """

    @Test("Kararlar ve aksiyonlar ayrı bölümlere düşüyor")
    func sectionsAreSeparated() {
        let document = SummaryDocument.parse(summary(transcript))
        let titles = document.sections.map(\.title)

        #expect(titles.contains("Kararlar"))
        #expect(titles.contains("Aksiyonlar"))
    }

    @Test("Kararsızlık Kararlar bölümüne girmiyor")
    func indecisionStaysOutOfDecisions() {
        let document = SummaryDocument.parse(summary(transcript))
        let decisions = document.sections.first { $0.title == "Kararlar" }?.items ?? []

        #expect(!decisions.contains { $0.text.contains("kararsız") })
    }

    @Test("Üretilen markdown sözleşmeye uyuyor")
    func outputMatchesContract() {
        let markdown = summary(transcript)
        let document = SummaryDocument.parse(markdown)

        #expect(document.title?.isEmpty == false)
        #expect(!document.isEmpty)
        #expect(SummaryDocument.taskProgress(in: markdown).total >= 1)
    }
}

// MARK: - İnceleme sonrası eklenen korumalar

@Suite("Olumsuzlama ayrımı")
struct NegationNuanceTests {

    @Test("\"yok\" olumlama taşıdığında karar korunuyor")
    func affirmativeYokKeepsDecision() {
        // Çıplak "yok" olumsuzluk işareti sayılıyordu ve Türkçe toplantı
        // dilinde ağırlıklı olarak OLUMLAMA taşıyor.
        #expect(Summarizer.classify("İtiraz yok, onaylandı.", language: turkish) == .decision)
        #expect(Summarizer.classify("Sorun yok, anlaştık.", language: turkish) == .decision)
    }

    @Test("Gerçek olumsuz kalıplar hâlâ yakalanıyor")
    func realNegativePhrasesStillCaught() {
        #expect(Summarizer.classify("Bu konuda karar yok.", language: turkish) == .keyPoint)
        #expect(Summarizer.classify("Karar ertelendi.", language: turkish) == .keyPoint)
    }

    @Test("Türkçe çekimli olumsuzluk yakalanıyor")
    func inflectedNegationIsCaught() {
        // Token eşitliği "değiliz"i görmüyordu; açık bir anlaşmazlık Kararlar
        // bölümüne karar olarak yazılıyordu.
        #expect(Summarizer.classify("Bu konuda mutabık değiliz.", language: turkish) == .keyPoint)
        #expect(Summarizer.classify("Ben mutabık değilim.", language: turkish) == .keyPoint)
    }

    @Test("İngilizce olumsuzluk tam eşleşmeyle aranıyor")
    func englishNegationUsesExactMatch() {
        let english = Summarizer.Language(code: "en")
        // Önek aransaydı "note" kelimesi her cümleyi olumsuz yapardı.
        #expect(Summarizer.classify("We decided to note the risk.", language: english) == .decision)
        #expect(Summarizer.classify("We have not decided yet.", language: english) == .keyPoint)
    }
}

@Suite("Gelecek zaman eki")
struct FutureTenseCueTests {

    @Test("Çekimli gelecek zaman görev sayılıyor", arguments: [
        "Pazarlama takvimi güncelleyecek.",
        "Raporu ben hazırlayacağım.",
        "Dosyayı yarın göndereceğiz."
    ])
    func finiteFutureIsATask(sentence: String) {
        #expect(Summarizer.classify(sentence, language: turkish) == .action)
    }

    @Test("Adlaşmış yan cümle görev sayılmıyor", arguments: [
        "Ne yapacağımızı hâlâ bilmiyoruz.",
        "Ne yapacağını sormadık."
    ])
    func nominalisedClauseIsNotATask(sentence: String) {
        // Serbest önek eşleşmesi bunları tikleyebilir göreve çeviriyordu.
        #expect(Summarizer.classify(sentence, language: turkish) != .action)
    }
}

@Suite("Cümleleme kenar durumları")
struct SentenceSplittingEdgeTests {

    @Test("Sürüm numarası cümleyi bölmüyor")
    func versionNumberDoesNotSplit() {
        // "Sürüm 2.1 yayınlandı." ilk noktada "Sürüm 2." olarak kesiliyordu.
        let sentences = Summarizer.sentences(from: "Sürüm 2.1 yayınlandı ve ekip memnun.")
        #expect(sentences.count == 1)
    }

    @Test("Ondalık sayı cümle sayılmıyor")
    func decimalIsNotASentence() {
        #expect(!Summarizer.isCompleteShortSentence("Sürüm 2."))
    }

    @Test("Tek durak kelimelik parça madde olmuyor")
    func stopwordOnlyFragmentIsNotAnItem() {
        // Çeşitlilik filtresinin doldurma döngüsünde anlamlı-kelime kapısı
        // yoktu ve "Tamam." Ana Başlıklar'a madde olarak giriyordu.
        let markdown = summary("Tamam. Evet. Bugün lansman takvimini uzun uzun konuştuk ve netleştirdik.")

        // TAM SATIR karşılaştırması. Alt-dize araması meşru bir maddeyi
        // ("- Evet. Bugün lansman takvimini…") yakalayıp testi yanlış yere
        // kırıyordu.
        let bullets = markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        #expect(!bullets.contains("- Tamam."))
        #expect(!bullets.contains("- Evet."))
    }
}

@Suite("Tekrarlanan cümle bütçesi")
struct RepeatedSentenceBudgetTests {

    @Test("Aynı cümlenin tekrarı slot harcamıyor")
    func repeatsDoNotConsumeBudget() {
        // Tekilleştirme bütçe seçiminden SONRA yapılsaydı üç kez "Onaylandı."
        // diyen konuşmacı üç slotu da harcar, gerçek kararlar hiç seçilmezdi.
        let transcript = """
        Onaylandı. Onaylandı. Onaylandı. \
        Bütçe artışı konusunda anlaştık bugün. \
        Lansman tarihini öne çekmeye karar verdik.
        """
        let document = SummaryDocument.parse(summary(transcript, seconds: 1_800))
        let decisions = document.sections.first { $0.title == "Kararlar" }?.items ?? []

        #expect(decisions.count >= 3)
    }
}
