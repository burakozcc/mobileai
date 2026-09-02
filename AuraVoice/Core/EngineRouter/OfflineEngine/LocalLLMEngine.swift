//
//  LocalLLMEngine.swift
//  AuraVoice
//
//  Cihaz içi özetleme. Ağ yok, sunucu yok, telemetri yok.
//
//  İki katman:
//   1. `LocalSummarizer` protokolü — özetleme sınırı.
//   2. `ExtractiveSummarizer` — bağımlılıksız, model indirmeden çalışan
//      çıkarımsal özetleyici. Cümleleri terim frekansına göre puanlar, karar
//      ve aksiyon cümlelerini ipucu kalıplarıyla ayıklar.
//
//  Nöral bir arka uç (ExecuTorch / llama.cpp / Apple Foundation Models) aynı
//  protokole uyarak takılabilir; `ExtractiveSummarizer` o zaman da yedek
//  kalır — model indirilmemişken veya bellek baskısı altında kullanılır.
//

import Foundation

// MARK: - Sözleşme

public struct SummarizationInput: Sendable {
    public let transcript: String
    public let segments: [TranscriptSegment]
    public let template: SummaryTemplate
    /// ISO 639-1; boşsa Türkçe varsayılır.
    public let language: String
    public let durationSeconds: Double

    public init(
        transcript: String,
        segments: [TranscriptSegment] = [],
        template: SummaryTemplate,
        language: String = "tr",
        durationSeconds: Double = 0
    ) {
        self.transcript = transcript
        self.segments = segments
        self.template = template
        self.language = language
        self.durationSeconds = durationSeconds
    }
}

public protocol LocalSummarizer: Sendable {
    /// Markdown biçiminde özet döner.
    func summarize(_ input: SummarizationInput) async throws -> String
}

// MARK: - Çıkarımsal Özetleyici

public struct ExtractiveSummarizer: LocalSummarizer {

    public init() {}

    public func summarize(_ input: SummarizationInput) async throws -> String {
        Self.buildSummary(input)
    }

    // MARK: Ana akış (saf fonksiyon — testler doğrudan buraya bakar)

    public static func buildSummary(_ input: SummarizationInput) -> String {
        let language = Language(code: input.language)

        var sentences = self.sentences(from: input.transcript)
        // Noktalama içermeyen ASR çıktısında cümle bulunamayabilir; o zaman
        // segment sınırlarını cümle kabul ederiz.
        if sentences.count < 2, !input.segments.isEmpty {
            sentences = input.segments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= minimumSentenceLength }
        }

        guard !sentences.isEmpty else {
            return emptySummary(for: input.template, language: language)
        }

        let frequencies = termFrequencies(in: sentences, language: language)

        // ÖNCE puanla, SONRA sınıflandır. Eskiden sıra tersti ve karar/aksiyon
        // kovasına düşen cümlelerin puanı hiç hesaplanmıyordu; o kovalar
        // transkript sırasına göre doldurulup `prefix(6)`/`prefix(8)` ile
        // kesiliyordu. Uzun bir toplantının son çeyreğinde alınan karar
        // ("cuma yayına alıyoruz") nota hiç girmiyordu.
        // Aynı cümlenin tekrarları bütçe SEÇİMİNDEN önce eleniyor. Sonra
        // elenseydi üç kez "Onaylandı." diyen bir konuşmacı üç slotu da aynı
        // cümleye harcar, render tekrarları atar ve az farkla altta kalan
        // gerçek kararlar hiç seçilmemiş olurdu.
        var seenSentences: Set<String> = []
        let candidates = sentences.enumerated().compactMap { index, sentence -> Candidate? in
            let key = normalized(sentence)
            guard !key.isEmpty, seenSentences.insert(key).inserted else { return nil }
            return Candidate(
                index: index,
                sentence: sentence,
                score: score(sentence, frequencies: frequencies, language: language),
                kind: classify(sentence, language: language)
            )
        }

        let keyPointBudget = keyPointCount(
            forSeconds: input.durationSeconds,
            available: candidates.filter { $0.kind == .keyPoint }.count
        )

        let keyPoints = selectDiverse(
            candidates.filter { $0.kind == .keyPoint },
            limit: keyPointBudget,
            language: language
        )
        let decisions = selectTop(
            candidates.filter { $0.kind == .decision },
            limit: sectionCount(forSeconds: input.durationSeconds, cap: 8)
        )
        let actions = selectTop(
            candidates.filter { $0.kind == .action },
            limit: sectionCount(forSeconds: input.durationSeconds, cap: 10)
        )

        guard !keyPoints.isEmpty || !decisions.isEmpty || !actions.isEmpty else {
            return emptySummary(for: input.template, language: language)
        }

