//
//  NoteDetailView.swift
//  AuraVoice
//
//  Özet + ham transkript görünümü. Markdown satır satır render edilir
//  (AttributedString yalnızca satır içi biçimlendirmeyi çözer, başlık ve
//  görev kutularını kendimiz çiziyoruz).
//

import SwiftUI

public struct NoteDetailView: View {

    private let note: NoteSummary
    @State private var showsTranscript = false

    public init(note: NoteSummary) {
        self.note = note
    }

    private var accent: Color { AuraTheme.accent(for: note.mode) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metaCard

                GlassCardView(padding: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                            MarkdownLine(raw: line, accent: accent)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showsTranscript) {
                    Text(note.rawTranscript)
                        .font(.system(size: 13))
                        .foregroundStyle(AuraTheme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                } label: {
                    Label("Ham Transkript", systemImage: "text.alignleft")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                }
                .tint(accent)
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.cardRadius, style: .continuous)
                        .fill(AuraTheme.surface)
                }
            }
            .padding(AuraTheme.screenPadding)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: note.summaryMarkdown) {
                    Image(systemName: "square.and.arrow.up")
                }
                .tint(accent)
            }
        }
        .auraBackground()
    }

    private var metaCard: some View {
        GlassCardView(padding: 14, borderTint: accent) {
            HStack(spacing: 10) {
                AuraBadge(
                    note.mode == .offlineZeroCloud ? "Zero-Cloud" : "Bulut",
                    systemImage: note.mode.systemImage,
                    tint: accent
                )
                AuraBadge(note.template.shortTitle, systemImage: note.template.systemImage, tint: AuraTheme.textSecondary)
                Spacer(minLength: 0)
                Label(AuraFormat.clock(note.durationSeconds), systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
    }

    private var summaryLines: [String] {
        note.summaryMarkdown
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Satır Renderer

private struct MarkdownLine: View {
    let raw: String
    let accent: Color

    var body: some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("###") {
            Text(strip(trimmed, prefix: "###"))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(AuraTheme.textPrimary)
        } else if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") {
            let done = trimmed.hasPrefix("- [x]")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? accent : AuraTheme.textSecondary)
                    .font(.system(size: 14))
                inline(String(trimmed.dropFirst(5)))
            }
        } else if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                inline(String(trimmed.dropFirst(1)))
            }
        } else {
            inline(trimmed)
        }
    }

    private func strip(_ text: String, prefix: String) -> String {
        String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func inline(_ text: String) -> some View {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let attributed = (try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(cleaned)

        return Text(attributed)
            .font(.system(size: 14))
            .foregroundStyle(AuraTheme.textPrimary.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: NoteSummary(
            title: "Haftalık Ürün Sync",
            durationSeconds: 1840,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: """
            ### Toplantı Özeti
            - Q3 lansmanı iki hafta öne çekildi.
            - Offline mod **öncelikli** olarak konumlandırılacak.

            **Aksiyonlar**
            - [ ] Pazarlama metinlerini güncelle
            - [x] TestFlight build'i yayınla
            """,
            rawTranscript: "Bu alanda kaydın tam metni yer alır…",
            waveformPreview: (0..<24).map { _ in Float.random(in: 0.1...0.9) }
        ))
    }
    .preferredColorScheme(.dark)
}
