//
//  AuraAppIntents.swift
//  AuraVoice
//
//  Siri, Kısayollar, Action Button ve (ileride) widget için niyet tanımları.
//
//  TASARIM KARARI — kayıt intent içinde BAŞLAMIYOR: intent yalnızca niyeti
//  kutuya bırakıp uygulamayı açıyor, kaydı Dashboard başlatıyor. Kaydın
//  mikrofon izni, kota kontrolü, ses oturumu yapılandırması ve bir ekranı var;
//  bunları intent'in kısa ömürlü bağlamında yapmak, kullanıcının "kaydediyor
//  mu, kaydetmiyor mu" sorusunu cevapsız bırakırdı. Kayıt ekranı açılması
//  aynı zamanda görsel onaydır.
//
//  İSTİSNA: `RemainingMinutesIntent` uygulamayı açmıyor — soruya cevap
//  vermek için ekrana ihtiyaç yok.
//

import Foundation
import AppIntents

// MARK: - Parametre türleri

public enum RecordingModeChoice: String, AppEnum {

    case offline
    case online

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Kayıt Modu")
    }

    public static var caseDisplayRepresentations: [RecordingModeChoice: DisplayRepresentation] {
        [
            .offline: DisplayRepresentation(
                title: "Offline (Zero-Cloud)",
                subtitle: "Ses cihazdan hiç çıkmaz"
            ),
            .online: DisplayRepresentation(
                title: "Online (Hızlı)",
                subtitle: "Bulutta işlenir"
            )
        ]
    }

    public var processingMode: ProcessingMode {
        switch self {
        case .offline: return .offlineZeroCloud
        case .online:  return .onlineCloudFast
        }
    }
}

public enum RecordingTemplateChoice: String, AppEnum {

    case meeting
    case call
    case quickNote

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Özet Şablonu")
    }

    public static var caseDisplayRepresentations: [RecordingTemplateChoice: DisplayRepresentation] {
        [
            .meeting:   DisplayRepresentation(title: "Toplantı Özeti & Aksiyonlar"),
            .call:      DisplayRepresentation(title: "Telefon Görüşmesi Özeti"),
            .quickNote: DisplayRepresentation(title: "Hızlı Not & Fikirler")
        ]
    }

    public var summaryTemplate: SummaryTemplate {
        switch self {
        case .meeting:   return .meetingNotes
        case .call:      return .phoneCallSummary
        case .quickNote: return .quickNotes
        }
    }
}

// MARK: - Kaydı başlat

public struct StartRecordingIntent: AppIntent {

    public static var title: LocalizedStringResource { "Kaydı Başlat" }

    public static var description: IntentDescription {
        IntentDescription(
            "AuraVoice'u açar ve kayıt ekranını hazır hale getirir. Mod seçilmezse panelde seçili olan mod kullanılır.",
            categoryName: "Kayıt"
        )
    }

    /// Kayıt ekranı açılmadan kayıt başlamaz — kullanıcı ne olduğunu görmeli.
    public static var openAppWhenRun: Bool { true }

    @Parameter(title: "Mod")
    public var mode: RecordingModeChoice?

    @Parameter(title: "Şablon")
    public var template: RecordingTemplateChoice?

    public init() {}

    public init(mode: RecordingModeChoice?, template: RecordingTemplateChoice?) {
        self.mode = mode
        self.template = template
    }

    public func perform() async throws -> some IntentResult {
        RecordingLaunchInbox.shared.submit(
            RecordingLaunchRequest(
                source: .siri,
                template: (template ?? .meeting).summaryTemplate,
                mode: mode?.processingMode
            )
        )
        return .result()
    }
}

// MARK: - Zero-Cloud kısayolu

/// Action Button için tek dokunuşluk, parametresiz giriş. Modu açıkça offline'a
/// sabitliyor: "düğmeye bastım, ses cihazımdan çıkmadı" garantisi kullanıcının
/// bu uygulamayı seçme sebebi.
public struct StartOfflineRecordingIntent: AppIntent {

    public static var title: LocalizedStringResource { "Zero-Cloud Kaydı Başlat" }

    public static var description: IntentDescription {
        IntentDescription(
            "Kaydı tamamen cihaz içinde işlenecek şekilde başlatır. Ses ve metin cihazdan hiç çıkmaz.",
            categoryName: "Kayıt"
        )
    }

    public static var openAppWhenRun: Bool { true }

    public init() {}

    public func perform() async throws -> some IntentResult {
        RecordingLaunchInbox.shared.submit(
            RecordingLaunchRequest(
                source: .actionButton,
                template: .meetingNotes,
                mode: .offlineZeroCloud
            )
        )
        return .result()
    }
}

// MARK: - Kalan dakika

public struct RemainingMinutesIntent: AppIntent {

    public static var title: LocalizedStringResource { "Kalan Dakikam" }

    public static var description: IntentDescription {
        IntentDescription("Bu ay kaç dakika kaydın kaldığını söyler.", categoryName: "Kota")
    }

    /// Soruya cevap vermek için uygulamayı açmaya gerek yok.
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let minutes = Int(QuotaManager.shared.getRemainingMinutes().rounded(.down))
        let sentence = minutes > 0
            ? "AuraVoice'ta \(minutes) dakikan kaldı."
            : "AuraVoice kotan bitti. Yeni dakika eklemek için uygulamayı aç."

        return .result(value: minutes, dialog: IntentDialog(stringLiteral: sentence))
    }
}

// MARK: - Kısayol önerileri

public struct AuraShortcuts: AppShortcutsProvider {

    /// Siri ifadeleri uygulama adını içermek ZORUNDA; içermeyen ifade sessizce
    /// yok sayılır ve kısayol Siri'de hiç çalışmaz.
    @AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {

        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "\(.applicationName) ile kayda başla",
                "\(.applicationName) kaydı başlat",
                "Start a recording with \(.applicationName)"
            ],
            shortTitle: "Kaydı Başlat",
            systemImageName: "mic.circle.fill"
        )

        AppShortcut(
            intent: StartOfflineRecordingIntent(),
            phrases: [
                "\(.applicationName) ile gizli kayıt",
                "\(.applicationName) zero cloud kayıt",
                "Start a private recording with \(.applicationName)"
            ],
            shortTitle: "Zero-Cloud Kayıt",
            systemImageName: "lock.shield.fill"
        )

        AppShortcut(
            intent: RemainingMinutesIntent(),
            phrases: [
                "\(.applicationName) kaç dakikam kaldı",
                "\(.applicationName) kalan dakikam",
                "How many minutes are left in \(.applicationName)"
            ],
            shortTitle: "Kalan Dakikam",
            systemImageName: "gauge.with.needle"
        )
    }
}
