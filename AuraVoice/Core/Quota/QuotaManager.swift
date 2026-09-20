//
//  QuotaManager.swift
//  AuraVoice
//
//  Dakika bakiyesi yönetimi — İKİ AYRI HAVUZ.
//
//  Cihaz içi işleme ile bulut işleme bize aynı şeye mal olmuyor: birincisinin
//  marjinal maliyeti sıfır (kullanıcının kendi işlemcisi), ikincisi her dakika
//  için sağlayıcıya ödenen gerçek para. Tek havuz bu farkı gizliyordu ve iki
//  yanlış sonuç doğuruyordu: bulut dakikasını bitiren kullanıcı Zero-Cloud
//  modunu da kaybediyor, cihaz içinde çalışan kullanıcı ise bize hiçbir
//  maliyeti olmayan bir işlem için ücretli kotasını yakıyordu.
//
//  Bu yüzden bakiye `QuotaLane` başına tutuluyor. Ortak kalan tek şey DÖNEM:
//  iki havuz da aynı anda, aynı takvim sınırında yenileniyor — kullanıcının
//  aklında iki farklı yenileme tarihi tutmasını istemiyoruz.
//
//  Depolama enjekte edilebilir: üretimde Keychain, testte bellek içi. Bu ayrım
//  CI'da ortaya çıkan gerçek bir hatadan doğdu — eski sürüm `SecItemAdd`/
//  `SecItemUpdate` dönüş kodlarını yok sayıyordu, yazma başarısız olduğunda
//  kullanıcının bakiyesi sessizce sıfırlanıyordu.
//

import Foundation
import Security

// MARK: - Havuz köprüsü

/// `QuotaLane` App Group sınırındaki `SharedLaunchContract.swift` içinde
/// tanımlı (widget de havuz biliyor). `ProcessingMode` ise uzantı hedefine
/// girmiyor, bu yüzden köprü burada.
///
/// `ProcessingMode` kullanıcıya gösterilen SEÇİM, `QuotaLane` o seçimin
/// faturalandığı havuz. İkisi bugün birebir eşleşiyor ama aynı şey değiller:
/// bulut isteği cihaz içi motora düştüğünde seçim `online` kalır, düşülen
/// havuz `offline` olur — parayı harcamayan iş, para havuzunu da yakmamalı.
extension QuotaLane {

    public init(mode: ProcessingMode) {
        self = mode == .onlineCloudFast ? .online : .offline
    }
}

// MARK: - Depolama Sözleşmesi

public protocol QuotaStorage: Sendable {

    func readBalanceSeconds(_ lane: QuotaLane) -> Double?
    /// `false` → yazma başarısız; çağıran bunu kullanıcıya yansıtmalı.
    @discardableResult func writeBalanceSeconds(_ seconds: Double, lane: QuotaLane) -> Bool

    /// Yürürlükteki planın o havuz için aylık dakikası. Yenilemede bakiye buna eşitleniyor.
    func readPlanMinutes(_ lane: QuotaLane) -> Double?
    @discardableResult func writePlanMinutes(_ minutes: Double, lane: QuotaLane) -> Bool

    func isBootstrapped() -> Bool
    @discardableResult func markBootstrapped() -> Bool

    /// İçinde bulunulan kota döneminin başlangıcı — İKİ HAVUZ İÇİN ORTAK.
    func readPeriodStart() -> Date?
    @discardableResult func writePeriodStart(_ date: Date) -> Bool
}

// MARK: - Keychain Uygulaması

public final class KeychainQuotaStorage: QuotaStorage {

    private let service: String
    // Anahtarlar havuz adıyla türetiliyor. Tek havuzlu sürümün anahtarları
    // (`remaining_seconds_balance`) bilerek KULLANILMIYOR: aynı isme iki farklı
    // anlam yüklemek, güncellenen bir cihazda bulut bakiyesini cihaz içi
    // bakiyesi sanmak demekti. Eski kayıt varsa öksüz kalıyor, zararsız.
    private let bootstrapKey = "free_grant_issued_v2"
    private let periodKey = "quota_period_start_epoch"

    public init(service: String = "com.auravoice.quota") {
        self.service = service
    }

    private func balanceKey(_ lane: QuotaLane) -> String { "remaining_seconds_\(lane.rawValue)_v2" }
    private func planKey(_ lane: QuotaLane) -> String { "plan_minutes_\(lane.rawValue)_v2" }

