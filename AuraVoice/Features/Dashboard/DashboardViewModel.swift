//
//  DashboardViewModel.swift
//  AuraVoice
//
//  Dashboard'un tek doğruluk kaynağı. Kota, mod seçimi, takvim tetikleyicileri,
//  görüşme algılama ve bildirim eylemlerini tek @MainActor durumunda toplar.
//

import Foundation
import Observation
import EventKit
import UserNotifications

// MARK: - Kayıt Niyeti

/// Kayıt ekranını hangi bağlamda açtığımızı taşır (manuel, takvim, arama…).
public struct RecordingIntent: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let mode: ProcessingMode
    public let template: SummaryTemplate
    public let source: RecordingTriggerSource
    public let contextTitle: String?

    public init(
        mode: ProcessingMode,
        template: SummaryTemplate = .meetingNotes,
        source: RecordingTriggerSource = .manual,
        contextTitle: String? = nil
    ) {
        self.mode = mode
        self.template = template
        self.source = source
        self.contextTitle = contextTitle
    }
}

// MARK: - ViewModel

@MainActor
@Observable
public final class DashboardViewModel {

    // MARK: Yayınlanan durum

    public private(set) var remainingSeconds: Double = 0
    public private(set) var planMonthlyMinutes: Double = 30
    public private(set) var minutesUsedThisMonth: Double = 0

    public private(set) var notes: [NoteSummary] = []
    public private(set) var upcomingMeetings: [MeetingCandidate] = []

    public private(set) var calendarStatus: EKAuthorizationStatus = .notDetermined
    public private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    public private(set) var scheduledReminderCount: Int = 0

    public private(set) var isCallActive = false
    public private(set) var isSyncing = false

    /// Kayıt ekranını sunmak için `sheet(item:)` ile bağlanır.
    public var recordingIntent: RecordingIntent?
    public var isPaywallPresented = false
    public var errorMessage: String?

