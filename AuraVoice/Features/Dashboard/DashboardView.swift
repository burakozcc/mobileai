//
//  DashboardView.swift
//  AuraVoice
//
//  Ana ekran: kalan dakika sayacı, Online/Offline geçişi, takvim tetikleyicileri
//  ve son kayıtlar.
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
            ZStack(alignment: .bottom) {
                AuraTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        quotaCard
                        modeSwitcher

                        if viewModel.isCallActive {
                            callBanner
                        }

                        meetingsSection
                        notesSection

                        // Yüzen kayıt butonunun altında kalan boşluk.
                        Color.clear.frame(height: 190)
                    }
                    .padding(.horizontal, AuraTheme.screenPadding)
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
                .refreshable { await viewModel.refresh() }

                recordDock
            }
            .navigationTitle("AuraVoice")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isPaywallPresented = true
                    } label: {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(AuraTheme.warning)
                    }
                    .accessibilityLabel("Aboneliği yönet")
                }
            }
        }
        .tint(accent)
        .auraBackground()
        .task { await viewModel.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            // Bildirimden dönüşte ve arka plandan gelişte kotayı/toplantıları tazele.
            if phase == .active { Task { await viewModel.refresh() } }
        }
        .sheet(item: $viewModel.recordingIntent) { intent in
            RecordingView(intent: intent) { note in
                Task { await viewModel.recordingFinished(with: note) }
            }
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $viewModel.isPaywallPresented) {
            PaywallPlaceholderView(remainingMinutes: viewModel.remainingMinutes)
                .presentationDetents([.medium, .large])
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

    // MARK: - Kota Kartı

    private var quotaCard: some View {
        GlassCardView(padding: 20, borderTint: accent, isHighlighted: viewModel.isQuotaCritical) {
            HStack(spacing: 20) {
                QuotaRing(
                    fraction: viewModel.quotaFraction,
                    tint: viewModel.isQuotaCritical ? AuraTheme.warning : accent
                )
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kalan Dakika")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AuraTheme.textSecondary)

                    Text(AuraFormat.minutes(viewModel.remainingMinutes))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: viewModel.remainingMinutes)

                    Text("Bu ay \(AuraFormat.minutes(viewModel.minutesUsedThisMonth)) kaydettin")
                        .font(.system(size: 12))
                        .foregroundStyle(AuraTheme.textSecondary)

                    if viewModel.isQuotaCritical {
                        Button {
                            viewModel.isPaywallPresented = true
                        } label: {
                            Text("Dakika ekle")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(AuraTheme.warning.opacity(0.18)))
                                .foregroundStyle(AuraTheme.warning)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Mod Geçişi

    private var modeSwitcher: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(ProcessingMode.allCases) { candidate in
                    ModeTile(
                        mode: candidate,
                        isSelected: viewModel.mode == candidate,
                        isAvailable: candidate == .onlineCloudFast || viewModel.isOfflineModelReady
                    ) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            viewModel.select(mode: candidate)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: viewModel.mode.systemImage)
                    .font(.system(size: 11, weight: .bold))
                Text(viewModel.mode.privacyStatement)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent.opacity(0.9))
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Görüşme Banner'ı

    private var callBanner: some View {
        GlassCardView(padding: 14, borderTint: AuraTheme.recordRed, isHighlighted: true) {
            HStack(spacing: 12) {
                Image(systemName: "phone.connected.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AuraTheme.recordRed)
                    .symbolEffect(.pulse)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Görüşme sürüyor")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                    Text("Hoparlörü açarak kaydı başlatabilirsiniz.")
                        .font(.system(size: 12))
                        .foregroundStyle(AuraTheme.textSecondary)
                }
                Spacer(minLength: 0)

                Button("Kaydet") { viewModel.startCallRecording() }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.recordRed)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Toplantılar

    @ViewBuilder
    private var meetingsSection: some View {
        VStack(spacing: 10) {
            AuraSectionHeader(
                "Yaklaşan Toplantılar",
                actionTitle: viewModel.scheduledReminderCount > 0
                    ? "\(viewModel.scheduledReminderCount) hatırlatma"
                    : nil
            ) {}

            if viewModel.calendarStatus != .fullAccess || viewModel.notificationStatus != .authorized {
                permissionCard
            } else if viewModel.upcomingMeetings.isEmpty {
                GlassCardView {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundStyle(accent)
                        Text("Önümüzdeki 12 saatte toplantı görünmüyor.")
                            .font(.system(size: 13))
                            .foregroundStyle(AuraTheme.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ForEach(viewModel.upcomingMeetings.prefix(3)) { meeting in
                    MeetingRow(meeting: meeting, accent: accent) {
                        viewModel.startRecording(for: meeting)
                    }
                }
            }
        }
    }

    private var permissionCard: some View {
        GlassCardView(borderTint: accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(accent)
                    Text("Toplantı algılamayı aç")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                }

                Text("Takvimin cihazda taranır, hiçbir etkinlik dışarı çıkmaz. Toplantı başlamadan 2 dakika önce tek dokunuşla kaydı başlatabileceğin bir bildirim gönderilir.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await viewModel.enableMeetingTriggers() }
                } label: {
                    Text("Takvim & Bildirim İzni Ver")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: AuraTheme.controlRadius, style: .continuous)
                                .fill(accent.opacity(0.18))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AuraTheme.controlRadius, style: .continuous)
                                .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                        }
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Notlar

    @ViewBuilder
    private var notesSection: some View {
        VStack(spacing: 10) {
            AuraSectionHeader("Son Kayıtlar")

            if viewModel.notes.isEmpty {
                GlassCardView(padding: 22) {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 26))
                            .foregroundStyle(accent.opacity(0.8))
                        Text("Henüz kayıt yok")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AuraTheme.textPrimary)
                        Text("Aşağıdaki butona basarak ilk toplantını kaydet.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AuraTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(viewModel.notes) { note in
                    NavigationLink {
                        NoteDetailView(note: note)
                    } label: {
                        NoteCard(note: note)
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

    // MARK: - Kayıt Dock'u

    private var recordDock: some View {
        VStack(spacing: 8) {
            PulseRecordButton(
                state: viewModel.isQuotaEmpty ? .disabled : .idle,
                tint: accent,
                diameter: 74
            ) {
                viewModel.startManualRecording()
            }

            Text(viewModel.isQuotaEmpty ? "Dakika bakiyen bitti" : "Kaydı başlat")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewModel.isQuotaEmpty ? AuraTheme.warning : AuraTheme.textSecondary)
        }
        .padding(.bottom, 10)
        .background {
            LinearGradient(
                colors: [AuraTheme.background.opacity(0), AuraTheme.background.opacity(0.92), AuraTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Kota Halkası

private struct QuotaRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 9)

            Circle()
                .trim(from: 0, to: max(0.005, fraction))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .auraGlow(tint, radius: 12, opacity: 0.5)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)

            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(AuraTheme.textPrimary)
        }
        .accessibilityElement()
        .accessibilityLabel("Kalan kota yüzdesi")
        .accessibilityValue("\(Int((fraction * 100).rounded())) yüzde")
    }
}

// MARK: - Mod Kartı

private struct ModeTile: View {
    let mode: ProcessingMode
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    private var tint: Color { AuraTheme.accent(for: mode) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isSelected ? tint : AuraTheme.textSecondary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(tint)
                            .transition(.scale.combined(with: .opacity))
                    } else if !isAvailable {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(AuraTheme.warning)
                    }
                }

                Text(mode.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(AuraTheme.textPrimary)

                Text(isAvailable ? mode.subtitle : "Model indirilmeli")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.12) : AuraTheme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.6) : AuraTheme.hairline, lineWidth: isSelected ? 1.4 : 1)
            }
            .shadow(color: isSelected ? tint.opacity(0.22) : .clear, radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityLabel("\(mode.title) modu")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Toplantı Satırı

private struct MeetingRow: View {
    let meeting: MeetingCandidate
    let accent: Color
    let action: () -> Void

    var body: some View {
        GlassCardView(padding: 14, borderTint: meeting.isOngoing ? AuraTheme.recordRed : nil, isHighlighted: meeting.isOngoing) {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(meeting.startDate, format: .dateTime.hour().minute())
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AuraTheme.textPrimary)
                    Text("\(meeting.durationMinutes)dk")
                        .font(.system(size: 10))
                        .foregroundStyle(AuraTheme.textSecondary)
                }
                .frame(width: 48)

                Rectangle()
                    .fill(AuraTheme.hairline)
                    .frame(width: 1, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if meeting.isOngoing {
                            AuraBadge("Devam ediyor", systemImage: "dot.radiowaves.left.and.right", tint: AuraTheme.recordRed)
                        } else if meeting.isImminent {
                            AuraBadge("Birazdan", systemImage: "clock.fill", tint: AuraTheme.warning)
                        }
                        if meeting.isVirtual {
                            AuraBadge("Video", systemImage: "video.fill", tint: accent)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(action: action) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(AuraTheme.recordRed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(meeting.title) için kaydı başlat")
            }
        }
    }
}

// MARK: - Not Kartı

private struct NoteCard: View {
    let note: NoteSummary

    private var tint: Color { AuraTheme.accent(for: note.mode) }

    var body: some View {
        GlassCardView(padding: 15) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(note.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    AuraBadge(
                        note.mode == .offlineZeroCloud ? "Zero-Cloud" : "Bulut",
                        systemImage: note.mode.systemImage,
                        tint: tint
                    )
                }

                Text(note.previewLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    if !note.waveformPreview.isEmpty {
                        WaveformThumbnail(levels: note.waveformPreview, tint: tint)
                            .frame(height: 20)
                            .frame(maxWidth: 110)
                    }
                    Spacer(minLength: 0)
                    Label(AuraFormat.clock(note.durationSeconds), systemImage: "clock")
                    Text(note.createdAt, format: .relative(presentation: .named))
                }
                .font(.system(size: 11))
                .foregroundStyle(AuraTheme.textSecondary)
            }
        }
    }
}

// MARK: - Geçici Paywall

/// `SubscriptionPaywallView` (RevenueCat) devreye girene kadarki yer tutucu.
private struct PaywallPlaceholderView: View {
    let remainingMinutes: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(AuraTheme.warning)
                Text("AuraVoice Pro")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(AuraTheme.textPrimary)
                Text("Kalan: \(AuraFormat.minutes(remainingMinutes))\nRevenueCat entegrasyonu bir sonraki adımda bağlanacak.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AuraTheme.textSecondary)
                Button("Kapat") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigo)
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    DashboardView()
}
