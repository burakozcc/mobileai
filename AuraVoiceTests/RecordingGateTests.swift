//
//  RecordingGateTests.swift
//  AuraVoiceTests
//
//  Kayıt başlatmanın tek kapısı: kota + cihaz içi model hazırlığı.
//
//  Bu testlerin çalıştığı ortamda hiçbir Whisper modeli kurulu değil, yani
//  `OfflineModelManager.isOfflineReady()` false. Offline yolun engellendiğini
//  doğrulamak için tam olarak bu durum gerekiyor.
//

import Testing
import Foundation
@testable import AuraVoice

@MainActor
@Suite("Kayıt başlatma kapısı", .serialized)
struct RecordingGateTests {

    private func makeViewModel(
        quotaSeconds: Double = 30 * 60,
        mode: ProcessingMode = .offlineZeroCloud
    ) -> (DashboardViewModel, RecordingLaunchInbox, String) {
        makeViewModel(offlineSeconds: quotaSeconds, onlineSeconds: quotaSeconds, mode: mode)
    }

    /// Havuzlara AYRI değer koyan kurucu. Kapının hangi havuza baktığını
    /// sınayabilmenin tek yolu ikisini ayırmak: eşitken, yanlış havuza bakan
    /// bir kapı da testleri geçerdi.
    private func makeViewModel(
        offlineSeconds: Double,
        onlineSeconds: Double,
        mode: ProcessingMode = .offlineZeroCloud,
        offlinePlanMinutes: Double? = nil,
        onlinePlanMinutes: Double? = nil
    ) -> (DashboardViewModel, RecordingLaunchInbox, String) {

        let suite = "aura.gate.\(UUID().uuidString)"
        let inbox = RecordingLaunchInbox(defaults: UserDefaults(suiteName: suite)!)

        let viewModel = DashboardViewModel(
            quotaManager: QuotaManager(
                storage: InMemoryQuotaStorage(
                    offlineSeconds: offlineSeconds,
                    onlineSeconds: onlineSeconds,
                    bootstrapped: true,
                    offlinePlanMinutes: offlinePlanMinutes,
                    onlinePlanMinutes: onlinePlanMinutes
                )
            ),
            repository: InMemoryNoteRepository(),
            launchInbox: inbox
        )
        // `select(mode:)` model yokken offline'ı reddediyor; testin kurmak
        // istediği durum tam olarak o, bu yüzden doğrudan atanıyor.
        viewModel.mode = mode
        return (viewModel, inbox, suite)
    }

