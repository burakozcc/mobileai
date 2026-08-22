//
//  OnboardingView.swift
//  AuraVoice
//
//  İlk açılış akışı — mockup'taki üç adımlı karusel.
//
//  İZİN STRATEJİSİ: İzinler teker teker ve GEREKÇESİYLE isteniyor. Hepsini
//  bir anda istemek reddedilme oranını yükseltir ve iOS'ta reddedilen izni
//  uygulama içinden tekrar isteyemezsin — kullanıcıyı Ayarlar'a göndermek
//  zorunda kalırsın. Bu yüzden her izin, ne işe yaradığı anlatıldıktan
//  sonra isteniyor.
//
//  Mikrofon zorunlu (onsuz ürün yok), takvim ve bildirim isteğe bağlı —
//  atlanabilir olmaları bilinçli.
//

import SwiftUI
import AVFoundation

// MARK: - ViewModel

@MainActor
@Observable
public final class OnboardingViewModel {

    public enum Step: Int, CaseIterable {
        case promise
        case microphone
        case optionalPermissions

        var isLast: Bool { self == .optionalPermissions }
    }

    public private(set) var step: Step = .promise
    public private(set) var isMicrophoneGranted = false
    public private(set) var isCalendarGranted = false
    public private(set) var areNotificationsGranted = false
    public private(set) var isRequesting = false
    public var errorMessage: String?

    public static let completedKey = "aura.onboarding.completed"

    public init() {}

    public var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    public var primaryButtonTitle: String {
        switch step {
        case .promise:             return "Başlayalım"
        case .microphone:          return isMicrophoneGranted ? "Devam" : "Mikrofona İzin Ver"
        case .optionalPermissions: return "Kuruluma Bitir"
        }
    }

    /// Mikrofon adımında izin verilmeden ileri gidilemez.
    public var canAdvance: Bool {
        step != .microphone || isMicrophoneGranted
    }

    public func refreshPermissionStates() async {
        isMicrophoneGranted = AVAudioApplication.shared.recordPermission == .granted
        isCalendarGranted = CalendarTriggerService.shared.hasAccess
        areNotificationsGranted = await NotificationManager.shared.authorizationStatus() == .authorized
    }

    // MARK: Adım geçişleri

    /// Ana butonun davranışı adıma göre değişir.
    public func advance() async -> Bool {
        switch step {
        case .promise:
            step = .microphone
            return false

        case .microphone:
            if isMicrophoneGranted {
                step = .optionalPermissions
                return false
            }
            await requestMicrophone()
            // İzin verildiyse otomatik ilerle; reddedildiyse kullanıcı ekranda kalsın.
            if isMicrophoneGranted { step = .optionalPermissions }
            return false

        case .optionalPermissions:
            complete()
            return true
        }
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: İzinler

    public func requestMicrophone() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        let granted = await AudioRecorderService.requestMicrophonePermission()
        isMicrophoneGranted = granted
        if !granted {
            errorMessage = "Mikrofon izni olmadan kayıt alınamaz. Ayarlar › AuraVoice üzerinden açabilirsin."
        }
    }

    public func requestCalendar() async {
        guard !isCalendarGranted, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        isCalendarGranted = await CalendarTriggerService.shared.requestAccess()
    }

    public func requestNotifications() async {
        guard !areNotificationsGranted, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        areNotificationsGranted = await NotificationManager.shared.requestAuthorization()
    }

    public func complete() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }

    public nonisolated static func isCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }
}

// MARK: - Görünüm

public struct OnboardingView: View {

    @State private var viewModel = OnboardingViewModel()
    @State private var isSpinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()
            ambientGlow

