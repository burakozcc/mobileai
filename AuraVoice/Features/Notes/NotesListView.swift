//
//  NotesListView.swift
//  AuraVoice
//
//  Notlar sekmesi. Mockup setinde bu ekran yoktu — sekme çubuğu onu
//  gerektirdiği için mevcut tasarım dilinden türetildi: aynı cam kart,
//  aynı `label-caps` bölüm başlıkları, aynı boşluk ritmi.
//

import SwiftUI

@MainActor
@Observable
public final class NotesListViewModel {

    public private(set) var notes: [NoteSummary] = []
    public private(set) var isLoading = false
    public var searchText = ""
    public var modeFilter: ProcessingMode?
    public var errorMessage: String?

    @ObservationIgnored private let repository: any NoteRepository

    public init(repository: any NoteRepository = DatabaseManager.shared) {
        self.repository = repository
    }

    /// Arama ve mod filtresi uygulanmış liste.
    public var filtered: [NoteSummary] {
        var result = notes

        if let modeFilter {
            result = result.filter { $0.mode == modeFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }

        // Başlık, özet ve transkriptte ara — kullanıcı "şu cümle geçiyordu"
        // diye hatırlar, sadece başlıkta aramak yetmez.
        let needle = MeetingKeywordMatcher.normalize(query)
        return result.filter { note in
            MeetingKeywordMatcher.normalize(note.title).contains(needle)
                || MeetingKeywordMatcher.normalize(note.summaryMarkdown).contains(needle)
                || MeetingKeywordMatcher.normalize(note.rawTranscript).contains(needle)
        }
    }

    /// Tarihe göre gruplanmış bölümler.
    public var sections: [(title: String, notes: [NoteSummary])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [NoteSummary] = []
        var thisWeek: [NoteSummary] = []
        var older: [NoteSummary] = []

        for note in filtered {
            if calendar.isDateInToday(note.createdAt) {
                today.append(note)
            } else if let days = calendar.dateComponents([.day], from: note.createdAt, to: now).day, days < 7 {
                thisWeek.append(note)
            } else {
                older.append(note)
            }
        }

        return [
            ("Bugün", today),
            ("Bu Hafta", thisWeek),
            ("Daha Eski", older)
        ].filter { !$0.1.isEmpty }
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await repository.all()
        } catch {
            errorMessage = String(localized: "Kayıtlar okunamadı: \(error.localizedDescription)")
        }
    }

    public func delete(_ note: NoteSummary) async {
        do {
            notes = try await repository.delete(id: note.id)
        } catch {
            errorMessage = String(localized: "Not silinemedi: \(error.localizedDescription)")
        }
    }
}

// MARK: - Görünüm

public struct NotesListView: View {

    @State private var viewModel = NotesListViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                AuraTheme.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: AuraTheme.Spacing.stackLG, pinnedViews: []) {
                        searchField
                        modeFilterRow

                        if viewModel.sections.isEmpty {
                            emptyState
                                .padding(.top, AuraTheme.Spacing.stackLG)
                        } else {
                            ForEach(viewModel.sections, id: \.title) { section in
                                VStack(spacing: AuraTheme.Spacing.stackSM) {
                                    AuraSectionTitle(section.title)
                                    ForEach(section.notes) { note in
                                        NavigationLink {
                                            NoteDetailView(note: note)
                                        } label: {
                                            AuraNoteCard(note: note, showsModeBadge: true)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                Task { await viewModel.delete(note) }
                                            } label: {
                                                Label("Sil", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Sekme çubuğunun altında kalan boşluk.
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, AuraTheme.Spacing.screenMargin)
                    .padding(.top, AuraTheme.Spacing.stackMD)
                }
                .scrollIndicators(.hidden)
                .refreshable { await viewModel.refresh() }
            }
            .navigationTitle("Notlar")
            .navigationBarTitleDisplayMode(.large)
        }
        .tint(AuraTheme.primary)
        .task { await viewModel.refresh() }
    }

    // MARK: Arama

    private var searchField: some View {
        HStack(spacing: AuraTheme.Spacing.stackSM) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AuraTheme.onSurfaceVariant)

            TextField("Notlarda ara", text: $viewModel.searchText)
                .font(AuraFont.bodyLarge)
                .foregroundStyle(AuraTheme.onSurface)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Aramayı temizle")
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.stackMD)
        .frame(height: 44)
        .glassSurface(cornerRadius: AuraTheme.Radius.extraLarge)
    }

    // MARK: Mod filtresi

    private var modeFilterRow: some View {
        HStack(spacing: AuraTheme.Spacing.stackSM) {
            filterChip(title: "Tümü", isActive: viewModel.modeFilter == nil, tint: AuraTheme.onSurfaceVariant) {
                viewModel.modeFilter = nil
            }
            ForEach(ProcessingMode.allCases) { mode in
                filterChip(
                    title: mode.title,
                    isActive: viewModel.modeFilter == mode,
                    tint: AuraTheme.accent(for: mode)
                ) {
                    viewModel.modeFilter = viewModel.modeFilter == mode ? nil : mode
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(
        title: String,
        isActive: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(AuraFont.labelCaps)
                .tracking(AuraFont.labelCapsTracking)
                .foregroundStyle(isActive ? tint : AuraTheme.onSurfaceVariant)
                .padding(.horizontal, AuraTheme.Spacing.gutter)
                .padding(.vertical, 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(isActive ? tint.opacity(0.10) : AuraTheme.surfaceContainer)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isActive ? tint.opacity(0.20) : AuraTheme.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Boş durum

    private var emptyState: some View {
        VStack(spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: viewModel.searchText.isEmpty ? "waveform.badge.mic" : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(AuraTheme.primary.opacity(0.7))

            Text(viewModel.searchText.isEmpty ? "Henüz kayıt yok" : "Sonuç bulunamadı")
                .font(AuraFont.headlineMedium)
                .tracking(AuraFont.headlineMediumTracking)
                .foregroundStyle(AuraTheme.onSurface)

            Text(viewModel.searchText.isEmpty
                 ? "Panel sekmesindeki kayıt butonuyla ilk toplantını kaydet."
                 : "Farklı bir kelime dene ya da filtreyi kaldır.")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(AuraTheme.Spacing.stackLG)
        .glassSurface()
    }
}

#Preview {
    NotesListView()
}
