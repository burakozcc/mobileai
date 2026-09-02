//
//  CloudEngineTests.swift
//  AuraVoiceTests
//
//  Bulut istemcileri `URLProtocol` ile kesilerek uçtan uca test ediliyor:
//  gerçek ağ yok, gerçek anahtar yok, ama gerçek istek kurma / yanıt çözümleme
//  / hata eşleme yolu çalışıyor.
//

import Testing
import Foundation
@testable import AuraVoice

// MARK: - Sahte ağ katmanı

final class MockURLProtocol: URLProtocol {

    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock(); defer { lock.unlock() }
        storedHandler = handler
    }

    static var handler: Handler? {
        lock.lock(); defer { lock.unlock() }
        return storedHandler
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func httpResponse(_ status: Int, url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

// MARK: - İstek kurucu

@Suite("Bulut istek kurucu")
struct CloudRequestBuilderTests {

    @Test("BYOK modunda Anthropic başlıkları doğru kurulur")
    func directAnthropicHeaders() throws {
        let store = InMemoryCredentialStore(keys: [.anthropic: "sk-test-123"])
        let builder = CloudRequestBuilder(route: .userProvidedKey, store: store)

        let request = try builder.makeRequest(provider: .anthropic, path: "v1/messages", body: Data())

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.httpMethod == "POST")
    }

    @Test("BYOK modunda Groq Bearer kullanır")
    func directGroqHeaders() throws {
        let store = InMemoryCredentialStore(keys: [.groq: "gsk-test"])
        let builder = CloudRequestBuilder(route: .userProvidedKey, store: store)

        let request = try builder.makeRequest(provider: .groq, path: "v1/audio/transcriptions", body: Data())

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
        #expect(request.url?.absoluteString.contains("api.groq.com") == true)
    }

    @Test("Proxy modunda sağlayıcı anahtarı DEĞİL oturum jetonu gönderilir")
    func proxyUsesSessionTokenNotProviderKey() throws {
        let store = InMemoryCredentialStore(
            keys: [.anthropic: "sk-should-never-be-sent"],
            sessionToken: "user-session-abc"
        )
        let builder = CloudRequestBuilder(
            route: .proxy(baseURL: URL(string: "https://api.auravoice.app")!),
            store: store
        )

        let request = try builder.makeRequest(provider: .anthropic, path: "v1/messages", body: Data())

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-session-abc")
        // Sağlayıcı anahtarı cihazdan çıkmamalı.
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.url?.absoluteString.hasPrefix("https://api.auravoice.app") == true)
    }

    @Test("Kimlik yoksa açık hata verir")
    func missingCredentialsThrows() {
        let builder = CloudRequestBuilder(route: .userProvidedKey, store: InMemoryCredentialStore())
        #expect(throws: AuraError.cloudCredentialsMissing(provider: "anthropic")) {
            _ = try builder.makeRequest(provider: .anthropic, path: "v1/messages", body: Data())
        }
    }

    @Test("Çağıranın Content-Type'ı ezilmez (multipart için kritik)")
    func extraHeadersOverrideDefaults() throws {
        let store = InMemoryCredentialStore(keys: [.groq: "gsk"])
        let builder = CloudRequestBuilder(route: .userProvidedKey, store: store)

        let request = try builder.makeRequest(
            provider: .groq,
            path: "v1/audio/transcriptions",
            body: Data(),
            extraHeaders: ["Content-Type": "multipart/form-data; boundary=XYZ"]
        )

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=XYZ")
    }
}

// MARK: - HTTP hata eşlemesi

@Suite("Bulut HTTP katmanı")
struct CloudHTTPTests {

    private let url = URL(string: "https://example.test")!

    @Test("401 kimlik doğrulama hatasına eşlenir")
    func mapsAuthError() {
        let error = CloudHTTP.mapError(status: 401, data: Data(), provider: "Anthropic")
        #expect(error == .cloudAuthenticationFailed(provider: "Anthropic"))
    }

    @Test("429 hız sınırına eşlenir")
    func mapsRateLimit() {
        #expect(CloudHTTP.mapError(status: 429, data: Data(), provider: "Groq") == .cloudRateLimited(provider: "Groq"))
    }

