//
//  AuraVoiceWidgetBundle.swift
//  AuraVoiceWidget
//
//  Uzantının giriş noktası. Kontrol Merkezi kontrolü iOS 18 gerektirdiği için
//  koşullu ekleniyor; iOS 17 cihazlarda paket yalnızca kota widget'ını sunar.
//

import WidgetKit
import SwiftUI

@main
struct AuraVoiceWidgetBundle: WidgetBundle {

    var body: some Widget {
        AuraQuotaWidget()

        if #available(iOS 18.0, *) {
            AuraRecordControl()
        }
    }
}
