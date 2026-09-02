//
//  EnterpriseKeyView.swift
//  AuraVoice
//
//  Kurumsal müşterinin sağlayıcı anahtarını sisteme işleme yüzeyi.
//
//  NEDEN VAR: `setKey` yazılmıştı ama hiçbir ekrandan çağrılmıyordu — yani
//  kurumsal müşteriden anahtar alan satış temsilcisinin onu gireceği bir
//  yer yoktu. Bu ekran o boşluğu kapatıyor.
//
//  NE YAPMIYOR: anahtarı cihaza YAZMIYOR. `EnterpriseCredentials.swift`
//  başındaki karar geçerli — kurumsal/bireysel ayrımı yalnızca arayüzde,
//  arka planda değil. Anahtar sunucuya gidiyor, kuruma bağlı orada
//  saklanıyor, uygulama yine proxy ile konuşmaya devam ediyor.
//
//  Bireysel kullanıcı bu ekranı GÖRMÜYOR: Ayarlar satırı yalnızca sunucu
//  hesabın yetkili olduğunu söylediğinde çiziliyor.
//

import SwiftUI

@MainActor
@Observable
public final class EnterpriseKeyViewModel {

    public enum Outcome: Equatable, Sendable {
        case idle
        case saved(masked: String)
        case failed(String)
    }

    /// Girilen anahtar. Gönderim biter bitmez temizleniyor.
    public var keyInput = ""
    public var provider: CloudProvider = .anthropic

    public private(set) var outcome: Outcome = .idle
    public private(set) var isWorking = false
    public private(set) var access: EnterpriseAccess = .unauthorized
    /// Sunucuda o sağlayıcı için kayıtlı anahtarın maskeli kuyruğu.
    public private(set) var installedSuffix: String?
    public private(set) var isLoading = true

    @ObservationIgnored private let provisioner: (any EnterpriseCredentialProvisioning)?
    @ObservationIgnored private let accessProvider: (any EnterpriseAccessProviding)?

    public init(
        provisioner: (any EnterpriseCredentialProvisioning)? = nil,
        accessProvider: (any EnterpriseAccessProviding)? = nil
    ) {
        // Varsayılan yalnızca gerekince kuruluyor: testler kendi sahtesini
        // verdiğinde Bundle'a ve Keychain'e hiç dokunulmuyor. Proxy
        // yapılandırılmamışsa `ProxyEnterpriseProvisioner` nil dönüyor ve
        // özellik kapalı kalıyor.
        let shared: ProxyEnterpriseProvisioner? = (provisioner == nil || accessProvider == nil)
            ? ProxyEnterpriseProvisioner(route: .makeDefault(), store: KeychainCredentialStore())
            : nil
        if let provisioner {
            self.provisioner = provisioner
        } else {
            self.provisioner = shared
        }
        if let accessProvider {
            self.accessProvider = accessProvider
        } else {
            self.accessProvider = shared
        }
    }

    public var isAvailable: Bool { provisioner != nil && access.canManageProviderKeys }

    public func load() async {
        isLoading = true
        defer { isLoading = false }

        if let accessProvider {
            access = await accessProvider.currentAccess()
        } else {
            access = .unauthorized
        }

        guard access.canManageProviderKeys, let provisioner else {
            installedSuffix = nil
            return
        }
        installedSuffix = await provisioner.installedKeySuffix(provider: provider)
    }

    public func providerChanged() async {
        guard access.canManageProviderKeys, let provisioner else { return }
        outcome = .idle
        installedSuffix = await provisioner.installedKeySuffix(provider: provider)
    }

    public func submit() async {
        guard !isWorking, let provisioner else { return }

        let candidate = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            outcome = .failed(String(localized: "Önce anahtarı gir."))
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await provisioner.submit(key: candidate, provider: provider)
            switch result {
            case let .stored(masked):
                // Alan HEMEN temizleniyor: ekran açık kalıp omuz üstünden
                // okunmasın, ekran görüntüsüne düşmesin.
                keyInput = ""
                installedSuffix = masked
                outcome = .saved(masked: masked)
            case let .rejected(reason):
                outcome = .failed(reason)
            }
        } catch let error as AuraError {
            outcome = .failed(error.errorDescription ?? String(localized: "Anahtar kaydedilemedi."))
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    public func revoke() async {
        guard !isWorking, let provisioner else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await provisioner.revoke(provider: provider)
            installedSuffix = nil
            outcome = .idle
        } catch let error as AuraError {
            outcome = .failed(error.errorDescription ?? String(localized: "Anahtar silinemedi."))
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }
}

public struct EnterpriseKeyView: View {