    public func readBalanceSeconds(_ lane: QuotaLane) -> Double? {
        readDouble(key: balanceKey(lane))
    }

    @discardableResult
    public func writeBalanceSeconds(_ seconds: Double, lane: QuotaLane) -> Bool {
        let rounded = (max(0, seconds) * 1000).rounded() / 1000
        return writeDouble(rounded, key: balanceKey(lane))
    }

    public func readPlanMinutes(_ lane: QuotaLane) -> Double? {
        readDouble(key: planKey(lane))
    }

    @discardableResult
    public func writePlanMinutes(_ minutes: Double, lane: QuotaLane) -> Bool {
        writeDouble(max(0, minutes), key: planKey(lane))
    }

    public func readPeriodStart() -> Date? {
        guard let value = readDouble(key: periodKey) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    @discardableResult
    public func writePeriodStart(_ date: Date) -> Bool {
        writeDouble(date.timeIntervalSince1970, key: periodKey)
    }

    public func isBootstrapped() -> Bool {
        read(key: bootstrapKey) != nil
    }

    @discardableResult
    public func markBootstrapped() -> Bool {
        write(Data([1]), key: bootstrapKey)
    }

    // MARK: Sayısal alanlar

    private func readDouble(key: String) -> Double? {
        guard let data = read(key: key),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Double(text)
    }

    @discardableResult
    private func writeDouble(_ value: Double, key: String) -> Bool {
        guard let data = "\(value)".data(using: .utf8) else { return false }
        return write(data, key: key)
    }

    // MARK: Keychain temel işlemleri

    private func read(key: String) -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            print("[AuraVoice] Keychain okuma hatası (\(key)): \(Self.describe(status))")
            return nil
        }
    }

    @discardableResult
    private func write(_ data: Data, key: String) -> Bool {
        let query = baseQuery(key: key)
        let existing = SecItemCopyMatching(query as CFDictionary, nil)

        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            status = SecItemAdd(insert as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            // Eskiden bu satır yoktu: hata yutulunca bakiye sessizce kayboluyordu.
            print("[AuraVoice] Keychain yazma hatası (\(key)): \(Self.describe(status))")
            return false
        }
        return true
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Cihaz ilk açılıştan sonra kilitliyken de okunabilsin (arka plan
            // işleme), ama yedeklerle başka cihaza taşınmasın.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "bilinmeyen"
        return "\(status) (\(message))"
    }
}

// MARK: - Bellek İçi Uygulama (test / önizleme)

public final class InMemoryQuotaStorage: QuotaStorage, @unchecked Sendable {

    private let lock = NSLock()
    private var balances: [QuotaLane: Double]
    private var plans: [QuotaLane: Double]
    private var bootstrapped: Bool
    private var periodStart: Date?

    public init(
        offlineSeconds: Double? = nil,
        onlineSeconds: Double? = nil,
        bootstrapped: Bool = false,
        periodStart: Date? = nil,
        offlinePlanMinutes: Double? = nil,
        onlinePlanMinutes: Double? = nil
    ) {
        // Sözlüğe `nil` atamak anahtarı SİLİYOR; "yazılmamış" ile "sıfır"
        // arasındaki fark böyle korunuyor. Kurulum (`bootstrapIfNeeded`)
        // yalnızca yazılmamış havuza hediye veriyor.
        var balances: [QuotaLane: Double] = [:]
        balances[.offline] = offlineSeconds
        balances[.online] = onlineSeconds
        self.balances = balances

        var plans: [QuotaLane: Double] = [:]
        plans[.offline] = offlinePlanMinutes
        plans[.online] = onlinePlanMinutes
        self.plans = plans

        self.bootstrapped = bootstrapped
        self.periodStart = periodStart
    }

    /// İki havuza da aynı değeri koyan kısayol — havuz ayrımını sınamayan
    /// testler bununla tek satırda kuruluyor.
    public convenience init(
        initialSeconds: Double,
        bootstrapped: Bool = false,
        periodStart: Date? = nil,
        planMinutes: Double? = nil
    ) {
        self.init(
            offlineSeconds: initialSeconds,
            onlineSeconds: initialSeconds,
            bootstrapped: bootstrapped,
            periodStart: periodStart,
            offlinePlanMinutes: planMinutes,
            onlinePlanMinutes: planMinutes
        )
    }

