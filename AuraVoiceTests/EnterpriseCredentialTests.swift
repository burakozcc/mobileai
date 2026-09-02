//
//  EnterpriseCredentialTests.swift
//  AuraVoiceTests
//
//  Kurumsal anahtar yüzeyinin ürün kararına sadık kaldığını doğrular:
//  ayrım YALNIZCA arayüzde, arka planda değil. Anahtar cihaza yazılmıyor
//  ve yetkisiz hesap yüzeyi hiç görmüyor.
//

import Testing
import Foundation
@testable import AuraVoice

// MARK: - Sahteler

/// Sunucu yerine geçen, ne istendiğini kaydeden sahte.
private final class FakeProvisioner: EnterpriseCredentialProvisioning, EnterpriseAccessProviding,
                                     @unchecked Sendable {

    var access: EnterpriseAccess = .unauthorized
    var result: EnterpriseProvisioningResult = .stored(maskedKey: "••••••••ab12")
    var installed: String?
    var thrownError: (any Error)?

    private(set) var submittedKeys: [String] = []
    private(set) var revokedProviders: [CloudProvider] = []

    func currentAccess() async -> EnterpriseAccess { access }

    func submit(key: String, provider: CloudProvider) async throws -> EnterpriseProvisioningResult {
        if let thrownError { throw thrownError }
        submittedKeys.append(key)
        return result
    }

    func installedKeySuffix(provider: CloudProvider) async -> String? { installed }

    func revoke(provider: CloudProvider) async throws {
        if let thrownError { throw thrownError }
        revokedProviders.append(provider)
        installed = nil
    }
}

/// `setKey` çağrılıp çağrılmadığını yakalayan depo.
///
/// Asıl iddia bu: kurucu anahtarı OKUR ve gönderir, ama cihazdaki hiçbir
/// depoya YAZMAZ. Yazsaydı ayrım arka plana sızmış olurdu.
private final class SpyCredentialStore: CloudCredentialStore, @unchecked Sendable {

    private let lock = NSLock()
    private var token: String?
    private(set) var setKeyCalls: [String] = []

    init(sessionToken: String?) { self.token = sessionToken }

    func key(for provider: CloudProvider) -> String? { nil }

    @discardableResult
    func setKey(_ key: String?, for provider: CloudProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        setKeyCalls.append(provider.rawValue)
        return true
    }

    func sessionToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    @discardableResult
    func setSessionToken(_ token: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.token = token
        return true
    }
}

// MARK: - Maskeleme

@Suite("Anahtar maskeleme")
struct EnterpriseKeyMaskTests {

    @Test("Yalnızca son dört karakter gösteriliyor")
    func showsLastFourOnly() {
        let masked = EnterpriseKeyMask.mask("sk-ant-api03-SECRETVALUEab12")
        #expect(masked.hasSuffix("ab12"))
        #expect(!masked.contains("SECRET"))
        #expect(!masked.contains("sk-ant"))
    }

    @Test("Kısa girdide hiç karakter sızmıyor")
    func shortInputLeaksNothing() {
        // 8 karakterden kısa bir şey geçerli anahtar değil; yanlışlıkla başka
        // bir sır yapıştırıldıysa onun kuyruğunu da göstermemeliyiz.
        for candidate in ["", "abc", "1234567"] {
            let masked = EnterpriseKeyMask.mask(candidate)
            #expect(masked == "••••••••")
        }
    }

    @Test("Boşluklar kırpılıyor")
    func trimsWhitespace() {
        #expect(EnterpriseKeyMask.mask("  sk-test-value9999  ").hasSuffix("9999"))
    }
}

// MARK: - Kurucu

@Suite("Kurumsal kurucu yapılandırması")
struct ProxyEnterpriseProvisionerTests {

    @Test("Proxy yoksa özellik hiç var olmuyor")
    func requiresProxyRoute() {
        // BYOK/geliştirme kurulumunda kurumsal yüzey açılamaz: anahtarı
        // gönderecek bir sunucu yok.
        let provisioner = ProxyEnterpriseProvisioner(
            route: .userProvidedKey,
            store: InMemoryCredentialStore()
        )
        #expect(provisioner == nil)
    }

