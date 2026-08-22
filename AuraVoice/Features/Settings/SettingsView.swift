//
//  SettingsView.swift
//  AuraVoice
//
//  Ayarlar sekmesi — mockup'taki bölüm düzeni: Hesap, Sistem Durumu,
//  İzinler, Hakkında.
//
//  Model indirme ekranı ayrı bir görünüm (ModelDownloadView) olarak gelecek;
//  buradaki satır ona götürür.
//

import SwiftUI
import AVFoundation
import EventKit
import UserNotifications
import UIKit

// MARK: - ViewModel

@MainActor
@Observable
public final class SettingsViewModel {

    public enum PermissionState: Sendable, Equatable {
        case notDetermined
        case granted
        case denied

        var label: String {
            switch self {
            case .notDetermined: return "Sorulmadı"
            case .granted:       return "Verildi"
            case .denied:        return "Reddedildi"
            }
        }
    }

    // İzinler
    public private(set) var microphone: PermissionState = .notDetermined
    public private(set) var calendar: PermissionState = .notDetermined
    public private(set) var notifications: PermissionState = .notDetermined

    // Modeller
    public private(set) var installedASRVariants: [String] = []
    public private(set) var isDiarizationInstalled = false
    public private(set) var modelsDiskBytes: Int64 = 0

    // Depolama
    public private(set) var recordingsDiskBytes: Int64 = 0
    public private(set) var noteCount = 0

    // Bulut
    public private(set) var cloudRoute: CloudRoute = .makeDefault()
    public private(set) var isCloudConfigured = false

    public var errorMessage: String?

    /// Konuşmacı ayrıştırma açık mı? (Model kurulu değilse etkisi yok.)
    public var isDiarizationEnabled: Bool {
        didSet {
            guard oldValue != isDiarizationEnabled else { return }
            UserDefaults.standard.set(isDiarizationEnabled, forKey: SpeakerLabeler.Keys.enabled)
        }
    }

    @ObservationIgnored private let repository: any NoteRepository
    @ObservationIgnored private let credentialStore: any CloudCredentialStore

    public init(
        repository: any NoteRepository = DatabaseManager.shared,
        credentialStore: any CloudCredentialStore = KeychainCredentialStore()
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.isDiarizationEnabled =
            UserDefaults.standard.object(forKey: SpeakerLabeler.Keys.enabled) as? Bool ?? true
    }

    public var offlineReady: Bool { !installedASRVariants.isEmpty }

    public func refresh() async {
        microphone = Self.map(AVAudioApplication.shared.recordPermission)
        calendar = Self.map(EKEventStore.authorizationStatus(for: .event))
        notifications = Self.map(await NotificationManager.shared.authorizationStatus())

        installedASRVariants = OfflineModelManager.installations().map(\.variant)
        isDiarizationInstalled = OfflineModelManager.isDiarizationInstalled()
        modelsDiskBytes = await OfflineModelManager.shared.diskUsageBytes()
            + OfflineModelManager.shared.diarizationDiskUsageBytes()

        recordingsDiskBytes = OfflineModelManager.directorySize(at: DatabaseManager.recordingsDirectory)

        do {
            noteCount = try await repository.all().count
        } catch {
            noteCount = 0
        }

        cloudRoute = .makeDefault()
        switch cloudRoute {
        case .proxy:
            isCloudConfigured = credentialStore.sessionToken() != nil
        case .userProvidedKey:
            isCloudConfigured = credentialStore.key(for: .anthropic) != nil
                && credentialStore.key(for: .groq) != nil
        }
    }

    // MARK: İzin istekleri

    public func requestMicrophone() async {
        guard microphone == .notDetermined else { return openSystemSettings() }
        _ = await AudioRecorderService.requestMicrophonePermission()
        await refresh()
    }

    public func requestCalendar() async {
        guard calendar == .notDetermined else { return openSystemSettings() }
        _ = await CalendarTriggerService.shared.requestAccess()
        await refresh()
    }

    public func requestNotifications() async {
        guard notifications == .notDetermined else { return openSystemSettings() }
        _ = await NotificationManager.shared.requestAuthorization()
        await refresh()
    }

    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Bakım