    public var mode: ProcessingMode = .offlineZeroCloud {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
        }
    }

    // MARK: Türetilmiş

    public var remainingMinutes: Double { remainingSeconds / 60.0 }

    /// Kota halkası için 0...1 doluluk.
    public var quotaFraction: Double {
        guard planMonthlyMinutes > 0 else { return 0 }
        return min(1, max(0, remainingMinutes / planMonthlyMinutes))
    }

    public var isQuotaCritical: Bool { remainingMinutes < 5 }
    public var isQuotaEmpty: Bool { remainingSeconds < 30 }

    public var accentColorMode: ProcessingMode { mode }

    /// Offline mod için cihaz içi modeller hazır mı?
    public private(set) var isOfflineModelReady: Bool = OfflineAssetChecker.isReady()

    public var nextMeeting: MeetingCandidate? { upcomingMeetings.first }

    // MARK: Bağımlılıklar

    @ObservationIgnored private let quotaManager: QuotaManager
    @ObservationIgnored private let calendarService: CalendarTriggerService
    @ObservationIgnored private let notificationManager: NotificationManager
    @ObservationIgnored private let repository: any NoteRepository

    // `deinit` nonisolated olduğu için bu iki alan gözlemleme dışında tutulur;
    // aksi halde makro üreteceği @MainActor getter'a deinit'ten erişilemez.
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var callTask: Task<Void, Never>?

    private enum Keys {
        static let mode = "aura.processingMode"
        static let planMinutes = "aura.plan.monthlyMinutes"
    }

    public init(
        quotaManager: QuotaManager = .shared,
        calendarService: CalendarTriggerService = .shared,
        notificationManager: NotificationManager = .shared,
        repository: any NoteRepository = DatabaseManager.shared
    ) {
        self.quotaManager = quotaManager
        self.calendarService = calendarService
        self.notificationManager = notificationManager
        self.repository = repository

        if let raw = UserDefaults.standard.string(forKey: Keys.mode),
           let saved = ProcessingMode(rawValue: raw) {
            self.mode = saved
        }
        let storedPlan = UserDefaults.standard.double(forKey: Keys.planMinutes)
        self.planMonthlyMinutes = storedPlan > 0 ? storedPlan : 30
    }

    deinit {
        eventTask?.cancel()
        callTask?.cancel()
    }

    // MARK: Yaşam Döngüsü

    /// `.task` içinde bir kez çağrılır: akışlara abone olur, izinleri toplar,
    /// takvim tetikleyicilerini senkronlar.
    public func bootstrap() async {
        observeNotificationEvents()
        observeCallStates()

        calendarStatus = calendarService.authorizationStatus
        notificationStatus = await notificationManager.authorizationStatus()
        isCallActive = CallObserverService.shared.hasActiveCall

        await refresh()
    }

    /// Ön plana her dönüşte çağrılır — kota, notlar ve toplantılar tazelenir.
    public func refresh() async {
        isSyncing = true
        defer { isSyncing = false }

        remainingSeconds = quotaManager.getRemainingSeconds()
        isOfflineModelReady = OfflineAssetChecker.isReady()

        do {
            notes = try await repository.all()
            minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
        } catch {
            errorMessage = "Kayıtlar okunamadı: \(error.localizedDescription)"
        }

        calendarStatus = calendarService.authorizationStatus
        notificationStatus = await notificationManager.authorizationStatus()

        if calendarStatus == .fullAccess, notificationStatus == .authorized {
            upcomingMeetings = await notificationManager.syncMeetingTriggers(
                using: calendarService,
                leadTimeMinutes: 2
            )
            scheduledReminderCount = await notificationManager.pendingMeetingReminderCount()
        } else if calendarStatus == .fullAccess {
            upcomingMeetings = await calendarService.upcomingMeetings()
        } else {
            upcomingMeetings = []
            scheduledReminderCount = 0
        }
    }

    // MARK: İzinler

    /// Onboarding / boş durum kartından çağrılır: bildirim + takvim izni ister,
    /// ardından ilk senkronizasyonu yapar.
    public func enableMeetingTriggers() async {
        let notificationsGranted = await notificationManager.requestAuthorization()
        notificationStatus = await notificationManager.authorizationStatus()
        guard notificationsGranted else {
            errorMessage = AuraError.notificationPermissionDenied.errorDescription
            return
        }

        let calendarGranted = await calendarService.requestAccess()
        calendarStatus = calendarService.authorizationStatus
        guard calendarGranted else {
            errorMessage = AuraError.calendarPermissionDenied.errorDescription
            return
        }

        await refresh()
    }

    // MARK: Mod

    public func select(mode newMode: ProcessingMode) {
        if newMode == .offlineZeroCloud, !isOfflineModelReady {
            // Model yoksa kullanıcıyı sessizce online'da bırakmak yerine uyar.
            errorMessage = AuraError.offlineModelMissing.errorDescription
            return
        }
        mode = newMode
    }

    // MARK: Kayıt Tetikleyicileri

    public func startManualRecording() {
        guard ensureQuota() else { return }
        recordingIntent = RecordingIntent(mode: mode, template: .quickNotes, source: .manual)
    }

    public func startRecording(for meeting: MeetingCandidate) {
        guard ensureQuota() else { return }
        recordingIntent = RecordingIntent(
            mode: mode,
            template: .meetingNotes,
            source: .calendar,
            contextTitle: meeting.title
        )
    }

    public func startCallRecording() {
        guard ensureQuota() else { return }
        recordingIntent = RecordingIntent(
            mode: mode,
            template: .phoneCallSummary,
            source: .phoneCall,
            contextTitle: "Telefon görüşmesi"
        )
    }

    private func ensureQuota() -> Bool {
        remainingSeconds = quotaManager.getRemainingSeconds()
        guard !isQuotaEmpty else {
            isPaywallPresented = true
            return false
        }
        return true
    }

    // MARK: Sonuçlar

    /// RecordingView işlemi tamamlayıp notu kaydettikten sonra çağrılır.
    public func recordingFinished(with note: NoteSummary?) async {
        recordingIntent = nil
        if let note {
            do {
                notes = try await repository.insert(note)
                minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
            } catch {
                // Kota zaten düşüldü; notu kaybettiğimizi kullanıcıdan gizlemeyelim.
                errorMessage = "Not kaydedilemedi: \(error.localizedDescription)"
            }
        }
        remainingSeconds = quotaManager.getRemainingSeconds()
    }

    public func delete(_ note: NoteSummary) async {
        do {
            notes = try await repository.delete(id: note.id)
            minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
        } catch {
            errorMessage = "Not silinemedi: \(error.localizedDescription)"
        }
    }

    // MARK: Akışlar

    private func observeNotificationEvents() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            for await event in NotificationManager.shared.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: AuraNotificationEvent) {
        switch event.kind {
        case .startRecording:
            guard ensureQuota() else { return }
            recordingIntent = RecordingIntent(
                mode: mode,
                template: event.suggestedTemplate,
                source: event.source,
                contextTitle: event.title
            )
        case .open, .snoozed, .dismissed:
            Task { await self.refresh() }
        }
    }

    private func observeCallStates() {
        guard callTask == nil else { return }
        callTask = Task { [weak self] in
            for await state in CallObserverService.shared.states {
                guard let self else { return }
                self.isCallActive = state.isConnected
            }
        }
    }
}

// MARK: - Offline Varlık Kontrolü

/// Cihaz içi modellerin (WhisperKit + yerel LLM) indirilip indirilmediğini
/// kontrol eder. Model indirme akışı `OfflineModelDownloader` ile eklenecek;
/// burada yalnızca dosya varlığı sorgulanır.
public enum OfflineAssetChecker {

    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static func isReady() -> Bool {
        #if targetEnvironment(simulator)
        // Simülatörde ANE yok; arayüzü test edebilmek için hazır kabul edilir.
        return true
        #else
        let whisper = modelsDirectory.appendingPathComponent("whisperkit", isDirectory: true)
        let llm = modelsDirectory.appendingPathComponent("llm", isDirectory: true)
        let fm = FileManager.default
        return fm.fileExists(atPath: whisper.path) && fm.fileExists(atPath: llm.path)
        #endif
    }
}
