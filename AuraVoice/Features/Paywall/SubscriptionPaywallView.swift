//
//  SubscriptionPaywallView.swift
//  AuraVoice
//
//  Kota dolduğunda açılan abonelik ekranı — mockup'taki "Transcription Paused".
//
//  EKRANIN TONU: Kullanıcı burada bir duvara toslamış hissetmemeli. Zero-Cloud
//  modu kotadan bağımsız ve sınırsız çalışıyor; bu, ekranın en görünür ikinci
//  mesajı. "Öde ya da uygulamayı kullanma" değil, "bulut dakikası bitti, cihaz
//  içi mod açık" diyoruz.
//

import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
public final class PaywallViewModel {

    public private(set) var plans: [SubscriptionPlan] = []
    public private(set) var activePlanID: String?
    public private(set) var isLoading = true
    public private(set) var isWorking = false
    /// Bakiyenin yenileneceği an. Kota bittiğinde kullanıcının görmesi gereken
    /// tek eyleme dönük bilgi bu.
    public private(set) var renewalDate: Date?
    public var message: String?

    @ObservationIgnored private let provider: any SubscriptionProvider
    @ObservationIgnored private let quotaManager: QuotaManager

    public init(
        provider: any SubscriptionProvider,
        quotaManager: QuotaManager = .shared
    ) {
        self.provider = provider
        self.quotaManager = quotaManager
    }

    public func load() async {
        isLoading = true
        plans = await provider.loadPlans()
        activePlanID = await provider.activePlanID()
        renewalDate = quotaManager.nextRenewalDate()
        isLoading = false
    }

    public func purchase(_ plan: SubscriptionPlan) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        apply(await provider.purchase(planID: plan.id))
    }

    public func restore() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        apply(await provider.restorePurchases())
    }

    /// Satın alma sonucunu kotaya ve kullanıcıya yansıtır.
    ///
    /// Dakika ekleme burada yapılıyor ama üretimde tek başına yeterli değil:
    /// gerçek yetkilendirme sunucunun imzaladığı dakika biletiyle geliyor
    /// (`SecureTicketStore`). Bu satır, mağaza doğrulaması ile bilet arasındaki
    /// gecikmede kullanıcının beklememesi için.
    private func apply(_ outcome: PurchaseOutcome) {
        switch outcome {
        case .purchased(let planID, let minutes):
            activePlanID = planID
            _ = quotaManager.resetBalance(toMinutes: minutes)
            renewalDate = quotaManager.nextRenewalDate()
            message = String(localized: "Aboneliğin etkin. Aylık \(Int(minutes)) dakika hesabına tanımlandı.")

        case .restored(let planID, let minutes):
            activePlanID = planID
            _ = quotaManager.resetBalance(toMinutes: minutes)
            renewalDate = quotaManager.nextRenewalDate()
            message = String(localized: "Aboneliğin geri yüklendi.")

        case .cancelled:
            break

        case .nothingToRestore:
            message = String(localized: "Geri yüklenecek bir abonelik bulunamadı.")

        case .unavailable(let reason):
            message = reason
        }
    }
}

// MARK: - Ekran

