//
//  NotificationManager.swift
//  AuraVoice
//
//  Eyleme dönüştürülebilir yerel bildirimler (Actionable Notifications).
//  CalendarTriggerService'ten gelen toplantı adaylarını bildirime çevirir,
//  CallObserverService'ten gelen "arama bağlandı" olayını anında uyarıya döker.
//
//  Sürekli dinleme YOKTUR: uygulama yalnızca kullanıcı bildirimdeki
//  "Kaydı Başlat" eylemine dokunduğunda mikrofonu açar.
//
//  Swift 6 notu: `UNUserNotificationCenterDelegate` geri çağrıları arbitrary
//  thread'den gelir. Sınıf aktöre bağlanmak yerine durumsuz + `@unchecked
//  Sendable` tutulur; UI tarafına iletim `AsyncStream` üzerinden yapılır ve
//  akışı tüketen taraf (AppCoordinator / DashboardViewModel) @MainActor'dır.
//

import Foundation
import UserNotifications

// MARK: - Olay Modeli

public enum RecordingTriggerSource: String, Sendable, Codable {
    case manual
    case calendar
    case phoneCall
    case widget
    case siri
    case actionButton
}

public struct AuraNotificationEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Kullanıcı "Kaydı Başlat" dedi → kayıt ekranı açılmalı.
        case startRecording
        /// Bildirime dokunuldu → ilgili ekrana git.
        case open
        /// 5 dakika ertelendi.
        case snoozed
        /// Kullanıcı yok saydı.
        case dismissed
    }

    public let kind: Kind
    public let source: RecordingTriggerSource
    public let meetingID: String?
    public let title: String?
    public let suggestedTemplate: SummaryTemplate
}

