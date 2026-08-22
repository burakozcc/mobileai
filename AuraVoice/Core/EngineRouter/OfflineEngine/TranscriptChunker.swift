//
//  TranscriptChunker.swift
//  AuraVoice
//
//  Uzun deşifreleri model bağlamına sığan parçalara böler.
//
//  NEDEN GEREKLİ: 45 dakikalık bir Türkçe toplantı ≈ 5.850 kelime ≈ 11-13 bin
//  token; 120 dakikalık ise 30-35 bin. 4096 bağlamlı bir modele tek seferde
//  verilemez. Çözüm map-reduce: her parça kendi `K: / D: / A:` satırlarını
//  üretiyor, sonra o satırlar birleştiriliyor.
//
//  TÜRKÇE UYARISI: Qwen BPE'de Türkçe ~1,8-2,2 token/kelime, İngilizce ~1,3.
//  Kelime sayısından İngilizce varsayımıyla yapılan her tahmin iki kat yanlış
//  çıkar ve parça bağlama sığmaz. Varsayılan tahminci bu yüzden karakter
//  tabanlı ve bilerek TEMKİNLİ (fazla tahmin ediyor).
//
//  Parçalar segment sınırında kesiliyor, asla cümle ortasından. Komşu parçalar
//  iki segment üst üste biniyor ki sınıra denk gelen bir karar kaybolmasın;
//  tekrar `Points.merge` içinde eleniyor.
//

import Foundation

public struct TranscriptChunk: Sendable, Equatable, Identifiable {

    public let index: Int
    /// Modele verilecek metin. Konuşmacı etiketi varsa satır başına taşınıyor.
    public let text: String
    /// Kaynak satır aralığı — bindirmeyi ve testleri okunur kılıyor.
    public let lineRange: Range<Int>

    public var id: Int { index }

    public init(index: Int, text: String, lineRange: Range<Int>) {
        self.index = index
        self.text = text
        self.lineRange = lineRange
    }
}

public enum TranscriptChunker {

    /// Komşu parçaların paylaştığı satır sayısı.
    public static let overlapLines = 2

    /// Parça başına düşen deşifre bütçesi (talimat ve üretim payı hariç).
    public static let defaultTokenBudget = 1_400

    // MARK: Satırlama

    /// Deşifreyi modele verilecek satırlara çevirir.
    ///
    /// Segment varsa onlar kullanılıyor: konuşmacı etiketi aksiyon sorumlusunu
    /// çıkarmak için elimizdeki TEK sinyal. Segment yoksa cümlelere düşülüyor.
    public static func lines(segments: [TranscriptSegment], transcript: String) -> [String] {
        if !segments.isEmpty {
            let mapped = segments.compactMap { segment -> String? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                guard let speaker = segment.speakerLabel, !speaker.isEmpty else { return text }
                return "\(speaker): \(text)"
            }
            if !mapped.isEmpty { return mapped }
        }
        return ExtractiveSummarizer.sentences(from: transcript)
    }

    // MARK: Parçalama

    public static func chunks(
        segments: [TranscriptSegment],
        transcript: String,
        tokenBudget: Int = defaultTokenBudget,
        estimate: (String) -> Int = estimateTokens
    ) -> [TranscriptChunk] {
        chunks(lines: lines(segments: segments, transcript: transcript),
               tokenBudget: tokenBudget,
               estimate: estimate)
    }

    public static func chunks(
        lines: [String],
        tokenBudget: Int = defaultTokenBudget,
        estimate: (String) -> Int = estimateTokens
    ) -> [TranscriptChunk] {

        guard !lines.isEmpty, tokenBudget > 0 else { return [] }

        var result: [TranscriptChunk] = []
        var start = 0

        while start < lines.count {
            var end = start
            var used = 0

            while end < lines.count {
                let cost = estimate(lines[end])
                // İlk satır bütçeyi tek başına aşsa bile alınıyor: aksi halde
                // tek uzun segmentte döngü hiç ilerlemez.
                if end > start, used + cost > tokenBudget { break }
                used += cost
                end += 1
            }

            result.append(TranscriptChunk(
                index: result.count,
                text: lines[start..<end].joined(separator: "\n"),
                lineRange: start..<end
            ))

            if end >= lines.count { break }
            // `start + 1` garantisi sonsuz döngüyü engelliyor.
            start = max(start + 1, end - overlapLines)
        }

        return result
    }

    // MARK: Token tahmini

    /// Karakter tabanlı temkinli tahmin.
    ///
    /// Kelime sayısı kullanılmıyor: Türkçe sondan eklemeli ve tek kelime
    /// ("gerçekleştirebileceğimizi") birçok token'a bölünüyor. Karakter/2,5
    /// oranı Qwen BPE'de Türkçe için üst sınıra yakın duruyor, yani parçalar
    /// bağlamı aşmak yerine biraz küçük kalıyor — istenen taraf bu.
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / 2.5).rounded(.up)))
    }
}