    /// Notu silinmiş ama diskte kalmış ses dosyalarını temizler.
    public func pruneOrphanedRecordings() async {
        do {
            let removed = try await DatabaseManager.shared.pruneOrphanedRecordings()
            errorMessage = removed > 0
                ? "\(removed) artık kullanılmayan ses dosyası silindi."
                : "Temizlenecek dosya bulunamadı."
            await refresh()
        } catch {
            errorMessage = "Temizlik başarısız: \(error.localizedDescription)"
        }
    }

    // MARK: Eşlemeler

    static func map(_ status: AVAudioApplication.recordPermission) -> PermissionState {
        switch status {
        case .granted:      return .granted
        case .denied:       return .denied
        case .undetermined: return .notDetermined
        @unknown default:   return .notDetermined
        }
    }

    static func map(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess:    return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    static func map(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }
}

// MARK: - Görünüm

public struct SettingsView: View {

    @State private var viewModel = SettingsViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                AuraTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: AuraTheme.Spacing.stackLG) {
                        systemSection
                        permissionsSection
                        storageSection
                        aboutSection
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, AuraTheme.Spacing.screenMargin)
                    .padding(.top, AuraTheme.Spacing.stackMD)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.large)
        }
        .tint(AuraTheme.primary)
        .task { await viewModel.refresh() }
        .alert(
            "Bilgi",
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

    // MARK: Sistem durumu

    private var systemSection: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            AuraSectionTitle("Sistem Durumu")

            VStack(spacing: 0) {
                NavigationLink {
                    ModelDownloadView()
                } label: {
                    row(
                        icon: "cpu",
                        iconTint: viewModel.offlineReady ? AuraTheme.primary : AuraTheme.onSurfaceVariant,
                        title: "Cihaz İçi Modeller",
                        subtitle: viewModel.offlineReady
                            ? "Offline mod hazır"
                            : "Offline mod için model indirilmeli"
                    ) {
                        HStack(spacing: 6) {
                            statusPill(
                                text: viewModel.offlineReady ? "KURULU" : "EKSİK",
                                tint: viewModel.offlineReady ? AuraTheme.primary : AuraTheme.warning
                            )
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AuraTheme.onSurfaceVariant)
                        }
                    }
                }
                .buttonStyle(.plain)

                divider

                row(
                    icon: "person.wave.2",
                    iconTint: viewModel.isDiarizationInstalled ? AuraTheme.primary : AuraTheme.onSurfaceVariant,
                    title: "Konuşmacı Ayrıştırma",
                    subtitle: viewModel.isDiarizationInstalled
                        ? "Transkriptte konuşmacılar ayrılır"
                        : "Model indirilmemiş (~\(OfflineModelManager.diarizationApproximateMegabytes) MB)"
                ) {
                    if viewModel.isDiarizationInstalled {
                        Toggle("", isOn: $viewModel.isDiarizationEnabled)
                            .labelsHidden()
                            .tint(AuraTheme.primaryContainer)
                    } else {
                        NavigationLink {
                            ModelDownloadView()
                        } label: {
                            Text("İNDİR")
                                .font(AuraFont.labelCaps)
                                .tracking(AuraFont.labelCapsTracking)
                                .foregroundStyle(AuraTheme.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                divider

                row(
                    icon: viewModel.isCloudConfigured ? "cloud.fill" : "cloud",
                    iconTint: viewModel.isCloudConfigured ? AuraTheme.secondary : AuraTheme.onSurfaceVariant,
                    title: "Bulut Erişimi",
                    subtitle: viewModel.cloudRoute.requiresUserKeys
                        ? "Kendi API anahtarın"
                        : "AuraVoice hesabı"
                ) {
                    statusPill(
                        text: viewModel.isCloudConfigured ? "BAĞLI" : "KAPALI",
                        tint: viewModel.isCloudConfigured ? AuraTheme.secondary : AuraTheme.onSurfaceVariant
                    )
                }
            }
            .glassSurface()
        }
    }

    // MARK: İzinler

    private var permissionsSection: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            AuraSectionTitle("İzinler")

            VStack(spacing: 0) {
                permissionRow(
                    icon: "mic",
                    title: "Mikrofon",
                    subtitle: "Kayıt için zorunlu",
                    state: viewModel.microphone
                ) { await viewModel.requestMicrophone() }

                divider

                permissionRow(
                    icon: "calendar",
                    title: "Takvim",
                    subtitle: "Toplantı algılama",
                    state: viewModel.calendar
                ) { await viewModel.requestCalendar() }

                divider

                permissionRow(
                    icon: "bell",
                    title: "Bildirimler",
                    subtitle: "Toplantı hatırlatmaları",
                    state: viewModel.notifications
                ) { await viewModel.requestNotifications() }
            }
            .glassSurface()
        }
    }

    // MARK: Depolama

    private var storageSection: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            AuraSectionTitle("Depolama")

            VStack(spacing: 0) {
                row(
                    icon: "externaldrive",
                    iconTint: AuraTheme.onSurfaceVariant,
                    title: "Modeller",
                    subtitle: OfflineModelManager.formatted(bytes: viewModel.modelsDiskBytes)
                ) { EmptyView() }

                divider

                row(
                    icon: "waveform",
                    iconTint: AuraTheme.onSurfaceVariant,
                    title: "Ses Kayıtları",
                    subtitle: "\(viewModel.noteCount) not · \(OfflineModelManager.formatted(bytes: viewModel.recordingsDiskBytes))"
                ) { EmptyView() }

                divider

                Button {
                    Task { await viewModel.pruneOrphanedRecordings() }
                } label: {
                    row(
                        icon: "trash",
                        iconTint: AuraTheme.onSurfaceVariant,
                        title: "Artık Dosyaları Temizle",
                        subtitle: "Notu silinmiş ses dosyaları"
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AuraTheme.onSurfaceVariant)
                    }
                }
                .buttonStyle(.plain)
            }
            .glassSurface()
        }
    }

    // MARK: Hakkında

    private var aboutSection: some View {
        VStack(spacing: AuraTheme.Spacing.stackSM) {
            VStack(spacing: 0) {
                row(
                    icon: "lock.shield",
                    iconTint: AuraTheme.primary,
                    title: "Gizlilik",
                    subtitle: "Offline modda veri cihazdan çıkmaz"
                ) { EmptyView() }
            }
            .glassSurface()

            Text("AuraVoice \(Bundle.main.appVersionString)")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant.opacity(0.5))
                .padding(.top, AuraTheme.Spacing.stackSM)
        }
    }

    // MARK: Yapı taşları

    private var divider: some View {
        Rectangle()
            .fill(AuraTheme.hairline)
            .frame(height: 1)
    }

    private func row<Trailing: View>(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(AuraFont.bodySmall)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AuraTheme.Spacing.stackSM)

            trailing()
        }
        .padding(AuraTheme.Spacing.stackMD)
        .contentShape(Rectangle())
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        state: SettingsViewModel.PermissionState,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            row(
                icon: icon,
                iconTint: state == .granted ? AuraTheme.primary : AuraTheme.onSurfaceVariant,
                title: title,
                subtitle: subtitle
            ) {
                Text(state.label)
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(Self.tint(for: state))
            }
        }
        .buttonStyle(.plain)
        // Verilmiş izin için dokunmanın bir işi yok; reddedilmişse Ayarlar'a götürür.
        .disabled(state == .granted)
    }

    private static func tint(for state: SettingsViewModel.PermissionState) -> Color {
        switch state {
        case .granted:       return AuraTheme.primary
        case .denied:        return AuraTheme.warning
        case .notDetermined: return AuraTheme.onSurfaceVariant
        }
    }

    private func statusPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(AuraFont.labelCaps)
            .tracking(AuraFont.labelCapsTracking)
            .foregroundStyle(tint)
            .padding(.horizontal, AuraTheme.Spacing.gutter)
            .padding(.vertical, 5)
            .background { Capsule().fill(tint.opacity(0.10)) }
            .overlay { Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1) }
    }
}

// MARK: - Sürüm

public extension Bundle {
    var appVersionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
}
