//
//  ModelDownloadView.swift
//  AuraVoice
//
//  Cihaz içi model indirme — mockup'taki "Secure AI Models" ekranı.
//
//  Bu ürünün en kritik ikna anı: kullanıcıdan 78–480 MB indirmesini
//  istiyoruz. Ekran bunu hak etmeli, o yüzden önce KARŞILIĞINDA NE
//  KAZANDIĞI anlatılıyor (uçak modunda çalışma, verinin cihazdan
//  çıkmaması), sonra seçenekler geliyor.
//

import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
public final class ModelDownloadViewModel {

    public enum RowState: Equatable, Sendable {
        case available
        case downloading(Double)
        case installed
        case failed(String)
    }

    public enum Kind: Equatable, Hashable, Sendable {
        case speech(WhisperKitEngine.Variant)
        case diarization
        /// Nöral özetleyici (GGUF). İsteğe bağlı: kurulu değilse çıkarımsal
        /// özetleyici devrede kalıyor ve offline mod yine çalışıyor.
        case neuralSummarizer
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let title: String
        public let subtitle: String
        public let iconName: String
        public let megabytes: Int
        public var state: RowState
        /// Önerilen seçenek vurgulanır.
        public let isRecommended: Bool
    }

    public private(set) var rows: [Row] = []
    public private(set) var totalDiskBytes: Int64 = 0
    public var errorMessage: String?

    @ObservationIgnored private let manager: OfflineModelManager
    @ObservationIgnored private let diarizer: SpeakerKitDiarizer
    @ObservationIgnored private let neuralInstaller: NeuralModelInstaller
    @ObservationIgnored private var tasks: [Kind: Task<Void, Never>] = [:]

    public init(
        manager: OfflineModelManager = .shared,
        diarizer: SpeakerKitDiarizer = SpeakerKitDiarizer(),
        neuralInstaller: NeuralModelInstaller = .shared
    ) {
        self.manager = manager
        self.diarizer = diarizer
        self.neuralInstaller = neuralInstaller
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    public var hasAnySpeechModel: Bool {
        rows.contains { row in
            guard case .speech = row.kind else { return false }
            return row.state == .installed
        }
    }

    // MARK: Yükleme

    public func refresh() async {
        let installed = Set(OfflineModelManager.installations().map(\.variant))
        let diarizationInstalled = OfflineModelManager.isDiarizationInstalled()

        rows = WhisperKitEngine.Variant.allCases.map { variant in
            Row(
                id: variant.rawValue,
                kind: .speech(variant),
                title: variant.displayName,
                subtitle: Self.subtitle(for: variant),
                iconName: Self.icon(for: variant),
                megabytes: variant.approximateMegabytes,
                state: currentState(for: .speech(variant),
                                    fallback: installed.contains(variant.rawValue) ? .installed : .available),
                isRecommended: variant == .base
            )
        } + [
            Row(
                id: "diarization",
                kind: .diarization,
                title: "Konuşmacı Ayrıştırma",
                subtitle: "Transkriptte kimin konuştuğunu ayırır. Ses tanımadan bağımsız, isteğe bağlı.",
                iconName: "person.2.wave.2.fill",
                megabytes: OfflineModelManager.diarizationApproximateMegabytes,
                state: currentState(for: .diarization,
                                    fallback: diarizationInstalled ? .installed : .available),
                isRecommended: false
            ),
            Row(
                id: "neural-summarizer",
                kind: .neuralSummarizer,
                title: "Gelişmiş Özetleyici",
                subtitle: "Cihaz içi dil modeli. Kurmazsan özetler yine çıkar, sadece daha basit olur. Wi-Fi gerekir.",
                iconName: "brain.head.profile",
                megabytes: OfflineModelManager.NeuralModel.approximateMegabytes,
                state: currentState(for: .neuralSummarizer,
                                    fallback: OfflineModelManager.isNeuralSummarizerReady() ? .installed : .available),
                isRecommended: false
            )
        ]

        totalDiskBytes = await manager.diskUsageBytes()
            + manager.diarizationDiskUsageBytes()
            + neuralInstaller.diskUsageBytes()
    }

    /// Sürmekte olan indirmenin ilerlemesini koru, yoksa diskteki duruma dön.
    private func currentState(for kind: Kind, fallback: RowState) -> RowState {
        if let existing = rows.first(where: { $0.kind == kind })?.state,
           case .downloading = existing {
            return existing
        }
        return fallback
    }

    // MARK: Eylemler

    public func download(_ kind: Kind) {
        guard tasks[kind] == nil else { return }
        setState(.downloading(0), for: kind)

        tasks[kind] = Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case let .speech(variant):
                    try await self.manager.install(variant: variant) { fraction in
                        Task { @MainActor [weak self] in
                            self?.setState(.downloading(fraction), for: kind)
                        }
                    }
                case .diarization:
                    try await self.diarizer.install { fraction in
                        Task { @MainActor [weak self] in
                            self?.setState(.downloading(fraction), for: kind)
                        }
                    }
                case .neuralSummarizer:
                    try await self.neuralInstaller.install { fraction in
                        Task { @MainActor [weak self] in
                            self?.setState(.downloading(fraction), for: kind)
                        }
                    }
                }
                self.setState(.installed, for: kind)
            } catch {
                let reason = (error as? AuraError)?.errorDescription ?? error.localizedDescription
                self.setState(.failed(reason), for: kind)
                self.errorMessage = reason
            }
            self.tasks[kind] = nil
            await self.refresh()
        }
    }

    public func remove(_ kind: Kind) async {
        do {
            switch kind {
            case let .speech(variant): try await manager.remove(variant: variant)
            case .diarization:         try await manager.removeDiarization()
            case .neuralSummarizer:    try await neuralInstaller.remove()
            }
            await refresh()
        } catch {
            errorMessage = "Silinemedi: \(error.localizedDescription)"
        }
    }

    public func cancel(_ kind: Kind) {
        tasks[kind]?.cancel()
        tasks[kind] = nil
        setState(.available, for: kind)
    }

    private func setState(_ state: RowState, for kind: Kind) {
        guard let index = rows.firstIndex(where: { $0.kind == kind }) else { return }
        rows[index].state = state
    }

    // MARK: Metinler

    static func subtitle(for variant: WhisperKitEngine.Variant) -> String {
        switch variant {
        case .tiny:
            return "Eski cihazlar için. En düşük pil tüketimi."
        case .base:
            // Artık "önerilen" bu değil: Türkçe'de large sınıfıyla arasında
            // Whisper makalesinin ölçtüğü kadar büyük fark var.
            return "Küçük cihazlar için denge."
        case .small:
            return "Karmaşık terimler ve çok konuşmacılı kayıtlar için iyi."
        case .largeV3Turbo:
            return "Türkçe için önerilen. Şive, özel isim ve teknik terimde belirgin fark."
        }
    }

    static func icon(for variant: WhisperKitEngine.Variant) -> String {
        switch variant {
        case .tiny:         return "bolt.fill"
        case .base:         return "scalemass.fill"
        case .small:        return "diamond.fill"
        case .largeV3Turbo: return "sparkles"
        }
    }
}