    @Test("Anthropic hata gövdesinden mesaj çıkarılır")
    func extractsAnthropicMessage() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens too large"}}"#
        #expect(CloudHTTP.extractMessage(from: Data(body.utf8)) == "max_tokens too large")
    }

    @Test("OpenAI/Groq hata gövdesinden mesaj çıkarılır")
    func extractsGroqMessage() {
        let body = #"{"error":{"message":"file too large","type":"invalid_request_error"}}"#
        #expect(CloudHTTP.extractMessage(from: Data(body.utf8)) == "file too large")
    }

    @Test("retry-after başlığına uyulur")
    func honorsRetryAfter() {
        let response = httpResponse(429, url: url, headers: ["retry-after": "7"])
        #expect(CloudHTTP.backoffSeconds(attempt: 1, response: response) == 7)
    }

    @Test("retry-after yoksa üstel geri çekilme")
    func exponentialBackoff() {
        #expect(CloudHTTP.backoffSeconds(attempt: 1, response: nil) == 1)
        #expect(CloudHTTP.backoffSeconds(attempt: 2, response: nil) == 2)
        #expect(CloudHTTP.backoffSeconds(attempt: 3, response: nil) == 4)
        // Üst sınır
        #expect(CloudHTTP.backoffSeconds(attempt: 10, response: nil) == 8)
    }

    @Test("Aşırı retry-after değeri kırpılır")
    func clampsAbsurdRetryAfter() {
        let response = httpResponse(429, url: url, headers: ["retry-after": "3600"])
        #expect(CloudHTTP.backoffSeconds(attempt: 1, response: response) == 30)
    }
}

// MARK: - ASR

@Suite("Bulut transkripsiyon", .serialized)
struct CloudASRClientTests {

    private func makeClient() -> CloudASRClient {
        CloudASRClient(
            builder: CloudRequestBuilder(
                route: .userProvidedKey,
                store: InMemoryCredentialStore(keys: [.groq: "gsk-test"])
            ),
            session: MockURLProtocol.makeSession(),
            // Testlerde sahte WAV baytları var; AVFoundation'a girmesin.
            preparer: PassthroughUploadPreparer()
        )
    }

    @Test("verbose_json segmentlere ve metne çözümlenir")
    func parsesVerboseJSON() throws {
        let json = """
        {"task":"transcribe","language":"turkish","duration":12.4,
         "text":"Lansman tarihini konuştuk. Karar verildi.",
         "segments":[
           {"id":0,"start":0.0,"end":4.2,"text":" Lansman tarihini konuştuk."},
           {"id":1,"start":4.2,"end":8.1,"text":" Karar verildi."}
         ]}
        """
        let output = try CloudASRClient.parse(Data(json.utf8))

        #expect(output.language == "tr")
        #expect(output.segments.count == 2)
        #expect(output.segments.first?.text == "Lansman tarihini konuştuk.")
        #expect(output.text.contains("Karar verildi"))
    }

    @Test("Dil adı ISO koduna indirgenir", arguments: zip(
        ["turkish", "english", "TR", "", "klingon"],
        ["tr", "en", "tr", "", "kl"]
    ))
    func normalizesLanguage(input: String, expected: String) {
        #expect(CloudASRClient.normalizeLanguage(input.isEmpty ? nil : input) == expected)
    }

