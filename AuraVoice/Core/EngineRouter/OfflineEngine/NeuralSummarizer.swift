//
//  NeuralSummarizer.swift
//  AuraVoice
//
//  Cihaz içi nöral özetleme — map-reduce boru hattı.
//
//  MODEL MARKDOWN YAZMIYOR. Model yalnızca `K:` / `D:` / `A:` satırları
//  üretiyor; nihai markdown yine `ExtractiveSummarizer.render` ile kuruluyor.
//  Sebebi tek: uygulamada tek bir markdown üreteci kalsın. `SummaryDocument`
//  parse'ının sözleşmesi (### başlık, _meta_, **Bölüm**, - [ ] görev) ve
//  `toggleTask` / `taskProgress` davranışı modelin keyfine bırakılamaz.
//
//  Bu dosya HİÇBİR ÜÇÜNCÜ PARTİ BAĞIMLILIĞA dokunmuyor. Gerçek çıkarım
//  `TextGenerator` protokolünün arkasında; llama.cpp arka ucu ayrı bir dosyada
//  gelecek ve buradaki mantık sahte üreticiyle bugünden test edilebiliyor.
//

import Foundation

// MARK: - Üretici sınırı

public protocol TextGenerator: Sendable {

    /// Model yüklü ve çıkarım yapabilecek durumda mı.
    var isReady: Bool { get async }

    /// Gramerle kısıtlanmış üretim.
    ///
    /// - Parameter grammar: GBNF metni. Modelin biçim dışına çıkmasını
    ///   YAPISAL olarak imkânsız kılıyor; prompt'a güvenmek yetmiyor çünkü
    ///   `SummaryDocument.parse` her serseri satırı sessizce maddeye çeviriyor.
    func generate(prompt: String, grammar: String?, maxTokens: Int) async throws -> String

    /// Gerçek tokenizer ile ölçüm. Parça bütçesi bunun üzerinden hesaplanıyor.
    func tokenCount(_ text: String) async -> Int

    /// Modeli bellekten bırakır.
    func unload() async
}

// MARK: - Çıktı ayrıştırma

/// Modelin ürettiği `K: / D: / A:` satırlarının yapılandırılmış hâli.
public struct Points: Sendable, Equatable {

    public var keyPoints: [String] = []
    public var decisions: [String] = []
    public var actions: [String] = []

    public init(keyPoints: [String] = [], decisions: [String] = [], actions: [String] = []) {
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actions = actions
    }

    public var isEmpty: Bool {
        keyPoints.isEmpty && decisions.isEmpty && actions.isEmpty
    }

    public var totalCount: Int {
        keyPoints.count + decisions.count + actions.count
    }

    // MARK: Ayrıştırma

    public static func parse(_ raw: String) -> Points {
        var points = Points()

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 2 else { continue }

            // Gramer bunu garanti ediyor ama gramersiz bir arka uç ya da
            // ileride değişen bir model olabilir; ayrıştırıcı yine de dayanıklı.
            let prefix = trimmed.prefix(2).uppercased()
            let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            switch prefix {
            case "K:": points.keyPoints.append(body)
            case "D:": points.decisions.append(body)
            case "A:": points.actions.append(body)
            default:   continue
            }
        }

        return points
    }

    /// Başka bir parçanın sonuçlarını tekrar üretmeden ekler.
    ///
    /// Bindirmeli parçalama sınırdaki cümleyi iki kez gösteriyor; ayrıca model
    /// aynı kararı farklı parçalarda tekrar edebiliyor. Normalizasyon
    /// `MeetingKeywordMatcher` ile aynı — Türkçe katlama dahil.
    public mutating func merge(_ other: Points) {
        keyPoints = Self.appendingUnique(keyPoints, other.keyPoints)
        decisions = Self.appendingUnique(decisions, other.decisions)
        actions = Self.appendingUnique(actions, other.actions)
    }

    static func appendingUnique(_ existing: [String], _ incoming: [String]) -> [String] {
        var seen = Set(existing.map { MeetingKeywordMatcher.normalize($0) })
        var result = existing

        for candidate in incoming {
            let key = MeetingKeywordMatcher.normalize(candidate)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(candidate)
        }
        return result
    }

    /// Ara özet için modele geri verilecek metin.
    public func asLines() -> String {
        (keyPoints.map { "K: \($0)" }
            + decisions.map { "D: \($0)" }
            + actions.map { "A: \($0)" })
            .joined(separator: "\n")
    }
}

// MARK: - Prompt ve gramer

public enum SummaryPrompt {

    /// Modelin biçim dışına çıkmasını yapısal olarak engelleyen dilbilgisi.
    public static let grammar = """
    root ::= line+
    line ::= prefix text "\\n"
    prefix ::= "K: " | "D: " | "A: "
    text ::= [^\\n]+
    """

