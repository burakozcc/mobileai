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
}

// MARK: - Keychain Uygulaması

public final class KeychainQuotaStorage: QuotaStorage {

    private let service: String
    private let quotaKey = "remaining_seconds_balance"
    private let bootstrapKey = "free_grant_issued_v1"

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

    public func isBootstrapped() -> Bool {
        read(key: bootstrapKey) != nil
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

    public init(initialSeconds: Double? = nil, bootstrapped: Bool = false) {
        self.balance = initialSeconds
        self.bootstrapped = bootstrapped
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
}

// MARK: - Yönetici

public final class QuotaManager: Sendable {

    public static let shared = QuotaManager(storage: KeychainQuotaStorage())

    /// Ücretsiz plan ilk kurulum hediyesi: 30 dakika.
    public static let freeTierSeconds: Double = 30 * 60

    private let storage: any QuotaStorage

    public init(storage: any QuotaStorage) {
        self.storage = storage
    }

    // MARK: Okuma

    public func getRemainingSeconds() -> Double {
        bootstrapIfNeeded()
        return max(0, storage.readBalanceSeconds() ?? 0)
    }

    public func getRemainingMinutes() -> Double {
        getRemainingSeconds() / 60.0
    }

    public func canProcess(durationSeconds: Double) -> Bool {
        getRemainingSeconds() >= durationSeconds
    }

    // MARK: Yazma

    public func deductUsage(durationSeconds: Double) throws {
        let currentBalance = getRemainingSeconds()
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
    public func resetBalance(toMinutes minutes: Double) -> Bool {
        storage.writeBalanceSeconds(max(0, minutes * 60.0))
    }

    // MARK: Kurulum

    /// İlk açılışta bir kez ücretsiz dakikaları yükler. Bayrak ayrı bir kayıtta
    /// tutulur; bakiye silinse bile hediye tekrar verilmez (kota manipülasyonuna
    /// karşı ilk savunma hattı — imzalı bilet doğrulaması bunun üstüne gelecek).
    private func bootstrapIfNeeded() {
        guard !storage.isBootstrapped() else { return }
        storage.markBootstrapped()
        if storage.readBalanceSeconds() == nil {
            storage.writeBalanceSeconds(Self.freeTierSeconds)
        }
    }
}
