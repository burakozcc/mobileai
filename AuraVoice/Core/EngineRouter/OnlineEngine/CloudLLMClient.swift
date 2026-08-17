//
//  CloudLLMClient.swift
//  AuraVoice
//
//  Anthropic Messages API istemcisi (URLSession — Swift için resmî SDK yok).
//
//  MODEL KİMLİĞİ NOTU: Şartnamedeki "Claude 3.5 Sonnet" artık geçerli bir
//  model kimliği değil — `claude-3-5-sonnet-20241022` emekliye ayrıldı ve 404
//  döner. Şartnamenin tercih ettiği katman (hız/maliyet dengeli Sonnet)
//  bugünkü karşılığı `claude-sonnet-5` olduğu için varsayılan o. Daha yüksek
//  kalite gerekirse tek satırda `.opus5`'e geçilir.
//
//  API yüzeyi kritik detaylar (güncel Messages API):
//   • `temperature` / `top_p` / `top_k` ARTIK KABUL EDİLMİYOR → 400.
//     Davranış yönlendirmesi prompt ile yapılır.
//   • `budget_tokens` kaldırıldı → 400. Düşünme derinliği `output_config.effort`.
//   • `stop_reason == "refusal"` HTTP 200 ile gelir; `content` boş olabilir.
//     İçeriği okumadan önce mutlaka kontrol edilir.
//

import Foundation

// MARK: - Model

public enum AnthropicModel: String, Sendable, CaseIterable {
    /// Hız/maliyet dengeli — şartnamedeki Sonnet tercihinin güncel karşılığı.
    case sonnet5 = "claude-sonnet-5"
    /// En yüksek kalite; uzun ve karmaşık toplantılarda tercih edilir.
    case opus5 = "claude-opus-5"
    /// En ucuz ve hızlı; kısa notlar için.
    case haiku45 = "claude-haiku-4-5"

    public var displayName: String {
        switch self {
        case .sonnet5: return "Dengeli (Sonnet)"
        case .opus5:   return "En iyi kalite (Opus)"
        case .haiku45: return "Hızlı (Haiku)"
        }
    }
}

/// Düşünme derinliği / jeton harcaması ayarı.
public enum AnthropicEffort: String, Sendable {
    case low, medium, high
}

// MARK: - İstek / Yanıt Modelleri

private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Thinking: Encodable {
        let type: String
    }
    struct OutputConfig: Encodable {
        let effort: String
    }

    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [Message]
    /// `{"type": "adaptive"}` — sabit jeton bütçesi (`budget_tokens`) kaldırıldı.
    let thinking: Thinking
    let output_config: OutputConfig
}

private struct MessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    struct StopDetails: Decodable {
        let type: String?
        let category: String?
        let explanation: String?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    let id: String?
    let model: String?
    let content: [ContentBlock]
    let stop_reason: String?
    let stop_details: StopDetails?
    let usage: Usage?
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let type: String?
        let message: String?
    }
    let error: APIError?
    let request_id: String?
}

// MARK: - İstemci

public struct CloudLLMClient: Sendable {

    private let builder: CloudRequestBuilder
    private let session: URLSession
    private let model: AnthropicModel
    private let effort: AnthropicEffort
    private let maxTokens: Int

    public init(
        builder: CloudRequestBuilder,
        model: AnthropicModel = .sonnet5,
        effort: AnthropicEffort = .medium,
        // Akış kullanmadığımız için ~16K üstü HTTP zaman aşımı riski taşır.
        maxTokens: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.builder = builder
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.session = session
    }

    public var isConfigured: Bool {
        builder.hasCredentials(for: .anthropic)
    }

    // MARK: Özetleme

    public func summarize(
        transcript: String,
        template: SummaryTemplate,
        language: String,
        durationSeconds: Double
    ) async throws -> String {

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuraError.engineFailure("Özetlenecek transkript boş.")
        }