    public func readBalanceSeconds(_ lane: QuotaLane) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return balances[lane]
    }

    @discardableResult
    public func writeBalanceSeconds(_ seconds: Double, lane: QuotaLane) -> Bool {
        lock.lock(); defer { lock.unlock() }
        balances[lane] = max(0, seconds)
        return true
    }

    public func readPlanMinutes(_ lane: QuotaLane) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return plans[lane]
    }

    @discardableResult
    public func writePlanMinutes(_ minutes: Double, lane: QuotaLane) -> Bool {
        lock.lock(); defer { lock.unlock() }
        plans[lane] = max(0, minutes)
        return true
    }

    public func isBootstrapped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bootstrapped
    }

    @discardableResult
    public func markBootstrapped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        bootstrapped = true
        return true
    }

    public func readPeriodStart() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return periodStart
    }

    @discardableResult
    public func writePeriodStart(_ date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        periodStart = date
        return true
    }
}

// MARK: - Yönetici

public final class QuotaManager: Sendable {

    public static let shared = QuotaManager(storage: KeychainQuotaStorage())

    /// Ücretsiz planın AYLIK dakikaları.
    ///
    /// Cihaz içi rakamın büyük olması bilinçli: o dakikalar bize sağlayıcı
    /// faturası çıkarmıyor, bulut dakikası ise her biri için ödenen para.
    /// Rakamlar ürün kararı ve tek yerde duruyor — değiştirmek bu iki satırı
    /// düzenlemek demek; arayüz metinleri sayıyı buradan okuyup yerleştiriyor,
    /// çeviriye dokunmak gerekmiyor.
    public static let freeOfflineMinutes: Double = 20
    public static let freeOnlineMinutes: Double = 10

    public static func freeMinutes(_ lane: QuotaLane) -> Double {
        switch lane {
        case .offline: return freeOfflineMinutes
        case .online:  return freeOnlineMinutes
        }
    }

    private let storage: any QuotaStorage
    private let calendar: Calendar

    public init(storage: any QuotaStorage, calendar: Calendar = .current) {
        self.storage = storage
        self.calendar = calendar
    }

    // MARK: Okuma

    public func getRemainingSeconds(_ lane: QuotaLane, now: Date = Date()) -> Double {
        bootstrapIfNeeded(now: now)
        renewIfNeeded(now: now)
        return max(0, storage.readBalanceSeconds(lane) ?? 0)
    }

    public func getRemainingMinutes(_ lane: QuotaLane, now: Date = Date()) -> Double {
        getRemainingSeconds(lane, now: now) / 60.0
    }

    public func canProcess(durationSeconds: Double, lane: QuotaLane, now: Date = Date()) -> Bool {
        getRemainingSeconds(lane, now: now) >= durationSeconds
    }

    /// Yürürlükteki planın o havuz için aylık dakikası. Plan yazılmamışsa ücretsiz plan.
    public func planMonthlyMinutes(_ lane: QuotaLane) -> Double {
        storage.readPlanMinutes(lane) ?? Self.freeMinutes(lane)
    }

    /// Bakiyenin bir sonraki yenileneceği an — paywall ve panel bunu gösteriyor.
    ///
    /// Havuz parametresi YOK: dönem ikisi için ortak. Havuz başına ayrı tarih
    /// olsaydı kullanıcı iki yenileme günü ezberlemek zorunda kalırdı.
    public func nextRenewalDate(now: Date = Date()) -> Date? {
        bootstrapIfNeeded(now: now)
        guard let start = storage.readPeriodStart() else { return nil }
        let current = Self.currentPeriodStart(anchor: start, now: now, calendar: calendar)
        return calendar.date(byAdding: .month, value: 1, to: current)
    }

    // MARK: Yazma

    public func deductUsage(durationSeconds: Double, lane: QuotaLane, now: Date = Date()) throws {
        let currentBalance = getRemainingSeconds(lane, now: now)
        guard currentBalance >= durationSeconds else {
            throw AuraError.insufficientQuota(
                requiredSeconds: durationSeconds,
                availableSeconds: currentBalance,
                lane: lane
            )
        }
        guard storage.writeBalanceSeconds(currentBalance - durationSeconds, lane: lane) else {
            throw AuraError.quotaStorageUnavailable
        }
    }