public struct SubscriptionPaywallView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PaywallViewModel

    private let remainingMinutes: Double
    private let onContinueOffline: () -> Void

    public init(
        remainingMinutes: Double,
        usedMinutes: Double = 0,
        provider: (any SubscriptionProvider)? = nil,
        onContinueOffline: @escaping () -> Void = {}
    ) {
        self.remainingMinutes = remainingMinutes
        self.onContinueOffline = onContinueOffline
        _viewModel = State(initialValue: PaywallViewModel(
            provider: provider ?? LocalSubscriptionProvider(usedMinutes: usedMinutes)
        ))
    }

    private var isQuotaEmpty: Bool { remainingMinutes < 0.5 }

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AuraTheme.Spacing.stackLG) {
                    header
                    if viewModel.isLoading {
                        ProgressView().tint(AuraTheme.primary).padding(.vertical, 40)
                    } else {
                        ForEach(viewModel.plans) { plan in
                            planCard(plan)
                        }
                    }
                    footer
                }
                .padding(.horizontal, AuraTheme.Spacing.screenMargin)
                .padding(.top, AuraTheme.Spacing.stackLG)
                .padding(.bottom, 40)
            }

            closeButton
        }
        .task { await viewModel.load() }
        .alert(
            "AuraVoice Pro",
            isPresented: Binding(
                get: { viewModel.message != nil },
                set: { if !$0 { viewModel.message = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) { viewModel.message = nil }
        } message: {
            Text(viewModel.message ?? "")
        }
    }

    // MARK: Başlık

    private var header: some View {
        VStack(spacing: AuraTheme.Spacing.stackMD) {

            // Durum rozeti — kota bittiyse uyarı, bitmediyse bilgi tonunda.
            HStack(spacing: 6) {
                Image(systemName: isQuotaEmpty ? "exclamationmark.triangle.fill" : "crown.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isQuotaEmpty ? "KOTA DOLDU" : "AURAVOICE PRO")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
            }
            .foregroundStyle(isQuotaEmpty ? AuraTheme.warning : AuraTheme.primary)
            .padding(.horizontal, AuraTheme.Spacing.stackMD)
            .padding(.vertical, AuraTheme.Spacing.stackSM)
            .background {
                Capsule()
                    .fill((isQuotaEmpty ? AuraTheme.warning : AuraTheme.primary).opacity(0.10))
                    .overlay {
                        Capsule()
                            .strokeBorder((isQuotaEmpty ? AuraTheme.warning : AuraTheme.primary).opacity(0.30), lineWidth: 1)
                    }
            }
            .padding(.top, AuraTheme.Spacing.stackLG)

            Text(isQuotaEmpty ? "Dakikan bitti" : "Daha fazla dakika")
                .font(AuraFont.displayLarge)
                .tracking(AuraFont.displayLargeTracking)
                .foregroundStyle(AuraTheme.onBackground)
                .multilineTextAlignment(.center)

            Text(bodyText)
                .font(AuraFont.bodyLarge)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bodyText: String {
        // Zero-Cloud modu dakikayı AYNI havuzdan harcıyor; burada "offline'da
        // devam edebilirsin" demek kullanıcıyı çalışmayan bir yola yollamak
        // olurdu. Kota bittiğinde söylenecek doğru şey yenileme tarihi.
        if isQuotaEmpty {
            if let renewal = Self.renewalText(viewModel.renewalDate) {
                return String(localized: "Bu ayki işleme hakkını kullandın. Ücretsiz dakikaların \(renewal) yenilenecek; beklemek istemiyorsan Pro'ya geçebilirsin.")
            }
            return String(localized: "Bu ayki işleme hakkını kullandın. Pro'ya geçerek aylık dakikanı artırabilirsin.")
        }
        return String(localized: "Kalan \(AuraFormat.minutes(remainingMinutes)) işleme hakkın var. Zero-Cloud modunda ses cihazdan hiç çıkmaz, ama dakika aynı havuzdan düşer.")
    }

    static func renewalText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Ek AYRI cevrilemez: Turkce'de sona gelen bir bulunma eki, Ingilizce'de
        // basa gelen bir edat ("on <tarih>"), baska dillerde bambaska. Tarih
        // interpolasyonla TEK anahtarin icine giriyor ki cevirmen kelime
        // sirasini kendi dilinin gerektirdigi gibi kurabilsin.
        let formatted = formatter.string(from: date)
        return String(localized: "\(formatted)'te")
    }

    // MARK: Plan kartı

    private func planCard(_ plan: SubscriptionPlan) -> some View {
        let isActive = plan.id == viewModel.activePlanID

        return VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .top) {
                Text(plan.title)
                    .font(AuraFont.headlineMedium)
                    .tracking(AuraFont.headlineMediumTracking)
                    .foregroundStyle(AuraTheme.onSurface)

                Spacer()

                if plan.isRecommended {
                    Text("ÖNERİLEN")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(AuraTheme.primary)
                        .padding(.horizontal, AuraTheme.Spacing.gutter)
                        .padding(.vertical, 5)
                        .background {
                            Capsule()
                                .fill(AuraTheme.primary.opacity(0.20))
                                .overlay { Capsule().strokeBorder(AuraTheme.primary.opacity(0.30), lineWidth: 1) }
                        }
                }
            }
            .padding(.bottom, AuraTheme.Spacing.stackSM)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(plan.priceText)
                    .font(AuraFont.displayLarge)
                    .tracking(AuraFont.displayLargeTracking)
                    .foregroundStyle(plan.isRecommended ? AuraTheme.primary : AuraTheme.onBackground)
                Text(plan.periodText)
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
            }
            .padding(.bottom, AuraTheme.Spacing.stackLG)

            VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackMD) {
                ForEach(plan.features) { feature in
                    featureRow(feature)
                }
            }
            .padding(.bottom, AuraTheme.Spacing.stackLG)

            planButton(plan, isActive: isActive)
        }
        .padding(AuraTheme.Spacing.stackLG)
        .glassSurface(cornerRadius: AuraTheme.Radius.extraLarge)
        .overlay {
            // Önerilen kart sıcak bir kenarla ayrışıyor; mockup'taki
            // "warning-glow" karşılığı.
            if plan.isRecommended {
                RoundedRectangle(cornerRadius: AuraTheme.Radius.extraLarge, style: .continuous)
                    .strokeBorder(AuraTheme.warning.opacity(0.30), lineWidth: 1)
            }
        }
        .shadow(
            color: plan.isRecommended ? AuraTheme.warning.opacity(0.15) : .clear,
            radius: 20
        )
    }

    private func featureRow(_ feature: PlanFeature) -> some View {
        HStack(alignment: .top, spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: feature.isIncluded ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(tint(for: feature))

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.text)
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = feature.detail {
                    Text(detail.uppercased())
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(feature.isHighlighted ? AuraTheme.primary : AuraTheme.onSurfaceVariant)
                }
            }

            Spacer(minLength: 0)
        }
        .opacity(feature.isIncluded ? 1 : 0.5)
    }

    private func tint(for feature: PlanFeature) -> Color {
        guard feature.isIncluded else { return AuraTheme.onSurfaceVariant }
        return feature.isHighlighted ? AuraTheme.primary : AuraTheme.onSurfaceVariant
    }

    @ViewBuilder
    private func planButton(_ plan: SubscriptionPlan, isActive: Bool) -> some View {
        if !plan.isPurchasable || isActive {
            Text(isActive ? "MEVCUT PLAN" : "PLANI KULLAN")
                .font(AuraFont.labelCaps)
                .tracking(AuraFont.labelCapsTracking)
                .foregroundStyle(AuraTheme.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .fill(AuraTheme.surfaceContainerHigh)
                        .overlay {
                            RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                                .strokeBorder(AuraTheme.hairline, lineWidth: 1)
                        }
                }
        } else {
            Button {
                Task { await viewModel.purchase(plan) }
            } label: {
                Group {
                    if viewModel.isWorking {
                        ProgressView().tint(AuraTheme.onPrimary)
                    } else {
                        Text("PRO'YA GEÇ")
                            .font(AuraFont.labelCaps)
                            .tracking(AuraFont.labelCapsTracking)
                    }
                }
                .foregroundStyle(AuraTheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .fill(AuraTheme.primary)
                }
                .shadow(color: AuraTheme.primary.opacity(0.30), radius: 15)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWorking)
        }
    }

    // MARK: Alt bölüm

    private var footer: some View {
        VStack(spacing: AuraTheme.Spacing.stackMD) {

            if isQuotaEmpty {
                // Kota bittiğinde offline'a geçmek de işe yaramıyor; kullanıcıyı
                // çalışmayan bir düğmeyle oyalamak yerine gerçeği yazıyoruz.
                if let renewal = Self.renewalText(viewModel.renewalDate) {
                    Label("Ücretsiz dakikaların \(renewal) yenilenecek", systemImage: "arrow.clockwise")
                        .font(AuraFont.bodySmall)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                }
            } else {
                Button {
                    onContinueOffline()
                    dismiss()
                } label: {
                    Text("ZERO-CLOUD MODUNDA DEVAM ET")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .underline(true, color: AuraTheme.hairline)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await viewModel.restore() }
            } label: {
                Text("Satın alımları geri yükle")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWorking)
        }
        .padding(.top, AuraTheme.Spacing.stackSM)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(AuraTheme.surfaceContainerHigh))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kapat")
            }
            Spacer()
        }
        .padding(AuraTheme.Spacing.screenMargin)
    }
}

#Preview("Kota doldu") {
    SubscriptionPaywallView(remainingMinutes: 0, usedMinutes: 30)
}

#Preview("Kota var") {
    SubscriptionPaywallView(remainingMinutes: 12, usedMinutes: 18)
}
