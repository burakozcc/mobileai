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
        ["tr", "tr-TR", "TR", "", "en", "en-US", "es-MX", "fr-CA",
         "ar", "hi", "bn", "zh-Hans", "de", "ja"],
        [SummaryLanguage.Profile.turkish, .turkish, .turkish, .turkish,
         .english, .english, .spanish, .french,
         .arabic, .hindi, .bengali, .simplifiedChinese, .generic, .generic]
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
        #expect(de.negationCues.isEmpty)
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


// MARK: - Sekiz dilli özet sözlüğü

@Suite("Özet sözlüğü sekiz dilde")
struct SummaryVocabularyCoverageTests {

    @Test("Her yayınlanan dil KENDİ başlığını alıyor", arguments: zip(
        ["en", "zh-Hans", "hi", "es", "fr", "ar", "bn"],
        ["Meeting Summary", "会议摘要", "मीटिंग का सारांश", "Resumen de la reunión", "Résumé de la réunion", "ملخص الاجتماع", "মিটিংয়ের সারাংশ"]
    ))
    func shipsOwnHeadings(code: String, heading: String) {
        #expect(SummaryLanguage(code: code).heading(for: .meetingNotes) == heading)
    }

    @Test("Bölge eki sözlüğü bozmuyor")
    func regionSuffixResolves() {
        #expect(SummaryLanguage(code: "es-MX").heading(for: .meetingNotes)
                == SummaryLanguage(code: "es").heading(for: .meetingNotes))
        #expect(SummaryLanguage(code: "ar-EG").decisionsTitle
                == SummaryLanguage(code: "ar").decisionsTitle)
        // Geleneksel Çince ayrı yayınlanmıyor; "zh" üzerinden basitleştirilmişe düşüyor.
        #expect(SummaryLanguage(code: "zh-Hant").heading(for: .meetingNotes)
                == SummaryLanguage(code: "zh-Hans").heading(for: .meetingNotes))
    }

    @Test("Yayınlanmayan dil hâlâ İngilizce'ye düşüyor")
    func unshippedLanguageFallsBack() {
        // Almanca sekizlide yok: özet yine çıkıyor, başlıklar İngilizce.
        #expect(SummaryLanguage(code: "de").heading(for: .meetingNotes) == "Meeting Summary")
        #expect(SummaryLanguage(code: "ja").decisionsTitle == "Decisions")
    }

    @Test("Boş dil kodu Türkçe kalıyor")
    func emptyCodeStaysTurkish() {
        #expect(SummaryLanguage(code: "").heading(for: .meetingNotes) == "Toplantı Özeti")
    }

    @Test("Arapça artık kendi ipuçlarını alıyor")
    func arabicHasOwnCues() {
        // Eskiden .generic'ti: başlıkları çevriliydi ama karar/aksiyon
        // ayrımı yapılmıyordu, çünkü eşleştirici Türkçe morfolojisine
        // göre yazılmıştı. Eşleşme yöntemi artık ipucunun kendisinde
        // taşındığı için bu kısıt kalktı.
        let arabic = SummaryLanguage(code: "ar")
        #expect(arabic.profile == .arabic)
        #expect(!arabic.decisionCues.isEmpty)
        #expect(!arabic.actionCues.isEmpty)
        #expect(!arabic.decisionsTitle.isEmpty)
        #expect(arabic.decisionsTitle != "Decisions")
    }

    @Test("Hiçbir ipucu token yolunda ölü kalmıyor")
    func noCueIsDeadOnTokenPath() {
        // `.prefix` ve `.exact` TOKEN üzerinden çalışıyor, dolayısıyla
        // tokenizasyonun iki kuralına da uymak zorundalar. Uymayan ipucu
        // sessizce hiç eşleşmez — en kötü hata türü, çünkü test yazılmazsa
        // kimse fark etmez.
        for code in ["tr", "en", "es", "fr", "ar", "hi", "bn", "zh-Hans"] {
            let language = SummaryLanguage(code: code)
            for cue in language.decisionCues + language.actionCues + language.negationCues
            where cue.matching == .prefix || cue.matching == .exact {
                // 1) Bölme harf/rakam dışındaki her karakterde oluyor: hiçbir
                //    token boşluk ya da tire içermez.
                #expect(cue.text.allSatisfy { $0.isLetter || $0.isNumber },
                        "\(cue.text) token yolunda eşleşemez")
                // 2) `words(in:)` iki karakterden kısa tokenleri atıyor.
                //    Devanagari/Bengalce'de iki grafem kümelik kelimeler
                //    yaygın (सौंप), bu yüzden gerçek bir tuzak.
                #expect(cue.text.count > 2,
                        "\(cue.text) token uzunluk filtresine takılıyor")
            }
        }
    }

    @Test("Çince ipuçları token yoluna hiç girmiyor")
    func chineseNeverUsesTokenPath() {
        // Çincede boşluk yok: bütün cümle tek token oluyor ve uzunluk
        // filtresi kısa ipuçlarını eliyor. Token yolu orada tamamen ölü.
        let chinese = SummaryLanguage(code: "zh-Hans")
        for cue in chinese.decisionCues + chinese.actionCues + chinese.negationCues {
            #expect(cue.matching == .phrase, "\(cue.text) yöntemi \(cue.matching)")
        }
    }

    @Test("metaFormat biçim belirtecini koruyor")
    func metaFormatKeepsSpecifier() {
        for code in ["tr", "en", "zh-Hans", "hi", "es", "fr", "ar", "bn"] {
            let line = SummaryLanguage(code: code).metaLine(durationSeconds: 600)
            // Belirteç düşerse ya da bozulursa ham hâliyle çıktıya sızar.
            // Rakam biçimine bakmıyoruz: bazı yerellerde rakamlar farklı olabilir.
            #expect(!line.contains("%"), "\(code) belirteci tüketilmedi: \(line)")
            #expect(line.count > 4, "\(code) meta satırı boş: \(line)")
        }
    }

    @Test("Sözlük listesi tabloyla aynı kümeyi taşıyor")
    func allMatchesTable() {
        // `all` bölüm ikonu eşleştirmesinde kullanılıyor; tabloda olup
        // listede olmayan bir dil, o dilde ikonların bozulması demek.
        for vocabulary in SummaryVocabulary.table.values {
            #expect(SummaryVocabulary.all.contains(vocabulary))
        }
    }
}