    @Test("Düz metin taban URL reddediliyor")
    func refusesPlaintextBaseURL() {
        // Sır taşıyan uç nokta; `makeDefault` zaten bakıyor ama bu tip başka
        // yerlerden de kurulabiliyor.
        let provisioner = ProxyEnterpriseProvisioner(
            route: .proxy(baseURL: URL(string: "http://api.auravoice.app")!),
            store: InMemoryCredentialStore()
        )
        #expect(provisioner == nil)
    }

    @Test("HTTPS proxy kabul ediliyor")
    func acceptsHTTPSProxy() {
        let provisioner = ProxyEnterpriseProvisioner(
            route: .proxy(baseURL: URL(string: "https://api.auravoice.app")!),
            store: InMemoryCredentialStore()
        )
        #expect(provisioner != nil)
    }
}

// MARK: - Ekran

@MainActor
@Suite("Kurumsal anahtar ekranı")
struct EnterpriseKeyViewModelTests {

    private func makeViewModel(_ fake: FakeProvisioner) -> EnterpriseKeyViewModel {
        EnterpriseKeyViewModel(provisioner: fake, accessProvider: fake)
    }

    @Test("Yetkisiz hesap yüzeyi görmüyor")
    func unauthorizedAccountSeesNothing() async {
        let fake = FakeProvisioner()
        fake.access = .unauthorized
        let viewModel = makeViewModel(fake)

        await viewModel.load()

        #expect(!viewModel.isAvailable)
        #expect(viewModel.installedSuffix == nil)
    }

    @Test("Yetkili hesapta kurum adı ve kayıtlı anahtar geliyor")
    func authorizedAccountLoadsState() async {
        let fake = FakeProvisioner()
        fake.access = EnterpriseAccess(canManageProviderKeys: true, organizationName: "Acme A.Ş.")
        fake.installed = "••••••••cd34"
        let viewModel = makeViewModel(fake)

        await viewModel.load()

        #expect(viewModel.isAvailable)
        #expect(viewModel.access.organizationName == "Acme A.Ş.")
        #expect(viewModel.installedSuffix == "••••••••cd34")
    }

    @Test("Başarılı kayıttan sonra alan temizleniyor")
    func clearsFieldAfterSuccess() async {
        let fake = FakeProvisioner()
        fake.access = EnterpriseAccess(canManageProviderKeys: true, organizationName: nil)
        fake.result = .stored(maskedKey: "••••••••ab12")
        let viewModel = makeViewModel(fake)
        await viewModel.load()

        viewModel.keyInput = "sk-ant-api03-gercek-anahtar-ab12"
        await viewModel.submit()

        // Alan ekranda kalırsa omuz üstünden okunur ya da ekran görüntüsüne düşer.
        #expect(viewModel.keyInput.isEmpty)
        #expect(viewModel.outcome == .saved(masked: "••••••••ab12"))
        #expect(viewModel.installedSuffix == "••••••••ab12")
        #expect(fake.submittedKeys == ["sk-ant-api03-gercek-anahtar-ab12"])
    }

    @Test("Reddedilen anahtar alanda kalıyor")
    func keepsFieldOnRejection() async {
        let fake = FakeProvisioner()
        fake.access = EnterpriseAccess(canManageProviderKeys: true, organizationName: nil)
        fake.result = .rejected("Sağlayıcı anahtarı kabul etmedi.")
        let viewModel = makeViewModel(fake)
        await viewModel.load()

        viewModel.keyInput = "sk-ant-yanlis"
        await viewModel.submit()

        // Temizlenirse satış temsilcisi anahtarı baştan yazmak zorunda kalır.
        #expect(viewModel.keyInput == "sk-ant-yanlis")
        #expect(viewModel.outcome == .failed("Sağlayıcı anahtarı kabul etmedi."))
        #expect(viewModel.installedSuffix == nil)
    }

    @Test("Boş girdi sunucuya hiç gitmiyor")
    func emptyInputNeverReachesServer() async {
        let fake = FakeProvisioner()
        fake.access = EnterpriseAccess(canManageProviderKeys: true, organizationName: nil)
        let viewModel = makeViewModel(fake)
        await viewModel.load()

        viewModel.keyInput = "   \n "
        await viewModel.submit()

        #expect(fake.submittedKeys.isEmpty)
        #expect(viewModel.outcome == .failed("Önce anahtarı gir."))
    }

