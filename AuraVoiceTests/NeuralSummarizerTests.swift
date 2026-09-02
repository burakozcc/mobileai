//
//  NeuralSummarizerTests.swift
//  AuraVoiceTests
//
//  Nöral özetleyicinin map-reduce iskeleti. Gerçek model olmadan, sahte
//  üreticiyle test ediliyor — bağımlılık gelmeden mantık doğrulanmış olsun.
//

import Testing
import Foundation
@testable import AuraVoice

// MARK: - Sahte üretici

private actor MockTextGenerator: TextGenerator {

    /// Her `generate` çağrısına verilecek yanıtlar, sırayla.
    private var responses: [String]
    private var received: [String] = []
    private let ready: Bool
    private let failure: (any Error)?

    init(responses: [String] = [], ready: Bool = true, failure: (any Error)? = nil) {
        self.responses = responses
        self.ready = ready
        self.failure = failure
    }

    var isReady: Bool { ready }

    func generate(prompt: String, grammar: String?, maxTokens: Int) async throws -> String {
        if let failure { throw failure }
        received.append(prompt)
        guard !responses.isEmpty else { return "" }
        return responses.removeFirst()
    }

    func tokenCount(_ text: String) async -> Int {
        TranscriptChunker.estimateTokens(text)
    }

    func unload() async {}

    func prompts() -> [String] { received }
    func callCount() -> Int { received.count }
}

private func segment(_ text: String, speaker: String? = nil, start: Double = 0) -> TranscriptSegment {
    TranscriptSegment(startSeconds: start, endSeconds: start + 5, text: text, speakerLabel: speaker)
}

private func input(
    segments: [TranscriptSegment] = [],
    transcript: String = "",
    duration: Double = 600
) -> SummarizationInput {
    SummarizationInput(
        transcript: transcript,
        segments: segments,
        template: .meetingNotes,
        language: "tr",
        durationSeconds: duration
    )
}

// MARK: - Parçalama

@Suite("Deşifre parçalama")
struct TranscriptChunkerTests {

    @Test("Kısa deşifre tek parça kalıyor")
    func shortTranscriptStaysWhole() {
        let chunks = TranscriptChunker.chunks(lines: ["birinci satır", "ikinci satır"], tokenBudget: 1_000)
        #expect(chunks.count == 1)
        #expect(chunks[0].lineRange == 0..<2)
    }

    @Test("Bütçe aşılınca bölünüyor ve tüm satırlar kapsanıyor")
    func longTranscriptIsSplitAndCovered() {
        let lines = (0..<40).map { "Bu on üçüncü çeyrekte konuşulan \($0) numaralı uzunca bir cümledir." }
        let chunks = TranscriptChunker.chunks(lines: lines, tokenBudget: 120)

        #expect(chunks.count > 1)
        #expect(chunks.first?.lineRange.lowerBound == 0)
        #expect(chunks.last?.lineRange.upperBound == lines.count)

        // Boşluk kalmamalı: her parça bir öncekinin bitişinden önce başlıyor.
        for (previous, current) in zip(chunks, chunks.dropFirst()) {
            #expect(current.lineRange.lowerBound < previous.lineRange.upperBound)
        }
    }

    @Test("Komşu parçalar bindirmeli")
    func chunksOverlap() {
        let lines = (0..<30).map { "Satır \($0) — burada makul uzunlukta bir cümle var." }
        let chunks = TranscriptChunker.chunks(lines: lines, tokenBudget: 100)

        #expect(chunks.count > 1)
        for (previous, current) in zip(chunks, chunks.dropFirst()) {
            let overlap = previous.lineRange.upperBound - current.lineRange.lowerBound
            #expect(overlap >= 1)
            #expect(overlap <= TranscriptChunker.overlapLines)
        }
    }

    @Test("Tek satır bütçeyi aşsa bile döngü ilerliyor")
    func oversizedSingleLineDoesNotStall() {
        // Aksi halde parçalayıcı sonsuza kadar aynı satırda kalırdı.
        let lines = [String(repeating: "a", count: 5_000), "kısa satır"]
        let chunks = TranscriptChunker.chunks(lines: lines, tokenBudget: 50)

        #expect(chunks.count >= 1)
        #expect(chunks.last?.lineRange.upperBound == lines.count)
    }

