//
//  ProcessingProtocol.swift
//  AuraVoice
//
//  Online / Offline motorların ortak sözleşmesi ve veri modelleri.
//

import Foundation

public enum ProcessingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case offlineZeroCloud = "OFFLINE_ZERO_CLOUD"
    case onlineCloudFast = "ONLINE_CLOUD_FAST"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .offlineZeroCloud: return "Offline"
        case .onlineCloudFast:  return "Online"
        }
    }

    public var subtitle: String {
        switch self {
        case .offlineZeroCloud: return "Cihaz içi · Zero-Cloud"
        case .onlineCloudFast:  return "Bulut · Yüksek hız"
        }
    }

    public var systemImage: String {
        switch self {
        case .offlineZeroCloud: return "lock.shield.fill"
        case .onlineCloudFast:  return "bolt.horizontal.fill"
        }
    }

    /// Kullanıcıya gizlilik vaadini net anlatan tek satır.
    public var privacyStatement: String {
        switch self {
        case .offlineZeroCloud:
            return "Ses ve metin cihazdan hiç çıkmaz. Uçuş modunda dahi çalışır."
        case .onlineCloudFast:
            return "Ses şifreli olarak işlenmek üzere buluta gönderilir."
        }
    }
}

public enum SummaryTemplate: String, Codable, CaseIterable, Sendable, Identifiable {
    case meetingNotes = "Toplantı Özeti & Aksiyonlar"
    case phoneCallSummary = "Telefon Görüşmesi Özeti"
    case quickNotes = "Hızlı Not & Fikirler"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .meetingNotes:     return "person.2.fill"
        case .phoneCallSummary: return "phone.fill"
        case .quickNotes:       return "lightbulb.fill"
        }
    }

    /// Kısa etiket (segment kontrolü için).
    public var shortTitle: String {
        switch self {
        case .meetingNotes:     return "Toplantı"
        case .phoneCallSummary: return "Görüşme"
        case .quickNotes:       return "Hızlı Not"
        }
    }
}

public struct ProcessingRequest: Sendable {
    public let audioFileURL: URL
    public let durationSeconds: Double
    public let mode: ProcessingMode
    public let summaryTemplate: SummaryTemplate

    public init(
        audioFileURL: URL,
        durationSeconds: Double,
        mode: ProcessingMode,
        summaryTemplate: SummaryTemplate
    ) {
        self.audioFileURL = audioFileURL
        self.durationSeconds = durationSeconds
        self.mode = mode
        self.summaryTemplate = summaryTemplate
    }
}

public struct ProcessingResult: Sendable {
    public let rawTranscript: String
    public let summaryMarkdown: String
    public let detectedLanguage: String
    public let usedMinutes: Double
    public let processingTimeSeconds: Double
    /// Zaman damgalı transkript parçaları. Motor segment üretmiyorsa boştur.
    public let segments: [TranscriptSegment]

    public init(
        rawTranscript: String,
        summaryMarkdown: String,
        detectedLanguage: String,
        usedMinutes: Double,
        processingTimeSeconds: Double,
        segments: [TranscriptSegment] = []
    ) {
        self.rawTranscript = rawTranscript
        self.summaryMarkdown = summaryMarkdown
        self.detectedLanguage = detectedLanguage
        self.usedMinutes = usedMinutes
        self.processingTimeSeconds = processingTimeSeconds
        self.segments = segments
    }
}

/// İşleme boru hattının kullanıcıya gösterilebilir aşamaları.
///
/// Eskiden ekran tüm süre boyunca "Özet çıkarılıyor…" yazıyordu — oysa 45
/// dakikalık bir kayıtta zamanın neredeyse tamamı transkripsiyonda geçiyor.
/// Kullanıcı yanlış aşamayı dakikalarca donuk görünce takıldığını sanıp
/// uygulamayı öldürüyordu.
public enum ProcessingStage: String, Sendable, CaseIterable {

    case transcribing
    case diarizing
    case summarizing

    public func label(for mode: ProcessingMode) -> String {
        switch self {
        case .transcribing:
            return mode == .offlineZeroCloud ? "Cihaz içi transkripsiyon" : "Buluta yükleniyor"
        case .diarizing:
            return "Konuşmacılar ayrıştırılıyor"
        case .summarizing:
            return "Özet çıkarılıyor"
        }
    }
}

