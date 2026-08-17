//
//  AudioWaveformProcessorTests.swift
//  AuraVoiceTests
//

import Testing
@testable import AuraVoice

@Suite("Dalga formu işlemcisi")
struct AudioWaveformProcessorTests {

    // MARK: normalize

    @Test("Sessizlik 0, tam genlik 1 üretir")
    func normalizeBounds() {
        #expect(AudioWaveformProcessor.normalize(rms: 0) == 0)
        #expect(AudioWaveformProcessor.normalize(rms: 1.0) == 1)
    }

    @Test("Çıktı her zaman 0...1 aralığında kalır", arguments: [0.0001, 0.01, 0.1, 0.5, 0.9, 1.0, 2.0] as [Float])
    func normalizeStaysInUnitRange(rms: Float) {
        let value = AudioWaveformProcessor.normalize(rms: rms)
        #expect(value >= 0 && value <= 1)
    }

    @Test("Daha yüksek RMS daha yüksek çubuk verir")
    func normalizeIsMonotonic() {
        let quiet = AudioWaveformProcessor.normalize(rms: 0.01)
        let loud = AudioWaveformProcessor.normalize(rms: 0.4)
        #expect(loud > quiet)
    }

    // MARK: smooth

    @Test("Atak bırakmadan hızlıdır")
    func smoothAttackIsFasterThanRelease() {
        let rising = AudioWaveformProcessor.smooth(previous: 0.2, target: 0.8)
        let falling = AudioWaveformProcessor.smooth(previous: 0.8, target: 0.2)

        let riseDelta = rising - 0.2
        let fallDelta = 0.8 - falling
        #expect(riseDelta > fallDelta)
    }

    @Test("Yumuşatma hedefi aşmaz")
    func smoothNeverOvershoots() {
        let value = AudioWaveformProcessor.smooth(previous: 0.1, target: 1.0)
        #expect(value <= 1.0)
        #expect(value > 0.1)
    }

    // MARK: advance

    @Test("Pencere boyu sabit kalır")
    func advanceKeepsWindowSize() {
        let window = AudioWaveformProcessor.emptyWindow(resolution: 56)
        let next = AudioWaveformProcessor.advance(window: window, with: 0.9)

        #expect(next.count == window.count)
        #expect(next.last == 0.9)
    }

    @Test("Yeni değer taban seviyenin altına inmez")
    func advanceClampsToFloor() {
        let window = AudioWaveformProcessor.emptyWindow(resolution: 4)
        let next = AudioWaveformProcessor.advance(window: window, with: 0)
        #expect(next.last == AudioWaveformProcessor.silenceFloor)
    }

    @Test("Boş pencereye ekleme çökmez")
    func advanceOnEmptyWindow() {
        let next = AudioWaveformProcessor.advance(window: [], with: 0.5)
        #expect(next == [0.5])
    }

    // MARK: downsample

    @Test("İstenen sayıda örnek üretir")
    func downsampleProducesRequestedCount() {
        let values = (0..<56).map { Float($0) / 56 }
        #expect(AudioWaveformProcessor.downsample(values, to: 24).count == 24)
    }

    @Test("Tepe noktaları korunur — ortalama alınmaz")
    func downsamplePreservesPeaks() {
        // Tek bir yüksek tepe içeren düz sinyal.
        var values = [Float](repeating: 0.05, count: 100)
        values[42] = 0.98

        let result = AudioWaveformProcessor.downsample(values, to: 10)
        #expect(result.contains(0.98))
    }

    @Test("Girdi hedeften kısaysa olduğu gibi döner")
    func downsampleShortInput() {
        let values: [Float] = [0.1, 0.2, 0.3]
        #expect(AudioWaveformProcessor.downsample(values, to: 24) == values)
    }

    @Test("Sıfır hedef boş dizi döner")
    func downsampleZeroCount() {
        #expect(AudioWaveformProcessor.downsample([0.1, 0.2], to: 0).isEmpty)
    }

    @Test("Boş girdi çökmez")
    func downsampleEmptyInput() {
        #expect(AudioWaveformProcessor.downsample([], to: 10).isEmpty)
    }
}
