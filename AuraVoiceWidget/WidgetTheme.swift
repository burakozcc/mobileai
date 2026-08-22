//
//  WidgetTheme.swift
//  AuraVoiceWidget
//
//  Widget'ın renkleri.
//
//  Uygulamanın `AuraTheme` dosyası SwiftUI'ın yanı sıra uygulama içi
//  bileşenlere de bağlı; uzantıya sokmak tüm arayüz katmanını buraya taşımak
//  demekti. Widget yalnızca üç renk kullanıyor, o üçü burada birebir aynı
//  değerlerle tekrarlandı. Palet değişirse iki dosya birlikte güncellenmeli.
//

import SwiftUI

enum WidgetTheme {

    /// Koyu zemin üzerinde METİN ve İKON için soluk mint.
    static let primary = Color(red: 0xCD / 255, green: 0xFF / 255, blue: 0xDE / 255)
    /// DOLGU için doygun mint (ilerleme yayı, düğme zemini).
    static let primaryContainer = Color(red: 0x00 / 255, green: 0xF5 / 255, blue: 0xA0 / 255)
    static let onPrimaryContainer = Color(red: 0x00 / 255, green: 0x21 / 255, blue: 0x14 / 255)

    static let surface = Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x17 / 255)
    static let onSurface = Color(red: 0xE2 / 255, green: 0xE2 / 255, blue: 0xE8 / 255)
    static let onSurfaceVariant = Color(red: 0xB9 / 255, green: 0xCB / 255, blue: 0xBD / 255)

    static let error = Color(red: 0xFF / 255, green: 0xB4 / 255, blue: 0xAD / 255)

    /// Kota azaldıkça renk değişiyor: kullanıcı sayıyı okumadan durumu görsün.
    static func accent(for fraction: Double, isEmpty: Bool) -> Color {
        if isEmpty { return error }
        return fraction < 0.15 ? error : primaryContainer
    }
}
