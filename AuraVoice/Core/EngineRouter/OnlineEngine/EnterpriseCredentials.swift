//
//  EnterpriseCredentials.swift
//  AuraVoice
//
//  Kurumsal müşterinin sağlayıcı anahtarının SUNUCUYA iletilmesi.
//
//  ⚠️ ÜRÜN KARARI — okumadan değiştirme:
//
//  Kurumsal/bireysel ayrımı bir ARAYÜZ ayrımıdır, arka planda bir ayrım
//  DEĞİLDİR. Uygulama her iki durumda da yalnızca AuraVoice proxy'siyle
//  konuşur. Satış temsilcisi kurumsal müşterinin anahtarını bu yüzeyden
//  girer; anahtar sunucuya gider ve orada KURUMA bağlı olarak saklanır.
//  Uygulama sadece giriş yüzeyidir, anahtarın deposu değildir.
//
//  Buradan `CloudRoute.userProvidedKey`e geçmek cazip görünüyor ama yanlış
//  olurdu: o zaman cihaz doğrudan sağlayıcıya giderdi, dakika kotası
//  sunucuda düşmezdi ve "yalnızca arayüz" olması gereken ayrım gerçekten
//  arka plana sızardı. Bireysel kullanıcıda kendi anahtarını getir kurgusu
//  yok; bu yüzey onlara hiç görünmüyor.
//
//  Anahtar cihazda HİÇBİR yere yazılmıyor: Keychain'e değil, UserDefaults'a
//  değil, günlüğe değil. Gövdede gidiyor, URL'de değil.
//

import Foundation

// MARK: - Erişim

/// Bu hesabın kurumsal anahtar yönetebilip yönetemediği.
///
/// Kaynağı SUNUCU. İstemci tarafında bir bayrakla karar verilseydi, ekranı
/// açmak için uygulamayı kurcalamak yeterdi.
public struct EnterpriseAccess: Sendable, Equatable {

    public let canManageProviderKeys: Bool
    /// Ekranda gösterilecek kurum adı; yetki yoksa nil.
    public let organizationName: String?

    public init(canManageProviderKeys: Bool, organizationName: String?) {
        self.canManageProviderKeys = canManageProviderKeys
        self.organizationName = organizationName
    }

    /// Yetkisiz. Sunucuya ulaşılamadığında da bu dönüyor — kapalı tarafa
    /// düşmek doğru: erişim belirsizken yüzeyi açmak, yetkisiz birine
    /// kurumun anahtar alanını göstermek demek.
    public static let unauthorized = EnterpriseAccess(
        canManageProviderKeys: false,
        organizationName: nil
    )
}

public protocol EnterpriseAccessProviding: Sendable {
    func currentAccess() async -> EnterpriseAccess
}

// MARK: - Anahtar iletimi

public enum EnterpriseProvisioningResult: Sendable, Equatable {
    /// Sunucu anahtarı kabul etti. Yalnızca maskeli kuyruk geri geliyor.
    case stored(maskedKey: String)
    /// Sunucu reddetti (geçersiz anahtar, yetkisiz hesap, kota vb.).
    case rejected(String)
}

public protocol EnterpriseCredentialProvisioning: Sendable {
    /// Anahtarı sunucuya iletir. Hiçbir koşulda cihaza yazmaz.
    func submit(key: String, provider: CloudProvider) async throws -> EnterpriseProvisioningResult
    /// Kurum için o sağlayıcıda kayıtlı bir anahtar var mı (maskeli kuyruk).
    func installedKeySuffix(provider: CloudProvider) async -> String?
    /// Kayıtlı anahtarı siler.
    func revoke(provider: CloudProvider) async throws
}

// MARK: - Proxy uygulaması

/// Sunucu sözleşmesi:
///
///   POST   {base}/v1/org/credentials   {"provider":"anthropic","key":"..."}
///          -> 200 {"masked":"••••••••ab12"} | 4xx {"error":"..."}
///   GET    {base}/v1/org/credentials   -> 200 {"anthropic":"••••••••ab12"}
///   DELETE {base}/v1/org/credentials/{provider} -> 204
///   GET    {base}/v1/org/access
///          -> 200 {"canManageProviderKeys":true,"organizationName":"..."}
///
/// Hepsi `Authorization: Bearer <oturum jetonu>` istiyor. Arka uç henüz
/// yazılmadı; sözleşme burada sabitlendiği için sunucu tarafı bunu
/// karşılamak zorunda.
public struct ProxyEnterpriseProvisioner: EnterpriseCredentialProvisioning, EnterpriseAccessProviding {

