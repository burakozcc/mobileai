//
//  LaunchIntentTests.swift
//  AuraVoiceTests
//
//  Siri / Kısayol / Action Button isteklerinin uygulamaya taşınması.
//

import Testing
import Foundation
import AppIntents
@testable import AuraVoice

@Suite("Kayıt isteği kutusu")
struct RecordingLaunchInboxTests {

    /// Her test kendi UserDefaults alanında çalışsın; testler birbirinin
    /// kutusunu görmesin.
    private func makeInbox() -> (RecordingLaunchInbox, String) {
        let suite = "aura.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (RecordingLaunchInbox(defaults: defaults), suite)
    }

    private func cleanUp(_ suite: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test("Bırakılan istek okunur")
    func submitThenTake() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .siri, template: .quickNotes, mode: .offlineZeroCloud))
        let request = inbox.take()

        #expect(request?.source == .siri)
        #expect(request?.template == .quickNotes)
        #expect(request?.mode == .offlineZeroCloud)
    }

    @Test("Okunan istek kutuda kalmaz")
    func takeEmptiesInbox() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .actionButton))
        _ = inbox.take()

        #expect(inbox.take() == nil)
    }

    @Test("Boş kutu nil döner")
    func emptyInbox() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }
        #expect(inbox.take() == nil)
    }

    @Test("Bayat istek kayıt başlatmaz")
    func staleRequestIsIgnored() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        let now = Date()
        inbox.submit(RecordingLaunchRequest(
            source: .siri,
            createdAt: now.addingTimeInterval(-RecordingLaunchInbox.freshnessWindow - 1)
        ))

        #expect(inbox.take(now: now) == nil)
    }

    @Test("Pencerenin içindeki istek geçerli")
    func freshRequestSurvives() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        let now = Date()
        inbox.submit(RecordingLaunchRequest(source: .siri, createdAt: now.addingTimeInterval(-10)))

        #expect(inbox.take(now: now) != nil)
    }

    @Test("Gelecek tarihli istek de yok sayılır")
    func futureDatedRequestIsIgnored() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        let now = Date()
        // Saat oynatılmış cihazda damga ileri düşebilir; mutlak farka bakıyoruz.
        inbox.submit(RecordingLaunchRequest(
            source: .siri,
            createdAt: now.addingTimeInterval(RecordingLaunchInbox.freshnessWindow + 60)
        ))

        #expect(inbox.take(now: now) == nil)
    }

    @Test("Son istek öncekinin üstüne yazar")
    func lastRequestWins() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .siri, template: .meetingNotes))
        inbox.submit(RecordingLaunchRequest(source: .actionButton, template: .quickNotes))

        let request = inbox.take()
        #expect(request?.source == .actionButton)
        #expect(request?.template == .quickNotes)
    }

    @Test("peek kutuyu boşaltmaz")
    func peekKeepsRequest() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .widget))

        #expect(inbox.peek()?.source == .widget)
        #expect(inbox.take() != nil)
    }

    @Test("clear bekleyen isteği siler")
    func clearRemovesRequest() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .siri))
        inbox.clear()

        #expect(inbox.take() == nil)
    }

    @Test("Bozuk yük çökme yerine nil verir")
    func corruptPayloadIsSafe() {
        let suite = "aura.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(Data("bu json degil".utf8), forKey: "aura.recording.launchRequest")

        #expect(RecordingLaunchInbox(defaults: defaults).take() == nil)
    }

    @Test("Mod belirtilmezse panelin seçimi geçerli")
    func nilModeMeansUserChoice() {
        let (inbox, suite) = makeInbox()
        defer { cleanUp(suite) }

        inbox.submit(RecordingLaunchRequest(source: .siri))
        #expect(inbox.take()?.mode == nil)
    }
}

@Suite("Intent parametre eşlemesi")
struct IntentParameterMappingTests {

    @Test("Mod seçimi işleme moduna eşlenir", arguments: zip(
        [RecordingModeChoice.offline, .online],
        [ProcessingMode.offlineZeroCloud, .onlineCloudFast]
    ))
    func modeMapping(choice: RecordingModeChoice, expected: ProcessingMode) {
        #expect(choice.processingMode == expected)
    }

    @Test("Şablon seçimi özet şablonuna eşlenir", arguments: zip(
        [RecordingTemplateChoice.meeting, .call, .quickNote],
        [SummaryTemplate.meetingNotes, .phoneCallSummary, .quickNotes]
    ))
    func templateMapping(choice: RecordingTemplateChoice, expected: SummaryTemplate) {
        #expect(choice.summaryTemplate == expected)
    }

    @Test("Her mod seçeneğinin görünen adı var")
    func everyModeHasDisplayName() {
        for choice in RecordingModeChoice.allCases {
            #expect(RecordingModeChoice.caseDisplayRepresentations[choice] != nil)
        }
    }

    @Test("Her şablon seçeneğinin görünen adı var")
    func everyTemplateHasDisplayName() {
        for choice in RecordingTemplateChoice.allCases {
            #expect(RecordingTemplateChoice.caseDisplayRepresentations[choice] != nil)
        }
    }
}

@Suite("Uzantı sözleşmesi")
struct SharedContractValueTests {

