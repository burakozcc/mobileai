//
//  ExtractiveSummarizerTests.swift
//  AuraVoiceTests
//
//  Özetleyici model indirmeden çalıştığı için tamamen deterministik test
//  edilebiliyor — simülatörde ANE veya ağ gerekmez.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Cümleleme")
struct SentenceSplittingTests {

    @Test("Nokta, ünlem ve soru işareti cümleyi böler")
    func splitsOnTerminators() {
        let text = "Bugün lansmanı konuştuk. Tarih öne çekildi! Herkes hazır mı?"
        let sentences = ExtractiveSummarizer.sentences(from: text)
        #expect(sentences.count == 3)
    }

    @Test("Kısa parçalar kendi başına cümle sayılmaz")
    func mergesShortFragments() {
        // "Dr." tek başına cümle olmamalı; sonraki metinle birleşmeli.
        let sentences = ExtractiveSummarizer.sentences(from: "Dr. Ayşe raporu bugün gönderecek.")
        #expect(sentences.count == 1)
    }

    @Test("Noktalama olmayan uzun metin zorla bölünür")
    func hardWrapsUnpunctuatedText() {
        let long = String(repeating: "toplantida konustugumuz konu ", count: 40)
        let sentences = ExtractiveSummarizer.sentences(from: long)
        #expect(sentences.count > 1)
    }

    @Test("Boş metin boş dizi döner")
    func emptyTextProducesNoSentences() {
        #expect(ExtractiveSummarizer.sentences(from: "").isEmpty)
        #expect(ExtractiveSummarizer.sentences(from: "   \n  ").isEmpty)
    }
}

@Suite("Madde sayısı")
struct KeyPointBudgetTests {

    @Test("Kısa kayıtta en az 3 madde")
    func shortRecordingGetsMinimum() {
        #expect(ExtractiveSummarizer.keyPointCount(forSeconds: 60, available: 20) == 3)
    }

    @Test("Uzun kayıtta en fazla 7 madde")
    func longRecordingIsCapped() {
        #expect(ExtractiveSummarizer.keyPointCount(forSeconds: 7200, available: 50) == 7)
    }

    @Test("Mevcut cümle sayısını aşmaz")
    func neverExceedsAvailable() {
        #expect(ExtractiveSummarizer.keyPointCount(forSeconds: 3600, available: 2) == 2)
        #expect(ExtractiveSummarizer.keyPointCount(forSeconds: 3600, available: 0) == 0)
    }
}

@Suite("Çıkarımsal özetleme")
struct ExtractiveSummarizerTests {

    private let meetingTranscript = """
    Bugünkü toplantıda üçüncü çeyrek lansmanını konuştuk. Lansman tarihinin \
    iki hafta öne çekilmesine karar verildi. Pazarlama ekibi yeni tarihe göre \
    kampanya takvimini güncelleyecek. Mehmet, App Store metinlerini cuma gününe \
    kadar hazırlayacak. Offline modun ana satış argümanı olarak öne çıkarılması \
    konusunda anlaştık. Kullanıcı testlerinde gizlilik vurgusunun dönüşümü \
    artırdığı görüldü. Ayşe, test sonuçlarının detaylı raporunu paylaşacak.
    """

    private func summary(
        _ transcript: String,
        template: SummaryTemplate = .meetingNotes,
        language: String = "tr",
        duration: Double = 600
    ) -> String {
        ExtractiveSummarizer.buildSummary(
            SummarizationInput(
                transcript: transcript,
                template: template,
                language: language,
                durationSeconds: duration
            )
        )
    }

    @Test("Özet markdown başlığıyla başlar")
    func startsWithHeading() {
        #expect(summary(meetingTranscript).hasPrefix("### Toplantı Özeti"))
    }

    @Test("Karar cümleleri Kararlar bölümüne düşer")
    func decisionsAreExtracted() {
        let output = summary(meetingTranscript)
        #expect(output.contains("**Kararlar**"))
        #expect(output.contains("Lansman tarihinin"))
    }

    @Test("Aksiyon cümleleri işaretlenebilir kutu olur")
    func actionsBecomeCheckboxes() {
        let output = summary(meetingTranscript)
        #expect(output.contains("**Aksiyonlar**"))
        #expect(output.contains("- [ ]"))
        // "hazırlayacak" ve "paylaşacak" aksiyon ipuçları.
        #expect(output.contains("Mehmet") || output.contains("Ayşe"))
    }

    @Test("Ana başlıklar bölümü üretilir")
    func keyPointsAreProduced() {
        #expect(summary(meetingTranscript).contains("**Ana Başlıklar**"))
    }

    @Test("Boş transkript için yer tutucu döner, çökmez")
    func emptyTranscriptIsHandled() {
        let output = summary("")
        #expect(output.contains("Toplantı Özeti"))
        #expect(output.contains("Özetlenecek konuşma bulunamadı"))
        #expect(!output.contains("- [ ]"))
    }

