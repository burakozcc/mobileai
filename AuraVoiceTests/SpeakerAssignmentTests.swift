//
//  SpeakerAssignmentTests.swift
//  AuraVoiceTests
//
//  Birleştirme saf bir fonksiyon olduğu için model indirmeden, ses dosyası
//  olmadan ve ANE olmadan test edilebiliyor.
//

import Testing
import Foundation
@testable import AuraVoice

@Suite("Konuşmacı atama")
struct SpeakerAssignmentTests {

    private func segment(_ start: Double, _ end: Double, _ text: String = "metin") -> TranscriptSegment {
        TranscriptSegment(startSeconds: start, endSeconds: end, text: text)
    }

    private func turn(_ start: Double, _ end: Double, _ id: String) -> SpeakerTurn {
        SpeakerTurn(startSeconds: start, endSeconds: end, rawSpeakerID: id)
    }

    // MARK: Örtüşme matematiği

    @Test("Örtüşme hesabı", arguments: zip(
        [(0.0, 10.0, 5.0, 15.0), (0.0, 5.0, 5.0, 10.0), (0.0, 5.0, 6.0, 10.0), (2.0, 4.0, 0.0, 10.0)],
        [5.0, 0.0, 0.0, 2.0]
    ))
    func overlapMath(input: (Double, Double, Double, Double), expected: Double) {
        let value = SpeakerAssignment.overlapSeconds(
            aStart: input.0, aEnd: input.1, bStart: input.2, bEnd: input.3
        )
        #expect(abs(value - expected) < 0.0001)
    }

    // MARK: Temel atama

    @Test("Dönüşümlü iki konuşmacı doğru etiketlenir")
    func alternatingSpeakers() {
        let segments = [segment(0, 5, "merhaba"), segment(5, 10, "selam"), segment(10, 15, "devam")]
        let turns = [turn(0, 5, "SPEAKER_00"), turn(5, 10, "SPEAKER_01"), turn(10, 15, "SPEAKER_00")]

        let labeled = SpeakerAssignment.apply(turns: turns, to: segments)

        #expect(labeled[0].speakerLabel == "Konuşmacı 1")
        #expect(labeled[1].speakerLabel == "Konuşmacı 2")
        #expect(labeled[2].speakerLabel == "Konuşmacı 1")
    }

    @Test("Etiket numarası konuşma sırasına göre verilir, küme kimliğine göre değil")
    func numberingFollowsSpeakingOrder() {
        // Model rastgele kimlik veriyor: ilk konuşan SPEAKER_07.
        let segments = [segment(0, 5), segment(5, 10)]
        let turns = [turn(0, 5, "SPEAKER_07"), turn(5, 10, "SPEAKER_02")]

        let labeled = SpeakerAssignment.apply(turns: turns, to: segments)

        // Kimliği 07 olmasına rağmen ilk konuşan "1" olmalı.
        #expect(labeled[0].speakerLabel == "Konuşmacı 1")
        #expect(labeled[1].speakerLabel == "Konuşmacı 2")
    }

    @Test("En çok örtüşen konuşmacı kazanır")
    func dominantSpeakerWins() {
        // Segment 0-10; SPEAKER_A 7 saniye, SPEAKER_B 3 saniye örtüşüyor.
        let segments = [segment(0, 10)]
        let turns = [turn(0, 7, "SPEAKER_A"), turn(7, 10, "SPEAKER_B")]

        #expect(SpeakerAssignment.apply(turns: turns, to: segments)[0].speakerLabel == "Konuşmacı 1")
        #expect(SpeakerAssignment.dominantSpeaker(for: segments[0], in: turns) == "SPEAKER_A")
    }

    // MARK: Sınır durumlar

    @Test("Hiç örtüşme yoksa etiket verilmez")
    func noOverlapLeavesNil() {
        let segments = [segment(0, 5)]
        let turns = [turn(20, 30, "SPEAKER_00")]

        #expect(SpeakerAssignment.apply(turns: turns, to: segments)[0].speakerLabel == nil)
    }

    @Test("Çok küçük örtüşme etiket üretmez")
    func tinyOverlapIsIgnored() {
        // 10 saniyelik segmentin yalnızca 0.5 saniyesi örtüşüyor (%5 < %15 eşiği).
        let segments = [segment(0, 10)]
        let turns = [turn(9.5, 12, "SPEAKER_00")]

        #expect(SpeakerAssignment.apply(turns: turns, to: segments)[0].speakerLabel == nil)
    }

    @Test("Eşik üstündeki örtüşme etiket üretir")
    func sufficientOverlapLabels() {
        let segments = [segment(0, 10)]
        let turns = [turn(8, 12, "SPEAKER_00")] // 2 sn = %20 > %15

        #expect(SpeakerAssignment.apply(turns: turns, to: segments)[0].speakerLabel == "Konuşmacı 1")
    }

    @Test("Boş girdiler değiştirilmeden döner")
    func emptyInputsPassThrough() {
        let segments = [segment(0, 5)]
        #expect(SpeakerAssignment.apply(turns: [], to: segments)[0].speakerLabel == nil)
        #expect(SpeakerAssignment.apply(turns: [turn(0, 5, "A")], to: []).isEmpty)
    }

    @Test("Segment kimliği ve metni korunur")
    func preservesIdentityAndText() {
        let original = segment(0, 5, "orijinal metin")
        let labeled = SpeakerAssignment.apply(turns: [turn(0, 5, "A")], to: [original])[0]

        #expect(labeled.id == original.id)
        #expect(labeled.text == "orijinal metin")
        #expect(labeled.startSeconds == 0)
        #expect(labeled.endSeconds == 5)
    }