        let request = MessagesRequest(
            model: model.rawValue,
            max_tokens: maxTokens,
            system: Self.systemPrompt(template: template, language: language),
            messages: [
                .init(
                    role: "user",
                    content: Self.userPrompt(
                        transcript: trimmed,
                        template: template,
                        durationSeconds: durationSeconds
                    )
                )
            ],
            thinking: .init(type: "adaptive"),
            output_config: .init(effort: effort.rawValue)
        )

        let body = try JSONEncoder().encode(request)
        let urlRequest = try builder.makeRequest(
            provider: .anthropic,
            path: "v1/messages",
            body: body
        )

        let data = try await CloudHTTP.perform(urlRequest, session: session, provider: "Anthropic")
        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw AuraError.engineFailure("Anthropic yanıtı çözümlenemedi: \(error.localizedDescription)")
        }

        // Güvenlik sınıflandırıcısı isteği reddettiğinde HTTP 200 döner ama
        // `content` boş gelir — içeriği okumadan önce kontrol şart.
        if decoded.stop_reason == "refusal" {
            let category = decoded.stop_details?.category ?? "belirtilmemiş"
            throw AuraError.cloudRefused(category: category)
        }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw AuraError.engineFailure("Model boş yanıt döndürdü (stop_reason: \(decoded.stop_reason ?? "?")).")
        }

        if decoded.stop_reason == "max_tokens" {
            // Kesilen özeti atmak yerine uyarı ekliyoruz; kullanıcı en azından
            // elde edilen kısmı görsün.
            return text + "\n\n_(Özet jeton sınırına takıldı ve kısaltıldı.)_"
        }
        return text
    }

    // MARK: Prompt

    static func systemPrompt(template: SummaryTemplate, language: String) -> String {
        let isTurkish = language.isEmpty || language.lowercased().hasPrefix("tr")
        let outputLanguage = isTurkish ? "Türkçe" : "kaydın dili"

        return """
        Sen bir toplantı notu editörüsün. Sana konuşmaya dönüştürülmüş ham bir \
        transkript verilir; görevin onu okunabilir bir özete çevirmek.

        Kurallar:
        - Yanıtı \(outputLanguage) yaz.
        - Yalnızca Markdown döndür. Giriş cümlesi, açıklama veya "İşte özet" \
        gibi ön söz yazma.
        - Transkriptte olmayan hiçbir bilgiyi ekleme. Emin olmadığın bir isim \
        veya sayıyı yazmaktansa atla.
        - Konuşma tanıma hataları olabilir; bağlamdan anlaşılan bariz hataları \
        düzelt, anlaşılmayanları uydurma.
        - Aksiyon maddelerini `- [ ]` biçiminde yaz ve mümkünse sorumluyu belirt.
        - Boş bölüm başlığı bırakma; içeriği olmayan bölümü tamamen çıkar.
        """
    }

    static func userPrompt(
        transcript: String,
        template: SummaryTemplate,
        durationSeconds: Double
    ) -> String {
        let minutes = max(1, Int((durationSeconds / 60).rounded()))
        return """
        Kayıt süresi: \(minutes) dakika.
        İstenen çıktı biçimi: \(template.rawValue)

        Şu iskeleti kullan (içeriği olmayan başlıkları at):

        \(Self.skeleton(for: template))

        Transkript:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }

    static func skeleton(for template: SummaryTemplate) -> String {
        switch template {
        case .meetingNotes:
            return """
            ### Toplantı Özeti
            **Ana Başlıklar**
            - …

            **Kararlar**
            - …

            **Aksiyonlar**
            - [ ] … (sorumlu)
            """
        case .phoneCallSummary:
            return """
            ### Görüşme Özeti
            **Konuşulanlar**
            - …

            **Takip Edilecekler**
            - [ ] …
            """
        case .quickNotes:
            return """
            ### Hızlı Not
            **Öne Çıkanlar**
            - …
            """
        }
    }
}