    /// Tek havuza dakika ekler — imzalı bilet ve mağaza doğrulaması bunu çağırıyor.
    @discardableResult
    public func addMinutes(_ minutes: Double, lane: QuotaLane, now: Date = Date()) -> Bool {
        storage.writeBalanceSeconds(
            getRemainingSeconds(lane, now: now) + (minutes * 60.0),
            lane: lane
        )
    }

    /// Abonelik değiştiğinde iki havuzun planını ve dönemi birlikte yazar.
    ///
    /// Sıra önemli: plan → bakiye → dönem. Dönem en sonda, çünkü ondan önceki
    /// bir yazma başarısız olursa dönem ilerlememeli; ilerleseydi kullanıcı o
    /// ayı hiç almamış olurdu.
    @discardableResult
    public func setPlan(offlineMinutes: Double, onlineMinutes: Double, now: Date = Date()) -> Bool {
        // Sözlük değil DİZİ: sözlük üzerinde yineleme sırası belirsiz ve
        // yazma yarıda kaldığında hangi havuzun yazılmış olduğu çalıştırmadan
        // çalıştırmaya değişirdi.
        let values: [(QuotaLane, Double)] = [(.offline, offlineMinutes), (.online, onlineMinutes)]
        for (lane, minutes) in values {
            guard storage.writePlanMinutes(minutes, lane: lane) else { return false }
            guard storage.writeBalanceSeconds(max(0, minutes * 60), lane: lane) else { return false }
        }
        return storage.writePeriodStart(now)
    }

    // MARK: Aylık yenileme

    /// Dönem dolduysa İKİ havuzu da kendi plan dakikasına eşitler.
    ///
    /// Uykuda kalan kullanıcı biriktiremez: kaç ay geçmiş olursa olsun bakiye
    /// TEK dönemlik değere çekilir ve dönem başlangıcı bugüne en yakın sınıra
    /// taşınır.
    ///
    /// Bilinen sınır: cihaz saatini ileri alan kullanıcı erken yenileme
    /// alabilir. Bunun gerçek savunması sunucu tarafı (imzalı dakika bileti,
    /// `SecureTicketStore`); cihazda güvenilir bir saat kaynağı yok. Saati
    /// geriye almak ise işe yaramıyor — dönem başlangıcı asla geri gitmiyor.
    private func renewIfNeeded(now: Date) {
        guard let start = storage.readPeriodStart() else { return }

        let current = Self.currentPeriodStart(anchor: start, now: now, calendar: calendar)
        guard current > start else { return }

        // Önce iki bakiye, sonra dönem. Ters sırada olsaydı bakiye yazımı
        // başarısız olduğunda dönem ilerler ve kullanıcı o ayı kaybederdi.
        // Yazma bakiyeyi ARTIRMIYOR, plan değerine EŞİTLİYOR; yarıda kalıp
        // tekrar denenmesi bu yüzden zararsız.
        for lane in QuotaLane.allCases {
            guard storage.writeBalanceSeconds(planMonthlyMinutes(lane) * 60, lane: lane) else { return }
        }
        storage.writePeriodStart(current)
    }

    /// `anchor`'dan başlayarak `now`u geçmeyen en son ay sınırı.
    static func currentPeriodStart(anchor: Date, now: Date, calendar: Calendar) -> Date {
        guard now > anchor else { return anchor }

        var current = anchor
        // Ay uzunlukları eşit olmadığı için sabit 30 gün eklenemiyor; takvim
        // ayı kullanıcının beklediği davranış.
        while let next = calendar.date(byAdding: .month, value: 1, to: current), next <= now {
            current = next
        }
        return current
    }

    // MARK: Kurulum

    /// İlk açılışta bir kez ücretsiz dakikaları yükler ve ilk dönemi başlatır.
    ///
    /// Sıra önemli: önce bakiyeler yazılıyor, yazma BAŞARILIYSA bayrak konuyor.
    /// Tersi olsaydı (eski hali) Keychain yazımı başarısız olan bir cihazda
    /// hediye bir daha asla verilmezdi — cihaz ilk kilit açılmadan arka planda
    /// başlatıldığında bu gerçekten olabiliyor.
    private func bootstrapIfNeeded(now: Date) {
        guard !storage.isBootstrapped() else { return }

        for lane in QuotaLane.allCases where storage.readBalanceSeconds(lane) == nil {
            guard storage.writeBalanceSeconds(Self.freeMinutes(lane) * 60, lane: lane) else { return }
        }
        guard storage.writePeriodStart(now) else { return }
        storage.markBootstrapped()
    }
}
