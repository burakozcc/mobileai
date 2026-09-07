//
//  SubscriptionCatalog.swift
//  AuraVoice
//
//  Abonelik planları ve satın alma sınırı.
//
//  RevenueCat henüz bağlı değil (App Store Connect hesabı ve API anahtarı
//  gerekiyor). Bu yüzden satın alma bir PROTOKOLÜN arkasında duruyor:
//  ekran ve akış bugün tamamlanabiliyor, RevenueCat geldiğinde tek bir
//  uygulama sınıfı yazılıp `makeDefault` değiştiriliyor.
//
//  Sahte satın alma YOK. Sağlayıcı hazır değilken düğme sessizce başarılı
//  olmuyor; kullanıcıya durumu söyleyen açık bir sonuç dönüyor.
//

import Foundation

// MARK: - Plan modeli

public struct PlanFeature: Sendable, Equatable, Identifiable {

    public let id: String
    public let text: String
    /// İkinci satır — kullanım durumu ya da vurgu ("Şu an: 30/30 dk").
    public let detail: String?
    public let isIncluded: Bool
    /// Zero-Cloud vaadi gibi, ücretsiz planda da mint ile vurgulanan maddeler.
    public let isHighlighted: Bool

    public init(
        id: String,
        text: String,
        detail: String? = nil,
        isIncluded: Bool = true,
        isHighlighted: Bool = false
    ) {
        self.id = id
        self.text = text
        self.detail = detail
        self.isIncluded = isIncluded
        self.isHighlighted = isHighlighted
    }
}

public struct SubscriptionPlan: Sendable, Equatable, Identifiable {

    public let id: String
    public let title: String
    /// Mağazadan gelen yerelleştirilmiş fiyat metni ("₺149,99"). Elle biçim
    /// kurmuyoruz: para birimi ve ayraç kullanıcının bölgesine göre değişir.
    public let priceText: String
    public let periodText: String
    public let monthlyMinutes: Double
    public let features: [PlanFeature]
    public let isRecommended: Bool
    /// Ücretsiz plan satın alınamaz; düğmesi "Mevcut Plan" olarak durur.
    public let isPurchasable: Bool

    public init(
        id: String,
        title: String,
        priceText: String,
        periodText: String,
        monthlyMinutes: Double,
        features: [PlanFeature],
        isRecommended: Bool = false,
        isPurchasable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.priceText = priceText
        self.periodText = periodText
        self.monthlyMinutes = monthlyMinutes
        self.features = features
        self.isRecommended = isRecommended
        self.isPurchasable = isPurchasable
    }
}

// MARK: - Satın alma sonucu

public enum PurchaseOutcome: Sendable, Equatable {
    case purchased(planID: String, grantedMinutes: Double)
    case restored(planID: String, grantedMinutes: Double)
    case cancelled
    /// Sağlayıcı henüz kurulmadı ya da mağaza yanıt vermiyor.
    case unavailable(reason: String)
    case nothingToRestore
}

// MARK: - Sağlayıcı sınırı

public protocol SubscriptionProvider: Sendable {

    /// Mağazadan (ya da yerel katalogdan) planları getirir.
    func loadPlans() async -> [SubscriptionPlan]

    /// Kullanıcının şu an sahip olduğu plan kimliği.
    func activePlanID() async -> String?

    func purchase(planID: String) async -> PurchaseOutcome
    func restorePurchases() async -> PurchaseOutcome
}

// MARK: - Yerel katalog

/// RevenueCat bağlanana kadar kullanılan sağlayıcı.
///
/// Planları ve metinleri gerçekten döndürüyor (ekranı doğru gösterebilmek
/// için), ama satın almayı taklit etmiyor: `.unavailable` dönüyor.
public struct LocalSubscriptionProvider: SubscriptionProvider {

    public static let freePlanID = "aura.free"
    public static let proPlanID = "aura.pro.monthly"

    /// Ücretsiz plan aylık dakikası — `QuotaManager.freeTierMinutes` ile aynı
    /// olmak zorunda; `SubscriptionCatalogTests` bunu doğruluyor.
    public static let freeMinutes: Double = 30
    public static let proMinutes: Double = 1_200

    private let usedMinutes: Double

    public init(usedMinutes: Double = 0) {
        self.usedMinutes = usedMinutes
    }

    public func loadPlans() async -> [SubscriptionPlan] {
        [
            SubscriptionPlan(
                id: Self.freePlanID,
                title: String(localized: "Ücretsiz"),
                priceText: "₺0",
                periodText: String(localized: "/ay"),
                monthlyMinutes: Self.freeMinutes,
                features: [
                    PlanFeature(
                        id: "cloud",
                        text: String(localized: "Aylık 30 dakika işleme"),
                        detail: String(localized: "Bu ay: \(Int(min(usedMinutes, Self.freeMinutes).rounded()))/\(Int(Self.freeMinutes)) dk")
                    ),
                    PlanFeature(
                        id: "offline",
                        // Sınırsız olan kayıt değil, GİZLİLİK. Dakika her iki
                        // modda da aynı havuzdan düşüyor; bunu burada yanlış
                        // yazmak kullanıcıya tutulamayacak bir söz vermek olur.
                        text: String(localized: "Zero-Cloud modu — ses cihazdan hiç çıkmaz"),
                        detail: String(localized: "Aynı dakika havuzunu kullanır"),
                        isHighlighted: true
                    ),
                    PlanFeature(
                        id: "export",
                        text: String(localized: "Gelişmiş dışa aktarma"),
                        isIncluded: false
                    )
                ],
                isPurchasable: false
            ),
            SubscriptionPlan(
                id: Self.proPlanID,
                title: String(localized: "Pro"),
                priceText: "₺149,99",
                periodText: String(localized: "/ay"),
                monthlyMinutes: Self.proMinutes,
                features: [
                    PlanFeature(
                        id: "cloud",
                        text: String(localized: "Aylık 1200 dakika işleme"),
                        detail: String(localized: "Yüksek doğruluklu bulut transkripsiyonu"),
                        isHighlighted: true
                    ),
                    PlanFeature(id: "offline", text: String(localized: "Zero-Cloud modu — ses cihazdan hiç çıkmaz")),
                    PlanFeature(id: "export", text: String(localized: "Gelişmiş dışa aktarma (PDF, SRT, TXT)"))
                ],
                isRecommended: true
            )
        ]
    }

    public func activePlanID() async -> String? { Self.freePlanID }

    public func purchase(planID: String) async -> PurchaseOutcome {
        .unavailable(reason: String(localized: "Abonelik altyapısı henüz bağlanmadı. Ücretsiz dakikaların her ay yenileniyor."))
    }

    public func restorePurchases() async -> PurchaseOutcome {
        .unavailable(reason: String(localized: "Abonelik altyapısı henüz bağlanmadı."))
    }
}
