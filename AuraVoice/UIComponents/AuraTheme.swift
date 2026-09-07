//
//  AuraTheme.swift
//  AuraVoice
//
//  Tasarım sistemi — teslim edilen mockup'lardaki token setinin birebir
//  Swift karşılığı (Material 3 tonal paleti).
//
//  TONAL AYRIM ÖNEMLİ: `primary` (#CDFFDE) soluk mint, koyu zemin üzerinde
//  METİN ve İKON için. `primaryContainer` (#00F5A0) doygun mint, DOLGU için
//  (buton yüzeyi, ilerleme çubuğu). İkisini karıştırmak kontrastı bozar:
//  #00F5A0 üstüne beyaz metin okunmaz, #CDFFDE dolgu ise fazla soluk kalır.
//  Aynı ayrım error (#FFB4AB metin / #93000A dolgu) ve secondary için de geçerli.
//

import SwiftUI

public enum AuraTheme {

    // MARK: - Yüzeyler

    public static let background = Color(auraHex: 0x111317)
    public static let surfaceDim = Color(auraHex: 0x111317)
    public static let surfaceContainerLowest = Color(auraHex: 0x0C0E12)
    public static let surfaceContainerLow = Color(auraHex: 0x1A1C20)
    public static let surfaceContainer = Color(auraHex: 0x1E2024)
    public static let surfaceContainerHigh = Color(auraHex: 0x282A2E)
    public static let surfaceContainerHighest = Color(auraHex: 0x333539)
    public static let surfaceVariant = Color(auraHex: 0x333539)
    public static let surfaceBright = Color(auraHex: 0x37393E)

    // MARK: - Primary (mint) — Offline / Zero-Cloud

    /// Metin ve ikon rengi.
    public static let primary = Color(auraHex: 0xCDFFDE)
    /// Dolgu rengi (buton yüzeyi, ilerleme çubuğu).
    public static let primaryContainer = Color(auraHex: 0x00F5A0)
    public static let onPrimaryContainer = Color(auraHex: 0x006B43)
    public static let primaryFixed = Color(auraHex: 0x50FFAF)
    public static let primaryFixedDim = Color(auraHex: 0x00E293)
    /// `primaryContainer` dolgusu üzerindeki metin.
    public static let onPrimaryFixed = Color(auraHex: 0x002111)
    public static let onPrimary = Color(auraHex: 0x003921)
    public static let surfaceTint = Color(auraHex: 0x00E293)

    // MARK: - Secondary (indigo) — Online / Bulut

    public static let secondary = Color(auraHex: 0xC0C1FF)
    public static let secondaryFixed = Color(auraHex: 0xE1E0FF)
    public static let secondaryFixedDim = Color(auraHex: 0xC0C1FF)
    public static let secondaryContainer = Color(auraHex: 0x3131C0)
    public static let onSecondary = Color(auraHex: 0x1000A9)
    public static let onSecondaryContainer = Color(auraHex: 0xB0B2FF)

    // MARK: - Error — Canlı kayıt

    public static let error = Color(auraHex: 0xFFB4AB)
    public static let onError = Color(auraHex: 0x690005)
    public static let errorContainer = Color(auraHex: 0x93000A)
    public static let onErrorContainer = Color(auraHex: 0xFFDAD6)

    // MARK: - Uyarı (kota kritik)

    public static let warning = Color(auraHex: 0xFFB020)

    // MARK: - Metin ve çizgiler

    public static let onSurface = Color(auraHex: 0xE2E2E8)
    public static let onBackground = Color(auraHex: 0xE2E2E8)
    /// Yeşile çalan gri — ikincil metin.
    public static let onSurfaceVariant = Color(auraHex: 0xB9CBBD)
    public static let outline = Color(auraHex: 0x849588)
    public static let outlineVariant = Color(auraHex: 0x3B4A40)
    /// Cam panel kenarı.
    public static let hairline = Color.white.opacity(0.07)

    // MARK: - Metrikler

    public enum Radius {
        public static let small: CGFloat = 4
        public static let large: CGFloat = 8
        /// Kartların standart yarıçapı.
        public static let extraLarge: CGFloat = 12
    }

    public enum Spacing {
        public static let stackSM: CGFloat = 8
        public static let gutter: CGFloat = 12
        public static let stackMD: CGFloat = 16
        public static let stackLG: CGFloat = 24
        public static let screenMargin: CGFloat = 20
    }

    // MARK: - Cam panel

    /// Mockup'lardaki `.glass-panel` degradesi.
    public static var glassGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.055), Color.white.opacity(0.015)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Mod bazlı yardımcılar

    /// Metin ve ikon için mod rengi.
    public static func accent(for mode: ProcessingMode) -> Color {
        switch mode {
        case .offlineZeroCloud: return primary
        case .onlineCloudFast:  return secondary
        }
    }

    /// Dolgu için mod rengi (buton yüzeyi vb.).
    public static func accentFill(for mode: ProcessingMode) -> Color {
        switch mode {
        case .offlineZeroCloud: return primaryContainer
        case .onlineCloudFast:  return secondaryContainer
        }
    }

    /// Dolgunun üzerine gelen metin rengi.
    public static func onAccentFill(for mode: ProcessingMode) -> Color {
        switch mode {
        case .offlineZeroCloud: return onPrimaryFixed
        case .onlineCloudFast:  return secondaryFixed
        }
    }
}

