//
//  SharedLaunchContract.swift
//  AuraVoice · AuraVoiceWidget
//
//  Ana uygulama ile widget uzantısının ORTAK kullandığı tek dosya.
//
//  NEDEN AYRI DOSYA: Uzantı ayrı bir süreçte çalışıyor, kendi UserDefaults
//  alanı var. Widget'tan gelen "kaydı başlat" isteğinin uygulamaya ulaşması
//  için ikisinin aynı App Group konteynerini ve aynı veri şeklini kullanması
//  gerekiyor.
//
//  NEDEN UYGULAMA TİPLERİ DEĞİL: `ProcessingMode`, `SummaryTemplate` ve
//  `RecordingTriggerSource` uygulamanın içinde EventKit, UserNotifications ve
//  ses yığınına bağlı dosyalarda tanımlı. Onları uzantıya sokmak, 40 satırlık
//  bir widget için tüm uygulamayı uzantıya taşımak demekti. Bunun yerine
//  sınırda düz String'ler taşınıyor; eşleme uygulama tarafında yapılıyor.
//
//  Bu dosya YALNIZCA Foundation'a bağlı olmalı — uzantıya giren tek şey bu.
//

import Foundation

public enum AuraSharedContract {

    /// Xcode'da her iki hedefte de "App Groups" yetkisi bu kimlikle açılmalı.
    /// Yetki verilmemişse `sharedDefaults()` sessizce standart alana düşer:
    /// uygulama çalışmaya devam eder, yalnızca widget köprüsü kurulmaz.
    public static let appGroupIdentifier = "group.com.auravoice.shared"

    public static let launchRequestKey = "aura.recording.launchRequest"
    public static let quotaSnapshotKey = "aura.quota.snapshot"
    /// O anda yazılmakta olan kayıt dosyasının adı. Yetim temizliği bu dosyaya
    /// dokunmuyor: dosya kayıt başlar başlamaz oluşuyor, notu ise ancak kayıt
    /// bitince yazılıyor — aradaki pencerede temizlik onu silebilirdi.
    public static let activeRecordingKey = "aura.recording.activeFile"

    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// Uzantının kullandığı ham değerler.
    ///
    /// Uzantı uygulamanın enum'larını göremediği için bu String'leri elle
    /// yazmak zorunda. Tek nüsha burada duruyor ve uygulama tarafındaki
    /// `SharedContractValueTests` bunların enum'larla aynı kaldığını
    /// doğruluyor — sessiz kayma böyle yakalanıyor.
    public enum Values {
        public static let widgetSource = "widget"
        public static let meetingTemplate = "Toplantı Özeti & Aksiyonlar"
        public static let offlineMode = "OFFLINE_ZERO_CLOUD"
    }
}

// MARK: - Kayıt isteği

/// Sınırdan geçen ham biçim. Alanlar String çünkü uzantı uygulamanın
/// enum'larını görmüyor.
public struct SharedLaunchRequest: Codable, Sendable, Equatable {

    public let source: String
    public let template: String
    public let mode: String?
    public let contextTitle: String?
    public let createdAt: Date

    public init(
        source: String,
        template: String,
        mode: String? = nil,
        contextTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.source = source
        self.template = template
        self.mode = mode
        self.contextTitle = contextTitle
        self.createdAt = createdAt
    }

    /// Uzantı tarafından da çağrılabilecek en yalın yazma yolu.
    public func write(to defaults: UserDefaults = AuraSharedContract.sharedDefaults()) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AuraSharedContract.launchRequestKey)
    }
}

// MARK: - Kota havuzu

/// Dakikanın hangi işleme türünden düştüğü.
///
/// Bu dosyada duruyor çünkü widget de havuz biliyor: anlık görüntüdeki sayı
/// hangi havuza aitse uzantı onu yazmak zorunda. Uygulama tarafındaki
/// `ProcessingMode` köprüsü `QuotaManager.swift` içinde bir uzantıda — o tip
/// uzantı hedefine girmiyor ve buraya konsaydı widget derlenmezdi.
public enum QuotaLane: String, Sendable, Codable, CaseIterable, Identifiable {

    case offline
    case online

    public var id: String { rawValue }

    /// Arayüzde havuzu adlandıran kısa etiket.
    ///
    /// `String(localized:)` çağıranın paketine bakıyor: aynı satır uygulamada
    /// uygulamanın kataloğundan, widget'ta widget'ın kataloğundan çözülüyor.
    /// Anahtarın İKİ katalogda da bulunması bu yüzden şart.
    public var title: String {
        switch self {
        case .offline: return String(localized: "Cihaz içi")
        case .online:  return String(localized: "Bulut")
        }
    }
}

// MARK: - Kota anlık görüntüsü