    @Test("Uzantının elle yazdığı ham değerler enum'larla aynı")
    func rawValuesMatchAppEnums() {
        // Uzantı uygulamanın enum'larını göremiyor ve bu String'leri elle
        // taşıyor. Enum ham değeri değişip burası unutulursa widget düğmesi
        // sessizce yanlış şablonla kayıt açardı — bu test onu yakalar.
        #expect(AuraSharedContract.Values.widgetSource == RecordingTriggerSource.widget.rawValue)
        #expect(AuraSharedContract.Values.meetingTemplate == SummaryTemplate.meetingNotes.rawValue)
        #expect(AuraSharedContract.Values.offlineMode == ProcessingMode.offlineZeroCloud.rawValue)
    }

    @Test("Sınır dönüşümü kayıpsız")
    func boundaryRoundTrip() {
        let original = RecordingLaunchRequest(
            source: .actionButton,
            template: .phoneCallSummary,
            mode: .onlineCloudFast,
            contextTitle: "Müşteri görüşmesi"
        )
        let restored = RecordingLaunchRequest(original.shared)

        #expect(restored == original)
    }

    @Test("Tanınmayan değerler güvenli varsayılana düşer")
    func unknownValuesFallBack() {
        let request = RecordingLaunchRequest(SharedLaunchRequest(
            source: "gelecekteki-kaynak",
            template: "bilinmeyen-sablon",
            mode: "bilinmeyen-mod"
        ))

        #expect(request.source == .widget)
        #expect(request.template == .meetingNotes)
        // Mod tanınmadıysa nil kalıyor: kullanıcının panel seçimi kazanır,
        // yanlış modda kayıt açmaktansa mevcut tercihi korunur.
        #expect(request.mode == nil)
    }

    /// Etkin havuzu doğrudan kuran yardımcı — bu testlerin konusu halkanın
    /// matematiği, havuz seçimi değil.
    private func snapshot(
        lane: QuotaLane = .online,
        remaining: Double,
        plan: Double
    ) -> SharedQuotaSnapshot {
        SharedQuotaSnapshot(
            lane: lane,
            offlineRemainingMinutes: lane == .offline ? remaining : 0,
            offlinePlanMinutes: lane == .offline ? plan : 0,
            onlineRemainingMinutes: lane == .online ? remaining : 0,
            onlinePlanMinutes: lane == .online ? plan : 0
        )
    }

    @Test("Kota oranı 0...1 aralığında kalır", arguments: zip(
        [30.0, 0.0, 45.0, 10.0],
        [30.0, 30.0, 30.0, 0.0]
    ))
    func snapshotFractionIsClamped(remaining: Double, plan: Double) {
        #expect(snapshot(remaining: remaining, plan: plan).fraction >= 0)
        #expect(snapshot(remaining: remaining, plan: plan).fraction <= 1)
    }

    @Test("Plan tanımsızsa oran sıfır — yanlış güven verilmez")
    func unknownPlanMeansEmptyRing() {
        #expect(snapshot(remaining: 45, plan: 0).fraction == 0)
    }

    @Test("Yarım dakikanın altı boş sayılır")
    func nearlyZeroIsEmpty() {
        #expect(snapshot(remaining: 0.4, plan: 30).isEmpty)
        #expect(!snapshot(remaining: 0.6, plan: 30).isEmpty)
    }

    @Test("Gösterilen sayı etkin havuzdan geliyor", arguments: QuotaLane.allCases)
    func snapshotShowsActiveLane(lane: QuotaLane) {
        // Widget kotayı kendi hesaplamıyor; hangi havuzu göstereceğini de
        // seçmiyor. Bu eşleme bozulursa uzantı doğru sayıyı yanlış etiketle
        // gösterirdi ve bunu fark ettirecek başka bir yer yok.
        let snapshot = SharedQuotaSnapshot(
            lane: lane,
            offlineRemainingMinutes: 84,
            offlinePlanMinutes: 120,
            onlineRemainingMinutes: 12,
            onlinePlanMinutes: 30
        )
        #expect(snapshot.remainingMinutes == (lane == .online ? 12 : 84))
        #expect(snapshot.planMinutes == (lane == .online ? 30 : 120))
    }

    @Test("Tek havuzlu eski anlık görüntü çözülebiliyor")
    func legacySnapshotStillDecodes() throws {
        // Uygulama güncellendiğinde App Group'ta eski biçimli bir kayıt
        // duruyor olabilir. Çözümleme patlarsa widget bir sonraki tazelemeye
        // kadar TAMAMEN boş kalırdı.
        let legacy = Data("""
        {"remainingMinutes":12,"planMinutes":30,"updatedAt":768000,"offlineAvailable":true}
        """.utf8)

        let decoded = try JSONDecoder().decode(SharedQuotaSnapshot.self, from: legacy)
        #expect(decoded.remainingMinutes == 12)
        #expect(decoded.lane == .offline)
        // Havuz alanları yokken etkin değerden kopyalanıyor: uygulama bir kez
        // tazeleyene kadar bilinen tek gerçek o.
        #expect(decoded.offlineRemainingMinutes == 12)
        #expect(decoded.onlineRemainingMinutes == 12)
    }
}
