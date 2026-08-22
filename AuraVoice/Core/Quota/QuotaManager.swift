//
//  QuotaManager.swift
//  AuraVoice
//
//  Dakika bakiyesi yönetimi.
//
//  Depolama enjekte edilebilir: üretimde Keychain, testte bellek içi. Bu ayrım
//  CI'da ortaya çıkan gerçek bir hatadan doğdu — eski sürüm `SecItemAdd`/
//  `SecItemUpdate` dönüş kodlarını yok sayıyordu, yazma başarısız olduğunda
//  kullanıcının bakiyesi sessizce sıfırlanıyordu.
//

import Foundation
import Security

// MARK: - Depolama Sözleşmesi

public protocol QuotaStorage: Sendable {
    func readBalanceSeconds() -> Double?
    /// `false` → yazma başarısız; çağıran bunu kullanıcıya yansıtmalı.
    @discardableResult func writeBalanceSeconds(_ seconds: Double) -> Bool
    func isBootstrapped() -> Bool
    @discardableResult func markBootstrapped() -> Bool

    /// İçinde bulunulan kota döneminin başlangıcı. Aylık yenileme buna dayanıyor.
    func readPeriodStart() -> Date?
    @discardableResult func writePeriodStart(_ date: Date) -> Bool

    /// Yürürlükteki planın aylık dakikası. Yenilemede bakiye buna eşitleniyor.
    func readPlanMinutes() -> Double?
    @discardableResult func writePlanMinutes(_ minutes: Double) -> Bool
}

// MARK: - Keychain Uygulaması

public final class KeychainQuotaStorage: QuotaStorage {

    private let service: String
    private let quotaKey = "remaining_seconds_balance"
    private let bootstrapKey = "free_grant_issued_v1"
    private let periodKey = "quota_period_start_epoch"
    private let planKey = "quota_plan_monthly_minutes"

    public init(service: String = "com.auravoice.quota") {
        self.service = service
    }

    public func readBalanceSeconds() -> Double? {
        guard let data = read(key: quotaKey),
              let text = String(data: data, encoding: .utf8),
              let value = Double(text)
        else { return nil }
        return value
    }

    @discardableResult
    public func writeBalanceSeconds(_ seconds: Double) -> Bool {
        let rounded = (max(0, seconds) * 1000).rounded() / 1000
        guard let data = "\(rounded)".data(using: .utf8) else { return false }
        return write(data, key: quotaKey)
    }