// MARK: - Tipografi

public enum AuraFont {

    /// Gövde metni ailesi. `useBundledInter` açılırsa paketlenmiş Inter,
    /// kapalıyken sistem fontu (SF Pro) kullanılır — SF Pro dinamik tip ve
    /// optik boyut ayarıyla iOS'ta daha doğru davranır ve paket boyutu eklemez.
    public static let useBundledInter = false

    private static func text(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        useBundledInter
            ? .custom("Inter", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    /// Rakam gösterimleri (süre, dakika) — mockup'ta Be Vietnam Pro.
    private static func digits(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    public static let displayLarge = text(34, .bold)
    public static let headlineMedium = text(24, .semibold)
    public static let bodyLarge = text(17, .regular)
    public static let bodySmall = text(15, .regular)
    public static let labelCaps = text(12, .semibold)
    public static let digitMono = digits(17, .medium)
    public static let durationDisplay = digits(48, .medium)

    // Harf aralığı (em değerleri pt karşılığına çevrildi)
    //
    // BİTİŞİK YAZILAN DİLLERDE SIFIRLANIYOR. Arapçada harfler birbirine
    // bağlanır; harf aralığı bu bağları koparır ve metin kırık görünür.
    // Negatif aralık (sıkıştırma) da aynı şekilde zararlı. Aynısı Farsça,
    // Urduca ve Arap yazısı kullanan diğer diller için de geçerli.
    public static var displayLargeTracking: CGFloat { trackingSafe(-0.68) }
    public static var headlineMediumTracking: CGFloat { trackingSafe(-0.24) }
    public static var labelCapsTracking: CGFloat { trackingSafe(0.6) }
    public static var durationTracking: CGFloat { trackingSafe(-0.48) }

    /// Harf aralığını yalnızca güvenli yazı sistemlerinde uygular.
    public static func trackingSafe(_ value: CGFloat) -> CGFloat {
        isCursiveScript ? 0 : value
    }

    /// Arap yazısı ailesinden bir dilde miyiz?
    ///
    /// `Locale.current` uygulamanın seçili dilini yansıtıyor. SwiftUI ortam
    /// yereli daha isabetli olurdu ama o, elli çağrı noktasını birden
    /// değiştirmeyi gerektirirdi; bu ödün bilerek verildi.
    static var isCursiveScript: Bool {
        guard let code = Locale.current.language.languageCode?.identifier.lowercased()
        else { return false }
        return cursiveScripts.contains(code)
    }

    static let cursiveScripts: Set<String> = ["ar", "fa", "ur", "ps", "sd", "ckb", "ug"]
}

// MARK: - Color + Hex

public extension Color {
    init(auraHex hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Ortak View Modifier'ları

public extension View {

    func auraBackground() -> some View {
        self
            .background(AuraTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    func auraGlow(_ color: Color, radius: CGFloat = 20, opacity: Double = 0.15) -> some View {
        shadow(color: color.opacity(opacity), radius: radius, x: 0, y: 0)
    }

    /// Mockup'lardaki `.glass-panel` yüzeyi.
    func glassSurface(
        cornerRadius: CGFloat = AuraTheme.Radius.extraLarge,
        borderColor: Color = AuraTheme.hairline,
        borderWidth: CGFloat = 1
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AuraTheme.surfaceContainerLow)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(AuraTheme.glassGradient)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
    }
}

// MARK: - Biçimlendiriciler

public enum AuraFormat {

    /// 754.0 sn → "12:34"
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        // Yerel ayar VERILIYOR: String(format:) locale almazsa daima Batılı
        // rakam basar; Arapça/Bengalce arayüzde aynı ekrandaki tarihler
        // yerel rakamla çıkarken sayacın Batılı kalması tutarsız görünür.
        return h > 0
            ? String(format: "%d:%02d:%02d", locale: .current, arguments: [h, m, s])
            : String(format: "%02d:%02d", locale: .current, arguments: [m, s])
    }

    /// 12.4 → "12,4 dk" (yerel ayara duyarlı)
    public static func minutes(_ value: Double) -> String {
        let measurement = Measurement(value: max(0, value), unit: UnitDuration.minutes)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = value < 10 ? 1 : 0
        return formatter.string(from: measurement)
    }

    /// Toplantı satırı için "14:30 · 45 dk"
    public static func meetingSubtitle(start: Date, durationMinutes: Int) -> String {
        let time = start.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(time) · \(durationMinutes) dk")
    }
}

// MARK: - Geriye Dönük Uyumluluk
//
// Ekranlar tek tek yeni tasarıma geçirilene kadar eski isimler çalışmaya
// devam etsin diye tutuluyor. Her ekran dönüştürüldükçe ilgili alias silinecek.

public extension AuraTheme {

    static var surface: Color { surfaceContainerLow }
    static var surfaceElevated: Color { surfaceContainerHigh }
    static var mint: Color { primary }
    static var indigo: Color { secondary }
    static var recordRed: Color { error }
    static var textPrimary: Color { onSurface }
    static var textSecondary: Color { onSurfaceVariant }
    static var cardRadius: CGFloat { Radius.extraLarge }
    static var controlRadius: CGFloat { Radius.large }
    static var screenPadding: CGFloat { Spacing.screenMargin }

    static func accentGradient(for mode: ProcessingMode) -> LinearGradient {
        let base = accentFill(for: mode)
        return LinearGradient(
            colors: [base, base.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