    @Test("Eşit örtüşmede sonuç tekrarlanabilir")
    func tiesAreDeterministic() {
        let segments = [segment(0, 10)]
        let turns = [turn(0, 5, "SPEAKER_B"), turn(5, 10, "SPEAKER_A")]

        // Aynı girdi her çalıştırmada aynı sonucu vermeli (sözlük sırası
        // Swift'te çalıştırmalar arası değişir).
        let results = (0..<20).map { _ in
            SpeakerAssignment.dominantSpeaker(for: segments[0], in: turns)
        }
        #expect(Set(results).count == 1)
    }

    @Test("Üç konuşmacı sırayla numaralanır")
    func threeSpeakers() {
        let segments = [segment(0, 5), segment(5, 10), segment(10, 15), segment(15, 20)]
        let turns = [
            turn(0, 5, "SPEAKER_02"),
            turn(5, 10, "SPEAKER_00"),
            turn(10, 15, "SPEAKER_01"),
            turn(15, 20, "SPEAKER_00")
        ]

        let labels = SpeakerAssignment.apply(turns: turns, to: segments).map(\.speakerLabel)
        #expect(labels == ["Konuşmacı 1", "Konuşmacı 2", "Konuşmacı 3", "Konuşmacı 2"])
    }

    @Test("Etiket öneki değiştirilebilir")
    func customLabelPrefix() {
        let labeled = SpeakerAssignment.apply(
            turns: [turn(0, 5, "A")],
            to: [segment(0, 5)],
            labelPrefix: "Speaker"
        )
        #expect(labeled[0].speakerLabel == "Speaker 1")
    }
}

@Suite("Konuşmacı etiketleyici")
struct SpeakerLabelerTests {

    /// Model kurulu değilmiş gibi davranan ayrıştırıcı.
    private struct UnavailableDiarizer: SpeakerDiarizer {
        var isAvailable: Bool { get async { false } }
        func diarize(audioURL: URL, progress: DiarizationProgress?) async throws -> DiarizationOutput {
            Issue.record("Model yokken ayrıştırma çağrılmamalıydı")
            return .empty
        }
    }

    /// Her zaman patlayan ayrıştırıcı.
    private struct FailingDiarizer: SpeakerDiarizer {
        var isAvailable: Bool { get async { true } }
        func diarize(audioURL: URL, progress: DiarizationProgress?) async throws -> DiarizationOutput {
            throw AuraError.engineFailure("ayrıştırma çöktü")
        }
    }

    private struct StubDiarizer: SpeakerDiarizer {
        let output: DiarizationOutput
        var isAvailable: Bool { get async { true } }
        func diarize(audioURL: URL, progress: DiarizationProgress?) async throws -> DiarizationOutput {
            output
        }
    }

    private let audioURL = URL(fileURLWithPath: "/tmp/aura.wav")
    private var segments: [TranscriptSegment] {
        [
            TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "bir"),
            TranscriptSegment(startSeconds: 5, endSeconds: 10, text: "iki")
        ]
    }

    @Test("Model yoksa transkript aynen döner")
    func passesThroughWhenUnavailable() async {
        let labeler = SpeakerLabeler(diarizer: UnavailableDiarizer())
        let result = await labeler.label(segments, audioURL: audioURL)
        #expect(result.allSatisfy { $0.speakerLabel == nil })
    }

    @Test("Ayrıştırma çökerse transkript kaybolmaz")
    func survivesDiarizationFailure() async {
        let labeler = SpeakerLabeler(diarizer: FailingDiarizer())
        let result = await labeler.label(segments, audioURL: audioURL)

        #expect(result.count == 2)
        #expect(result.map(\.text) == ["bir", "iki"])
        #expect(result.allSatisfy { $0.speakerLabel == nil })
    }

    @Test("Tek konuşmacıda etiket eklenmez")
    func singleSpeakerIsNotLabeled() async {
        let labeler = SpeakerLabeler(diarizer: StubDiarizer(output: DiarizationOutput(
            turns: [SpeakerTurn(startSeconds: 0, endSeconds: 10, rawSpeakerID: "A")],
            speakerCount: 1
        )))
        let result = await labeler.label(segments, audioURL: audioURL)
        #expect(result.allSatisfy { $0.speakerLabel == nil })
    }

    @Test("İki konuşmacıda etiket eklenir")
    func twoSpeakersAreLabeled() async {
        let labeler = SpeakerLabeler(diarizer: StubDiarizer(output: DiarizationOutput(
            turns: [
                SpeakerTurn(startSeconds: 0, endSeconds: 5, rawSpeakerID: "A"),
                SpeakerTurn(startSeconds: 5, endSeconds: 10, rawSpeakerID: "B")
            ],
            speakerCount: 2
        )))
        let result = await labeler.label(segments, audioURL: audioURL)
        #expect(result[0].speakerLabel == "Konuşmacı 1")
        #expect(result[1].speakerLabel == "Konuşmacı 2")
    }

    @Test("Kapalıyken ayrıştırıcıya hiç dokunulmaz")
    func disabledSkipsEntirely() async {
        let labeler = SpeakerLabeler(diarizer: UnavailableDiarizer(), isEnabled: false)
        let result = await labeler.label(segments, audioURL: audioURL)
        #expect(result.count == 2)
    }
}
