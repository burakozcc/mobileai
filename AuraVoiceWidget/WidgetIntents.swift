//
//  WidgetIntents.swift
//  AuraVoiceWidget
//
//  Widget ve Kontrol Merkezi düğmelerinin çalıştırdığı niyetler.
//
//  Bunlar ana uygulamadaki intent'lerin kopyası DEĞİL: uzantı ayrı bir süreç
//  ve ana uygulamanın tiplerini görmüyor. Ortak olan tek şey App Group'taki
//  veri şekli (`SharedLaunchRequest`) — o da tek bir paylaşılan dosyada.
//
//  Niyet uzantıda çalışıp isteği App Group'a yazıyor, `openAppWhenRun`
//  uygulamayı öne getiriyor, kaydı Dashboard başlatıyor. Kayıt uzantıda
//  başlatılamaz: uzantının mikrofon erişimi ve ses oturumu yoktur.
//

import AppIntents
import WidgetKit

struct StartRecordingFromWidgetIntent: AppIntent {

    static var title: LocalizedStringResource { "Kaydı Başlat" }

    static var description: IntentDescription {
        IntentDescription("AuraVoice'u açar ve kayıt ekranını hazırlar.")
    }

    static var openAppWhenRun: Bool { true }

    init() {}

    func perform() async throws -> some IntentResult {
        SharedLaunchRequest(
            source: AuraSharedContract.Values.widgetSource,
            template: AuraSharedContract.Values.meetingTemplate
        ).write()
        return .result()
    }
}

struct StartOfflineRecordingFromControlIntent: AppIntent {

    static var title: LocalizedStringResource { "Zero-Cloud Kaydı Başlat" }

    static var description: IntentDescription {
        IntentDescription("Kaydı tamamen cihaz içinde işlenecek şekilde başlatır.")
    }

    static var openAppWhenRun: Bool { true }

    init() {}

    func perform() async throws -> some IntentResult {
        SharedLaunchRequest(
            source: AuraSharedContract.Values.widgetSource,
            template: AuraSharedContract.Values.meetingTemplate,
            mode: AuraSharedContract.Values.offlineMode
        ).write()
        return .result()
    }
}