    private func cleanUp(_ suite: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: Model hazırlığı

    @Test("Model yokken offline kayıt başlamıyor")
    func offlineWithoutModelIsBlocked() {
        let (viewModel, _, suite) = makeViewModel(mode: .offlineZeroCloud)
        defer { cleanUp(suite) }

        viewModel.startManualRecording()

        // Eskiden kayıt başlıyor, 40 dakika sonra "Durdur"da patlıyordu.
        #expect(viewModel.recordingIntent == nil)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.offersModelDownload)
    }

    @Test("Online kayıt model gerektirmiyor")
    func onlineDoesNotNeedModel() {
        let (viewModel, _, suite) = makeViewModel(mode: .onlineCloudFast)
        defer { cleanUp(suite) }

        viewModel.startManualRecording()

        #expect(viewModel.recordingIntent?.mode == .onlineCloudFast)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Takvim ve arama tetikleyicileri de aynı kapıdan geçiyor")
    func calendarAndCallTriggersAreGated() {
        let (viewModel, _, suite) = makeViewModel(mode: .offlineZeroCloud)
        defer { cleanUp(suite) }

        viewModel.startCallRecording()
        #expect(viewModel.recordingIntent == nil)

        viewModel.dismissError()
        viewModel.startRecording(for: MeetingCandidate(
            id: "evt-1",
            eventIdentifier: "evt-1",
            title: "Sprint planlama",
            startDate: Date().addingTimeInterval(120),
            endDate: Date().addingTimeInterval(3_600),
            isVirtual: false,
            locationHint: nil,
            matchedKeyword: "sprint"
        ))
        #expect(viewModel.recordingIntent == nil)
    }

    // MARK: Kota

    @Test("Kota bittiyse paywall açılıyor, kayıt başlamıyor")
    func emptyQuotaOpensPaywall() {
        let (viewModel, _, suite) = makeViewModel(quotaSeconds: 0, mode: .onlineCloudFast)
        defer { cleanUp(suite) }

        viewModel.startManualRecording()

        #expect(viewModel.recordingIntent == nil)
        #expect(viewModel.isPaywallPresented)
    }

    @Test("Kota kontrolü model kontrolünden önce geliyor")
    func quotaCheckedBeforeModel() {
        // İkisi de eksikse kullanıcıya önce ödeme yolunu gösteriyoruz; model
        // indirmek kotayı geri getirmiyor.
        let (viewModel, _, suite) = makeViewModel(quotaSeconds: 0, mode: .offlineZeroCloud)
        defer { cleanUp(suite) }

        viewModel.startManualRecording()

        #expect(viewModel.isPaywallPresented)
        #expect(!viewModel.offersModelDownload)
    }

    @Test("Bulut havuzu boşken cihaz içi dolu olsa da bulut kaydı açılmıyor")
    func emptyOnlineLaneStillOpensPaywall() {
        // Kapı "herhangi bir havuzda dakika var mı" diye sorsaydı bu kayıt
        // başlar ve işleme anında yetersiz kotayla patlardı.
        let (viewModel, _, suite) = makeViewModel(
            offlineSeconds: 60 * 60, onlineSeconds: 0, mode: .onlineCloudFast
        )
        defer { cleanUp(suite) }

        viewModel.startManualRecording()

        #expect(viewModel.recordingIntent == nil)
        #expect(viewModel.isPaywallPresented)
        // Ekran hangi dakikanın bittiğini bilmeden doğru cümleyi kuramıyor.
        #expect(viewModel.paywallLane == .online)
    }

    @Test("Cihaz içi havuz boşken bulut dolu olsa da Zero-Cloud kaydı açılmıyor")
    func emptyOfflineLaneStillOpensPaywall() {
        let (viewModel, _, suite) = makeViewModel(
            offlineSeconds: 0, onlineSeconds: 60 * 60, mode: .offlineZeroCloud
        )
        defer { cleanUp(suite) }

        viewModel.startManualRecording()

        #expect(viewModel.recordingIntent == nil)
        #expect(viewModel.isPaywallPresented)
        #expect(viewModel.paywallLane == .offline)
    }

    @Test("Halka ve özet satırı seçili havuzu izliyor")
    func ringFollowsSelectedMode() {
        let (viewModel, _, suite) = makeViewModel(
            offlineSeconds: 120 * 60, onlineSeconds: 30 * 60, mode: .onlineCloudFast
        )
        defer { cleanUp(suite) }

        // Bakiyeyi kapı okuyor. `refresh()` bu paketin hiçbir testinde
        // çağrılmıyor: takvim ve bildirim yığınlarına dokunuyor ve testin
        // konusuyla ilgisi olmayan bir kırılganlık ekler.
        viewModel.startManualRecording()

        #expect(viewModel.activeLane == .online)
        #expect(viewModel.remainingMinutes == 30)

        viewModel.mode = .offlineZeroCloud
        #expect(viewModel.activeLane == .offline)
        #expect(viewModel.remainingMinutes == 120)
        // Özet satırı her iki havuzu da yazıyor; halka değişse de bu sabit.
        #expect(viewModel.laneSummary.contains("120"))
        #expect(viewModel.laneSummary.contains("30"))
    }

    /// Verilen plan ve bakiye ile "kota kritik mi" sorusunu sorar.
    private func isCritical(plan: Double, remaining: Double) -> Bool {
        let (viewModel, _, suite) = makeViewModel(
            offlineSeconds: 0,
            onlineSeconds: remaining * 60,
            mode: .onlineCloudFast,
            onlinePlanMinutes: plan
        )
        defer { cleanUp(suite) }

        // Bakiyeyi kapı okuyor.
        viewModel.startManualRecording()
        return viewModel.isQuotaCritical
    }

    @Test("Kritik eşiği plana oranlı")
    func criticalThresholdScalesWithPlan() {
        // Beklenen değerler ELLE yazılı, formül tekrar edilmiyor: testin
        // uygulamayla aynı hatayı yapması böyle engelleniyor.
        //
        // Küçük havuz (10 dk): eşik 2 dk.
        #expect(!isCritical(plan: 10, remaining: 4))
        #expect(isCritical(plan: 10, remaining: 1))
        // Büyük havuz (200 dk): eşik 5 dakikada tavanlanıyor, %20'de değil —
        // yoksa Pro kullanıcısı 40 dakika kala uyarı görürdü.
        #expect(isCritical(plan: 200, remaining: 4))
        #expect(!isCritical(plan: 200, remaining: 6))
        #expect(!isCritical(plan: 200, remaining: 40))
    }

    @Test("Küçük planda yarı yarıya kalan kota kritik sayılmıyor")
    func halfOfSmallPlanIsNotCritical() {
        // Yukarıdaki tablo formülü tekrar ediyor; bu test ÜRÜN davranışını
        // sabitliyor: ücretsiz bulut havuzunun (10 dk) yarısı kritik değil.
        let (viewModel, _, suite) = makeViewModel(
            offlineSeconds: 0,
            onlineSeconds: QuotaManager.freeOnlineMinutes * 60 / 2,
            mode: .onlineCloudFast,
            onlinePlanMinutes: QuotaManager.freeOnlineMinutes
        )
        defer { cleanUp(suite) }

        viewModel.startManualRecording()
        #expect(!viewModel.isQuotaCritical)
    }

    // MARK: Dışarıdan gelen istekler

    @Test("Açıkça istenen Zero-Cloud karşılanamıyorsa buluta düşmüyor")
    func explicitOfflineNeverFallsBackToCloud() {
        // Kontrol Merkezi'ndeki "Zero-Cloud Kayıt" düğmesi. Model kurulu değil
        // ve son seçili mod Online. Eski kod sessizce buluta kaydediyordu —
        // uygulamanın verdiği tek sözün sessizce bozulması.
        let (viewModel, inbox, suite) = makeViewModel(mode: .onlineCloudFast)
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .widget, mode: .offlineZeroCloud))
        viewModel.consumeLaunchRequest()

        #expect(viewModel.recordingIntent == nil)
        #expect(viewModel.mode == .onlineCloudFast)
        #expect(viewModel.offersModelDownload)
    }

