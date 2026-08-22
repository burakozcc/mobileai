//
//  NoteDetailView.swift
//  AuraVoice
//
//  Not detayı — mockup'taki "bento" düzeni: özet ayrı kartlara bölünmüş,
//  aksiyonlar işaretlenebilir, ham transkript açılır kapanır bir bölümde
//  konuşmacı etiketleriyle.
//

import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
public final class NoteDetailViewModel {

    public private(set) var note: NoteSummary
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var isLoadingSegments = false
    public var errorMessage: String?

    @ObservationIgnored private let repository: any NoteRepository

    public init(note: NoteSummary, repository: any NoteRepository = DatabaseManager.shared) {
        self.note = note
        self.repository = repository
    }

    public var document: SummaryDocument {
        SummaryDocument.parse(note.summaryMarkdown)
    }

    public var taskProgress: (done: Int, total: Int) {
        SummaryDocument.taskProgress(in: note.summaryMarkdown)
    }

    /// Aynı konuşmacının art arda gelen segmentleri tek blokta toplanır —
    /// her cümlede etiketi tekrarlamak okumayı zorlaştırıyor.
    public var transcriptBlocks: [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for segment in segments {
            if var last = blocks.last, last.speakerLabel == segment.speakerLabel {
                last.text += " " + segment.text
                last.endSeconds = segment.endSeconds
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(TranscriptBlock(
                    id: segment.id,
                    speakerLabel: segment.speakerLabel,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds,
                    text: segment.text
                ))
            }
        }
        return blocks
    }

    public struct TranscriptBlock: Identifiable, Equatable {
        public let id: UUID
        public let speakerLabel: String?
        public let startSeconds: Double
        public var endSeconds: Double
        public var text: String
    }

    public func loadSegments() async {
        isLoadingSegments = true
        defer { isLoadingSegments = false }
        do {
            segments = try await repository.segments(forNote: note.id)
        } catch {
            segments = []
        }
    }

    /// Aksiyon kutusunu ters çevirir ve markdown'ı kaydeder.
    public func toggleTask(_ text: String) async {
        let updated = SummaryDocument.toggleTask(withText: text, in: note.summaryMarkdown)
        guard updated != note.summaryMarkdown else { return }

        var edited = note
        edited.summaryMarkdown = updated
        note = edited

        do {
            try await repository.insert(edited)
        } catch {
            errorMessage = "Değişiklik kaydedilemedi: \(error.localizedDescription)"
        }
    }
}

// MARK: - Görünüm

public struct NoteDetailView: View {

    @State private var viewModel: NoteDetailViewModel
    @State private var isTranscriptExpanded = false

    public init(note: NoteSummary) {
        _viewModel = State(initialValue: NoteDetailViewModel(note: note))
    }

