//
//  RecordControl.swift
//  AuraVoiceWidget
//
//  Kontrol Merkezi ve kilit ekranı düğmesi (iOS 18+).
//
//  Şartnamedeki "Kontrol Merkezi'nden tek dokunuşla kayıt" maddesi. Uygulama
//  iOS 17'yi de desteklediği için tüm dosya `@available` ile kapalı; iOS 17
//  cihazlarda widget ve Siri kısayolu yolları çalışmaya devam ediyor.
//
//  Kontrol, kaydı offline moda sabitliyor: Kontrol Merkezi'ne düğme koyan
//  kullanıcı hızlı ve sessiz bir yol istiyor, "bu kayıt buluta mı gitti"
//  sorusunu sonradan sormak zorunda kalmamalı.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct AuraRecordControl: ControlWidget {

    static let kind = "AuraRecordControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartOfflineRecordingFromControlIntent()) {
                Label("Zero-Cloud Kayıt", systemImage: "mic.fill")
            }
        }
        .displayName("AuraVoice Kayıt")
        .description("Kaydı cihaz içinde işlenecek şekilde başlatır.")
    }
}