// MARK: - Yönetici

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    public static let shared = NotificationManager()

    // Kategori & eylem kimlikleri
    public enum Category {
        public static let meeting = "AURA_MEETING"
        public static let call = "AURA_CALL"
    }

    public enum Action {
        public static let startRecording = "AURA_START_RECORDING"
        public static let snooze = "AURA_SNOOZE_5"
        public static let dismiss = "AURA_DISMISS"
    }

    private enum PayloadKey {
        static let source = "aura.source"
        static let meetingID = "aura.meetingID"
        static let title = "aura.title"
        static let startDate = "aura.startDate"
        static let template = "aura.template"
    }

    /// Toplantı bildirimlerinin kimlik öneki — senkronizasyonda temizlik için.
    private static let meetingIdentifierPrefix = "aura.meeting."
    private static let callIdentifierPrefix = "aura.call."

    private let center = UNUserNotificationCenter.current()
    private let continuation: AsyncStream<AuraNotificationEvent>.Continuation

    /// Kullanıcı bildirim eylemlerinin akışı. Uygulama başlangıcında bir kez tüketilir.
    public let events: AsyncStream<AuraNotificationEvent>

    private override init() {
        let (stream, continuation) = AsyncStream<AuraNotificationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        self.events = stream
        self.continuation = continuation
        super.init()
    }

    // MARK: - Kurulum

    /// `AppDelegate.didFinishLaunching` içinde ÇAĞRILMALI (uygulama açılmadan
    /// gelen bildirim eylemlerinin kaybolmaması için delegate erken atanır).
    public func bootstrap() {
        center.delegate = self
        registerCategories()
    }

    public func registerCategories() {
        let start = UNNotificationAction(
            identifier: Action.startRecording,
            title: "Kaydı Başlat",
            options: [.foreground, .authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze,
            title: "5 dk Ertele",
            options: []
        )
        let dismiss = UNNotificationAction(
            identifier: Action.dismiss,
            title: "Yok Say",
            options: [.destructive]
        )

        let meeting = UNNotificationCategory(
            identifier: Category.meeting,
            actions: [start, snooze, dismiss],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Yaklaşan toplantı",
            options: [.customDismissAction]
        )

        let call = UNNotificationCategory(
            identifier: Category.call,
            actions: [start, dismiss],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Devam eden görüşme",
            options: [.customDismissAction]
        )

        center.setNotificationCategories([meeting, call])
    }

    // MARK: - İzin

    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            // `.timeSensitive` iOS 15'te kullanımdan kaldırıldı: artık izin
            // isteğiyle değil, entitlement ile veriliyor
            // (Support/AuraVoice.entitlements içinde tanımlı).
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[AuraVoice] Bildirim izni hatası: \(error.localizedDescription)")
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Takvim Senkronizasyonu

    /// CalendarTriggerService ile entegre ana giriş noktası.
    /// Yaklaşan toplantıları tarar, silinen/değişen etkinliklerin bildirimlerini
    /// iptal eder, eksik olanları planlar. İdempotenttir — her açılışta ve
    /// `didBecomeActive`'de güvenle çağrılabilir.
    @discardableResult
    public func syncMeetingTriggers(
        using calendar: CalendarTriggerService = .shared,
        leadTimeMinutes: Int = 2,
        withinHours: Int = 12
    ) async -> [MeetingCandidate] {

        guard await authorizationStatus() != .denied else { return [] }
        guard await calendar.requestAccess() else { return [] }

        let candidates = await calendar.upcomingMeetings(withinHours: withinHours)
        let desired = Dictionary(
            candidates.map { (Self.meetingIdentifierPrefix + $0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 1) Artık geçerli olmayan planlı bildirimleri temizle.
        let pending = await center.pendingNotificationRequests()
        let staleIdentifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.meetingIdentifierPrefix) && desired[$0] == nil }
        if !staleIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }

        // 2) Eksik olanları planla.
        let existing = Set(pending.map(\.identifier))
        for (identifier, candidate) in desired where !existing.contains(identifier) {
            await scheduleMeetingReminder(for: candidate, leadTimeMinutes: leadTimeMinutes)
        }

        return candidates
    }

    /// Tek bir toplantı için hatırlatma planlar. Fırlatma zamanı geçmişse atlanır.
    public func scheduleMeetingReminder(for candidate: MeetingCandidate, leadTimeMinutes: Int = 2) async {
        let fireDate = candidate.startDate.addingTimeInterval(-Double(leadTimeMinutes) * 60)
        guard fireDate.timeIntervalSinceNow > 5 else { return }

        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.isVirtual
            ? "Toplantı \(leadTimeMinutes) dk sonra başlıyor. Kaydı başlatıp özet çıkarabilirim."
            : "Toplantın başlamak üzere. Tek dokunuşla kaydı başlat."
        content.subtitle = AuraFormatTime.meetingSubtitle(
            start: candidate.startDate,
            durationMinutes: candidate.durationMinutes
        )
        content.sound = .default
        content.categoryIdentifier = Category.meeting
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 0.9
        content.threadIdentifier = "aura.meetings"
        content.userInfo = [
            PayloadKey.source: RecordingTriggerSource.calendar.rawValue,
            PayloadKey.meetingID: candidate.id,
            PayloadKey.title: candidate.title,
            PayloadKey.startDate: candidate.startDate.timeIntervalSince1970,
            PayloadKey.template: SummaryTemplate.meetingNotes.rawValue
        ]

        // Takvim tetikleyici, kullanıcı saat dilimi değiştirse bile doğru anı korur.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: Self.meetingIdentifierPrefix + candidate.id,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("[AuraVoice] Toplantı bildirimi planlanamadı: \(error.localizedDescription)")
        }
    }

    // MARK: - Telefon Görüşmesi

    /// CallObserverService "arama bağlandı" dediğinde çağrılır.
    /// Uygulama arka plandayken kullanıcıya hoparlör ipucu verir.
    public func notifyCallConnected() async {
        let content = UNMutableNotificationContent()
        content.title = "Görüşme kaydı hazır"
        content.body = "Hoparlörü açarak kaydı başlatabilirsiniz."
        content.sound = .default
        content.categoryIdentifier = Category.call
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "aura.calls"
        content.userInfo = [
            PayloadKey.source: RecordingTriggerSource.phoneCall.rawValue,
            PayloadKey.template: SummaryTemplate.phoneCallSummary.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: Self.callIdentifierPrefix + UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
    }

    public func cancelCallPrompts() async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.callIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: pending)
    }

    // MARK: - Erteleme

    private func scheduleSnooze(from userInfo: [AnyHashable: Any], minutes: Int = 5) async {
        let content = UNMutableNotificationContent()
        content.title = (userInfo[PayloadKey.title] as? String) ?? "Toplantı kaydı"
        content.body = "Ertelendi — hâlâ kaydetmek ister misin?"
        content.sound = .default
        content.categoryIdentifier = Category.meeting
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "aura.meetings"
        content.userInfo = userInfo

        let meetingID = (userInfo[PayloadKey.meetingID] as? String) ?? UUID().uuidString
        let request = UNNotificationRequest(
            identifier: Self.meetingIdentifierPrefix + meetingID + ".snooze",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes) * 60, repeats: false)
        )
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Uygulama ön plandayken de banner göster: kullanıcı toplantıyı kaçırmasın.
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        let source = (userInfo[PayloadKey.source] as? String)
            .flatMap(RecordingTriggerSource.init(rawValue:)) ?? .manual
        let template = (userInfo[PayloadKey.template] as? String)
            .flatMap(SummaryTemplate.init(rawValue:)) ?? .meetingNotes
        let meetingID = userInfo[PayloadKey.meetingID] as? String
        let title = userInfo[PayloadKey.title] as? String

        let kind: AuraNotificationEvent.Kind
        switch response.actionIdentifier {
        case Action.startRecording:
            kind = .startRecording
        case Action.snooze:
            await scheduleSnooze(from: userInfo)
            kind = .snoozed
        case Action.dismiss, UNNotificationDismissActionIdentifier:
            kind = .dismissed
        case UNNotificationDefaultActionIdentifier:
            kind = .open
        default:
            kind = .open
        }

        continuation.yield(
            AuraNotificationEvent(
                kind: kind,
                source: source,
                meetingID: meetingID,
                title: title,
                suggestedTemplate: template
            )
        )
    }

    // MARK: - Bakım

    public func cancelAllMeetingReminders() async {
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.meetingIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func pendingMeetingReminderCount() async -> Int {
        await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.meetingIdentifierPrefix) }
            .count
    }
}

/// Bildirim altyazısı için hafif biçimlendirici (Core katmanının UI'a bağımlı olmaması adına).
enum AuraFormatTime {
    static func meetingSubtitle(start: Date, durationMinutes: Int) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) · \(durationMinutes) dk"
    }
}