    private var accent: Color { AuraTheme.accent(for: viewModel.note.mode) }

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackLG) {
                    metadata
                    summarySections
                    transcriptSection
                    Color.clear.frame(height: 48)
                }
                .padding(.horizontal, AuraTheme.Spacing.screenMargin)
                .padding(.top, AuraTheme.Spacing.stackMD)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(viewModel.note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: viewModel.note.summaryMarkdown) {
                    Image(systemName: "square.and.arrow.up")
                }
                .tint(accent)
            }
        }
        .task { await viewModel.loadSegments() }
        .alert(
            "Bir sorun var",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: Üst bilgi

    private var metadata: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.gutter) {
            HStack(spacing: AuraTheme.Spacing.stackSM) {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.note.mode == .offlineZeroCloud ? "lock.fill" : "cloud.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(viewModel.note.mode == .offlineZeroCloud ? "ZERO-CLOUD" : "BULUT")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, AuraTheme.Spacing.gutter)
                .padding(.vertical, 6)
                .background { Capsule().fill(accent.opacity(0.10)) }
                .overlay { Capsule().strokeBorder(accent.opacity(0.20), lineWidth: 1) }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text("\(viewModel.note.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(AuraFormat.clock(viewModel.note.durationSeconds))")
                        .font(AuraFont.bodySmall)
                }
                .foregroundStyle(AuraTheme.onSurfaceVariant)

                Spacer(minLength: 0)
            }

            Text(viewModel.note.title)
                .font(AuraFont.displayLarge)
                .tracking(AuraFont.displayLargeTracking)
                .foregroundStyle(AuraTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)

            let progress = viewModel.taskProgress
            if progress.total > 0 {
                Text("\(progress.done)/\(progress.total) aksiyon tamamlandı")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(progress.done == progress.total ? accent : AuraTheme.onSurfaceVariant)
            }
        }
    }

    // MARK: Özet kartları

    @ViewBuilder
    private var summarySections: some View {
        let document = viewModel.document

        if document.isEmpty {
            emptyCard(
                icon: "doc.text",
                title: "Özet bulunamadı",
                detail: "Bu kayıt için özet üretilmemiş."
            )
        } else {
            VStack(spacing: AuraTheme.Spacing.stackMD) {
                if !document.looseItems.isEmpty {
                    sectionCard(title: "Özet", items: document.looseItems)
                }
                ForEach(document.sections) { section in
                    sectionCard(title: section.title, items: section.items)
                }
            }
        }
    }

    private func sectionCard(title: String, items: [SummaryDocument.Item]) -> some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.gutter) {
            HStack(spacing: AuraTheme.Spacing.stackSM) {
                Image(systemName: Self.icon(for: title))
                    .font(.system(size: 16))
                    .foregroundStyle(accent)
                Text(title)
                    .font(AuraFont.headlineMedium)
                    .tracking(AuraFont.headlineMediumTracking)
                    .foregroundStyle(AuraTheme.onSurface)
            }

            VStack(alignment: .leading, spacing: AuraTheme.Spacing.gutter) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    itemRow(item)
                }
            }
        }
        .padding(AuraTheme.Spacing.stackMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    @ViewBuilder
    private func itemRow(_ item: SummaryDocument.Item) -> some View {
        switch item {
        case let .bullet(text):
            HStack(alignment: .top, spacing: AuraTheme.Spacing.stackSM) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                    .padding(.top, 8)
                Text(text)
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

        case let .task(text, isDone):
            Button {
                Task { await viewModel.toggleTask(text) }
            } label: {
                HStack(alignment: .top, spacing: AuraTheme.Spacing.stackSM) {
                    Image(systemName: isDone ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17))
                        .foregroundStyle(isDone ? accent : AuraTheme.onSurfaceVariant)

                    Text(text)
                        .font(AuraFont.bodyLarge)
                        .foregroundStyle(isDone ? AuraTheme.onSurfaceVariant : AuraTheme.onSurface)
                        .strikethrough(isDone, color: AuraTheme.onSurfaceVariant)
                        .opacity(isDone ? 0.55 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isDone)
            .accessibilityLabel(text)
            .accessibilityValue(isDone ? "Tamamlandı" : "Bekliyor")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: Transkript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isTranscriptExpanded.toggle()
                }
            } label: {
                HStack(spacing: AuraTheme.Spacing.stackSM) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 16))
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                    Text("Ham Transkript")
                        .font(AuraFont.headlineMedium)
                        .tracking(AuraFont.headlineMediumTracking)
                        .foregroundStyle(AuraTheme.onSurface)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .rotationEffect(.degrees(isTranscriptExpanded ? 180 : 0))
                }
                .padding(AuraTheme.Spacing.stackMD)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isTranscriptExpanded {
                Rectangle()
                    .fill(AuraTheme.hairline)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackMD) {
                    if viewModel.transcriptBlocks.isEmpty {
                        // Segment yoksa (eski kayıt veya segment üretmeyen motor)
                        // düz metne düş.
                        Text(viewModel.note.rawTranscript.isEmpty
                             ? "Bu kayıt için transkript saklanmamış."
                             : viewModel.note.rawTranscript)
                            .font(AuraFont.bodyLarge)
                            .foregroundStyle(AuraTheme.onSurfaceVariant)
                            .textSelection(.enabled)
                    } else {
                        ForEach(viewModel.transcriptBlocks) { block in
                            transcriptBlockView(block)
                        }
                    }
                }
                .padding(AuraTheme.Spacing.stackMD)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .glassSurface()
    }

    private func transcriptBlockView(_ block: NoteDetailViewModel.TranscriptBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let speaker = block.speakerLabel {
                    Text(speaker.uppercased())
                        .foregroundStyle(accent)
                    Text("·")
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                }
                Text(AuraFormat.clock(block.startSeconds))
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .monospacedDigit()
            }
            .font(AuraFont.labelCaps)
            .tracking(AuraFont.labelCapsTracking)

            Text(block.text)
                .font(AuraFont.bodyLarge)
                .foregroundStyle(AuraTheme.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Yardımcılar

    private func emptyCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(AuraTheme.onSurfaceVariant)
            Text(title)
                .font(AuraFont.bodyLarge.weight(.semibold))
                .foregroundStyle(AuraTheme.onSurface)
            Text(detail)
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(AuraTheme.Spacing.stackLG)
        .glassSurface()
    }

    /// Bölüm başlığına göre ikon — özet motor tarafından üretildiği için
    /// başlıklar sabit değil, anahtar kelimeyle eşleştiriyoruz.
    static func icon(for title: String) -> String {
        let normalized = MeetingKeywordMatcher.normalize(title)
        if normalized.contains("aksiyon") || normalized.contains("action") || normalized.contains("takip") {
            return "checklist"
        }
        if normalized.contains("karar") || normalized.contains("decision") {
            return "checkmark.seal.fill"
        }
        if normalized.contains("konusul") || normalized.contains("discussed") {
            return "bubble.left.and.bubble.right.fill"
        }
        return "sparkles"
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: NoteSummary(
            title: "Haftalık Ürün Sync",
            durationSeconds: 2712,
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            summaryMarkdown: """
            ### Toplantı Özeti
            _Cihaz içi · Zero-Cloud · 45 dk_

            **Ana Başlıklar**
            - Q3 lansmanı iki hafta öne çekildi.
            - Tasarım sistemi geçişi %80 tamamlandı.

            **Kararlar**
            - Güvenlik denetimi için bütçe artışı onaylandı.

            **Aksiyonlar**
            - [ ] App Store metinlerini güncelle (Mehmet)
            - [x] TestFlight build'i yayınla (Ayşe)
            """,
            rawTranscript: "Bu alanda kaydın tam metni yer alır…",
            waveformPreview: (0..<24).map { _ in Float.random(in: 0.1...0.9) }
        ))
    }
    .preferredColorScheme(.dark)
}