            VStack(spacing: 0) {
                Text("AuraVoice")
                    .font(AuraFont.displayLarge)
                    .tracking(AuraFont.displayLargeTracking)
                    .foregroundStyle(AuraTheme.primary)
                    .padding(.top, AuraTheme.Spacing.stackMD)

                Spacer(minLength: AuraTheme.Spacing.stackLG)

                content
                    .frame(maxWidth: 420)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(viewModel.step)

                Spacer(minLength: AuraTheme.Spacing.stackLG)

                footer
            }
            .padding(.horizontal, AuraTheme.Spacing.screenMargin)
            .padding(.bottom, AuraTheme.Spacing.stackLG)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.step)
        .task {
            await viewModel.refreshPermissionStates()
            if !reduceMotion { isSpinning = true }
        }
        .alert(
            "İzin gerekli",
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

    // MARK: Arka plan

    private var ambientGlow: some View {
        ZStack {
            Circle()
                .fill(AuraTheme.primary.opacity(0.05))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -120, y: -260)
            Circle()
                .fill(AuraTheme.secondary.opacity(0.05))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 130, y: 300)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Adımlar

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .promise:             promiseStep
        case .microphone:          microphoneStep
        case .optionalPermissions: optionalStep
        }
    }

    private var promiseStep: some View {
        VStack(spacing: AuraTheme.Spacing.stackLG) {
            ZStack {
                Circle()
                    .strokeBorder(AuraTheme.primary.opacity(0.20), lineWidth: 1)
                    .frame(width: 192, height: 192)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 18).repeatForever(autoreverses: false),
                        value: isSpinning
                    )

                Circle()
                    .strokeBorder(AuraTheme.primary.opacity(0.10), lineWidth: 1)
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(isSpinning ? -360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 24).repeatForever(autoreverses: false),
                        value: isSpinning
                    )

                Circle()
                    .fill(AuraTheme.surfaceContainerLow)
                    .overlay(Circle().fill(AuraTheme.glassGradient))
                    .frame(width: 128, height: 128)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(AuraTheme.primary)
                    .auraGlow(AuraTheme.primary, radius: 24, opacity: 0.25)
            }
            .accessibilityHidden(true)

            VStack(spacing: AuraTheme.Spacing.gutter) {
                Text("Sesin telefonunda kalır")
                    .font(AuraFont.headlineMedium)
                    .tracking(AuraFont.headlineMediumTracking)
                    .foregroundStyle(AuraTheme.onSurface)

                Text("Offline modda transkripsiyon ve özetleme tamamen cihazında yapılır. Ses ve metin hiçbir sunucuya gitmez — uçak modunda bile çalışır.")
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: AuraTheme.Spacing.stackLG) {
            iconTile(systemName: "mic.fill", isActive: viewModel.isMicrophoneGranted)

            VStack(spacing: AuraTheme.Spacing.gutter) {
                Text("Mikrofon izni")
                    .font(AuraFont.headlineMedium)
                    .tracking(AuraFont.headlineMediumTracking)
                    .foregroundStyle(AuraTheme.onSurface)

                Text("Toplantılarını kaydedip metne dökebilmek için gerekli. Uygulama arka planda dinlemez — kayıt yalnızca sen başlattığında çalışır.")
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionCard(
                icon: "mic.fill",
                title: "Mikrofon",
                subtitle: "Zorunlu",
                isGranted: viewModel.isMicrophoneGranted
            ) {
                await viewModel.requestMicrophone()
            }
        }
    }

    private var optionalStep: some View {
        VStack(spacing: AuraTheme.Spacing.stackLG) {
            HStack(spacing: AuraTheme.Spacing.gutter) {
                iconTile(systemName: "calendar", isActive: viewModel.isCalendarGranted, size: 96)
                iconTile(systemName: "bell.fill", isActive: viewModel.areNotificationsGranted, size: 96)
            }

            VStack(spacing: AuraTheme.Spacing.gutter) {
                Text("Toplantıları yakalayalım mı?")
                    .font(AuraFont.headlineMedium)
                    .tracking(AuraFont.headlineMediumTracking)
                    .foregroundStyle(AuraTheme.onSurface)
                    .multilineTextAlignment(.center)

                Text("Takvimin cihazda taranır ve toplantı başlamadan önce tek dokunuşla kayda başlayabileceğin bir bildirim gelir. Etkinlik verisi hiçbir yere gönderilmez.")
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AuraTheme.Spacing.stackSM) {
                permissionCard(
                    icon: "calendar",
                    title: "Takvim",
                    subtitle: "İsteğe bağlı",
                    isGranted: viewModel.isCalendarGranted
                ) {
                    await viewModel.requestCalendar()
                }

                permissionCard(
                    icon: "bell.fill",
                    title: "Bildirimler",
                    subtitle: "İsteğe bağlı",
                    isGranted: viewModel.areNotificationsGranted
                ) {
                    await viewModel.requestNotifications()
                }
            }
        }
    }

    // MARK: Yapı taşları

    private func iconTile(systemName: String, isActive: Bool, size: CGFloat = 128) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(AuraTheme.surfaceContainerLow)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(AuraTheme.glassGradient)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(
                            isActive ? AuraTheme.primary.opacity(0.35) : AuraTheme.hairline,
                            lineWidth: 1
                        )
                }

            Image(systemName: systemName)
                .font(.system(size: size * 0.36))
                .foregroundStyle(isActive ? AuraTheme.primary : AuraTheme.onSurface)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func permissionCard(
        icon: String,
        title: String,
        subtitle: String,
        isGranted: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            ZStack {
                Circle().fill(AuraTheme.surfaceContainerHigh)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(isGranted ? AuraTheme.primary : AuraTheme.onSurfaceVariant)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AuraFont.bodyLarge.weight(.semibold))
                    .foregroundStyle(AuraTheme.onSurface)
                Text(subtitle)
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
            }

            Spacer(minLength: AuraTheme.Spacing.stackSM)

            if isGranted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("VERİLDİ")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                }
                .foregroundStyle(AuraTheme.primary)
                .padding(.horizontal, AuraTheme.Spacing.gutter)
                .padding(.vertical, 7)
                .background { Capsule().fill(AuraTheme.primary.opacity(0.10)) }
            } else {
                Button {
                    Task { await action() }
                } label: {
                    Text("İzin Ver")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(AuraTheme.onPrimaryFixed)
                        .padding(.horizontal, AuraTheme.Spacing.stackMD)
                        .padding(.vertical, 9)
                        .background { Capsule().fill(AuraTheme.primaryContainer) }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRequesting)
            }
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface()
    }

    // MARK: Alt bölüm

    private var footer: some View {
        VStack(spacing: AuraTheme.Spacing.stackMD) {
            HStack(spacing: 6) {
                ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step == viewModel.step ? AuraTheme.primary : AuraTheme.surfaceVariant)
                        .frame(width: step == viewModel.step ? 32 : 8, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.step)
                }
            }
            .accessibilityHidden(true)

            Button {
                Task {
                    if await viewModel.advance() { onFinished() }
                }
            } label: {
                Text(viewModel.primaryButtonTitle)
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
                    .foregroundStyle(AuraTheme.onPrimaryFixed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AuraTheme.Spacing.stackMD)
                    .background {
                        RoundedRectangle(cornerRadius: AuraTheme.Radius.extraLarge, style: .continuous)
                            .fill(AuraTheme.primaryContainer)
                    }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRequesting)
            .opacity(viewModel.isRequesting ? 0.6 : 1)

            // Son adımda izinler atlanabilir — isteğe bağlı olmaları gerçek olsun.
            if viewModel.step.isLast {
                Button("Şimdilik atla") {
                    viewModel.complete()
                    onFinished()
                }
                .font(AuraFont.labelCaps)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
            }
        }
    }
}

#Preview {
    OnboardingView {}
}