        return render(
            template: input.template,
            language: language,
            durationSeconds: input.durationSeconds,
            keyPoints: keyPoints,
            decisions: decisions,
            actions: actions
        )
    }

    // MARK: Sınıflandırma

    enum CandidateKind: Sendable, Equatable {
        case keyPoint
        case decision
        case action
    }

    struct Candidate: Sendable {
        let index: Int
        let sentence: String
        let score: Double
        let kind: CandidateKind
    }

    /// Cümleyi ana başlık / karar / aksiyon olarak ayırır.
    ///
    /// Eşleşme ham `contains` DEĞİL: "hâlâ kararsızım" normalize edildiğinde
    /// "kararsizim" oluyor ve içinde "karar" geçtiği için Kararlar bölümüne
    /// giriyordu. Artık token öneki aranıyor ve olumsuzlama görülüyor.
    static func classify(_ sentence: String, language: Language) -> CandidateKind {
        let normalizedSentence = normalized(sentence)
        let tokens = allTokens(in: normalizedSentence)

        // Olumsuzlanmış cümle karar da aksiyon da değil: "bu konuda karar
        // veremedik" bir karar, "cuma yayına almayalım" bir görev değil.
        guard !isNegated(normalizedSentence, tokens: tokens, language: language) else {
            return .keyPoint
        }

        if matchesCue(language.decisionCues, tokens: tokens, sentence: normalizedSentence) {
            return .decision
        }
        if matchesCue(language.actionCues, tokens: tokens, sentence: normalizedSentence) {
            return .action
        }
        return .keyPoint
    }

    /// Cümle olumsuzlanmış mı.
    ///
    /// Üç ayrı eşleşme semantiği var ve karıştırmak pahalıya patlıyor:
    ///
    /// · ÖNEK — Türkçe çekim: "değiliz", "değilim", "değildi" hepsi `degil`
    ///   ile yakalanmalı. Token eşitliği bunların hiçbirini görmüyordu ve
    ///   "Mutabık değiliz." açık bir anlaşmazlıkken Kararlar bölümüne karar
    ///   olarak yazılıyordu.
    /// · TAM EŞLEŞME — İngilizce "not": önek aransaydı "note", "nothing",
    ///   "notice" kelimeleri her cümleyi olumsuz sayardı.
    /// · CÜMLE İÇİ — "karar yok" gibi çok kelimeli kalıplar.
    ///
    /// Çıplak "yok" BİLEREK yok: Türkçe toplantı dilinde ağırlıklı olarak
    /// OLUMLAMA taşıyor ("Sorun yok, cuma yayına alıyoruz", "İtiraz yok,
    /// onaylandı") ve gerçek kararları Kararlar bölümünden atıyordu.
    static func isNegated(_ normalizedSentence: String, tokens: [String], language: Language) -> Bool {
        if language.negationPhrases.contains(where: { normalizedSentence.contains($0) }) { return true }
        if language.negationExact.contains(where: { tokens.contains($0) }) { return true }
        return language.negationPrefixes.contains { prefix in
            tokens.contains { $0.hasPrefix(prefix) }
        }
    }

    /// Normalize edilmiş cümlenin bütün kelimeleri (durak kelimeler dahil).
    static func allTokens(in normalizedSentence: String) -> [String] {
        normalizedSentence
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Tek kelimelik ipuçları TOKEN ÖNEKİ, çok kelimeliler ardışık dizi olarak
    /// aranıyor.
    ///
    /// Önek eşleşmesi Türkçe için şart: "göndereceğim" de "gonderec" ipucunu
    /// karşılamalı. Ama kökün kendisi tehlikeliyse ("karar" → "kararsızım")
    /// o kök listeden çıkarıldı; yerine ayrık biçimleri kondu.
    static func matchesCue(_ cues: [String], tokens: [String], sentence: String) -> Bool {
        for cue in cues {
            if cue.contains(" ") {
                if sentence.contains(cue) { return true }
            } else if cue.hasSuffix("c") {
                // Fiil kökü ("yapac", "gonderec"): ekin ÇEKİMLİ gelecek zaman
                // olması şart. Serbest önek eşleşmesi "yapacağımızı hâlâ
                // bilmiyoruz" cümlesini tikleyebilir bir göreve çeviriyordu.
                if tokens.contains(where: { token in
                    guard token.hasPrefix(cue), token.count > cue.count else { return false }
                    return finiteFutureSuffixes.contains(String(token.dropFirst(cue.count)))
                }) { return true }
            } else if tokens.contains(where: { $0.hasPrefix(cue) }) {
                return true
            }
        }
        return false
    }

    /// Fiil kökünden sonra gelebilecek ÇEKİMLİ gelecek zaman ekleri.
    ///
    /// Kapalı küme, çünkü adlaşmış biçimler görev değil: "yapacağımızı"
    /// (-agimizi), "yapacağını" (-agini), "yapacaksak" (-aksak) burada yok.
    /// Ünlü uyumunun iki kolu da var (-acak / -ecek).
    static let finiteFutureSuffixes: Set<String> = [
        "ak", "aksin", "agim", "agiz", "aklar",
        "ek", "eksin", "egim", "egiz", "ekler"
    ]

    // MARK: Seçim

    /// Puana göre en iyiler, sonra konuşma sırasına geri dizilir.
    static func selectTop(_ candidates: [Candidate], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return candidates
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .sorted { $0.index < $1.index }
            .map(\.sentence)
    }

    /// Seçilmiş maddelerle bu orandan az yenilik getiren aday tekrar sayılıyor.
    static let minimumNovelty = 0.34

    /// Puana göre seçerken tekrarı cezalandırır.
    ///
    /// Saf TF puanlaması en çok tekrar eden tek konuya toplanıyordu: 45
    /// dakikalık bir toplantının bütün maddeleri aynı şeyi anlatabiliyordu.
    static func selectDiverse(_ candidates: [Candidate], limit: Int, language: Language) -> [String] {
        guard limit > 0 else { return [] }

        let ordered = candidates.sorted { $0.score > $1.score }
        var selected: [Candidate] = []
        var usedTerms: Set<String> = []

        for candidate in ordered {
            guard selected.count < limit else { break }
            let terms = Set(words(in: candidate.sentence, language: language))
            guard !terms.isEmpty else { continue }

            let novelty = Double(terms.subtracting(usedTerms).count) / Double(terms.count)
            // İlk madde koşulsuz alınıyor; sonrakiler yeterince yeni olmalı.
            if !selected.isEmpty, novelty < minimumNovelty { continue }

            selected.append(candidate)
            usedTerms.formUnion(terms)
        }

        // Çeşitlilik filtresi bütçeyi dolduramadıysa kalanları puana göre ekle:
        // az madde göstermek, tekrar göstermekten daha kötü değil ama boş
        // bölüm göstermek ikisinden de kötü.
        if selected.count < limit {
            let chosen = Set(selected.map(\.index))
            for candidate in ordered where !chosen.contains(candidate.index) {
                guard selected.count < limit else { break }
                // Ana döngüdeki anlamlı-kelime kapısı burada da geçerli.
                // Olmadığında "Tamam." / "Evet." gibi tek durak kelimelik
                // parçalar Ana Başlıklar'a madde olarak giriyordu.
                guard !words(in: candidate.sentence, language: language).isEmpty else { continue }
                selected.append(candidate)
            }
        }

        return selected.sorted { $0.index < $1.index }.map(\.sentence)
    }

    // MARK: Cümleleme

    static let minimumSentenceLength = 12
    /// Noktalama gelmezse bu uzunlukta zorla böleriz.
    static let hardWrapLength = 320

    /// 12 karakter eşiğinin altında kalan ama gerçek cümle olan parçalar.
    ///
    /// "Onaylandı." (10), "Anlaştık." (9), "Kabul." (6) — bir toplantının en
    /// net kararları tam da bu kısalıkta söyleniyor ve eşik onları sessizce
    /// atıyordu. Kısaltmalardan ayırmak için en uzun harf dizisine bakıyoruz:
    /// "Dr." → 2 harf (kısaltma), "Kabul." → 5 harf (cümle).
    static func isCompleteShortSentence(_ text: String) -> Bool {
        guard text.count >= 6, let last = text.last, ".!?…".contains(last) else { return false }
        // Sonlandırıcıdan önce HARF olmalı. Olmazsa ondalık/sürüm noktası
        // cümleyi ortadan bölüyor: "Sürüm 2.1 yayınlandı." ilk noktada
        // "Sürüm 2." olarak kesilip ayrı madde oluyordu.
        guard text.dropLast().last?.isLetter == true else { return false }

        var longestRun = 0
        var run = 0
        for character in text {
            if character.isLetter {
                run += 1
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
        return longestRun >= 4
    }

    public static func sentences(from text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "…", "\n", ";"]
        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= minimumSentenceLength || isCompleteShortSentence(trimmed) {
                result.append(trimmed)
                current = ""
            }
            // Kısa parça: "Dr." gibi kısaltmalar bölünmesin diye biriktirmeye
            // devam ediyoruz.
        }

        for character in text {
            current.append(character)
            if terminators.contains(character) {
                flush()
            } else if current.count >= hardWrapLength, character == " " {
                flush()
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count >= minimumSentenceLength || isCompleteShortSentence(tail) {
            result.append(tail)
        }
        return result
    }

    // MARK: Puanlama

    static func normalized(_ text: String) -> String {
        MeetingKeywordMatcher.normalize(text)
    }

    public static func words(in sentence: String, language: Language) -> [String] {
        normalized(sentence)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !language.stopwords.contains($0) }
    }

    static func termFrequencies(in sentences: [String], language: Language) -> [String: Double] {
        var counts: [String: Double] = [:]
        for sentence in sentences {
            for word in words(in: sentence, language: language) {
                counts[word, default: 0] += 1
            }
        }
        // En yüksek frekansa göre normalize et: uzun kayıtlarda puanlar patlamasın.
        guard let maximum = counts.values.max(), maximum > 0 else { return counts }
        return counts.mapValues { $0 / maximum }
    }

    static func score(_ sentence: String, frequencies: [String: Double], language: Language) -> Double {
        let tokens = words(in: sentence, language: language)
        guard !tokens.isEmpty else { return 0 }
        let total = tokens.reduce(0.0) { $0 + (frequencies[$1] ?? 0) }
        // Uzunluğa karekökle bölmek uzun cümlelerin haksız üstünlüğünü kırar.
        return total / Double(tokens.count).squareRoot()
    }

    static func keyPointCount(forSeconds seconds: Double, available: Int) -> Int {
        guard available > 0 else { return 0 }
        // Her ~3 dakikaya bir madde. Üst sınır 7'ydi: 45 dakikalık toplantı da
        // 7 dakikalık da aynı sayıda madde alıyordu.
        let byDuration = Int((seconds / 180).rounded(.up))
        return min(available, max(3, min(12, byDuration)))
    }

    /// Karar ve aksiyon bölümleri için süreye ölçekli bütçe.
    static func sectionCount(forSeconds seconds: Double, cap: Int) -> Int {
        // Her ~6 dakikaya bir madde; kısa kayıtta da en az 3.
        let byDuration = Int((seconds / 360).rounded(.up))
        return max(3, min(cap, byDuration))
    }

    // MARK: Markdown

    static func render(
        template: SummaryTemplate,
        language: Language,
        durationSeconds: Double,
        keyPoints: [String],
        decisions: [String],
        actions: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("### \(language.heading(for: template))")
        lines.append("_\(language.metaLine(durationSeconds: durationSeconds))_")

        // Aynı cümle iki bölümde ya da bir bölümde iki kez görünmemeli.
        // Özellikle aksiyonlarda kritik: özdeş iki `- [ ]` satırı kullanıcıya
        // bağımsız iki kutu gibi görünür ama aynı satırı işaretler.
        var seen: Set<String> = []
        func unique(_ items: [String]) -> [String] {
            items.compactMap { item in
                let cleaned = cleanup(item)
                let key = MeetingKeywordMatcher.normalize(cleaned)
                guard !key.isEmpty, !seen.contains(key) else { return nil }
                seen.insert(key)
                return cleaned
            }
        }

        let uniqueKeyPoints = unique(keyPoints)
        let uniqueDecisions = unique(decisions)
        let uniqueActions = unique(actions)

        if !uniqueKeyPoints.isEmpty {
            lines.append("")
            lines.append("**\(language.keyPointsTitle(for: template))**")
            lines.append(contentsOf: uniqueKeyPoints.map { "- \($0)" })
        }

        if !uniqueDecisions.isEmpty {
            lines.append("")
            lines.append("**\(language.decisionsTitle)**")
            lines.append(contentsOf: uniqueDecisions.map { "- \($0)" })
        }

        if !uniqueActions.isEmpty {
            lines.append("")
            lines.append("**\(language.actionsTitle)**")
            lines.append(contentsOf: uniqueActions.map { "- [ ] \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    /// Özetlenecek konuşma bulunamadığında gösterilen belge.
    ///
    /// Açıklama meta satırında (`_..._`) DEĞİL, madde olarak yazılıyor:
    /// hiçbir görünüm meta satırını render etmiyor, dolayısıyla gerçek sebep
    /// ("mikrofon bir şey almadı") kullanıcıya hiç ulaşmıyordu — yerine
    /// jenerik "özet üretilmemiş" kartı çıkıyordu.
    static func emptySummary(for template: SummaryTemplate, language: Language) -> String {
        """
        ### \(language.heading(for: template))

        - \(language.emptyNotice)
        """
    }

    /// Madde metnini temizler: baştaki bağlaçları ve markdown'ı bozacak
    /// karakterleri düşürür.
    static func cleanup(_ sentence: String) -> String {
        var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, "-*•>#".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if let last = text.last, last == ";" || last == "," {
            text.removeLast()
        }
        return text
    }
}

// MARK: - Dil Kaynakları

/// Dil modeli `SummaryLanguage.swift`'e taşındı. Eski hâli `isTurkish: Bool`
/// idi — yani dünyada iki dil varmış gibi davranıyordu. Bu takma ad mevcut
/// çağrı noktalarını (`Summarizer.Language(code:)`) olduğu gibi bırakıyor.
public extension ExtractiveSummarizer {
    typealias Language = SummaryLanguage
}