    @Test("Silme sunucuya gidiyor ve durumu sıfırlıyor")
    func revokeClearsState() async {
        let fake = FakeProvisioner()
        fake.access = EnterpriseAccess(canManageProviderKeys: true, organizationName: nil)
        fake.installed = "••••••••ab12"
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        #expect(viewModel.installedSuffix == "••••••••ab12")

        await viewModel.revoke()

        #expect(fake.revokedProviders == [.anthropic])
        #expect(viewModel.installedSuffix == nil)
        #expect(viewModel.outcome == .idle)
    }

    @Test("Sağlayıcı değişince kayıtlı anahtar yeniden okunuyor")
    func providerChangeReloadsSuffix() async {
        let fake = FakeProvisioner()
        fake.access = EnterpriseAccess(canManageProviderKeys: true, organizationName: nil)
        fake.installed = "••••••••ab12"
        let viewModel = makeViewModel(fake)
        await viewModel.load()

        fake.installed = "••••••••ef56"
        viewModel.provider = .groq
        await viewModel.providerChanged()

        #expect(viewModel.installedSuffix == "••••••••ef56")
        #expect(viewModel.outcome == .idle)
    }
}

// MARK: - Cihaza yazmama

@Suite("Kurumsal anahtar cihaza yazılmıyor", .serialized)
struct EnterpriseKeyStaysOffDeviceTests {

    /// Ürün kararının ÇEKİRDEĞİ: kurumsal/bireysel ayrımı yalnızca arayüzde.
    /// Anahtar Keychain'e yazılsaydı ayrım arka plana sızardı ve cihaz
    /// doğrudan sağlayıcıya gidebilirdi — kota sunucuda düşmezdi.
    @Test("Gönderim sırasında setKey hiç çağrılmıyor")
    func submitNeverPersistsKey() async throws {
        let store = SpyCredentialStore(sessionToken: "oturum-jetonu")
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"masked":"••••••••ab12"}"#.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        let provisioner = try #require(ProxyEnterpriseProvisioner(
            route: .proxy(baseURL: URL(string: "https://api.auravoice.app")!),
            store: store,
            session: MockURLProtocol.makeSession()
        ))

        let result = try await provisioner.submit(
            key: "sk-ant-api03-gizli-deger-ab12",
            provider: .anthropic
        )

        #expect(result == .stored(maskedKey: "••••••••ab12"))
        #expect(store.setKeyCalls.isEmpty)
    }

    @Test("Anahtar gövdede gidiyor, URL'de değil")
    func keyTravelsInBodyNotURL() async throws {
        let store = SpyCredentialStore(sessionToken: "oturum-jetonu")
        let secret = "sk-ant-api03-gizli-deger-ab12"

        // URL'ye sır koymak onu sunucu günlüklerine, proxy günlüklerine ve
        // tarayıcı geçmişine yazmak demek.
        let captured = CapturedRequest()
        MockURLProtocol.setHandler { request in
            captured.store(url: request.url?.absoluteString ?? "",
                           authorization: request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"masked":"••••••••ab12"}"#.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        let provisioner = try #require(ProxyEnterpriseProvisioner(
            route: .proxy(baseURL: URL(string: "https://api.auravoice.app")!),
            store: store,
            session: MockURLProtocol.makeSession()
        ))
        _ = try await provisioner.submit(key: secret, provider: .anthropic)

        #expect(!captured.url.contains(secret))
        #expect(captured.url.contains("v1/org/credentials"))
        // Kimlik doğrulama oturum jetonuyla; sağlayıcı anahtarıyla değil.
        #expect(captured.authorization == "Bearer oturum-jetonu")
    }
}

/// Sahte ağ katmanından ana teste veri taşıyan küçük kutu.
private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _url = ""
    private var _authorization: String?

    func store(url: String, authorization: String?) {
        lock.lock(); defer { lock.unlock() }
        _url = url
        _authorization = authorization
    }

    var url: String {
        lock.lock(); defer { lock.unlock() }
        return _url
    }

    var authorization: String? {
        lock.lock(); defer { lock.unlock() }
        return _authorization
    }
}