// MARK: - Görünüm

public struct ModelDownloadView: View {

    @State private var viewModel = ModelDownloadViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AuraTheme.Spacing.stackLG) {
                    header
                    benefits
                    modelSection
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, AuraTheme.Spacing.screenMargin)
                .padding(.top, AuraTheme.Spacing.stackMD)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Cihaz İçi Modeller")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
        .alert(
            "İndirme sorunu",
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

    // MARK: Başlık

    private var header: some View {
        VStack(spacing: AuraTheme.Spacing.gutter) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("ZERO-CLOUD İŞLEME")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking + 0.6)
            }
            .foregroundStyle(AuraTheme.primary)
            .padding(.horizontal, AuraTheme.Spacing.gutter)
            .padding(.vertical, 6)
            .background { Capsule().fill(AuraTheme.primary.opacity(0.10)) }
            .overlay { Capsule().strokeBorder(AuraTheme.primary.opacity(0.20), lineWidth: 1) }

            Text("Güvenli yapay zekâ modelleri")
                .font(AuraFont.headlineMedium)
                .tracking(AuraFont.headlineMediumTracking)
                .foregroundStyle(AuraTheme.onSurface)
                .multilineTextAlignment(.center)

            Text("Offline modda sesin telefondan hiç çıkmaz. Bunun için modeli bir kez indirmen gerekiyor — sonrasında internet olmadan da çalışır.")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AuraTheme.Spacing.stackSM)
    }

    // MARK: Kazanımlar

    private var benefits: some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            benefit(icon: "airplane", title: "Uçak Modu", detail: "Bağlantı olmadan çalışır")
            benefit(icon: "lock.fill", title: "Sıfır Sızıntı", detail: "Ses cihazdan çıkmaz")
            benefit(icon: "cpu", title: "Neural Engine", detail: "Cihazda hızlı çıkarım")
        }
    }

    private func benefit(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AuraTheme.primary)
            Text(title)
                .font(AuraFont.labelCaps)
                .tracking(AuraFont.labelCapsTracking)
                .foregroundStyle(AuraTheme.onSurface)
            Text(detail)
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AuraTheme.Spacing.stackMD)
        .padding(.horizontal, AuraTheme.Spacing.stackSM)
        .glassSurface()
    }

    // MARK: Model listesi

    private var modelSection: some View {
        VStack(spacing: AuraTheme.Spacing.gutter) {
            HStack {
                AuraSectionTitle("Mevcut Modeller")
                Spacer(minLength: 0)
                if viewModel.totalDiskBytes > 0 {
                    Text(OfflineModelManager.formatted(bytes: viewModel.totalDiskBytes))
                        .font(AuraFont.labelCaps)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                }
            }

            ForEach(viewModel.rows) { row in
                modelCard(row)
            }
        }
    }

    private func modelCard(_ row: ModelDownloadViewModel.Row) -> some View {
        let isActive = row.state == .installed || row.isDownloading
        let tint: Color = isActive ? AuraTheme.primary : AuraTheme.onSurfaceVariant

        return VStack(spacing: AuraTheme.Spacing.gutter) {
            HStack(spacing: AuraTheme.Spacing.gutter) {
                ZStack {
                    Circle()
                        .fill(isActive ? AuraTheme.primary.opacity(0.10) : AuraTheme.surfaceContainerHigh)
                    Circle()
                        .strokeBorder(isActive ? AuraTheme.primary.opacity(0.30) : AuraTheme.hairline, lineWidth: 1)
                    Image(systemName: row.iconName)
                        .font(.system(size: 16))
                        .foregroundStyle(tint)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(AuraFont.bodyLarge.weight(.semibold))
                            .foregroundStyle(isActive ? AuraTheme.primary : AuraTheme.onSurface)
                        if row.isRecommended && row.state == .available {
                            Text("ÖNERİLEN")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(AuraTheme.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(AuraTheme.primary.opacity(0.12)) }
                        }
                    }
                    Text(row.subtitle)
                        .font(AuraFont.bodySmall)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AuraTheme.Spacing.stackSM)

                VStack(alignment: .trailing, spacing: 6) {
                    Text("~\(row.megabytes) MB")
                        .font(AuraFont.digitMono)
                        .foregroundStyle(isActive ? AuraTheme.primary : AuraTheme.onSurfaceVariant)
                    actionControl(row)
                }
            }

            if case let .downloading(fraction) = row.state {
                progressBar(fraction)
            }
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(
            borderColor: isActive ? AuraTheme.primary.opacity(0.35) : AuraTheme.hairline
        )
    }

    @ViewBuilder
    private func actionControl(_ row: ModelDownloadViewModel.Row) -> some View {
        switch row.state {
        case .available, .failed:
            Button("İndir") { viewModel.download(row.kind) }
                .font(AuraFont.labelCaps)
                .foregroundStyle(AuraTheme.onSurface)
                .padding(.horizontal, AuraTheme.Spacing.gutter)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .fill(AuraTheme.surfaceContainerHigh)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .strokeBorder(AuraTheme.hairline, lineWidth: 1)
                }
                .buttonStyle(.plain)

        case .downloading:
            Button {
                viewModel.cancel(row.kind)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .background { Circle().fill(AuraTheme.surfaceContainerHigh) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("İndirmeyi iptal et")

        case .installed:
            Menu {
                Button(role: .destructive) {
                    Task { await viewModel.remove(row.kind) }
                } label: {
                    Label("Modeli sil", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("KURULU")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                }
                .foregroundStyle(AuraTheme.primary)
                .padding(.horizontal, AuraTheme.Spacing.gutter)
                .padding(.vertical, 6)
                .background { Capsule().fill(AuraTheme.primary.opacity(0.10)) }
                .overlay { Capsule().strokeBorder(AuraTheme.primary.opacity(0.20), lineWidth: 1) }
            }
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("İndiriliyor…")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
                    .foregroundStyle(AuraTheme.primary)
                Spacer()
                Text("%\(Int((fraction * 100).rounded()))")
                    .font(AuraFont.digitMono)
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AuraTheme.surfaceContainerHigh)
                    Capsule()
                        .fill(AuraTheme.primaryContainer)
                        .frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
                        .auraGlow(AuraTheme.primaryContainer, radius: 8, opacity: 0.4)
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.25), value: fraction)
        }
    }
}

private extension ModelDownloadViewModel.Row {
    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }
}

#Preview {
    NavigationStack {
        ModelDownloadView()
    }
    .preferredColorScheme(.dark)
}