    /// Sistem istemi.
    ///
    /// Türkçe kendi istemini koruyor: birincil kitle o ve bu metin deneyerek
    /// ayarlandı. Diğer BÜTÜN diller tek bir İngilizce şablondan geçiyor ve
    /// hedef dil şablonun içinde ADIYLA söyleniyor.
    ///
    /// Eski İngilizce dalın hatası buydu: modele hangi dilde yazacağını hiç
    /// söylemiyordu. Almanca bir deşifrede model çoğu zaman girdiyi taklit
    /// edip Almanca yazar, ama talimatın kendisi İngilizce olduğu için
    /// İngilizce özetlemesi de bir o kadar olası — kullanıcı Almanca
    /// toplantısının özetini İngilizce görebiliyordu. Artık dil bir emir.
    ///
    /// `K:`/`D:`/`A:` önekleri her dilde ASCII kalıyor: dilbilgisi onları
    /// yapısal olarak dayatıyor ve ayrıştırıcı onları bekliyor.
    public static func system(language: String) -> String {
        let target = SummaryLanguage(code: language)
        guard target.profile == .turkish else {
            return """
            You summarise meeting transcripts. Write every line in \(target.englishName). \
            Output ONLY lines in this format, nothing else — no preamble, no headings:
            K: <key point>
            D: <decision made>
            A: <action item — who, what, when>
            One line each, max 120 characters. If the text contains no decision, \
            omit D lines. If it contains no action, omit A lines. Do not invent \
            anything; write only what the text contains.
            """
        }
        return """
        Sen bir Türkçe toplantı özetleyicisisin. Sana verilen deşifre parçasından \
        SADECE aşağıdaki biçimde satırlar üret. Açıklama, giriş cümlesi ya da \
        başlık yazma:
        K: <ana fikir>
        D: <alınan karar>
        A: <yapılacak iş — kim, ne, ne zaman>
        Her satır tek satır olsun ve 120 karakteri geçmesin. Metinde karar yoksa \
        D: satırı, aksiyon yoksa A: satırı yazma. Uydurma; yalnızca metinde geçeni yaz.
        """
    }

    /// Tek parçayı özetleyen istem.
    public static func map(chunk: String, language: String) -> String {
        """
        \(system(language: language))

        --- DEŞİFRE PARÇASI ---
        \(chunk)
        --- SON ---
        """
    }

    /// Parça sonuçlarını tek listeye indiren istem.
    public static func reduce(points: String, language: String) -> String {
        let target = SummaryLanguage(code: language)
        let instruction = target.profile == .turkish
            ? "Aşağıdaki maddeler aynı toplantının farklı bölümlerinden geliyor. Tekrarları birleştir, aynı biçimde ve daha kısa bir liste üret. Yeni bilgi ekleme."
            : "The items below come from different parts of the same meeting. Merge duplicates and produce a shorter list in the same format, still written in \(target.englishName). Do not add new information."

        return """
        \(system(language: language))

        \(instruction)

        --- MADDELER ---
        \(points)
        --- SON ---
        """
    }
}

// MARK: - Özetleyici

public struct NeuralSummarizer: LocalSummarizer {

    /// Bir map çağrısının üreteceği azami token.
    public static let mapMaxTokens = 220
    /// Reduce daha uzun bir liste üretebilir.
    public static let reduceMaxTokens = 512
    /// Bu sayıdan fazla parça sonucu tek reduce'a sığmıyor; hiyerarşik iniyoruz.
    public static let collapseGroupSize = 8

    private let generator: any TextGenerator
    private let tokenBudget: Int

    public init(
        generator: any TextGenerator,
        tokenBudget: Int = TranscriptChunker.defaultTokenBudget
    ) {
        self.generator = generator
        self.tokenBudget = tokenBudget
    }

    public func summarize(_ input: SummarizationInput) async throws -> String {
        do {
            return try await neuralSummary(input)
        } catch is CancellationError {
            // İptal kullanıcının kararı; yedek özet üretmek yanlış olurdu.
            throw CancellationError()
        } catch {
            // BAŞKA HER HATA yedeğe düşüyor. Kullanıcı hiçbir koşulda özetsiz
            // kalmamalı: model yüklenemedi, bellek yetmedi, çıktı bozuldu —
            // hiçbiri 45 dakikalık toplantıyı özetsiz bırakmayı haklı çıkarmaz.
            return ExtractiveSummarizer.buildSummary(input)
        }
    }

    // MARK: Map-reduce

