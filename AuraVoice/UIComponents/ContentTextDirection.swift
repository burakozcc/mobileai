//
//  ContentTextDirection.swift
//  AuraVoice
//
//  Kullanıcı içeriğinin KENDİ yazım yönü.
//
//  NEDEN GEREKLİ: deşifre ve özet, arayüzün dilinde değil KAYDIN dilinde.
//  Whisper 99 dil tanıyor; Türkçe arayüz kullanan biri Arapça bir toplantı
//  kaydedebilir, Arapça arayüz kullanan biri İngilizce bir toplantı.
//  Metnin yönünü arayüzden almak bu iki durumda da yanlış: paragraf yanlış
//  kenara yaslanır, satır sonu noktalaması yanlış tarafa düşer.
//
//  Unicode iki yönlü algoritması bir satır İÇİNDEKİ harf sırasını zaten
//  doğru çiziyor; burada çözülen ayrı bir sorun — paragrafın taban yönü.
//

import SwiftUI

public enum ContentTextDirection {

    /// Metindeki baskın yazı sistemine göre taban yön.
    ///
    /// Tarayıcıların `dir="auto"` davranışı "ilk güçlü karakter" sezgisini
    /// kullanır; deşifrede bu yanılabiliyor çünkü metin sık sık Latin bir
    /// özel adla ya da saatle başlıyor. Bu yüzden baskın yazıyı SAYIYORUZ.
    /// Sayı ve noktalama yön taşımadığı için hesaba katılmıyor.
    /// Yön taşıyan karakter yoksa `nil` döner.
    ///
    /// "Bilmiyorum" ile "soldan sağa" AYRI şeyler. Yalnızca rakam ve
    /// noktalamadan oluşan bir önizleme ("10:00 – 11:00") ya da boş metin
    /// için LTR dayatmak, Arapça arayüzde çevredeki yönü boş yere eziyordu.
    public static func layoutDirection(for text: String) -> LayoutDirection? {
        var rightToLeft = 0
        var leftToRight = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            // İbranice, Arapça, Süryanice, Thaana, Arapça ek blokları,
            // Arapça sunum biçimleri
            case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F,
                 0x0750...0x077F, 0x0780...0x07BF, 0x08A0...0x08FF,
                 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                rightToLeft += 1
            // Latin, Yunan, Kiril, Devanagari, Bengalce, Çince/Japonca/Korece
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F,
                 0x0370...0x03FF, 0x0400...0x04FF, 0x0900...0x097F,
                 0x0980...0x09FF, 0x3040...0x30FF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF:
                leftToRight += 1
            default:
                continue
            }

            // İlk birkaç yüz yön taşıyan karakter kararı vermeye yeter;
            // uzun bir deşifrenin tamamını taramak boşuna iş.
            if rightToLeft + leftToRight >= 400 { break }
        }

        guard rightToLeft + leftToRight > 0 else { return nil }
        return rightToLeft > leftToRight ? .rightToLeft : .leftToRight
    }
}

/// Metnin yönü çözülemezse ÇEVREDEKİ yön korunur.
struct ContentDirectionModifier: ViewModifier {

    let text: String
    @Environment(\.layoutDirection) private var ambient

    func body(content: Content) -> some View {
        let resolved = ContentTextDirection.layoutDirection(for: text) ?? ambient
        return content
            .environment(\.layoutDirection, resolved)
            .multilineTextAlignment(.leading)
    }
}

public extension View {

    /// Görünümü, gösterdiği METNİN yönüne göre hizalar.
    ///
    /// Arayüz diline değil içeriğe bakar. Kullanıcının kendi metnini çizen
    /// her yerde (deşifre, özet, not önizlemesi) kullanılmalı.
    func contentDirection(of text: String) -> some View {
        modifier(ContentDirectionModifier(text: text))
    }
}