    @Test("Boş transkript hata verir, sessizce boş not üretmez")
    func emptyTranscriptThrows() {
        let json = #"{"text":"","language":"turkish","segments":[]}"#
        #expect(throws: AuraError.self) {
            _ = try CloudASRClient.parse(Data(json.utf8))
        }
    }

    @Test("Metin boşsa segmentlerden kurtarılır")
    func recoversTextFromSegments() throws {
        let json = """
        {"text":"","language":"english",
         "segments":[{"start":0,"end":2,"text":"hello there"}]}
        """
        let output = try CloudASRClient.parse(Data(json.utf8))
        #expect(output.text == "hello there")
        #expect(output.language == "en")
    }

    @Test("Multipart gövde alan ve dosya sınırlarını içerir")
    func multipartBodyStructure() throws {
        let body = CloudASRClient.multipartBody(
            boundary: "BOUND",
            fields: ["model": "whisper-large-v3", "response_format": "verbose_json"],
            fileField: "file",
            fileName: "rec.wav",
            mimeType: "audio/wav",
            fileData: Data([0x52, 0x49, 0x46, 0x46])
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.contains("--BOUND\r\n"))
        #expect(text.contains(#"name="model""#))
        #expect(text.contains("whisper-large-v3"))
        #expect(text.contains(#"name="file"; filename="rec.wav""#))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.hasSuffix("--BOUND--\r\n"))
    }

    @Test("Sunucu 401 dönerse kimlik hatası fırlatılır")
    func serverAuthErrorSurfaces() async throws {
        let audioURL = try makeTempAudio(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        MockURLProtocol.setHandler { request in
            (httpResponse(401, url: request.url!), Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        await #expect(throws: AuraError.cloudAuthenticationFailed(provider: "Groq")) {
            _ = try await makeClient().transcribe(audioURL: audioURL, languageHint: nil)
        }
    }

    @Test("Sınırı aşan kayıt sıkıştırılamıyorsa yüklenmeden reddedilir")
    func oversizedAudioRejectedBeforeUpload() async throws {
        let audioURL = try makeTempAudio(bytes: CloudASRClient.maxUploadBytes + 1)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // Handler kurulmadı: istek ağa çıkarsa test zaten patlar.
        MockURLProtocol.setHandler(nil)

        await #expect(throws: AuraError.self) {
            _ = try await makeClient().transcribe(audioURL: audioURL, languageHint: nil)
        }
    }

    private func makeTempAudio(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-test-\(UUID().uuidString).wav")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }
}

// MARK: - LLM

@Suite("Bulut özetleme", .serialized)
struct CloudLLMClientTests {

    private func makeClient() -> CloudLLMClient {
        CloudLLMClient(
            builder: CloudRequestBuilder(
                route: .userProvidedKey,
                store: InMemoryCredentialStore(keys: [.anthropic: "sk-test"])
            ),
            session: MockURLProtocol.makeSession()
        )
    }

    @Test("Varsayılan model güncel bir kimlik — emekli sürüm değil")
    func defaultModelIsCurrent() {
        #expect(AnthropicModel.sonnet5.rawValue == "claude-sonnet-5")
        #expect(AnthropicModel.opus5.rawValue == "claude-opus-5")
        // Emekli kimlikler 404 döner; kimsenin geri koymaması için sabitleniyor.
        for model in AnthropicModel.allCases {
            #expect(!model.rawValue.contains("3-5-sonnet"))
            #expect(!model.rawValue.contains("20241022"))
        }
    }

    @Test("Sistem prompt'u uydurmayı yasaklar")
    func systemPromptForbidsFabrication() {
        let prompt = CloudLLMClient.systemPrompt(
            template: .meetingNotes,
            language: SummaryLanguage(code: "tr")
        )
        #expect(prompt.contains("olmayan hiçbir bilgiyi ekleme"))
        #expect(prompt.contains("Markdown"))
    }

    @Test("Şablona göre iskelet değişir")
    func skeletonVariesByTemplate() {
        let tr = SummaryLanguage(code: "tr")
        #expect(CloudLLMClient.skeleton(for: .meetingNotes, language: tr).contains("Kararlar"))
        #expect(CloudLLMClient.skeleton(for: .meetingNotes, language: tr).contains("Aksiyonlar"))
        #expect(CloudLLMClient.skeleton(for: .phoneCallSummary, language: tr).contains("Görüşme Özeti"))
        #expect(CloudLLMClient.skeleton(for: .quickNotes, language: tr).contains("Hızlı Not"))
        // Hızlı notta karar/aksiyon bölümü yok.
        #expect(!CloudLLMClient.skeleton(for: .quickNotes, language: tr).contains("Kararlar"))
    }

    @Test("İskelet başlıkları deşifrenin dilinden geliyor")
    func skeletonFollowsTranscriptLanguage() {
        // Almanca bir kayıt için modele TÜRKÇE başlıklı bir iskelet
        // gösteriliyordu; kullanıcı Almanca toplantısının özetini "Kararlar"
        // başlığı altında görüyordu.
        let de = CloudLLMClient.skeleton(for: .meetingNotes, language: SummaryLanguage(code: "de"))
        #expect(de.contains("Decisions"))
        #expect(de.contains("Action Items"))
        #expect(!de.contains("Kararlar"))
        #expect(!de.contains("Aksiyonlar"))
    }

    @Test("Türkçe dışındaki dilde sistem prompt'u hedef dili adıyla söyler")
    func systemPromptNamesTargetLanguage() {
        let de = CloudLLMClient.systemPrompt(
            template: .meetingNotes,
            language: SummaryLanguage(code: "de")
        )
        #expect(de.contains("German"))
        #expect(de.contains("Markdown"))
        // Talimatın tamamı İngilizce: Türkçe kurallar sızmamalı.
        #expect(!de.contains("Kurallar"))

        let ja = CloudLLMClient.systemPrompt(
            template: .meetingNotes,
            language: SummaryLanguage(code: "ja")
        )
        #expect(ja.contains("Japanese"))
    }

    @Test("Kullanıcı prompt'u transkripti ve süreyi taşır")
    func userPromptCarriesContext() {
        let prompt = CloudLLMClient.userPrompt(
            transcript: "lansman konuşuldu",
            template: .meetingNotes,
            durationSeconds: 600,
            language: SummaryLanguage(code: "tr")
        )
        #expect(prompt.contains("10 dakika"))
        #expect(prompt.contains("lansman konuşuldu"))
    }

    @Test("Başarılı yanıttan metin çıkarılır")
    func extractsTextFromResponse() async throws {
        MockURLProtocol.setHandler { request in
            let body = """
            {"id":"msg_1","model":"claude-sonnet-5","stop_reason":"end_turn",
             "content":[{"type":"text","text":"### Toplantı Özeti\\n- Karar alındı"}],
             "usage":{"input_tokens":120,"output_tokens":40}}
            """
            return (httpResponse(200, url: request.url!), Data(body.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        let summary = try await makeClient().summarize(
            transcript: "bugün lansmanı konuştuk",
            template: .meetingNotes,
            language: "tr",
            durationSeconds: 300
        )
        #expect(summary.contains("Toplantı Özeti"))
    }

    @Test("refusal HTTP 200 ile gelir — içerik okunmadan yakalanır")
    func handlesRefusalStopReason() async {
        MockURLProtocol.setHandler { request in
            // Gerçek davranış: 200 OK, boş content, stop_reason refusal.
            let body = """
            {"id":"msg_2","model":"claude-sonnet-5","stop_reason":"refusal",
             "stop_details":{"type":"refusal","category":"cyber"},
             "content":[]}
            """
            return (httpResponse(200, url: request.url!), Data(body.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        await #expect(throws: AuraError.cloudRefused(category: "cyber")) {
            _ = try await makeClient().summarize(
                transcript: "bir şey",
                template: .meetingNotes,
                language: "tr",
                durationSeconds: 60
            )
        }
    }

    @Test("max_tokens ile kesilen özet atılmaz, işaretlenir")
    func marksTruncatedSummary() async throws {
        MockURLProtocol.setHandler { request in
            let body = """
            {"id":"msg_3","stop_reason":"max_tokens",
             "content":[{"type":"text","text":"### Özet\\n- Yarım kalan"}]}
            """
            return (httpResponse(200, url: request.url!), Data(body.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        let summary = try await makeClient().summarize(
            transcript: "uzun bir toplantı",
            template: .meetingNotes,
            language: "tr",
            durationSeconds: 3600
        )
        #expect(summary.contains("Yarım kalan"))
        #expect(summary.contains("kısaltıldı"))
    }

    @Test("Boş transkript ağa çıkmadan reddedilir")
    func emptyTranscriptRejectedLocally() async {
        MockURLProtocol.setHandler(nil)
        await #expect(throws: AuraError.self) {
            _ = try await makeClient().summarize(
                transcript: "   \n  ",
                template: .quickNotes,
                language: "tr",
                durationSeconds: 60
            )
        }
    }
}

// MARK: - Boru hattı yedeklemesi

@Suite("Online boru hattı yedeklemesi", .serialized)
struct OnlineProcessingEngineTests {

    /// Her zaman hata veren özetleyici — bulut LLM hatasını taklit eder.
    private struct FailingSummarizer: LocalSummarizer {
        func summarize(_ input: SummarizationInput) async throws -> String {
            throw AuraError.engineFailure("yedek de başarısız")
        }
    }

    @Test("Bulut özetleme çökerse cihaz içi özetle kurtarılır")
    func fallsBackToLocalSummarizer() async throws {
        let store = InMemoryCredentialStore(keys: [.groq: "gsk", .anthropic: "sk"])
        let builder = CloudRequestBuilder(route: .userProvidedKey, store: store)
        let session = MockURLProtocol.makeSession()

        MockURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("transcriptions") {
                let body = """
                {"text":"Lansman tarihinin öne çekilmesine karar verildi. Pazarlama ekibi takvimi güncelleyecek.",
                 "language":"turkish",
                 "segments":[{"start":0,"end":6,"text":"Lansman tarihinin öne çekilmesine karar verildi."}]}
                """
                return (httpResponse(200, url: request.url!), Data(body.utf8))
            }
            // Özetleme çağrısı 500 ile düşer.
            return (httpResponse(500, url: request.url!), Data(#"{"error":{"message":"boom"}}"#.utf8))
        }
        defer { MockURLProtocol.setHandler(nil) }

        let engine = OnlineProcessingEngine(
            asr: CloudASRClient(builder: builder, session: session, preparer: PassthroughUploadPreparer()),
            llm: CloudLLMClient(builder: builder, session: session),
            fallbackSummarizer: ExtractiveSummarizer()
        )

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-fallback-\(UUID().uuidString).wav")
        try Data(repeating: 0x41, count: 512).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await engine.process(request: ProcessingRequest(
            audioFileURL: audioURL,
            durationSeconds: 300,
            mode: .onlineCloudFast,
            summaryTemplate: .meetingNotes
        ))

        // Transkript korunmuş, özet cihaz içi üretilmiş, kullanıcı bilgilendirilmiş.
        #expect(result.rawTranscript.contains("Lansman"))
        #expect(result.summaryMarkdown.contains("###"))
        #expect(result.summaryMarkdown.contains("cihaz içi özet kullanıldı"))
        #expect(result.detectedLanguage == "tr")
    }
}