// MARK: - İçerik yönü

@Suite("İçerik yönü")
struct ContentTextDirectionTests {

    @Test("Latin ve Türkçe metin soldan sağa")
    func latinIsLeftToRight() {
        #expect(ContentTextDirection.layoutDirection(for: "Bugün lansmanı konuştuk") == .leftToRight)
        #expect(ContentTextDirection.layoutDirection(for: "Wir haben gesprochen") == .leftToRight)
    }

    @Test("Arapça metin sağdan sola")
    func arabicIsRightToLeft() {
        #expect(ContentTextDirection.layoutDirection(for: "تحدثنا اليوم عن الإطلاق") == .rightToLeft)
    }

    @Test("Yön taşımayan metin karar VERMİYOR")
    func neutralTextYieldsNil() {
        // "Bilmiyorum" ile "soldan sağa" ayrı şeyler: sinyalsiz metinde
        // çevredeki yön korunmalı, LTR dayatılmamalı.
        #expect(ContentTextDirection.layoutDirection(for: "") == nil)
        #expect(ContentTextDirection.layoutDirection(for: "10:00 – 11:00") == nil)
        #expect(ContentTextDirection.layoutDirection(for: "42 %") == nil)
    }

    @Test("Baskın yazı kazanıyor, ilk harf değil")
    func dominantScriptWins() {
        // Deşifre sık sık Latin bir özel adla başlıyor; "ilk güçlü karakter"
        // sezgisi bu yüzden yanılırdı.
        let mostlyArabic = "Zoom تحدثنا اليوم عن الإطلاق وقررنا تأجيل الموعد"
        #expect(ContentTextDirection.layoutDirection(for: mostlyArabic) == .rightToLeft)
    }
}

// MARK: - Bölüm ikonu

@Suite("Bölüm ikonu çok dilli")
struct SectionIconLanguageTests {

