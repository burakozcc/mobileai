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

        let suite = "aura.gate.\(UUID().uuidString)"
        let inbox = RecordingLaunchInbox(defaults: UserDefaults(suiteName: suite)!)

        let viewModel = DashboardViewModel(
            quotaManager: QuotaManager(
                storage: InMemoryQuotaStorage(initialSeconds: quotaSeconds, bootstrapped: true)
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
