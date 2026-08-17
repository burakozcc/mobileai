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

        var decisions: [String] = []
        var actions: [String] = []
        var scored: [(index: Int, sentence: String, score: Double)] = []

        for (index, sentence) in sentences.enumerated() {
            if language.decisionCues.contains(where: { normalized(sentence).contains($0) }) {
                decisions.append(sentence)
            } else if language.actionCues.contains(where: { normalized(sentence).contains($0) }) {
                actions.append(sentence)
            } else {
                scored.append((index, sentence, score(sentence, frequencies: frequencies, language: language)))
            }
        }

        let keyPointBudget = keyPointCount(forSeconds: input.durationSeconds, available: scored.count)
        let keyPoints = scored
            .sorted { $0.score > $1.score }
            .prefix(keyPointBudget)
            // Puana göre seçip zamana göre geri sıralıyoruz: özet konuşmanın
            // akışını korusun.
            .sorted { $0.index < $1.index }
            .map(\.sentence)

        return render(
            template: input.template,
            language: language,
            durationSeconds: input.durationSeconds,
            keyPoints: keyPoints,
            decisions: Array(decisions.prefix(6)),
            actions: Array(actions.prefix(8))
        )
    }

    // MARK: Cümleleme

    static let minimumSentenceLength = 12
    /// Noktalama gelmezse bu uzunlukta zorla böleriz.
    static let hardWrapLength = 320

    public static func sentences(from text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "…", "\n", ";"]
        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= minimumSentenceLength {
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
        if tail.count >= minimumSentenceLength { result.append(tail) }
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
        // Her ~3 dakikaya bir madde, 3...7 arasında sınırlı.
        let byDuration = Int((seconds / 180).rounded(.up))
        return min(available, max(3, min(7, byDuration)))
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

        if !keyPoints.isEmpty {
            lines.append("")
            lines.append("**\(language.keyPointsTitle(for: template))**")
            lines.append(contentsOf: keyPoints.map { "- \(cleanup($0))" })
        }

        if !decisions.isEmpty {
            lines.append("")
            lines.append("**\(language.decisionsTitle)**")
            lines.append(contentsOf: decisions.map { "- \(cleanup($0))" })
        }

        if !actions.isEmpty {
            lines.append("")
            lines.append("**\(language.actionsTitle)**")
            lines.append(contentsOf: actions.map { "- [ ] \(cleanup($0))" })
        }

        return lines.joined(separator: "\n")
    }

    static func emptySummary(for template: SummaryTemplate, language: Language) -> String {
        """
        ### \(language.heading(for: template))
        _\(language.emptyNotice)_
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

public extension ExtractiveSummarizer {

    struct Language: Sendable {

        public let isTurkish: Bool

        public init(code: String) {
            let lowered = code.lowercased()
            // Boş/bilinmeyen dilde Türkçe varsayıyoruz: hedef kitle Türkçe.
            self.isTurkish = lowered.isEmpty || lowered.hasPrefix("tr")
        }

        public var stopwords: Set<String> {
            isTurkish ? Self.turkishStopwords : Self.englishStopwords
        }

        public var decisionCues: [String] {
            isTurkish
                ? ["karar", "kararlastir", "anlastik", "onaylandi", "kabul edildi",
                   "netlesti", "belirlendi", "sonuclandi", "mutabik"]
                : ["decided", "agreed", "approved", "conclusion", "resolved",
                   "we will go with", "consensus"]
        }

        public var actionCues: [String] {
            isTurkish
                ? ["yapacak", "hazirlayacak", "gonderecek", "paylasacak", "iletecek",
                   "bakacak", "takip", "sorumlu", "gorev", "atandi", "son tarih",
                   "deadline", "gerekiyor", "yapilmali", "hazirlanmali", "kontrol et"]
                : ["action item", "todo", "to-do", "follow up", "follow-up",
                   "will send", "will prepare", "need to", "needs to", "should",
                   "assign", "responsible", "deadline", "due by", "let us"]
        }

        public func heading(for template: SummaryTemplate) -> String {
            if isTurkish {
                switch template {
                case .meetingNotes:     return "Toplantı Özeti"
                case .phoneCallSummary: return "Görüşme Özeti"
                case .quickNotes:       return "Hızlı Not"
                }
            }
            switch template {
            case .meetingNotes:     return "Meeting Summary"
            case .phoneCallSummary: return "Call Summary"
            case .quickNotes:       return "Quick Notes"
            }
        }

        public func keyPointsTitle(for template: SummaryTemplate) -> String {
            if isTurkish {
                switch template {
                case .meetingNotes:     return "Ana Başlıklar"
                case .phoneCallSummary: return "Konuşulanlar"
                case .quickNotes:       return "Öne Çıkanlar"
                }
            }
            switch template {
            case .meetingNotes:     return "Key Points"
            case .phoneCallSummary: return "Discussed"
            case .quickNotes:       return "Highlights"
            }
        }

        public var decisionsTitle: String { isTurkish ? "Kararlar" : "Decisions" }
        public var actionsTitle: String { isTurkish ? "Aksiyonlar" : "Action Items" }

        public var emptyNotice: String {
            isTurkish
                ? "Özetlenecek konuşma bulunamadı."
                : "No speech found to summarize."
        }

        public func metaLine(durationSeconds: Double) -> String {
            let minutes = max(1, Int((durationSeconds / 60).rounded()))
            return isTurkish
                ? "Cihaz içi · Zero-Cloud · \(minutes) dk"
                : "On-device · Zero-Cloud · \(minutes) min"
        }

        // Aksansız yazılmış: karşılaştırma `normalize` sonrası yapılıyor.
        static let turkishStopwords: Set<String> = [
            "ama", "ancak", "artik", "asla", "bana", "bazi", "belki", "ben", "beni",
            "benim", "bile", "bir", "biraz", "birkac", "birsey", "biz", "bize",
            "bizim", "bu", "buna", "bunda", "bundan", "bunu", "bunun", "burada",
            "cok", "cunku", "daha", "dahi", "de", "defa", "diger", "diye", "eger",
            "gibi", "hala", "hangi", "hani", "hem", "henuz", "hep", "hepsi", "her",
            "hic", "icin", "ile", "ise", "kadar", "karsin", "kendi", "ki", "kim",
            "mi", "mu", "mu", "nasil", "ne", "neden", "nerede", "niye", "o", "olan",
            "olarak", "oldu", "oldugu", "olur", "onlar", "onu", "onun", "oysa",
            "sadece", "sanki", "sen", "senin", "siz", "sizin", "sonra", "sey",
            "seyler", "simdi", "tum", "tabi", "ve", "veya", "ya", "yani",
            "yine", "yoksa", "zaten", "zira", "var", "yok", "evet", "hayir",
            "tamam", "peki", "iste", "acaba", "bakin"
        ]

        static let englishStopwords: Set<String> = [
            "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
            "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
            "his", "how", "its", "new", "now", "old", "see", "two", "way", "who",
            "boy", "did", "she", "use", "man", "too", "with", "that", "this",
            "have", "from", "they", "will", "would", "there", "their", "what",
            "about", "which", "when", "make", "like", "time", "just", "know",
            "take", "into", "your", "some", "them", "than", "then", "look",
            "only", "come", "over", "also", "back", "after", "work", "well",
            "even", "want", "because", "these", "give", "most", "yeah", "okay",
            "right", "really", "actually", "basically", "kind", "sort", "gonna"
        ]
    }
}