    @Test("Şablon başlığı değişir", arguments: zip(
        [SummaryTemplate.meetingNotes, .phoneCallSummary, .quickNotes],
        ["Toplantı Özeti", "Görüşme Özeti", "Hızlı Not"]
    ))
    func templateChangesHeading(template: SummaryTemplate, heading: String) {
        #expect(summary(meetingTranscript, template: template).hasPrefix("### \(heading)"))
    }

    @Test("İngilizce kayıtta İngilizce başlıklar kullanılır")
    func englishTranscriptUsesEnglishHeadings() {
        let english = """
        We discussed the third quarter launch today. The team decided to move \
        the date two weeks earlier. Marketing will prepare the campaign calendar. \
        Sarah needs to update the App Store copy before Friday.
        """
        let output = summary(english, language: "en")
        #expect(output.hasPrefix("### Meeting Summary"))
        #expect(output.contains("**Decisions**") || output.contains("**Action Items**"))
    }

    @Test("Bilinmeyen dil kodu Türkçeye düşer")
    func unknownLanguageFallsBackToTurkish() {
        #expect(summary(meetingTranscript, language: "").hasPrefix("### Toplantı Özeti"))
    }

    @Test("Segment listesi noktalamasız metinde cümle kaynağı olur")
    func segmentsAreUsedWhenPunctuationMissing() {
        let input = SummarizationInput(
            transcript: "bugun lansman tarihini konustuk ekip hazir",
            segments: [
                TranscriptSegment(startSeconds: 0, endSeconds: 4, text: "bugun lansman tarihini konustuk"),
                TranscriptSegment(startSeconds: 4, endSeconds: 8, text: "tarih iki hafta one cekilmesine karar verildi"),
                TranscriptSegment(startSeconds: 8, endSeconds: 12, text: "pazarlama ekibi takvimi guncelleyecek")
            ],
            template: .meetingNotes,
            language: "tr",
            durationSeconds: 120
        )
        let output = ExtractiveSummarizer.buildSummary(input)
        #expect(output.contains("karar verildi") || output.contains("Kararlar"))
    }

    @Test("Madde metnindeki markdown karakterleri temizlenir")
    func cleanupStripsMarkdownPrefixes() {
        #expect(ExtractiveSummarizer.cleanup("- Karar alındı") == "Karar alındı")
        #expect(ExtractiveSummarizer.cleanup("• Görüşme yapıldı,") == "Görüşme yapıldı")
        #expect(ExtractiveSummarizer.cleanup("  ## Başlık") == "Başlık")
    }

    @Test("Protokol üzerinden çağrı da aynı sonucu verir")
    func protocolCallMatchesPureFunction() async throws {
        let input = SummarizationInput(
            transcript: meetingTranscript,
            template: .meetingNotes,
            language: "tr",
            durationSeconds: 600
        )
        let viaProtocol = try await ExtractiveSummarizer().summarize(input)
        #expect(viaProtocol == ExtractiveSummarizer.buildSummary(input))
    }
}

@Suite("Offline boru hattı")
struct OfflineProcessingEngineTests {

    /// Ağ ve model gerektirmeyen sahte ASR.
    private struct StubTranscriber: SpeechTranscriber {
        let output: TranscriptionOutput

        var isAvailable: Bool { get async { true } }
        func prepare() async throws {}
        func transcribe(
            audioURL: URL,
            languageHint: String?,
            progress: TranscriptionProgress?
        ) async throws -> TranscriptionOutput {
            progress?(1.0)
            return output
        }
    }

    @Test("ASR çıktısı özete ve segmentlere taşınır")
    func pipelineCarriesTranscriptAndSegments() async throws {
        let segments = [
            TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "Lansman tarihi öne çekilmesine karar verildi."),
            TranscriptSegment(startSeconds: 5, endSeconds: 9, text: "Pazarlama ekibi takvimi güncelleyecek.")
        ]
        let engine = OfflineProcessingEngine(
            transcriber: StubTranscriber(output: TranscriptionOutput(
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                language: "tr"
            )),
            summarizer: ExtractiveSummarizer()
        )

        let result = try await engine.process(request: ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura.wav"),
            durationSeconds: 300,
            mode: .offlineZeroCloud,
            summaryTemplate: .meetingNotes
        ))

        #expect(result.segments.count == 2)
        #expect(result.detectedLanguage == "tr")
        #expect(result.summaryMarkdown.contains("###"))
        #expect(abs(result.usedMinutes - 5.0) < 0.001)
    }

    @Test("Dil tespit edilemezse Türkçeye düşer")
    func emptyLanguageFallsBack() async throws {
        let engine = OfflineProcessingEngine(
            transcriber: StubTranscriber(output: TranscriptionOutput(
                text: "Kısa bir not aldık bugün.",
                segments: [],
                language: ""
            )),
            summarizer: ExtractiveSummarizer()
        )

        let result = try await engine.process(request: ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura.wav"),
            durationSeconds: 60,
            mode: .offlineZeroCloud,
            summaryTemplate: .quickNotes
        ))

        #expect(result.detectedLanguage == "tr")
    }
}
