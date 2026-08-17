//
//  AuraTheme.swift
//  AuraVoice
//
//  Dark Mode First tasarım dili. Tüm renk / tipografi / metrik sabitleri
//  tek noktadan yönetilir ki mod değişiminde (Offline mint ↔ Online indigo)
//  tüm ekranlar tutarlı kalsın.
//

import SwiftUI

public enum AuraTheme {

    // MARK: - Renk Paleti

    /// Ana arka plan — #0B0D11
    public static let background = Color(auraHex: 0x0B0D11)
    /// Kart yüzeyi — #161B22
    public static let surface = Color(auraHex: 0x161B22)
    /// Kart üstü ikincil yüzey (chip, alan doldurucu)
    public static let surfaceElevated = Color(auraHex: 0x1E252F)
    /// Offline "Zero-Cloud" güven rengi — #00F5A0
    public static let mint = Color(auraHex: 0x00F5A0)
    /// Canlı kayıt rengi — #FF3B30
    public static let recordRed = Color(auraHex: 0xFF3B30)
    /// Online vurgu rengi — #6366F1
    public static let indigo = Color(auraHex: 0x6366F1)
    /// Uyarı / kota kritik rengi
    public static let warning = Color(auraHex: 0xFFB020)

    public static let textPrimary = Color(auraHex: 0xF2F5F9)
    public static let textSecondary = Color(auraHex: 0x8B95A5)
    public static let hairline = Color.white.opacity(0.07)

    // MARK: - Metrikler

    public static let cardRadius: CGFloat = 22
    public static let controlRadius: CGFloat = 14
    public static let screenPadding: CGFloat = 20

    // MARK: - Mod Bazlı Yardımcılar

    /// Seçili işleme moduna göre vurgu rengi.
    public static func accent(for mode: ProcessingMode) -> Color {
        switch mode {
        case .offlineZeroCloud: return mint
        case .onlineCloudFast:  return indigo
        }
    }

    public static func accentGradient(for mode: ProcessingMode) -> LinearGradient {
        let base = accent(for: mode)
        return LinearGradient(
            colors: [base, base.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Kart arka planı için kullanılan hafif "cam" degrade.
    public static var glassGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.055), Color.white.opacity(0.015)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Color + Hex

public extension Color {
    /// `Color(auraHex: 0x0B0D11)` biçiminde kullanım için.
    init(auraHex hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Ortak View Modifier'ları

public extension View {
    /// Ekranın tamamını AuraVoice arka planıyla kaplar.
    func auraBackground() -> some View {
        self
            .background(AuraTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    /// Metin/ikon üzerine mod rengiyle yumuşak parıltı.
    func auraGlow(_ color: Color, radius: CGFloat = 18, opacity: Double = 0.45) -> some View {
        shadow(color: color.opacity(opacity), radius: radius, x: 0, y: 0)
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
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
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
        return "\(time) · \(durationMinutes) dk"
    }
}
