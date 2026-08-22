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