    @Test("Sekiz dilde de doğru ikon seçiliyor")
    func iconsResolveInEveryLanguage() {
        for vocabulary in SummaryVocabulary.all {
            #expect(NoteDetailView.icon(for: vocabulary.actions) == "checklist")
            #expect(NoteDetailView.icon(for: vocabulary.decisions) == "checkmark.seal.fill")
        }
    }

    @Test("Tanınmayan başlık varsayılana düşüyor")
    func unknownTitleFallsBack() {
        #expect(NoteDetailView.icon(for: "Rastgele Başlık") == "sparkles")
    }
}


// MARK: - Cümle bölme ve sınıflandırma

@Suite("Cümle bölme çok dilli")
struct MultilingualSentenceSplittingTests {

    @Test("Latin dışı sonlandırıcılar cümleyi bölüyor", arguments: zip(
        ["产品会议决定推迟发布。团队同意了这个方案。",
         "هل وافقنا على العرض؟ نعم، وافقنا عليه.",
         "हमने तारीख तय कर ली। टीम सहमत है।",
         "আমরা তারিখ ঠিক করেছি। দল একমত হয়েছে।"],
        [2, 2, 2, 2]
    ))
    func splitsOnNonLatinTerminators(text: String, expected: Int) {
        // Sonlandırıcı listesi yalnızca Latin noktalamasını tanıdığı sürece
        // bu diller HİÇ bölünmüyordu: Çince'de boşluk da olmadığı için
        // yedek bölme devreye girmiyor ve bütün deşifre tek madde oluyordu.
        #expect(ExtractiveSummarizer.sentences(from: text).count >= expected)
    }

    @Test("Boşluksuz uzun metin yine de bölünüyor")
    func splitsSpacelessLongText() {
        // Yedek bölme `character == " "` şartına bağlıydı; Çince'de boşluk
        // olmadığı için hiç tetiklenmiyordu.
        let long = String(repeating: "会议内容记录", count: 120)
        #expect(ExtractiveSummarizer.sentences(from: long).count > 1)
    }
}

@Suite("Sınıflandırma kuralları")
struct ClassificationRuleTests {

    @Test("Soru cümlesi hiçbir dilde karar sayılmıyor", arguments: [
        "Sağlayıcıya karar verdik mi?",
        "¿Hemos decidido ya el proveedor?",
        "Est-ce qu'on a décidé la date ?",
        "هل وافقنا على العرض؟",
        "我们决定了吗？"
    ])
    func questionsAreNeverDecisions(sentence: String) {
        // Kural KODDA, ipucu listelerinde değil: dilden bağımsız olduğu için
        // altı dilde birden aynı boşluğu açıyordu.
        let language = SummaryLanguage(code: "")
        #expect(ExtractiveSummarizer.classify(sentence, language: language) != .decision)
    }

    @Test("Sözcük sınırı gerçek kararı düşürmüyor")
    func wordBoundaryProtectsRealDecision() {
        // "si queda aprobado" olumsuzluk ipucu sınırsız aransaydı
        // "Así queda aprobado" cümlesindeki GERÇEK kararı da düşürürdü.
        let spanish = SummaryLanguage(code: "es")
        #expect(ExtractiveSummarizer.classify("Así queda aprobado el presupuesto.",
                                              language: spanish) == .decision)
        #expect(ExtractiveSummarizer.classify("Si queda aprobado el presupuesto, arrancamos.",
                                              language: spanish) != .decision)
    }

    @Test("Olumsuz cümle Ana Başlıklar'da kalıyor", arguments: zip(
        ["Bu konuda karar veremedik.",
         "No hemos decidido el proveedor todavía.",
         "Personne ne se charge de ce sujet pour l'instant.",
         "我们还没有决定。"],
        ["tr", "es", "fr", "zh-Hans"]
    ))
    func negatedSentencesStayKeyPoints(sentence: String, code: String) {
        // Cümle KENDİ diliyle sınanıyor: başka bir dilin ipuçlarıyla
        // denemek anlamsız olurdu.
        let language = SummaryLanguage(code: code)
        #expect(ExtractiveSummarizer.classify(sentence, language: language) == .keyPoint)
    }
}
