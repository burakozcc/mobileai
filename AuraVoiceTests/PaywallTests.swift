//
//  PaywallTests.swift
//  AuraVoiceTests
//
//  Abonelik kataloğu ve satın alma sonuçlarının kotaya yansıması.
//

import Testing
import Foundation
@testable import AuraVoice

// MARK: - Sahte sağlayıcı

private struct StubProvider: SubscriptionProvider {

    let plans: [SubscriptionPlan]
    let active: String?
    let purchaseResult: PurchaseOutcome
    let restoreResult: PurchaseOutcome

    init(
        plans: [SubscriptionPlan] = [],
        active: String? = nil,
        purchaseResult: PurchaseOutcome = .cancelled,
        restoreResult: PurchaseOutcome = .nothingToRestore
    ) {
        self.plans = plans
        self.active = active
        self.purchaseResult = purchaseResult
        self.restoreResult = restoreResult
    }

    func loadPlans() async -> [SubscriptionPlan] { plans }
    func activePlanID() async -> String? { active }
    func purchase(planID: String) async -> PurchaseOutcome { purchaseResult }
    func restorePurchases() async -> PurchaseOutcome { restoreResult }
}

private func makeQuota(seconds: Double = 0) -> QuotaManager {
    QuotaManager(storage: InMemoryQuotaStorage(initialSeconds: seconds, bootstrapped: true))
}

// MARK: - Katalog

@Suite("Abonelik kataloğu")
struct SubscriptionCatalogTests {

    @Test("İki plan sunuluyor ve Pro öneriliyor")
    func offersTwoPlans() async {
        let plans = await LocalSubscriptionProvider().loadPlans()

        #expect(plans.count == 2)
        #expect(plans.first?.id == LocalSubscriptionProvider.freePlanID)
        #expect(plans.last?.isRecommended == true)
    }

    @Test("Ücretsiz plan satın alınamaz")
    func freePlanIsNotPurchasable() async {
        let plans = await LocalSubscriptionProvider().loadPlans()
        let free = plans.first { $0.id == LocalSubscriptionProvider.freePlanID }

        #expect(free?.isPurchasable == false)
        #expect(free?.monthlyMinutes == LocalSubscriptionProvider.freeMinutes)
    }

    @Test("Ücretsiz planın dakikası QuotaManager ile aynı")
    func freeMinutesMatchQuotaManager() {
        // İki yerde farklı sayı, kullanıcıya farklı vaat demek olurdu.
        #expect(LocalSubscriptionProvider.freeMinutes * 60 == QuotaManager.freeTierSeconds)
    }

    @Test("Kullanım bilgisi ücretsiz planda gösteriliyor")
    func usageAppearsOnFreePlan() async {
        let plans = await LocalSubscriptionProvider(usedMinutes: 18).loadPlans()
        let detail = plans.first?.features.first?.detail

        #expect(detail?.contains("18") == true)
        #expect(detail?.contains("30") == true)
    }

    @Test("Kullanım plan sınırını aşmış görünmüyor")
    func usageIsClampedToPlan() async {
        // Bilet ya da düzeltmeyle kullanım sınırın üstüne çıkabilir; kartta
        // "45/30 dk" yazması kullanıcıyı yanıltırdı.
        let plans = await LocalSubscriptionProvider(usedMinutes: 45).loadPlans()
        #expect(plans.first?.features.first?.detail?.contains("30/30") == true)
    }

    @Test("Zero-Cloud maddesi her iki planda da var")
    func zeroCloudInBothPlans() async {
        let plans = await LocalSubscriptionProvider().loadPlans()
        for plan in plans {
            let offline = plan.features.first { $0.id == "offline" }
            #expect(offline?.isIncluded == true)
        }
    }

    @Test("Satın alma bağlanmadan sahte başarı dönmüyor")
    func purchaseIsHonestlyUnavailable() async {
        let outcome = await LocalSubscriptionProvider().purchase(planID: LocalSubscriptionProvider.proPlanID)

        guard case .unavailable(let reason) = outcome else {
            Issue.record("Sağlayıcı hazır değilken satın alma başarılı dönemez: \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }
}

// MARK: - ViewModel

@MainActor
@Suite("Paywall akışı", .serialized)
struct PaywallViewModelTests {

    @Test("Planlar yükleniyor")
    func loadsPlans() async {
        let plans = await LocalSubscriptionProvider().loadPlans()
        let viewModel = PaywallViewModel(
            provider: StubProvider(plans: plans, active: LocalSubscriptionProvider.freePlanID),
            quotaManager: makeQuota()
        )

        await viewModel.load()

        #expect(viewModel.plans.count == 2)
        #expect(viewModel.activePlanID == LocalSubscriptionProvider.freePlanID)
        #expect(!viewModel.isLoading)
    }

    @Test("Satın alma kotayı plan sınırına çekiyor")
    func purchaseResetsQuota() async {
        let quota = makeQuota(seconds: 0)
        let plans = await LocalSubscriptionProvider().loadPlans()
        let viewModel = PaywallViewModel(
            provider: StubProvider(
                plans: plans,
                purchaseResult: .purchased(planID: "aura.pro.monthly", grantedMinutes: 1_200)
            ),
            quotaManager: quota
        )

        await viewModel.load()
        await viewModel.purchase(plans[1])

        #expect(quota.getRemainingMinutes() == 1_200)
        #expect(viewModel.activePlanID == "aura.pro.monthly")
        #expect(viewModel.message != nil)
    }

    @Test("İptal edilen satın alma kotaya dokunmuyor")
    func cancelledPurchaseLeavesQuota() async {
        let quota = makeQuota(seconds: 600)
        let plans = await LocalSubscriptionProvider().loadPlans()
        let viewModel = PaywallViewModel(
            provider: StubProvider(plans: plans, purchaseResult: .cancelled),
            quotaManager: quota
        )

        await viewModel.load()
        await viewModel.purchase(plans[1])

        #expect(quota.getRemainingMinutes() == 10)
        // İptal kullanıcının kendi kararı; uyarı göstermek gürültü olurdu.
        #expect(viewModel.message == nil)
    }

    @Test("Kullanılamıyorsa sebep kullanıcıya iletiliyor")
    func unavailableSurfacesReason() async {
        let quota = makeQuota()
        let plans = await LocalSubscriptionProvider().loadPlans()
        let viewModel = PaywallViewModel(
            provider: StubProvider(plans: plans, purchaseResult: .unavailable(reason: "Mağaza yanıt vermedi")),
            quotaManager: quota
        )

        await viewModel.load()
        await viewModel.purchase(plans[1])

        #expect(viewModel.message == "Mağaza yanıt vermedi")
        #expect(quota.getRemainingMinutes() == 0)
    }

    @Test("Geri yükleme yoksa kullanıcı bilgilendiriliyor")
    func nothingToRestore() async {
        let viewModel = PaywallViewModel(
            provider: StubProvider(restoreResult: .nothingToRestore),
            quotaManager: makeQuota()
        )

        await viewModel.restore()
        #expect(viewModel.message?.isEmpty == false)
    }

    @Test("Geri yükleme kotayı tanımlıyor")
    func restoreGrantsMinutes() async {
        let quota = makeQuota()
        let viewModel = PaywallViewModel(
            provider: StubProvider(restoreResult: .restored(planID: "aura.pro.monthly", grantedMinutes: 600)),
            quotaManager: quota
        )

        await viewModel.restore()

        #expect(quota.getRemainingMinutes() == 600)
        #expect(viewModel.activePlanID == "aura.pro.monthly")
    }
}
