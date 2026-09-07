//
//  AuraNoteCard.swift
//  AuraVoice
//
//  Not kartı — mockup'taki "Recent Notes" kartının birebir karşılığı.
//  Hem Dashboard hem Notlar listesi kullanır; tek yerde durması ikisinin
//  zamanla birbirinden ayrılmasını engelliyor.
//

import SwiftUI

public struct AuraNoteCard: View {

    private let note: NoteSummary
    private let showsModeBadge: Bool

    public init(note: NoteSummary, showsModeBadge: Bool = false) {
        self.note = note
        self.showsModeBadge = showsModeBadge
    }

    private var accent: Color { AuraTheme.accent(for: note.mode) }

    public var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.gutter) {

            HStack(alignment: .top, spacing: AuraTheme.Spacing.stackSM) {
                // Baslik kullanicinin kendi icerigi; yonu ondan geliyor.
                // Yalnizca metne uygulaniyor: kartin duzeni (tarihin karsi
                // kenarda durmasi) arayuz yonunde kalmali.
                Text(note.title)
                    .font(AuraFont.bodyLarge.weight(.semibold))
                    .foregroundStyle(AuraTheme.onSurface)
                    .lineLimit(1)
                    .contentDirection(of: note.title)

                Spacer(minLength: 4)

                Text(note.createdAt, format: .relative(presentation: .named))
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .lineLimit(1)
            }

            Text(note.previewLine)
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentDirection(of: note.previewLine)

            HStack(spacing: AuraTheme.Spacing.stackSM) {
                if !note.waveformPreview.isEmpty {
                    WaveformThumbnail(levels: note.waveformPreview, tint: accent)
                        .frame(height: 24)
                        .frame(maxWidth: 96, alignment: .leading)
                        .opacity(0.6)
                }

                Spacer(minLength: 0)

                // İşlenmeyi bekleyen ve başarısız notlar listede kaybolmasın:
                // sesleri duruyor ve tekrar denenebiliyorlar.
                if note.processingState.isPending {
                    AuraBadge(
                        note.processingState.label,
                        systemImage: note.processingState == .failed
                            ? "exclamationmark.triangle.fill"
                            : "clock.fill",
                        tint: note.processingState == .failed ? AuraTheme.warning : AuraTheme.onSurfaceVariant
                    )
                }

                if showsModeBadge {
                    AuraBadge(
                        note.mode == .offlineZeroCloud ? String(localized: "Zero-Cloud") : String(localized: "Bulut"),
                        systemImage: note.mode == .offlineZeroCloud ? "lock.fill" : "cloud.fill",
                        tint: accent
                    )
                }

                // Süre çipi — mockup'ta surface-container zemin + ince kenar.
                Text(AuraFormat.clock(note.durationSeconds))
                    .font(AuraFont.digitMono)
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .padding(.horizontal, AuraTheme.Spacing.stackSM)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: AuraTheme.Radius.small, style: .continuous)
                            .fill(AuraTheme.surfaceContainer)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: AuraTheme.Radius.small, style: .continuous)
                            .strokeBorder(AuraTheme.hairline, lineWidth: 1)
                    }
            }
        }
        .padding(AuraTheme.Spacing.stackMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.title), \(AuraFormat.clock(note.durationSeconds))")
    }
}

// MARK: - Bölüm başlığı

/// Mockup'taki `label-caps` + uppercase + geniş harf aralığı başlık.
public struct AuraSectionTitle: View {

    private let text: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(AuraFont.labelCaps)
                .tracking(AuraFont.trackingSafe(1.2))
                .foregroundStyle(AuraTheme.onSurfaceVariant)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AuraFont.labelCaps)
                    .foregroundStyle(AuraTheme.primary)
            }
        }
        .padding(.horizontal, 4)
    }
}

#Preview {
    ZStack {
        AuraTheme.background.ignoresSafeArea()
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            AuraSectionTitle("Son Kayıtlar", actionTitle: "Tümü") {}
            AuraNoteCard(note: NoteSummary(
                title: "Ürün Sync",
                durationSeconds: 2712,
                mode: .offlineZeroCloud,
                template: .meetingNotes,
                summaryMarkdown: "- Lansman takvimi konuşuldu ve yeni transkripsiyon motoru önceliklendirildi.",
                rawTranscript: "",
                waveformPreview: (0..<24).map { _ in Float.random(in: 0.15...0.95) }
            ), showsModeBadge: true)
        }
        .padding(AuraTheme.Spacing.screenMargin)
    }
    .preferredColorScheme(.dark)
}
