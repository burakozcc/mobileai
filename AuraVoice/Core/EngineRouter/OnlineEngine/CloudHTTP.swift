//
//  CloudHTTP.swift
//  AuraVoice
//
//  Bulut istekleri için ortak taşıma katmanı: durum kodu eşlemesi, sunucunun
//  `retry-after` başlığına saygılı yeniden deneme ve okunabilir hata mesajları.
//

import Foundation

public enum CloudHTTP {

    /// Yeniden denenebilir durumlar: hız sınırı, geçici sunucu hataları.
    static let retryableStatusCodes: Set<Int> = [408, 409, 429, 500, 502, 503, 504, 529]

    public static let maxAttempts = 3

    @discardableResult
    public static func perform(
        _ request: URLRequest,
        session: URLSession,
        provider: String,
        maxAttempts: Int = maxAttempts
    ) async throws -> Data {

        var lastError: Error = AuraError.engineFailure("\(provider): istek gönderilemedi.")

        for attempt in 1...max(1, maxAttempts) {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AuraError.engineFailure("\(provider): beklenmeyen yanıt tipi.")
                }

                if (200..<300).contains(http.statusCode) {
                    return data
                }

                let error = mapError(status: http.statusCode, data: data, provider: provider)

                guard retryableStatusCodes.contains(http.statusCode), attempt < maxAttempts else {
                    throw error
                }
                lastError = error
                let delay = backoffSeconds(attempt: attempt, response: http)
                try await Task.sleep(for: .seconds(delay))

            } catch let error as AuraError {
                // Yeniden denenmeyecek hatalar doğrudan yukarı çıkar.
                throw error
            } catch let urlError as URLError {
                let mapped: AuraError = switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                    .networkUnavailable
                case .timedOut:
                    .engineFailure("\(provider): istek zaman aşımına uğradı.")
                default:
                    .engineFailure("\(provider): ağ hatası — \(urlError.localizedDescription)")
                }
                guard attempt < maxAttempts, urlError.code != .notConnectedToInternet else {
                    throw mapped
                }
                lastError = mapped
                try await Task.sleep(for: .seconds(backoffSeconds(attempt: attempt, response: nil)))
            }
        }

        throw lastError
    }

    // MARK: Hata eşlemesi

    static func mapError(status: Int, data: Data, provider: String) -> AuraError {
        let detail = extractMessage(from: data) ?? "HTTP \(status)"

        switch status {
        case 401, 403:
            return .cloudAuthenticationFailed(provider: provider)
        case 413:
            return .engineFailure("\(provider): istek çok büyük. Kayıt parçalanmalı.")
        case 429:
            return .cloudRateLimited(provider: provider)
        case 500...599:
            return .engineFailure("\(provider) geçici olarak hizmet veremiyor (\(status)). Offline moda geçebilirsin.")
        default:
            return .engineFailure("\(provider): \(detail)")
        }
    }

    /// Hem Anthropic (`{"error": {"message": …}}`) hem Groq/OpenAI biçimini okur.
    static func extractMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }

    /// Sunucu `retry-after` verdiyse ona uyar, yoksa üstel geri çekilme.
    static func backoffSeconds(attempt: Int, response: HTTPURLResponse?) -> Double {
        if let header = response?.value(forHTTPHeaderField: "retry-after"),
           let seconds = Double(header), seconds > 0 {
            return min(seconds, 30)
        }
        return min(pow(2.0, Double(attempt - 1)), 8)
    }
}
