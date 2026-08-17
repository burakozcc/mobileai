//
//  CloudCredentials.swift
//  AuraVoice
//
//  Bulut sağlayıcı kimlik bilgilerinin yönetimi.
//
//  ⚠️ GÜVENLİK KARARI — okumadan geçme:
//
//  Sağlayıcı API anahtarını (Anthropic / Groq) uygulama ikilisine gömmek
//  KIRILMIŞ bir tasarımdır. IPA dosyası herkese açıktır; anahtar `strings`
//  ile 10 saniyede çıkarılır ve senin hesabına fatura edilir. Ayrıca
//  RevenueCat ile dakika satıyorsak, anahtar cihazdayken kullanıcı bizim
//  kotamızı tamamen atlayıp doğrudan sağlayıcıya gidebilir — yani ürünün
//  gelir modeli çöker.
//
//  Bu yüzden iki mod destekleniyor:
//
//   1. `.proxy` (VARSAYILAN, üretim) — istek AuraVoice arka ucuna gider;
//      anahtarlar orada durur, kota orada doğrulanır. Cihazda sır yok.
//   2. `.userProvidedKey` (BYOK) — kullanıcı kendi anahtarını girer, kendi
//      hesabından öder. Anahtar yalnızca o kullanıcının Keychain'inde.
//      Güçlü kullanıcılar ve geliştirme için.
//

import Foundation
import Security

public enum CloudProvider: String, Sendable, CaseIterable {
    case anthropic
    case groq

    /// BYOK modunda doğrudan konuşulan ana bilgisayar.
    public var directBaseURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com")!
        case .groq:      return URL(string: "https://api.groq.com/openai")!
        }
    }

    /// Proxy modunda arka uçtaki yol öneki.
    public var proxyPathPrefix: String {
        switch self {
        case .anthropic: return "/v1/proxy/anthropic"
        case .groq:      return "/v1/proxy/groq"
        }
    }
}

public enum CloudRoute: Sendable, Equatable {
    /// Üretim yolu: anahtarlar sunucuda, kota sunucuda doğrulanır.
    case proxy(baseURL: URL)
    /// Kullanıcının kendi anahtarı; Keychain'de saklanır.
    case userProvidedKey
}

// MARK: - Anahtar Deposu

public protocol CloudCredentialStore: Sendable {
    func key(for provider: CloudProvider) -> String?
    @discardableResult func setKey(_ key: String?, for provider: CloudProvider) -> Bool
    /// Proxy modunda kullanıcı oturum jetonu (RevenueCat App User ID'ye bağlı).
    func sessionToken() -> String?
    @discardableResult func setSessionToken(_ token: String?) -> Bool
}

public final class KeychainCredentialStore: CloudCredentialStore {

    private let service: String

    public init(service: String = "com.auravoice.cloud") {
        self.service = service
    }

    public func key(for provider: CloudProvider) -> String? {
        read(account: "provider.\(provider.rawValue)")
    }

    @discardableResult
    public func setKey(_ key: String?, for provider: CloudProvider) -> Bool {
        write(key, account: "provider.\(provider.rawValue)")
    }

    public func sessionToken() -> String? {
        read(account: "session.token")
    }

    @discardableResult
    public func setSessionToken(_ token: String?) -> Bool {
        write(token, account: "session.token")
    }

    // MARK: Keychain

    private func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }

    @discardableResult
    private func write(_ value: String?, account: String) -> Bool {
        let query = baseQuery(account: account)

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = value.data(using: .utf8) else { return false }

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

/// Testler için bellek içi depo.
public final class InMemoryCredentialStore: CloudCredentialStore, @unchecked Sendable {

    private let lock = NSLock()
    private var keys: [String: String] = [:]
    private var token: String?

    public init(keys: [CloudProvider: String] = [:], sessionToken: String? = nil) {
        for (provider, value) in keys { self.keys[provider.rawValue] = value }
        self.token = sessionToken
    }

    public func key(for provider: CloudProvider) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[provider.rawValue]
    }

    @discardableResult
    public func setKey(_ key: String?, for provider: CloudProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        keys[provider.rawValue] = key
        return true
    }

    public func sessionToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    @discardableResult
    public func setSessionToken(_ token: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.token = token
        return true
    }
}

// MARK: - İstek Kurucu

/// Rota ve kimlik bilgisine göre doğru URL ve başlıkları üretir.
public struct CloudRequestBuilder: Sendable {

    public let route: CloudRoute
    private let store: any CloudCredentialStore

    public init(route: CloudRoute, store: any CloudCredentialStore) {
        self.route = route
        self.store = store
    }

    public func makeRequest(
        provider: CloudProvider,
        path: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {

        let url: URL
        // Varsayılan önce, çağıranın başlıkları sonra: multipart isteklerin
        // kendi Content-Type'ı (boundary ile) ezilmesin.
        var headers: [String: String] = ["Content-Type": "application/json"]
        for (field, value) in extraHeaders { headers[field] = value }

        switch route {
        case let .proxy(baseURL):
            url = baseURL
                .appendingPathComponent(provider.proxyPathPrefix)
                .appendingPathComponent(path)
            guard let token = store.sessionToken() else {
                throw AuraError.cloudCredentialsMissing(provider: provider.rawValue)
            }
            // Anahtar değil, kullanıcı oturum jetonu. Kota sunucuda düşülür.
            headers["Authorization"] = "Bearer \(token)"

        case .userProvidedKey:
            url = provider.directBaseURL.appendingPathComponent(path)
            guard let key = store.key(for: provider) else {
                throw AuraError.cloudCredentialsMissing(provider: provider.rawValue)
            }
            switch provider {
            case .anthropic:
                headers["x-api-key"] = key
                headers["anthropic-version"] = "2023-06-01"
            case .groq:
                headers["Authorization"] = "Bearer \(key)"
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    public func hasCredentials(for provider: CloudProvider) -> Bool {
        switch route {
        case .proxy:          return store.sessionToken() != nil
        case .userProvidedKey: return store.key(for: provider) != nil
        }
    }
}