    private func neuralSummary(_ input: SummarizationInput) async throws -> String {

        guard await generator.isReady else {
            throw AuraError.offlineModelMissing
        }

        let chunks = TranscriptChunker.chunks(
            segments: input.segments,
            transcript: input.transcript,
            tokenBudget: tokenBudget
        )
        guard !chunks.isEmpty else {
            throw AuraError.engineFailure(String(localized: "Özetlenecek deşifre bulunamadı."))
        }

        // MAP — parçalar sırayla; eşzamanlı çıkarım tek modelde zaten mümkün
        // değil ve bellek tepe noktasını ikiye katlardı.
        var merged = Points()
        for chunk in chunks {
            try Task.checkCancellation()
            let raw = try await generator.generate(
                prompt: SummaryPrompt.map(chunk: chunk.text, language: input.language),
                grammar: SummaryPrompt.grammar,
                maxTokens: Self.mapMaxTokens
            )
            merged.merge(Points.parse(raw))
        }

        guard !merged.isEmpty else {
            throw AuraError.engineFailure(String(localized: "Model özet üretmedi."))
        }

        // REDUCE — tek parça varsa gereksiz; model zaten o parçayı özetledi.
        let final = chunks.count > 1 ? try await reduce(merged, language: input.language) : merged

        return ExtractiveSummarizer.render(
            template: input.template,
            language: ExtractiveSummarizer.Language(code: input.language),
            durationSeconds: input.durationSeconds,
            keyPoints: Array(final.keyPoints.prefix(
                ExtractiveSummarizer.keyPointCount(
                    forSeconds: input.durationSeconds,
                    available: final.keyPoints.count
                )
            )),
            // Bütçeler çıkarımsal özetleyiciyle AYNI olmalı: aynı kayıt,
            // hangi motorun özetlediğine göre farklı sayıda madde vermemeli.
            decisions: Array(final.decisions.prefix(
                ExtractiveSummarizer.sectionCount(forSeconds: input.durationSeconds, cap: 8)
            )),
            actions: Array(final.actions.prefix(
                ExtractiveSummarizer.sectionCount(forSeconds: input.durationSeconds, cap: 10)
            ))
        )
    }

    /// Madde listesini modele geri verip kısaltır; çok uzunsa gruplayarak iner.
    private func reduce(_ points: Points, language: String) async throws -> Points {

        var current = points
        var depth = 0

        // Derinlik sınırı bilinçli: model her turda kısaltmayı reddederse
        // döngü sonsuza kadar sürerdi.
        while current.totalCount > Self.collapseGroupSize, depth < 3 {
            try Task.checkCancellation()

            let raw = try await generator.generate(
                prompt: SummaryPrompt.reduce(points: current.asLines(), language: language),
                grammar: SummaryPrompt.grammar,
                maxTokens: Self.reduceMaxTokens
            )
            let next = Points.parse(raw)

            // Model boş ya da daha uzun bir liste döndürdüyse eldekini koru.
            guard !next.isEmpty, next.totalCount < current.totalCount else { break }
            current = next
            depth += 1
        }

        return current
    }
}

// MARK: - Seçim

public enum LocalSummarizerFactory {

    /// Uygulamanın kullanacağı özetleyici.
    ///
    /// Nöral arka uç kurulu değilse çıkarımsala düşüyor. `isOfflineReady()`
    /// ASLA nöral modeli şart koşmamalı: taze kurulumda offline modun çalışması
    /// garantisi çıkarımsal özetleyicinin bağımlılıksız olmasına dayanıyor.
    /// Nöral çıkarım için yeterli fiziksel bellek var mı.
    ///
    /// `physicalMemory` kaba ama GÜVENİLİR bir ölçüt; cihaz modeline bakmak
    /// yerine bunu kullanıyoruz çünkü model listesi her yıl eskiyor.
    /// (`os_proc_available_memory()` daha isabetli olurdu — anlık kullanılabilir
    /// belleği veriyor — ama iOS'ta uygulama sınırını da hesaba katmak gerekir;
    /// cihazda ölçüm yapılınca bu eşik yeniden ayarlanmalı.)
    static func hasMemoryHeadroom(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Bool {
        physicalBytes >= minimumPhysicalMemoryBytes
    }

    /// 6 GB: iPhone 11/12/13 non-Pro, SE ve XR bu eşiğin altında kalıyor.
    static let minimumPhysicalMemoryBytes: UInt64 = 6 * 1024 * 1024 * 1024

    public static func makeDefault(generator: (any TextGenerator)? = nil) -> any LocalSummarizer {
        if let generator { return NeuralSummarizer(generator: generator) }

        // Yarım kalmış indirme "kurulu" sayılmıyor: `isNeuralSummarizerReady`
        // dosyanın TAM boyutta olmasını arıyor. Aksi halde her özetlemede
        // model yüklenmeye çalışılır, patlar ve sessizce çıkarımsala düşerdi.
        guard OfflineModelManager.isNeuralSummarizerReady() else {
            return ExtractiveSummarizer()
        }

        // BELLEK KAPISI. 1,28 GB ağırlık + KV önbelleği, 4 GB'lık bir cihazda
        // ASR'nin yanında jetsam demek: uygulama ölür ve kullanıcı 45 dakikalık
        // toplantısını kaybeder. Model kurulu olsa bile düşük bellekli cihazda
        // çıkarımsal özetleyici doğru cevap.
        guard Self.hasMemoryHeadroom() else { return ExtractiveSummarizer() }
        return NeuralSummarizer(
            generator: LlamaTextGenerator(modelURL: OfflineModelManager.neuralModelURL)
        )
    }
}
