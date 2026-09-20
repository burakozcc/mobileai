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

    /// Bakiye havuz başına tutuluyor; ekranda gösterilen ETKİN havuz `mode`
    /// ile belirleniyor. Tek bir `remainingSeconds` alanı, mod değiştiğinde
    /// bayat kalırdı — kullanıcı Zero-Cloud'a geçtiğinde hâlâ bulut
    /// bakiyesini görürdü.
    public private(set) var offlineRemainingSeconds: Double = 0
    public private(set) var onlineRemainingSeconds: Double = 0
    public private(set) var offlinePlanMinutes: Double = QuotaManager.freeOfflineMinutes
    public private(set) var onlinePlanMinutes: Double = QuotaManager.freeOnlineMinutes
    public private(set) var minutesUsedThisMonth: Double = 0

    public private(set) var notes: [NoteSummary] = []
    public private(set) var upcomingMeetings: [MeetingCandidate] = []

    public private(set) var calendarStatus: EKAuthorizationStatus = .notDetermined
    public private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    public private(set) var scheduledReminderCount: Int = 0

    public private(set) var isCallActive = false
    /// Ağ durumu. `NWPathMonitor` yolun varlığını söylüyor, karşı tarafın
    /// cevap verdiğini değil — bu yüzden bir garanti değil ipucu.
    public private(set) var networkReachability: NetworkReachability = .unknown
    public private(set) var isSyncing = false

    /// Kayıt ekranını sunmak için `sheet(item:)` ile bağlanır.
    public var recordingIntent: RecordingIntent?
    public var isPaywallPresented = false
    /// Paywall'ı açtıran havuz. Ekran hangi dakikanın bittiğini bilmeden
    /// doğru cümleyi kuramıyor.
    ///
    /// `presentPaywall(for:)` DIŞINDA yazılmıyor: `isPaywallPresented`ı
    /// doğrudan `true` yapan bir çağrı, bir önceki açılıştan kalan havuzu
    /// gösterirdi — cihaz içi modda çalışan kullanıcıya "bulut dakikan bitti"
    /// demek gibi.
    ///
    /// Varsayılan `.offline`, `mode`un varsayılanıyla (`.offlineZeroCloud`)
    /// aynı: ekran bir şekilde `presentPaywall` çağrılmadan açılsa bile
    /// anlattığı havuz seçili modla tutarlı kalıyor.
    public private(set) var paywallLane: QuotaLane = .offline

    /// Offline mod seçili ama model yokken kayıt denendiğinde açılır.
    public var isModelDownloadPresented = false
    /// Uyarıya "Modeli indir" düğmesi eklenmeli mi.
    public var offersModelDownload = false
    public var errorMessage: String?

    public var mode: ProcessingMode = .offlineZeroCloud {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            // Widget etkin havuzun bakiyesini gösteriyor; mod değişince
            // yayınlamazsak bir sonraki tazelemeye kadar öteki havuzun
            // sayısında kalırdı.
            publishSnapshot()
        }
    }

    // MARK: Türetilmiş

    /// Seçili modun havuzu. Halka, rozet ve kayıt kapısı bunu kullanıyor.
    public var activeLane: QuotaLane { QuotaLane(mode: mode) }

    public func remaining(_ lane: QuotaLane) -> Double {
        lane == .online ? onlineRemainingSeconds : offlineRemainingSeconds
    }

    public func planMinutes(_ lane: QuotaLane) -> Double {
        lane == .online ? onlinePlanMinutes : offlinePlanMinutes
    }

    public var remainingSeconds: Double { remaining(activeLane) }
    public var planMonthlyMinutes: Double { planMinutes(activeLane) }
    public var remainingMinutes: Double { remainingSeconds / 60.0 }

    public var offlineRemainingMinutes: Double { offlineRemainingSeconds / 60.0 }
    public var onlineRemainingMinutes: Double { onlineRemainingSeconds / 60.0 }

    /// Kota halkasının VoiceOver değeri.
    ///
    /// Düz `String` — dizge sabiti olarak yazılsaydı SwiftUI onu
    /// `LocalizedStringKey` sayar ve çevrilecek hiçbir sözcük içermeyen
    /// ("%@: %lld / %lld") bir anahtar sekiz dile dağıtılırdı. Havuz adı
    /// zaten kendi içinde çevrili geliyor.
    public var quotaAccessibilityValue: String {
        "\(activeLane.title): \(Int(remainingMinutes.rounded())) / \(Int(planMonthlyMinutes))"
    }

    /// Halkanın altındaki iki havuzu birden gösteren satır.
    ///
    /// Halka yalnızca etkin havuzu gösteriyor; bu satır olmadan kullanıcı
    /// öteki havuzda dakikası olduğunu ancak modu değiştirerek anlardı.
    public var laneSummary: String {
        String(localized: "Cihaz içi \(Int(offlineRemainingMinutes.rounded())) dk · Bulut \(Int(onlineRemainingMinutes.rounded())) dk")
    }

    /// Kota halkası için 0...1 doluluk.
    public var quotaFraction: Double {
        guard planMonthlyMinutes > 0 else { return 0 }
        return min(1, max(0, remainingMinutes / planMonthlyMinutes))
    }

    /// Uyarı eşiği: 5 dakika ya da planın beşte biri — hangisi küçükse.
    ///
    /// Sabit 5 dakika, havuzlar ayrılıp plan rakamları küçüldüğünde anlamını
    /// yitiriyordu: 10 dakikalık ücretsiz bulut havuzunda kullanıcı planının
    /// YARISINI harcadığı anda amber uyarıyı görüyordu. Sürekli yanan bir uyarı
    /// hiç yanmayanla aynı işe yarar. 200 dakikalık Pro havuzunda ise 5 dakika
    /// hâlâ doğru an, o yüzden tavan orada duruyor.
    public var isQuotaCritical: Bool {
        remainingMinutes < min(5, planMonthlyMinutes * 0.2)
    }
    public var isQuotaEmpty: Bool { remainingSeconds < 30 }

    public var accentColorMode: ProcessingMode { mode }

    /// Offline mod için cihaz içi ASR modeli indirilmiş mi?
    public private(set) var isOfflineModelReady: Bool = OfflineModelManager.isOfflineReady()

    public var nextMeeting: MeetingCandidate? { upcomingMeetings.first }

    // MARK: Bağımlılıklar

    @ObservationIgnored private let quotaManager: QuotaManager
    @ObservationIgnored private let calendarService: CalendarTriggerService
    @ObservationIgnored private let notificationManager: NotificationManager
    @ObservationIgnored private let repository: any NoteRepository
    @ObservationIgnored private let launchInbox: RecordingLaunchInbox

    // `deinit` nonisolated olduğu için bu iki alan gözlemleme dışında tutulur;
    // aksi halde makro üreteceği @MainActor getter'a deinit'ten erişilemez.
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var callTask: Task<Void, Never>?
    @ObservationIgnored private var networkToken: UUID?

    private enum Keys {
        static let mode = "aura.processingMode"
    }

    public init(
        quotaManager: QuotaManager = .shared,
        calendarService: CalendarTriggerService = .shared,
        notificationManager: NotificationManager = .shared,
        repository: any NoteRepository = DatabaseManager.shared,
        launchInbox: RecordingLaunchInbox = .shared
    ) {
        self.quotaManager = quotaManager
        self.calendarService = calendarService
        self.notificationManager = notificationManager
        self.repository = repository
        self.launchInbox = launchInbox

        if let raw = UserDefaults.standard.string(forKey: Keys.mode),
           let saved = ProcessingMode(rawValue: raw) {
            self.mode = saved
        }
        // Plan dakikası artık QuotaManager'ın kendi deposunda; UserDefaults'ta
        // ikinci bir kopya tutmak iki farklı sayı göstermek demekti.
        self.offlinePlanMinutes = quotaManager.planMonthlyMinutes(.offline)
        self.onlinePlanMinutes = quotaManager.planMonthlyMinutes(.online)
    }

    deinit {
        eventTask?.cancel()
        callTask?.cancel()
        if let networkToken { NetworkMonitor.shared.removeObserver(networkToken) }
    }

    // MARK: Yaşam Döngüsü

    /// `.task` içinde bir kez çağrılır: akışlara abone olur, izinleri toplar,
    /// takvim tetikleyicilerini senkronlar.
    public func bootstrap() async {
        observeNotificationEvents()
        observeCallStates()
        observeNetwork()

        // Kalıcı store açılamadıysa uygulama ÇALIŞIYOR görünüyor ama her not
        // uygulama kapanınca yok oluyor. Sessiz bırakmak, kullanıcının geçmişi
        // silinmiş sanmasına ve yeni notlarının da kaybolduğunu fark
        // etmemesine yol açardı.
        if AuraModelContainer.isEphemeral {
            errorMessage = String(localized: "Kayıt veritabanı açılamadı. Bu oturumda aldığın notlar kalıcı olmayacak — uygulamayı yeniden başlatmayı dene.")
        }

        calendarStatus = calendarService.authorizationStatus
        notificationStatus = await notificationManager.authorizationStatus()
        isCallActive = CallObserverService.shared.hasActiveCall

        await refresh()
    }

    /// Ön plana her dönüşte çağrılır — kota, notlar ve toplantılar tazelenir.
    public func refresh() async {
        isSyncing = true
        defer { isSyncing = false }

        reloadQuota()
        isOfflineModelReady = OfflineModelManager.isOfflineReady()

        // Widget kotayı kendi hesaplamıyor; buradan besleniyor.
        // `isOfflineModelReady` üç satır önce okundu; varsayılan argüman aynı
        // JSON okuma + dosya kontrolünü MainActor'da bir kez daha yapardı.
        publishSnapshot()

        do {
            notes = try await repository.all()
            minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
        } catch {
            errorMessage = String(localized: "Kayıtlar okunamadı: \(error.localizedDescription)")
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

        // Siri / Kısayol / Action Button uygulamayı açtıysa niyet burada
        // karşılanıyor: ön plana her dönüşte kutuya bakılıyor.
        consumeLaunchRequest()
    }

    // MARK: Dışarıdan gelen kayıt istekleri

    /// Kutuda bekleyen "kaydı başlat" isteğini uygular.
    ///
    /// Kayıt zaten açıksa dokunmuyoruz — kullanıcının süren kaydını başka bir
    /// niyetle kesmek, kaybedilen ses demek olurdu.
    public func consumeLaunchRequest(now: Date = Date()) {
        guard recordingIntent == nil else { return }
        guard let request = launchInbox.take(now: now) else { return }

        // AÇIKÇA istenen mod karşılanamıyorsa kayıt BAŞLAMIYOR.
        //
        // Eski hali sessizce `self.mode`'a düşüyordu: Kontrol Merkezi'ndeki
        // "Zero-Cloud Kayıt" düğmesine basan kullanıcı, model kurulu değilse ve
        // son seçili mod Online ise buluta kaydediyordu. Bu bir kolaylık
        // meselesi değil — uygulamanın verdiği tek sözün sessizce bozulması.
        let requestedMode = request.mode ?? mode
        guard canStartRecording(in: requestedMode) else { return }

        mode = requestedMode

        recordingIntent = RecordingIntent(
            mode: requestedMode,
            template: request.template,
            source: request.source,
            contextTitle: request.contextTitle
        )
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
        if newMode == .offlineZeroCloud {
            isOfflineModelReady = OfflineModelManager.isOfflineReady()
            guard isOfflineModelReady else {
                // Model yoksa kullanıcıyı sessizce online'da bırakmak yerine uyar.
                errorMessage = AuraError.offlineModelMissing.errorDescription
                offersModelDownload = true
                return
            }
        }
        mode = newMode
    }

    /// Paywall'ı açar ve hangi havuzu anlatacağını söyler.
    ///
    /// Havuz verilmezse SEÇİLİ modunki kullanılıyor: kota hapı ve taç düğmesi
    /// belirli bir havuza takılmadan açıldıkları için kullanıcının o an
    /// baktığı havuz doğru varsayılan.
    public func presentPaywall(for lane: QuotaLane? = nil) {
        paywallLane = lane ?? activeLane
        isPaywallPresented = true
    }

    /// Uyarı kapandığında iliştirilen durumu da temizler.
    public func dismissError() {
        errorMessage = nil
        offersModelDownload = false
    }

    // MARK: Kayıt Tetikleyicileri

    public func startManualRecording() {
        guard canStartRecording(in: mode) else { return }
        recordingIntent = RecordingIntent(mode: mode, template: .quickNotes, source: .manual)
    }

    public func startRecording(for meeting: MeetingCandidate) {
        guard canStartRecording(in: mode) else { return }
        recordingIntent = RecordingIntent(
            mode: mode,
            template: .meetingNotes,
            source: .calendar,
            contextTitle: meeting.title
        )
    }

    public func startCallRecording() {
        guard canStartRecording(in: mode) else { return }
        recordingIntent = RecordingIntent(
            mode: mode,
            template: .phoneCallSummary,
            source: .phoneCall,
            contextTitle: String(localized: "Telefon görüşmesi")
        )
    }

    /// Kayıt başlatmanın TEK kapısı.
    ///
    /// Hazırlık kaydın SONUNDA değil başında denetleniyor: eskiden kullanıcı
    /// 40 dakikalık toplantıyı sonuna kadar kaydedip "Durdur"a bastıktan sonra
    /// `offlineModelMissing` alıyordu ve o fazdan tekrar deneme yolu yoktu.
    private func canStartRecording(in requestedMode: ProcessingMode) -> Bool {

        // Kapı, kullanıcının SEÇTİĞİ modun havuzuna bakıyor. Etkin havuza
        // bakmak yanlış olurdu: kayıt başka bir modla da başlatılabiliyor
        // (widget, kısayol, takvim tetikleyicisi).
        let lane = QuotaLane(mode: requestedMode)
        reloadQuota()
        guard remaining(lane) >= 30 else {
            presentPaywall(for: lane)
            return false
        }

        // Dosya sistemi kontrolü ucuz; kullanıcı ekranı açık bırakıp modeli
        // Ayarlar'dan indirmiş olabilir.
        isOfflineModelReady = OfflineModelManager.isOfflineReady()

        guard requestedMode != .offlineZeroCloud || isOfflineModelReady else {
            errorMessage = AuraError.offlineModelMissing.errorDescription
            // Uyarı ile indirme ekranını aynı anda açmak yerine kullanıcıya
            // uyarının içinden bir çıkış yolu veriyoruz.
            offersModelDownload = true
            return false
        }

        return true
    }

    // MARK: Sonuçlar

    /// RecordingView işlemi tamamladıktan sonra çağrılır.
    public func recordingFinished(with outcome: RecordingOutcome?) async {
        recordingIntent = nil
        if let outcome {
            do {
                notes = try await repository.insert(outcome.note)
                // Zaman damgalı parçalar ayrı tabloda; not eklendikten sonra yazılır.
                if !outcome.segments.isEmpty {
                    try await repository.replaceSegments(outcome.segments, forNote: outcome.note.id)
                }
                minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
            } catch {
                // Kota zaten düşüldü; notu kaybettiğimizi kullanıcıdan gizlemeyelim.
                errorMessage = String(localized: "Not kaydedilemedi: \(error.localizedDescription)")
            }
        } else {
            // Kayıt ekranı hata ya da iptalle kapandı. İşleme başlamışsa not
            // zaten `.failed` olarak yazıldı; listeyi tazelemezsek kullanıcı
            // onu göremezdi.
            do {
                notes = try await repository.all()
                minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
            } catch {
                errorMessage = String(localized: "Kayıtlar okunamadı: \(error.localizedDescription)")
            }
        }
        reloadQuota()

        // Kayıt bittiğinde widget'ı hemen tazele. Yalnızca `refresh()` içinde
        // yayınlansaydı widget bir saate kadar eski bakiyeyi gösterirdi.
        publishSnapshot()
    }

    // MARK: Kota tazeleme

    /// İki havuzu ve iki planı birlikte okur.
    ///
    /// Tek çağrıda toplanıyor: ayrı ayrı okunsaydı bir yerde havuzlardan
    /// birini tazelemeyi unutmak sessiz bir bayat sayı üretirdi.
    private func reloadQuota() {
        offlineRemainingSeconds = quotaManager.getRemainingSeconds(.offline)
        onlineRemainingSeconds = quotaManager.getRemainingSeconds(.online)
        offlinePlanMinutes = quotaManager.planMonthlyMinutes(.offline)
        onlinePlanMinutes = quotaManager.planMonthlyMinutes(.online)
    }

    private func publishSnapshot() {
        // `isOfflineModelReady` çağıranlarda zaten okundu; varsayılan argüman
        // aynı JSON okuma + dosya kontrolünü MainActor'da tekrarlardı.
        QuotaSnapshotPublisher.publish(
            lane: activeLane,
            offlineRemainingMinutes: offlineRemainingMinutes,
            offlinePlanMinutes: offlinePlanMinutes,
            onlineRemainingMinutes: onlineRemainingMinutes,
            onlinePlanMinutes: onlinePlanMinutes,
            offlineAvailable: isOfflineModelReady
        )
    }

    public func delete(_ note: NoteSummary) async {
        do {
            notes = try await repository.delete(id: note.id)
            minutesUsedThisMonth = try await repository.minutesUsedThisMonth()
        } catch {
            errorMessage = String(localized: "Not silinemedi: \(error.localizedDescription)")
        }
    }

    // MARK: Akışlar

    private func observeNetwork() {
        guard networkToken == nil else { return }
        NetworkMonitor.shared.start()
        networkToken = NetworkMonitor.shared.observe { [weak self] state in
            Task { @MainActor in self?.networkReachability = state }
        }
    }

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
            // Bildirimden gelen "Kaydı Başlat" da aynı kapıdan geçiyor:
            // toplantı hatırlatması model eksikken kaydı başlatmamalı.
            guard canStartRecording(in: mode) else { return }
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

// Offline hazırlık kontrolü artık `OfflineModelManager` üzerinden yapılıyor
// (kurulum kaydı + klasör doğrulaması). Eski `OfflineAssetChecker` yer tutucusu
// kaldırıldı.