/// Aşama ve o aşamanın 0...1 ilerlemesi.
public typealias ProcessingProgress = @Sendable (ProcessingStage, Double) -> Void

public protocol ProcessingEngineProtocol: Sendable {
    func process(request: ProcessingRequest) async throws -> ProcessingResult
    func process(request: ProcessingRequest, progress: ProcessingProgress?) async throws -> ProcessingResult
}

public extension ProcessingEngineProtocol {

    /// İlerleme bildirmeyen motorlar için varsayılan — mevcut sahte motorlar
    /// ve testler tek metodu uygulamaya devam edebiliyor.
    func process(request: ProcessingRequest, progress: ProcessingProgress?) async throws -> ProcessingResult {
        try await process(request: request)
    }
}

// MARK: - Hata Tipleri

public enum AuraError: LocalizedError, Sendable, Equatable {
    case insufficientQuota(requiredSeconds: Double, availableSeconds: Double)
    case quotaStorageUnavailable
    case microphonePermissionDenied
    case calendarPermissionDenied
    case notificationPermissionDenied
    case audioEngineFailure(String)
    case offlineModelMissing
    case diarizationModelMissing
    case networkUnavailable
    case engineFailure(String)
    case cloudCredentialsMissing(provider: String)
    case cloudAuthenticationFailed(provider: String)
    case cloudRateLimited(provider: String)
    /// Sağlayıcının güvenlik sınıflandırıcısı isteği reddetti (HTTP 200 + refusal).
    case cloudRefused(category: String)
    case audioTooLargeForCloud(megabytes: Double, limitMegabytes: Double)

    public var errorDescription: String? {
        switch self {
        case let .insufficientQuota(required, available):
            return "Yetersiz dakika bakiyesi. Gerekli: \(AuraFormatSeconds.minutes(required)), kalan: \(AuraFormatSeconds.minutes(available))."
        case .quotaStorageUnavailable:
            return "Dakika bakiyen güvenli depoya yazılamadı. Cihazı yeniden başlatıp tekrar dene."
        case .microphonePermissionDenied:
            return "Mikrofon izni verilmedi. Ayarlar › AuraVoice üzerinden açabilirsin."
        case .calendarPermissionDenied:
            return "Takvim izni verilmedi. Toplantı algılama devre dışı."
        case .notificationPermissionDenied:
            return "Bildirim izni verilmedi. Toplantı hatırlatmaları gönderilemez."
        case let .audioEngineFailure(detail):
            return "Ses motoru başlatılamadı: \(detail)"
        case .offlineModelMissing:
            return "Cihaz içi model indirilmemiş. Offline mod için modeli indir."
        case .diarizationModelMissing:
            return "Konuşmacı ayrıştırma modeli indirilmemiş. Ayarlar'dan indirebilirsin."
        case .networkUnavailable:
            return "İnternet bağlantısı yok. Offline moda geçebilirsin."
        case let .engineFailure(detail):
            return "İşleme hatası: \(detail)"
        case let .cloudCredentialsMissing(provider):
            return "\(provider) erişimi yapılandırılmamış. Ayarlar'dan oturum aç veya offline moda geç."
        case let .cloudAuthenticationFailed(provider):
            return "\(provider) kimlik doğrulaması reddetti. Oturumun düşmüş olabilir."
        case let .cloudRateLimited(provider):
            return "\(provider) hız sınırına takıldı. Birazdan tekrar dene ya da offline modu kullan."
        case let .cloudRefused(category):
            return "Sağlayıcı bu içeriği işlemeyi reddetti (\(category)). Offline mod bu kısıtlamaya tabi değil."
        case let .audioTooLargeForCloud(megabytes, limit):
            return String(
                format: "Kayıt bulut için çok büyük (%.0f MB / %.0f MB sınırı). Offline mod bu kaydı işleyebilir.",
                megabytes, limit
            )
        }
    }
}

/// `AuraError` içinde kullanılan hafif biçimlendirici (UIComponents'a bağımlılık yaratmamak için).
enum AuraFormatSeconds {
    static func minutes(_ seconds: Double) -> String {
        String(format: "%.1f dk", max(0, seconds) / 60.0)
    }
}
