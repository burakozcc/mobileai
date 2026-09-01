//
//  QuotaWidget.swift
//  AuraVoiceWidget
//
//  Kalan dakikayı gösteren widget: ana ekran, kilit ekranı ve saat yüzü.
//
//  Uzantı kota mantığını YENİDEN HESAPLAMIYOR. Uygulama her tazelemede App
//  Group'a bir anlık görüntü yazıyor, widget yalnızca onu okuyor. Kota
//  kuralları (ücretsiz hediye, imzalı bilet, abonelik yenilemesi) tek yerde
//  kalsın diye — iki ayrı hesap iki farklı sayı gösterirdi.
//

import WidgetKit
import SwiftUI

// MARK: - Zaman çizelgesi

struct QuotaEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: SharedQuotaSnapshot?

    /// Uygulama hiç açılmadıysa gösterilecek nötr değer.
    static let placeholder = QuotaEntry(
        date: Date(timeIntervalSince1970: 0),
        snapshot: SharedQuotaSnapshot(
            remainingMinutes: 30,
            planMinutes: 30,
            updatedAt: Date(timeIntervalSince1970: 0),
            offlineAvailable: true
        )
    )
}

struct QuotaProvider: TimelineProvider {

    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: SharedQuotaSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: Date(), snapshot: SharedQuotaSnapshot.read())
        // Kota yalnızca kayıt işlendiğinde değişiyor; sık yenilemenin bütçesi
        // boşa gider. Uygulama tazeledikçe zaten `reloadAllTimelines` çağırıyor.
        let next = Date().addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Görünüm

struct QuotaWidgetView: View {

    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    private var minutes: Int {
        Int((entry.snapshot?.remainingMinutes ?? 0).rounded(.down))
    }

    private var fraction: Double { entry.snapshot?.fraction ?? 0 }
    private var isEmpty: Bool { entry.snapshot?.isEmpty ?? true }
    /// Kaydın gerçekten başlayabileceği durum: kota var VE cihaz içi model
    /// kurulu. Yalnızca kotaya bakmak, modeli olmayan kullanıcıya çalışan bir
    /// düğme göstermek olurdu.
    private var canRecord: Bool { !isEmpty && (entry.snapshot?.offlineAvailable ?? false) }
    private var accent: Color { WidgetTheme.accent(for: fraction, isEmpty: isEmpty) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            Text("\(minutes) dk kayıt")
        default:
            small
        }
    }

    // MARK: Kilit ekranı — dairesel

    private var circular: some View {
        Gauge(value: fraction) {
            Image(systemName: "mic.fill")
        } currentValueLabel: {
            Text("\(minutes)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    // MARK: Kilit ekranı — dikdörtgen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("AuraVoice", systemImage: "mic.fill")
                .font(.caption2.weight(.semibold))
            Text(isEmpty ? "Kota bitti" : "\(minutes) dakika kaldı")
                .font(.headline)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        }
    }

    // MARK: Ana ekran — küçük

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                Text("AuraVoice")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(WidgetTheme.primary)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(minutes)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(isEmpty ? WidgetTheme.error : WidgetTheme.onSurface)
                    .contentTransition(.numericText())
                Text(isEmpty ? "dakika kalmadı" : "dakika kaldı")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetTheme.onSurfaceVariant)
            }

            // İnteraktif widget: uygulamayı açıp kayıt ekranını hazırlıyor.
            // Kaydı uzantı başlatamaz (mikrofon erişimi yok), o yüzden düğme
            // "başlat" değil "hazırla" işi yapıyor — kullanıcı kayıt ekranını
            // görüyor ve ne olduğunu biliyor.
            Button(intent: StartRecordingFromWidgetIntent()) {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                    Text("Kaydet")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(canRecord ? accent : WidgetTheme.onSurfaceVariant.opacity(0.25), in: Capsule())
                .foregroundStyle(canRecord ? WidgetTheme.onPrimaryContainer : WidgetTheme.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .disabled(!canRecord)
        }
    }
}

// MARK: - Widget tanımı

struct AuraQuotaWidget: Widget {

    static let kind = "AuraQuotaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
                .containerBackground(WidgetTheme.surface, for: .widget)
        }
        .configurationDisplayName("Kalan Dakika")
        .description("Kalan kayıt dakikanı gösterir, tek dokunuşla kayda başlar.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