/// Widget'ın gösterdiği veri. Uygulama her tazelemede yazıyor; uzantı
/// yalnızca okuyor — kota mantığı tek yerde kalsın diye.
public struct SharedQuotaSnapshot: Codable, Sendable, Equatable {

    /// Etkin havuzun bakiyesi — halkanın ve büyük sayının gösterdiği değer.
    public let remainingMinutes: Double
    public let planMinutes: Double
    /// `remainingMinutes` hangi havuza ait. Uzantı bunu yazmadan gösterdiği
    /// sayı, mod değiştikçe açıklamasız biçimde zıplayan bir rakam olurdu.
    public let lane: QuotaLane
    /// İki havuzun tamamı. Uzantı bugün yalnızca etkin olanı çiziyor; alanlar
    /// burada çünkü anlık görüntü tek yazma noktası ve sonradan eklenen bir
    /// alan, güncellenmemiş widget'larda eksik veri demek olurdu.
    public let offlineRemainingMinutes: Double
    public let offlinePlanMinutes: Double
    public let onlineRemainingMinutes: Double
    public let onlinePlanMinutes: Double
    public let updatedAt: Date
    /// Cihaz içi kayıt şu an mümkün mü (model kurulu ve kota var).
    ///
    /// Widget bunu kendi hesaplayamıyor: model kurulumu uygulamanın
    /// konteynerinde. Alan yokken düğme yalnızca kotaya bakıyordu.
    public let offlineAvailable: Bool

    public init(
        lane: QuotaLane,
        offlineRemainingMinutes: Double,
        offlinePlanMinutes: Double,
        onlineRemainingMinutes: Double,
        onlinePlanMinutes: Double,
        updatedAt: Date = Date(),
        offlineAvailable: Bool = false
    ) {
        self.lane = lane
        self.offlineRemainingMinutes = offlineRemainingMinutes
        self.offlinePlanMinutes = offlinePlanMinutes
        self.onlineRemainingMinutes = onlineRemainingMinutes
        self.onlinePlanMinutes = onlinePlanMinutes
        self.remainingMinutes = lane == .online ? onlineRemainingMinutes : offlineRemainingMinutes
        self.planMinutes = lane == .online ? onlinePlanMinutes : offlinePlanMinutes
        self.updatedAt = updatedAt
        self.offlineAvailable = offlineAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case remainingMinutes, planMinutes, updatedAt, offlineAvailable
        case lane, offlineRemainingMinutes, offlinePlanMinutes
        case onlineRemainingMinutes, onlinePlanMinutes
    }

    /// Eski anlık görüntülerde alan yok; varsayılanla açılıyor ki uygulama
    /// güncellendiğinde widget çözümleme hatası vermesin.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remainingMinutes = try container.decode(Double.self, forKey: .remainingMinutes)
        planMinutes = try container.decode(Double.self, forKey: .planMinutes)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        offlineAvailable = try container.decodeIfPresent(Bool.self, forKey: .offlineAvailable) ?? false
        // Tek havuzlu sürümün yazdığı anlık görüntüde havuz alanları yok.
        // Varsayılan `.offline`: uygulamanın açılış modu o ve kullanıcıya
        // "bulut" diye yanlış etiket göstermektense doğru olanı seçiyoruz.
        // Değerler etkin havuzdan kopyalanıyor — uygulama bir kez tazeleyene
        // kadar geçerli olan tek gerçek o.
        lane = try container.decodeIfPresent(QuotaLane.self, forKey: .lane) ?? .offline
        offlineRemainingMinutes = try container.decodeIfPresent(Double.self, forKey: .offlineRemainingMinutes) ?? remainingMinutes
        offlinePlanMinutes = try container.decodeIfPresent(Double.self, forKey: .offlinePlanMinutes) ?? planMinutes
        onlineRemainingMinutes = try container.decodeIfPresent(Double.self, forKey: .onlineRemainingMinutes) ?? remainingMinutes
        onlinePlanMinutes = try container.decodeIfPresent(Double.self, forKey: .onlinePlanMinutes) ?? planMinutes
    }

    /// 0...1 — plan tanımsızsa dolu göstermek yerine boş gösteriyoruz ki
    /// widget yanlış bir güven vermesin.
    public var fraction: Double {
        guard planMinutes > 0 else { return 0 }
        return min(1, max(0, remainingMinutes / planMinutes))
    }

    public var isEmpty: Bool { remainingMinutes < 0.5 }

    public static func read(from defaults: UserDefaults = AuraSharedContract.sharedDefaults()) -> SharedQuotaSnapshot? {
        guard let data = defaults.data(forKey: AuraSharedContract.quotaSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(SharedQuotaSnapshot.self, from: data)
    }

    public func write(to defaults: UserDefaults = AuraSharedContract.sharedDefaults()) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AuraSharedContract.quotaSnapshotKey)
    }
}
