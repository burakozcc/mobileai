//
//  QuotaManager.swift
//  AuraVoice
//
//  Keychain tabanlı dakika bakiyesi yönetimi.
//
//  NOT (Swift 6): Şablondaki sürüme göre iki değişiklik yapıldı:
//   1. `@unchecked Sendable` — `static let shared` strict concurrency altında
//      Sendable olmayan bir tipte derlenmez. Sınıfın saklanan mutable durumu yok;
//      tüm durum Keychain'de ve Keychain API'leri thread-safe.
//   2. Okuma sırasında yazma (free grant) ayrı bir `bootstrapIfNeeded()` çağrısına
//      taşındı; getter'ın yan etkisi kaldırıldı.
//

import Foundation
import Security

public final class QuotaManager: @unchecked Sendable {

    public static let shared = QuotaManager()

    private let keychainService = "com.auravoice.quota"
    private let quotaKey = "remaining_seconds_balance"
    private let bootstrapKey = "free_grant_issued_v1"

    /// Ücretsiz plan ilk kurulum hediyesi: 30 dakika.
    public static let freeTierSeconds: Double = 30 * 60

    private init() {}

    // MARK: - Okuma

    public func getRemainingSeconds() -> Double {
        bootstrapIfNeeded()
        return max(0, readBalanceSeconds() ?? 0)
    }

    public func getRemainingMinutes() -> Double {
        getRemainingSeconds() / 60.0
    }

    public func canProcess(durationSeconds: Double) -> Bool {
        getRemainingSeconds() >= durationSeconds
    }

    // MARK: - Yazma

    public func deductUsage(durationSeconds: Double) throws {
        let currentBalance = getRemainingSeconds()
        guard currentBalance >= durationSeconds else {
            throw AuraError.insufficientQuota(
                requiredSeconds: durationSeconds,
                availableSeconds: currentBalance
            )
        }
        saveBalanceSeconds(currentBalance - durationSeconds)
    }

    public func addMinutesFromSubscription(_ minutes: Double) {
        let currentBalance = getRemainingSeconds()
        saveBalanceSeconds(currentBalance + (minutes * 60.0))
    }

    /// RevenueCat yenileme döngüsünde bakiyeyi plan kotasına eşitler.
    public func resetBalance(toMinutes minutes: Double) {
        saveBalanceSeconds(max(0, minutes * 60.0))
    }

    // MARK: - Kurulum

    /// İlk açılışta bir kez ücretsiz dakikaları yükler.
    /// Bayrak ayrı bir Keychain kaydında tutulur; bakiye silinse bile
    /// hediye tekrar verilmez (kota manipülasyonuna karşı ilk savunma hattı).
    private func bootstrapIfNeeded() {
        guard readData(forKey: bootstrapKey) == nil else { return }
        writeData(Data([1]), forKey: bootstrapKey)
        if readBalanceSeconds() == nil {
            saveBalanceSeconds(Self.freeTierSeconds)
        }
    }

    // MARK: - Keychain

    private func readBalanceSeconds() -> Double? {
        guard let data = readData(forKey: quotaKey),
              let text = String(data: data, encoding: .utf8),
              let value = Double(text)
        else { return nil }
        return value
    }

    private func saveBalanceSeconds(_ balance: Double) {
        let rounded = (max(0, balance) * 1000).rounded() / 1000
        guard let data = "\(rounded)".data(using: .utf8) else { return }
        writeData(data, forKey: quotaKey)
    }

    private func readData(forKey key: String) -> Data? {
        var query = keychainQuery(forKey: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func writeData(_ data: Data, forKey key: String) {
        let query = keychainQuery(forKey: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)

        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func keychainQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}