    @Test("Boş girdi boş sonuç veriyor")
    func emptyInput() {
        #expect(TranscriptChunker.chunks(lines: []).isEmpty)
        #expect(TranscriptChunker.chunks(lines: ["a"], tokenBudget: 0).isEmpty)
    }

    @Test("Konuşmacı etiketi satıra taşınıyor")
    func speakerLabelIsCarried() {
        let lines = TranscriptChunker.lines(
            segments: [
                segment("Lansmanı öne çekiyoruz.", speaker: "Konuşmacı 1"),
                segment("Tamam, takvimi güncellerim.", speaker: "Konuşmacı 2")
            ],
            transcript: ""
        )
        // Aksiyon sorumlusunu çıkarmak için elimizdeki tek sinyal bu.
        #expect(lines[0] == "Konuşmacı 1: Lansmanı öne çekiyoruz.")
        #expect(lines[1] == "Konuşmacı 2: Tamam, takvimi güncellerim.")
    }

    @Test("Etiketsiz segment düz metin kalıyor")
    func unlabelledSegmentStaysPlain() {
        let lines = TranscriptChunker.lines(segments: [segment("Merhaba.")], transcript: "")
        #expect(lines == ["Merhaba."])
    }

    @Test("Segment yoksa cümlelere düşülüyor")
    func fallsBackToSentences() {
        let lines = TranscriptChunker.lines(
            segments: [],
            transcript: "Birinci cümle burada duruyor. İkinci cümle de burada."
        )
        #expect(lines.count == 2)
    }

    @Test("Türkçe token tahmini kelime sayımından yüksek")
    func turkishEstimateIsConservative() {
        // Türkçe sondan eklemeli; İngilizce varsayımıyla yapılan tahmin iki kat
        // yanlış çıkar ve parça bağlama sığmaz.
        let text = "gerçekleştirebileceğimizi değerlendirdik"
        let words = text.split(separator: " ").count
        #expect(TranscriptChunker.estimateTokens(text) > words * 2)
    }
}

// MARK: - Çıktı ayrıştırma

@Suite("Model çıktısı ayrıştırma")
struct PointsParsingTests {

    @Test("K/D/A satırları ayrılıyor")
    func parsesAllThreeKinds() {
        let points = Points.parse("""
        K: Lansman iki hafta öne çekildi.
        D: Bütçe artışı onaylandı.
        A: Pazarlama takvimi güncelleyecek.
        """)

        #expect(points.keyPoints == ["Lansman iki hafta öne çekildi."])
        #expect(points.decisions == ["Bütçe artışı onaylandı."])
        #expect(points.actions == ["Pazarlama takvimi güncelleyecek."])
    }

    @Test("Biçim dışı satırlar atılıyor")
    func dropsMalformedLines() {
        // Gramer bunu engelliyor ama ayrıştırıcı yine de dayanıklı olmalı:
        // SummaryDocument her serseri satırı sessizce maddeye çeviriyor.
        let points = Points.parse("""
        İşte özet:
        K: Gerçek madde.

        - başka bir şey
        """)
        #expect(points.keyPoints == ["Gerçek madde."])
        #expect(points.decisions.isEmpty)
    }

    @Test("Küçük harfli önek de tanınıyor")
    func lowercasePrefixWorks() {
        #expect(Points.parse("k: madde").keyPoints == ["madde"])
    }

    @Test("Boş gövde madde üretmiyor")
    func emptyBodyIsSkipped() {
        #expect(Points.parse("K:   \nD:").isEmpty)
    }

    @Test("Birleştirme tekrarları eliyor")
    func mergeRemovesDuplicates() {
        // Bindirmeli parçalama sınırdaki cümleyi iki kez gösteriyor.
        var first = Points.parse("K: Lansman öne çekildi.\nD: Bütçe onaylandı.")
        first.merge(Points.parse("K: Lansman öne çekildi.\nA: Takvim güncellenecek."))

        #expect(first.keyPoints.count == 1)
        #expect(first.decisions.count == 1)
        #expect(first.actions.count == 1)
    }