    public func readPeriodStart() -> Date? {
        guard let value = readDouble(key: periodKey) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    @discardableResult
    public func writePeriodStart(_ date: Date) -> Bool {
        writeDouble(date.timeIntervalSince1970, key: periodKey)
    }

    public func readPlanMinutes() -> Double? {
        readDouble(key: planKey)
    }

    @discardableResult
    public func writePlanMinutes(_ minutes: Double) -> Bool {
        writeDouble(max(0, minutes), key: planKey)
    }

    public func isBootstrapped() -> Bool {
        read(key: bootstrapKey) != nil
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

    @discardableResult
    public func markBootstrapped() -> Bool {
        write(Data([1]), key: bootstrapKey)
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
    private var balance: Double?
    private var bootstrapped: Bool
    private var periodStart: Date?
    private var planMinutes: Double?

    public init(
        initialSeconds: Double? = nil,
        bootstrapped: Bool = false,
        periodStart: Date? = nil,
        planMinutes: Double? = nil
    ) {
        self.balance = initialSeconds
        self.bootstrapped = bootstrapped
        self.periodStart = periodStart
        self.planMinutes = planMinutes
    }

    public func readBalanceSeconds() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return balance
    }

    @discardableResult
    public func writeBalanceSeconds(_ seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        balance = max(0, seconds)
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

    public func readPlanMinutes() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return planMinutes
    }

    @discardableResult
    public func writePlanMinutes(_ minutes: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        planMinutes = max(0, minutes)
        return true
    }
}

// MARK: - Yönetici

public final class QuotaManager: Sendable {

    public static let shared = QuotaManager(storage: KeychainQuotaStorage())

    /// Ücretsiz planın AYLIK dakikası.
    public static let freeTierMinutes: Double = 30
    public static let freeTierSeconds: Double = freeTierMinutes * 60

    private let storage: any QuotaStorage
    private let calendar: Calendar

    public init(storage: any QuotaStorage, calendar: Calendar = .current) {
        self.storage = storage
        self.calendar = calendar
    }

    // MARK: Okuma

    public func getRemainingSeconds(now: Date = Date()) -> Double {
        bootstrapIfNeeded(now: now)
        renewIfNeeded(now: now)
        return max(0, storage.readBalanceSeconds() ?? 0)
    }

    public func getRemainingMinutes(now: Date = Date()) -> Double {
        getRemainingSeconds(now: now) / 60.0
    }

    public func canProcess(durationSeconds: Double, now: Date = Date()) -> Bool {
        getRemainingSeconds(now: now) >= durationSeconds
    }

    /// Yürürlükteki planın aylık dakikası. Plan yazılmamışsa ücretsiz plan.
    public func planMonthlyMinutes() -> Double {
        storage.readPlanMinutes() ?? Self.freeTierMinutes
    }

    /// Bakiyenin bir sonraki yenileneceği an — paywall ve panel bunu gösteriyor.
    public func nextRenewalDate(now: Date = Date()) -> Date? {
        bootstrapIfNeeded(now: now)
        guard let start = storage.readPeriodStart() else { return nil }
        let current = Self.currentPeriodStart(anchor: start, now: now, calendar: calendar)
        return calendar.date(byAdding: .month, value: 1, to: current)
    }

    // MARK: Yazma

    public func deductUsage(durationSeconds: Double, now: Date = Date()) throws {
        let currentBalance = getRemainingSeconds(now: now)
        guard currentBalance >= durationSeconds else {
            throw AuraError.insufficientQuota(
                requiredSeconds: durationSeconds,
                availableSeconds: currentBalance
            )
        }
        guard storage.writeBalanceSeconds(currentBalance - durationSeconds) else {
            throw AuraError.quotaStorageUnavailable
        }
    }

    @discardableResult
    public func addMinutesFromSubscription(_ minutes: Double) -> Bool {
        storage.writeBalanceSeconds(getRemainingSeconds() + (minutes * 60.0))
    }

    /// RevenueCat yenileme döngüsünde bakiyeyi plan kotasına eşitler.
    @discardableResult
    public func resetBalance(toMinutes minutes: Double, now: Date = Date()) -> Bool {
        setPlan(monthlyMinutes: minutes, now: now)
    }

    /// Abonelik değiştiğinde planı ve dönemi birlikte yazar.
    @discardableResult
    public func setPlan(monthlyMinutes: Double, now: Date = Date()) -> Bool {
        guard storage.writePlanMinutes(monthlyMinutes) else { return false }
        guard storage.writeBalanceSeconds(max(0, monthlyMinutes * 60)) else { return false }
        return storage.writePeriodStart(now)
    }

    // MARK: Aylık yenileme

    /// Dönem dolduysa bakiyeyi plan dakikasına eşitler.
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

        // Önce bakiye, sonra dönem. Ters sırada olsaydı bakiye yazımı
        // başarısız olduğunda dönem ilerler ve kullanıcı o ayı kaybederdi.
        guard storage.writeBalanceSeconds(planMonthlyMinutes() * 60) else { return }
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
    /// Sıra önemli: önce bakiye yazılıyor, yazma BAŞARILIYSA bayrak konuyor.
    /// Tersi olsaydı (eski hali) Keychain yazımı başarısız olan bir cihazda
    /// hediye bir daha asla verilmezdi — cihaz ilk kilit açılmadan arka planda
    /// başlatıldığında bu gerçekten olabiliyor.
    private func bootstrapIfNeeded(now: Date) {
        guard !storage.isBootstrapped() else { return }

        if storage.readBalanceSeconds() == nil {
            guard storage.writeBalanceSeconds(Self.freeTierSeconds) else { return }
        }
        guard storage.writePeriodStart(now) else { return }
        storage.markBootstrapped()
    }
}
