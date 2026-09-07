//
//  CloudCredentialValidator.swift
//  AuraVoice
//
//  Girilen kimlik bilgisini KAYDETMEDEN ÖNCE sağlayıcıya sorar.
//
//  "Kaydedildi" demek ucuz ve yanıltıcı: kullanıcı yanlış anahtar girip
//  Ayarlar'da yeşil tik görür, hatayı ancak 40 dakikalık bir toplantıyı
//  kaydettikten sonra öğrenir. Bunun yerine ücretsiz ve jetonsuz olan
//  `GET /v1/models` uç noktasına bir istek atıp gerçekten çalıştığını
//  doğruluyoruz.
//

import Foundation

public enum CredentialValidation: Sendable, Equatable {
    case untested
    case testing
    case valid
    case invalid(String)

    public var isValid: Bool { self == .valid }
}

public extension CloudRequestBuilder {

    /// Sağlayıcının model listesi uç noktasına kimlik doğrulama isteği.
    func makeValidationRequest(provider: CloudProvider) throws -> URLRequest {
        // Her iki sağlayıcı da OpenAI uyumlu `v1/models` sunuyor; taban URL
        // farkı `directBaseURL` içinde zaten çözülmüş durumda.
        try makeRequest(provider: provider, path: "v1/models", body: nil, method: "GET")
    }
}

public struct CloudCredentialValidator: Sendable {

    private let builder: CloudRequestBuilder
    private let session: URLSession

    public init(builder: CloudRequestBuilder, session: URLSession = .shared) {
        self.builder = builder
        self.session = session
    }

    /// Sağlayıcıya ulaşıp kimliğin kabul edildiğini doğrular.
    public func validate(provider: CloudProvider) async -> CredentialValidation {
        do {
            let request = try builder.makeValidationRequest(provider: provider)
            // Doğrulama kullanıcı beklerken yapılıyor: tek deneme, geri çekilme yok.
            _ = try await CloudHTTP.perform(
                request,
                session: session,
                provider: provider.rawValue,
                maxAttempts: 1
            )
            return .valid
        } catch let error as AuraError {
            return .invalid(error.errorDescription ?? String(localized: "Doğrulanamadı"))
        } catch {
            return .invalid(error.localizedDescription)
        }
    }
}

// MARK: - Varsayılan Rota

public extension CloudRoute {

    /// Info.plist'te `AuraCloudProxyBaseURL` tanımlıysa proxy, değilse BYOK.
    ///
    /// Tek doğruluk kaynağı: hem işleme motoru hem Ayarlar ekranı buradan
    /// okur, aksi halde ikisi farklı moda düşüp kullanıcıyı yanıltabilir.
    static func makeDefault(bundle: Bundle = .main) -> CloudRoute {
        if let raw = bundle.object(forInfoDictionaryKey: "AuraCloudProxyBaseURL") as? String,
           let url = URL(string: raw), url.scheme == "https" {
            return .proxy(baseURL: url)
        }
        return .userProvidedKey
    }

    /// Kullanıcı kendi anahtarını girmek zorunda mı?
    var requiresUserKeys: Bool {
        if case .userProvidedKey = self { return true }
        return false
    }
}