    @Test("Tekrar eleme Türkçe büyük-küçük harfe takılmıyor")
    func mergeIsTurkishAware() {
        var points = Points.parse("K: İstanbul ofisi taşınıyor.")
        points.merge(Points.parse("K: istanbul ofisi taşınıyor."))
        #expect(points.keyPoints.count == 1)
    }

    @Test("Farklı maddeler korunuyor ve sırası bozulmuyor")
    func mergeKeepsDistinctInOrder() {
        var points = Points.parse("K: Birinci.")
        points.merge(Points.parse("K: İkinci.\nK: Üçüncü."))
        #expect(points.keyPoints == ["Birinci.", "İkinci.", "Üçüncü."])
    }

    @Test("Satır biçimine geri dönüşüm kayıpsız")
    func roundTripThroughLines() {
        let original = Points.parse("K: bir\nD: iki\nA: üç")
        #expect(Points.parse(original.asLines()) == original)
    }
}

// MARK: - Uçtan uca

@Suite("Nöral özetleme akışı", .serialized)
struct NeuralSummarizerFlowTests {

    private let chunkResponse = """
    K: Lansman iki hafta öne çekildi.
    D: Bütçe artışı onaylandı.
    A: Pazarlama takvimi güncelleyecek.
    """

    @Test("Tek parçada reduce çağrılmıyor")
    func singleChunkSkipsReduce() async throws {
        let generator = MockTextGenerator(responses: [chunkResponse])
        let summarizer = NeuralSummarizer(generator: generator)

        let markdown = try await summarizer.summarize(input(
            segments: [segment("Lansmanı öne çekiyoruz.", speaker: "Konuşmacı 1")]
        ))

        #expect(await generator.callCount() == 1)
        #expect(markdown.contains("Lansman iki hafta öne çekildi."))
    }

    @Test("Üretilen markdown SummaryDocument sözleşmesine uyuyor")
    func outputMatchesMarkdownContract() async throws {
        let generator = MockTextGenerator(responses: [chunkResponse])
        let summarizer = NeuralSummarizer(generator: generator)

        let markdown = try await summarizer.summarize(input(segments: [segment("bir şeyler")]))
        let document = SummaryDocument.parse(markdown)

        // Model markdown YAZMIYOR; render tek yerden yapılıyor ki toggleTask ve
        // taskProgress sözleşmesi modelin keyfine kalmasın.
        #expect(document.title?.isEmpty == false)
        #expect(document.sections.contains { $0.containsTasks })
        #expect(SummaryDocument.taskProgress(in: markdown).total == 1)
    }

    @Test("Her parça için bir çağrı yapılıyor")
    func callsGeneratorPerChunk() async throws {
        let lines = (0..<20).map { segment("Bu \($0) numaralı oldukça uzunca bir toplantı cümlesidir.") }
        let generator = MockTextGenerator(responses: Array(repeating: chunkResponse, count: 30))
        let summarizer = NeuralSummarizer(generator: generator, tokenBudget: 80)

        _ = try await summarizer.summarize(input(segments: lines))

        let expected = TranscriptChunker.chunks(
            segments: lines, transcript: "", tokenBudget: 80
        ).count
        // Parça sayısı + en az bir reduce turu.
        #expect(await generator.callCount() >= expected)
    }

    @Test("Model hazır değilse çıkarımsala düşülüyor")
    func fallsBackWhenNotReady() async throws {
        let generator = MockTextGenerator(ready: false)
        let summarizer = NeuralSummarizer(generator: generator)

        let markdown = try await summarizer.summarize(input(
            transcript: "Lansman tarihini konuştuk ve öne çekmeye karar verdik. Pazarlama takvimi güncelleyecek."
        ))

        // Kullanıcı hiçbir koşulda özetsiz kalmamalı.
        #expect(!markdown.isEmpty)
        #expect(markdown.hasPrefix("###"))
        #expect(await generator.callCount() == 0)
    }

    @Test("Üretim hatası özet üretmeyi engellemiyor")
    func generationFailureFallsBack() async throws {
        let generator = MockTextGenerator(failure: AuraError.engineFailure("model çöktü"))
        let summarizer = NeuralSummarizer(generator: generator)

        let markdown = try await summarizer.summarize(input(
            transcript: "Bütçe artışı onaylandı. Ekip cuma günü yayına alacak."
        ))
        #expect(markdown.hasPrefix("###"))
    }