    private let baseURL: URL
    private let store: any CloudCredentialStore
    private let session: URLSession

    /// Proxy yapılandırılmamışsa (geliştirme/BYOK) nil döner: kurumsal
    /// yüzey o kurulumda hiç var olmuyor.
    public init?(route: CloudRoute, store: any CloudCredentialStore, session: URLSession = .shared) {
        guard case let .proxy(baseURL) = route else { return nil }
        // Sır taşıyan bir uç nokta: taban URL'yi burada BİR KEZ DAHA
        // doğruluyoruz. `makeDefault` zaten bakıyor ama bu tip başka
        // yerlerden de kurulabilir ve düz metin http kabul edilemez.
        guard baseURL.scheme?.lowercased() == "https" else { return nil }
        self.baseURL = baseURL
        self.store = store
        self.session = session
    }

    // MARK: Erişim

    public func currentAccess() async -> EnterpriseAccess {
        guard let request = try? makeRequest(path: "v1/org/access", method: "GET", body: nil),
              let data = try? await CloudHTTP.perform(
                  request, session: session, provider: "AuraVoice", maxAttempts: 1
              ),
              let decoded = try? JSONDecoder().decode(AccessResponse.self, from: data)
        else { return .unauthorized }

        return EnterpriseAccess(
            canManageProviderKeys: decoded.canManageProviderKeys,
            organizationName: decoded.organizationName
        )
    }

    // MARK: Anahtar

    public func submit(key: String, provider: CloudProvider) async throws -> EnterpriseProvisioningResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected("Anahtar boş.")
        }

        let body = try JSONEncoder().encode(
            SubmitRequest(provider: provider.rawValue, key: trimmed)
        )
        let request = try makeRequest(path: "v1/org/credentials", method: "POST", body: body)

        do {
            let data = try await CloudHTTP.perform(
                request, session: session, provider: "AuraVoice", maxAttempts: 1
            )
            let decoded = try JSONDecoder().decode(SubmitResponse.self, from: data)
            return .stored(maskedKey: decoded.masked)
        } catch let error as AuraError {
            // Hata metni sunucudan geliyor ve anahtarı ASLA içermiyor;
            // yankılamadığımızı sözleşmede sabitledik.
            return .rejected(error.errorDescription ?? "Anahtar kaydedilemedi.")
        } catch is DecodingError {
            // Ham `DecodingError` metnini kullanıcıya göstermek işe yaramaz.
            return .rejected("Sunucu yanıtı çözümlenemedi.")
        }
    }

    public func installedKeySuffix(provider: CloudProvider) async -> String? {
        guard let request = try? makeRequest(path: "v1/org/credentials", method: "GET", body: nil),
              let data = try? await CloudHTTP.perform(
                  request, session: session, provider: "AuraVoice", maxAttempts: 1
              ),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return decoded[provider.rawValue]
    }

    public func revoke(provider: CloudProvider) async throws {
        let request = try makeRequest(
            path: "v1/org/credentials/\(provider.rawValue)",
            method: "DELETE",
            body: nil
        )
        _ = try await CloudHTTP.perform(
            request, session: session, provider: "AuraVoice", maxAttempts: 1
        )
    }

    // MARK: Ortak

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let token = store.sessionToken() else {
            throw AuraError.cloudCredentialsMissing(provider: "AuraVoice")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private struct SubmitRequest: Encodable {
        let provider: String
        let key: String
    }

    private struct SubmitResponse: Decodable {
        let masked: String
    }

    private struct AccessResponse: Decodable {
        let canManageProviderKeys: Bool
        let organizationName: String?
    }
}

// MARK: - Maskeleme

public enum EnterpriseKeyMask {

    /// Anahtarın yalnızca son dört karakterini gösterir.
    ///
    /// Kısa girdide hiç karakter sızdırmıyoruz: 8 karakterden kısa bir şey
    /// zaten geçerli bir anahtar değil, ama yanlışlıkla başka bir sır
    /// yapıştırıldıysa onun kuyruğunu da göstermeyelim.
    public static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return String(repeating: "•", count: 8) }
        return String(repeating: "•", count: 8) + trimmed.suffix(4)
    }
}