    @State private var viewModel = EnterpriseKeyViewModel()
    @State private var isConfirmingRevoke = false

    public init() {}

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackMD) {
                    header

                    if viewModel.isLoading {
                        ProgressView().tint(AuraTheme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if viewModel.isAvailable {
                        providerPicker
                        installedRow
                        editor
                        actions
                    } else {
                        unavailableNotice
                    }

                    if case let .saved(masked) = viewModel.outcome {
                        card(
                            icon: "checkmark.circle.fill",
                            tint: AuraTheme.primary,
                            text: "Anahtar kuruma kaydedildi (\(masked)). Cihazda saklanmadı."
                        )
                    }
                    if case let .failed(reason) = viewModel.outcome {
                        card(icon: "exclamationmark.triangle.fill", tint: AuraTheme.warning, text: reason)
                    }
                }
                .padding(AuraTheme.Spacing.screenMargin)
            }
        }
        .navigationTitle("Kurumsal Anahtar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .confirmationDialog(
            "Kayıtlı anahtar silinsin mi?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                Task { await viewModel.revoke() }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Kurumun bulut işlemleri, yeni bir anahtar girilene kadar durur.")
        }
    }

    // MARK: Parçalar

    private var header: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackSM) {
            Text(viewModel.access.organizationName.map { "\($0) için sağlayıcı anahtarı." }
                 ?? String(localized: "Kurumun sağlayıcı anahtarı."))
                .font(AuraFont.bodyLarge)
                .foregroundStyle(AuraTheme.onSurface)
            Text("Anahtar sunucuda kuruma bağlı olarak saklanır; bu cihaza yazılmaz. Uygulama her durumda AuraVoice sunucusu üzerinden çalışmaya devam eder.")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerPicker: some View {
        Picker("Sağlayıcı", selection: $viewModel.provider) {
            ForEach(CloudProvider.allCases, id: \.self) { provider in
                Text(provider.rawValue.capitalized).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: viewModel.provider) { _, _ in
            Task { await viewModel.providerChanged() }
        }
    }

    @ViewBuilder
    private var installedRow: some View {
        if let suffix = viewModel.installedSuffix {
            card(
                icon: "key.fill",
                tint: AuraTheme.secondary,
                text: "Kayıtlı anahtar: \(suffix)"
            )
        }
    }

    private var editor: some View {
        // `SecureField`: anahtar ekranda açık durmuyor, klavye önerilerine ve
        // otomatik düzeltmeye takılmıyor.
        // `textContentType` bilerek verilmiyor: `.password` deseydik iOS
        // anahtarı iCloud Keychain'e kaydetmeyi teklif ederdi — kullanıcıya
        // "bu cihaza yazılmaz" dediğimiz şeyin tam tersi.
        SecureField("Sağlayıcı anahtarını yapıştır", text: $viewModel.keyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(AuraFont.bodySmall)
            .padding(AuraTheme.Spacing.stackMD)
            .glassSurface()
    }

    private var actions: some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            if viewModel.installedSuffix != nil {
                Button("SİL") { isConfirmingRevoke = true }
                    .font(AuraFont.labelCaps)
                    .foregroundStyle(AuraTheme.warning)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                            .fill(AuraTheme.surfaceContainerHigh)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isWorking)
            }

            Button {
                Task { await viewModel.submit() }
            } label: {
                Group {
                    if viewModel.isWorking {
                        ProgressView().tint(AuraTheme.onPrimary)
                    } else {
                        Text("KAYDET").font(AuraFont.labelCaps)
                    }
                }
                .foregroundStyle(AuraTheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .fill(AuraTheme.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWorking || viewModel.keyInput.isEmpty)
        }
    }

    private var unavailableNotice: some View {
        card(
            icon: "lock.slash.fill",
            tint: AuraTheme.onSurfaceVariant,
            text: "Bu hesap kurumsal anahtar yönetmeye yetkili değil."
        )
    }

    private func card(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
            Text(text)
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(borderColor: tint.opacity(0.30))
    }
}
