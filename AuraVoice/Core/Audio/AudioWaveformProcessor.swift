//
//  AudioWaveformProcessor.swift
//  AuraVoice
//
//  Dalga formu verisi üzerindeki saf (yan etkisiz) dönüşümler. Görünümlerin
//  içinden çıkarıldı ki birim testlerle doğrulanabilsin — simülatör ya da
//  mikrofon gerektirmez.
//

import Foundation

public enum AudioWaveformProcessor {

    /// Sessizlikte bile çubukların görünmesini sağlayan taban değer.
    public static let silenceFloor: Float = 0.04

    /// RMS değerini (0...1 lineer genlik) algısal 0...1 çubuk yüksekliğine çevirir.
    /// -50 dBFS…0 dBFS bandı konuşmanın yaşadığı aralıktır.
    public static func normalize(rms: Float, floorDB: Float = -50) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db - floorDB) / -floorDB))
        return powf(normalized, 0.72)
    }

    /// Hızlı atak / yavaş bırakma zarfı — çubuklar titremek yerine akar.
    public static func smooth(previous: Float, target: Float, attack: Float = 0.65, release: Float = 0.28) -> Float {
        let factor = target > previous ? attack : release
        return min(1, max(0, previous + (target - previous) * factor))
    }

    /// Kayan pencereye yeni bir seviye ekler, pencere boyunu korur.
    public static func advance(window: [Float], with level: Float) -> [Float] {
        guard !window.isEmpty else { return [max(silenceFloor, level)] }
        var next = window
        next.removeFirst()
        next.append(min(1, max(silenceFloor, level)))
        return next
    }

    /// Uzun seviye dizisini kart önizlemesi için sabit sayıda örneğe indirger.
    /// Aralıktaki en yüksek değeri alır — ortalama alsaydık konuşma tepeleri
    /// silinir ve tüm kayıtlar birbirine benzerdi.
    public static func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard values.count > count else { return values }

        let bucketSize = Double(values.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * bucketSize)
            let end = min(values.count, max(start + 1, Int(Double(index + 1) * bucketSize)))
            return values[start..<end].max() ?? silenceFloor
        }
    }

    /// Boş pencere üretir.
    public static func emptyWindow(resolution: Int) -> [Float] {
        Array(repeating: silenceFloor, count: max(1, resolution))
    }
}