    @Test("Açıkça istenen Online modu uygulanıyor")
    func explicitOnlineIsHonoured() {
        let (viewModel, inbox, suite) = makeViewModel(mode: .offlineZeroCloud)
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .siri, template: .quickNotes, mode: .onlineCloudFast))
        viewModel.consumeLaunchRequest()

        #expect(viewModel.recordingIntent?.mode == .onlineCloudFast)
        #expect(viewModel.recordingIntent?.template == .quickNotes)
        #expect(viewModel.mode == .onlineCloudFast)
    }

    @Test("Mod belirtilmemişse panelin seçimi kullanılıyor")
    func nilModeUsesCurrentSelection() {
        let (viewModel, inbox, suite) = makeViewModel(mode: .onlineCloudFast)
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .actionButton))
        viewModel.consumeLaunchRequest()

        #expect(viewModel.recordingIntent?.mode == .onlineCloudFast)
    }

    @Test("Süren kayıt başka bir niyetle kesilmiyor")
    func activeRecordingIsNotInterrupted() {
        let (viewModel, inbox, suite) = makeViewModel(mode: .onlineCloudFast)
        defer { cleanUp(suite) }

        viewModel.startManualRecording()
        let firstIntent = viewModel.recordingIntent
        #expect(firstIntent != nil)

        inbox.submit(RecordingLaunchRequest(source: .widget, mode: .onlineCloudFast))
        viewModel.consumeLaunchRequest()

        #expect(viewModel.recordingIntent == firstIntent)
    }

    @Test("Karşılanamayan istek kutuda birikmiyor")
    func rejectedRequestIsNotReplayed() {
        // İstek okunduğu anda kutudan çıkıyor; aksi halde her tazelemede aynı
        // uyarı tekrar tekrar açılırdı.
        let (viewModel, inbox, suite) = makeViewModel(mode: .onlineCloudFast)
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .widget, mode: .offlineZeroCloud))
        viewModel.consumeLaunchRequest()
        viewModel.dismissError()

        viewModel.consumeLaunchRequest()
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: Uyarı durumu

    @Test("Uyarı kapanınca indirme teklifi de kapanıyor")
    func dismissClearsOffer() {
        let (viewModel, _, suite) = makeViewModel(mode: .offlineZeroCloud)
        defer { cleanUp(suite) }

        viewModel.startManualRecording()
        #expect(viewModel.offersModelDownload)

        viewModel.dismissError()
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.offersModelDownload)
    }
}
