//
//  DashboardView.swift
//  AuraVoice
//
//  Panel — mockup'taki düzen: sabit üst bar, kota halkası, mod seçici,
//  yaklaşan toplantılar, son kayıtlar ve sağ altta yüzen kayıt butonu.
//

import SwiftUI
import EventKit

public struct DashboardView: View {

    @State private var viewModel = DashboardViewModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    private var accent: Color { AuraTheme.accent(for: viewModel.mode) }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                AuraTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar

                    ScrollView {
                        VStack(spacing: AuraTheme.Spacing.stackLG) {
                            quotaRing
                            modeSelector

                            if viewModel.isCallActive {
                                callBanner
                            }

                            meetingsSection
                            notesSection

                            // Sekme çubuğu + yüzen buton payı.
                            Color.clear.frame(height: 140)
                        }
                        .padding(.horizontal, AuraTheme.Spacing.screenMargin)
                        .padding(.top, AuraTheme.Spacing.stackMD)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await viewModel.refresh() }
                }

                recordButton
                    .padding(.trailing, AuraTheme.Spacing.screenMargin)
                    .padding(.bottom, 108)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(accent)
        .task { await viewModel.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            // Bildirimden dönüşte ve arka plandan gelişte kotayı/toplantıları tazele.
            if phase == .active { Task { await viewModel.refresh() } }
        }
        .sheet(item: $viewModel.recordingIntent) { intent in
            RecordingView(intent: intent) { outcome in
                Task { await viewModel.recordingFinished(with: outcome) }
            }
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
        .fullScreenCover(isPresented: $viewModel.isPaywallPresented) {
            SubscriptionPaywallView(
                remainingMinutes: viewModel.remainingMinutes,
                usedMinutes: viewModel.minutesUsedThisMonth
            ) {
                // "Zero-Cloud modunda devam et" — sadece kapatmakla kalmıyor,
                // kullanıcıyı gerçekten kotasız çalışan moda alıyor.
                viewModel.select(mode: .offlineZeroCloud)
            }
        }
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

    // MARK: - Üst bar

    private var topBar: some View {
        HStack {
            circleButton(icon: viewModel.mode == .offlineZeroCloud ? "lock.fill" : "cloud.fill", tint: accent) {}
                .allowsHitTesting(false)

            Spacer()

            Text("AuraVoice")
                .font(AuraFont.displayLarge)
                .tracking(AuraFont.displayLargeTracking)
                .foregroundStyle(AuraTheme.primary)

            Spacer()

            circleButton(icon: "crown.fill", tint: AuraTheme.warning) {
                viewModel.isPaywallPresented = true
            }
            .accessibilityLabel("Aboneliği yönet")
        }
        .padding(.horizontal, AuraTheme.Spacing.screenMargin)
        .padding(.vertical, AuraTheme.Spacing.gutter)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(AuraTheme.background.opacity(0.75))
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuraTheme.hairline).frame(height: 1)
        }
    }

    private func circleButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .glassSurface(cornerRadius: 19)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Kota halkası

    private var quotaRing: some View {
        VStack(spacing: AuraTheme.Spacing.stackMD) {
            ZStack {
                Circle()
                    .stroke(AuraTheme.surfaceVariant, lineWidth: 2)

                Circle()
                    .trim(from: 0, to: max(0.004, viewModel.quotaFraction))
                    .stroke(
                        viewModel.isQuotaCritical ? AuraTheme.warning : AuraTheme.primaryContainer,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .auraGlow(
                        viewModel.isQuotaCritical ? AuraTheme.warning : AuraTheme.primaryContainer,
                        radius: 14, opacity: 0.35
                    )
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: viewModel.quotaFraction)

                VStack(spacing: 2) {
                    Text("\(Int(viewModel.remainingMinutes.rounded()))")
                        .font(AuraFont.durationDisplay)
                        .tracking(AuraFont.durationTracking)
                        .monospacedDigit()
                        .foregroundStyle(AuraTheme.onSurface)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: viewModel.remainingMinutes)

                    Text("/ \(Int(viewModel.planMonthlyMinutes)) DK")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking + 0.8)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                }
            }
            .frame(width: 192, height: 192)
            .padding(.top, AuraTheme.Spacing.stackSM)
            .accessibilityElement()
            .accessibilityLabel("Kalan dakika")
            .accessibilityValue("\(Int(viewModel.remainingMinutes.rounded())) / \(Int(viewModel.planMonthlyMinutes))")

            quotaPill
        }
    }

    private var quotaPill: some View {
        let tint: Color = viewModel.isQuotaEmpty ? AuraTheme.warning
                        : viewModel.isQuotaCritical ? AuraTheme.warning
                        : AuraTheme.primary
        let text: String = viewModel.isQuotaEmpty ? "KOTA BİTTİ"
                         : viewModel.isQuotaCritical ? "KOTA AZALDI"
                         : "KOTA NORMAL"

        return Button {
            if viewModel.isQuotaCritical { viewModel.isPaywallPresented = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.isQuotaCritical ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(text)
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, AuraTheme.Spacing.gutter)
            .padding(.vertical, 6)
            .background { Capsule().fill(tint.opacity(0.10)) }
            .overlay { Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isQuotaCritical)
    }

    // MARK: - Mod seçici

    private var modeSelector: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            HStack(spacing: AuraTheme.Spacing.gutter) {
                ForEach(ProcessingMode.allCases) { mode in
                    modeCard(mode)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: viewModel.mode.systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(viewModel.mode.privacyStatement)
                    .font(AuraFont.bodySmall)
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent.opacity(0.85))
            .padding(.horizontal, 4)
        }
    }

    private func modeCard(_ mode: ProcessingMode) -> some View {
        let isSelected = viewModel.mode == mode
        let tint = AuraTheme.accent(for: mode)
        let isReady = mode == .onlineCloudFast || viewModel.isOfflineModelReady

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                viewModel.select(mode: mode)
            }
        } label: {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackSM) {
                HStack {
                    Text(mode.title)
                        .font(AuraFont.headlineMedium)
                        .tracking(AuraFont.headlineMediumTracking)
                        .foregroundStyle(isSelected ? tint : AuraTheme.onSurface)
                    Spacer(minLength: 4)
                    Image(systemName: mode == .offlineZeroCloud ? "icloud.slash.fill" : "icloud.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? tint : AuraTheme.onSurfaceVariant.opacity(0.6))
                }

                Text(mode == .offlineZeroCloud
                     ? "Veri telefondan çıkmaz"
                     : "Daha hızlı işleme")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                statusChip(mode: mode, isReady: isReady, tint: tint)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .padding(AuraTheme.Spacing.stackMD)
            .glassSurface(borderColor: isSelected ? tint.opacity(0.30) : AuraTheme.hairline)
            .auraGlow(isSelected ? tint : .clear, radius: 20, opacity: isSelected ? 0.15 : 0)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityLabel("\(mode.title) modu")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func statusChip(mode: ProcessingMode, isReady: Bool, tint: Color) -> some View {
        if mode == .offlineZeroCloud {
            HStack(spacing: 5) {
                Circle()
                    .fill(isReady ? tint : AuraTheme.warning)
                    .frame(width: 6, height: 6)
                Text(isReady ? "Kurulu" : "Model gerekli")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
            }
            .foregroundStyle(isReady ? tint : AuraTheme.warning)
            .padding(.horizontal, AuraTheme.Spacing.stackSM)
            .padding(.vertical, 4)
            .background { Capsule().fill((isReady ? tint : AuraTheme.warning).opacity(0.10)) }
            .overlay { Capsule().strokeBorder((isReady ? tint : AuraTheme.warning).opacity(0.20), lineWidth: 1) }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    // MARK: - Görüşme banner'ı

    private var callBanner: some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: "phone.connected.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AuraTheme.error)
                .symbolEffect(.pulse)

            VStack(alignment: .leading, spacing: 2) {
                Text("Görüşme sürüyor")
                    .font(AuraFont.bodyLarge.weight(.semibold))
                    .foregroundStyle(AuraTheme.onSurface)
                Text("Hoparlörü açarak kaydı başlatabilirsin.")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
            }

            Spacer(minLength: 0)

            Button {
                viewModel.startCallRecording()
            } label: {
                Text("KAYDET")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
                    .foregroundStyle(AuraTheme.onError)
                    .padding(.horizontal, AuraTheme.Spacing.stackMD)
                    .padding(.vertical, 9)
                    .background { Capsule().fill(AuraTheme.error) }
            }
            .buttonStyle(.plain)
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(borderColor: AuraTheme.error.opacity(0.35))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Toplantılar

    @ViewBuilder
    private var meetingsSection: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            AuraSectionTitle(
                "Yaklaşan Toplantılar",
                actionTitle: viewModel.scheduledReminderCount > 0
                    ? "\(viewModel.scheduledReminderCount) hatırlatma" : nil
            ) {}

            if viewModel.calendarStatus != .fullAccess || viewModel.notificationStatus != .authorized {
                permissionCard
            } else if viewModel.upcomingMeetings.isEmpty {
                infoCard(icon: "calendar", text: "Önümüzdeki 12 saatte toplantı görünmüyor.")
            } else {
                ForEach(viewModel.upcomingMeetings.prefix(3)) { meeting in
                    meetingRow(meeting)
                }
            }
        }
    }

    private func meetingRow(_ meeting: MeetingCandidate) -> some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            // Tarih kutusu — mockup'taki gün/ay bloğu.
            VStack(spacing: 0) {
                Text(meeting.startDate, format: .dateTime.day())
                    .font(AuraFont.digitMono)
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.onSurface)
                Text(meeting.startDate.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
            }
            .frame(width: 48, height: 48)
            .background {
                RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                    .fill(AuraTheme.surfaceContainer)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                    .strokeBorder(AuraTheme.hairline, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(AuraFont.bodyLarge.weight(.semibold))
                    .foregroundStyle(AuraTheme.onSurface)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text(AuraFormat.meetingSubtitle(
                        start: meeting.startDate,
                        durationMinutes: meeting.durationMinutes
                    ))
                    if meeting.isOngoing {
                        Text("· DEVAM EDİYOR")
                            .foregroundStyle(AuraTheme.error)
                    } else if meeting.isImminent {
                        Text("· BİRAZDAN")
                            .foregroundStyle(AuraTheme.warning)
                    }
                }
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
            }

            Spacer(minLength: 0)

            Button {
                viewModel.startRecording(for: meeting)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(AuraTheme.onPrimaryFixed)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(AuraTheme.primaryContainer) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(meeting.title) için kaydı başlat")
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(borderColor: meeting.isOngoing ? AuraTheme.error.opacity(0.30) : AuraTheme.hairline)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.gutter) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(accent)
                Text("Toplantı algılamayı aç")
                    .font(AuraFont.bodyLarge.weight(.semibold))
                    .foregroundStyle(AuraTheme.onSurface)
            }

            Text("Takvimin cihazda taranır, hiçbir etkinlik dışarı çıkmaz. Toplantı başlamadan önce tek dokunuşla kayda başlayabilirsin.")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await viewModel.enableMeetingTriggers() }
            } label: {
                Text("İZİN VER")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
                    .foregroundStyle(AuraTheme.onPrimaryFixed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AuraTheme.Spacing.gutter)
                    .background {
                        RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                            .fill(AuraTheme.primaryContainer)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(borderColor: accent.opacity(0.25))
    }

    // MARK: - Notlar

    @ViewBuilder
    private var notesSection: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            AuraSectionTitle("Son Kayıtlar")

            if viewModel.notes.isEmpty {
                infoCard(icon: "waveform.badge.mic", text: "Henüz kayıt yok. Sağ alttaki butonla başla.")
            } else {
                ForEach(viewModel.notes.prefix(4)) { note in
                    NavigationLink {
                        NoteDetailView(note: note)
                    } label: {
                        AuraNoteCard(note: note)
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

    private func infoCard(icon: String, text: String) -> some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(accent.opacity(0.8))
            Text(text)
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface()
    }

    // MARK: - Kayıt butonu

    private var recordButton: some View {
        Button {
            viewModel.startManualRecording()
        } label: {
            Image(systemName: viewModel.isQuotaEmpty ? "lock.fill" : "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(viewModel.isQuotaEmpty ? AuraTheme.onSurfaceVariant : AuraTheme.onPrimaryFixed)
                .frame(width: 64, height: 64)
                .background {
                    Circle().fill(
                        viewModel.isQuotaEmpty ? AuraTheme.surfaceContainerHigh : AuraTheme.primaryContainer
                    )
                }
                .auraGlow(viewModel.isQuotaEmpty ? .clear : AuraTheme.primaryContainer, radius: 22, opacity: 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isQuotaEmpty ? "Dakika bakiyen bitti" : "Kaydı başlat")
    }
}

#Preview {
    DashboardView()
}