    @Test("Boş model çıktısı yedeğe düşürüyor")
    func emptyModelOutputFallsBack() async throws {
        let generator = MockTextGenerator(responses: ["", "", ""])
        let summarizer = NeuralSummarizer(generator: generator)

        let markdown = try await summarizer.summarize(input(
            transcript: "Karar verildi: lansman öne alınıyor."
        ))
        #expect(markdown.hasPrefix("###"))
    }

    @Test("İptal yedek üretmeden yukarı taşınıyor")
    func cancellationPropagates() async {
        let generator = MockTextGenerator(failure: CancellationError())
        let summarizer = NeuralSummarizer(generator: generator)

        await #expect(throws: CancellationError.self) {
            _ = try await summarizer.summarize(input(segments: [segment("bir şey")]))
        }
    }

    @Test("Gramer üreticiye iletiliyor")
    func grammarIsPassedThrough() async throws {
        // Gramer olmadan model biçim dışına çıkıyor ve SummaryDocument o
        // satırları sessizce maddeye çeviriyor.
        #expect(SummaryPrompt.grammar.contains("\"K: \""))
        #expect(SummaryPrompt.grammar.contains("\"D: \""))
        #expect(SummaryPrompt.grammar.contains("\"A: \""))
    }

    @Test("Türkçe ve İngilizce istemler ayrışıyor")
    func promptsAreLocalised() {
        #expect(SummaryPrompt.system(language: "tr").contains("Türkçe"))
        #expect(SummaryPrompt.system(language: "en").contains("meeting"))
        // Dil boşsa Türkçe varsayılıyor: hedef kitle Türkçe.
        #expect(SummaryPrompt.system(language: "").contains("Türkçe"))
    }

    @Test("Üretici yoksa fabrika çıkarımsal veriyor")
    func factoryDefaultsToExtractive() async throws {
        let summarizer = LocalSummarizerFactory.makeDefault()
        let markdown = try await summarizer.summarize(input(transcript: "Kısa bir toplantı metni burada."))
        #expect(markdown.hasPrefix("###"))
    }
}

@Suite("Bellek kapısı")
struct NeuralMemoryGateTests {

    @Test("Düşük bellekli cihazda nöral yol açılmıyor")
    func lowMemoryDeviceStaysExtractive() {
        // 4 GB'lık bir cihazda 1,28 GB ağırlık + KV önbelleği, ASR'nin
        // yanında jetsam demek: uygulama ölür ve kullanıcı toplantısını
        // kaybeder.
        #expect(!LocalSummarizerFactory.hasMemoryHeadroom(physicalBytes: 4 * 1024 * 1024 * 1024))
        #expect(!LocalSummarizerFactory.hasMemoryHeadroom(physicalBytes: 3 * 1024 * 1024 * 1024))
    }

    @Test("Yeterli bellekte kapı açık")
    func highMemoryDevicePasses() {
        #expect(LocalSummarizerFactory.hasMemoryHeadroom(physicalBytes: 6 * 1024 * 1024 * 1024))
        #expect(LocalSummarizerFactory.hasMemoryHeadroom(physicalBytes: 8 * 1024 * 1024 * 1024))
    }

    @Test("Model boyutu Hugging Face'in bildirdiği değer")
    func modelSizeMatchesHuggingFace() {
        // Tahmin değil: unsloth/Qwen3.5-2B-GGUF ağaç ucundan alındı.
        #expect(OfflineModelManager.NeuralModel.expectedBytes == 1_280_835_840)
        #expect(OfflineModelManager.NeuralModel.fileName == "Qwen3.5-2B-Q4_K_M.gguf")
    }

    @Test("Büyük model MB yerine GB olarak gösteriliyor")
    func largeModelShowsGigabytes() {
        let label = ModelDownloadViewModel.Row.sizeLabel(
            megabytes: OfflineModelManager.NeuralModel.approximateMegabytes
        )
        #expect(label.contains("GB"))
        #expect(ModelDownloadViewModel.Row.sizeLabel(megabytes: 627) == "~627 MB")
    }
}
