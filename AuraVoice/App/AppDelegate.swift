//
//  AppDelegate.swift
//  AuraVoice
//
//  Bildirim delegate'i ve CallKit gözlemcisi uygulama açılışında, SwiftUI
//  sahnesi kurulmadan ÖNCE bağlanmalı: aksi halde uygulama kapalıyken
//  bildirimdeki "Kaydı Başlat" eylemi kaybolur.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationManager.shared.bootstrap()
        CallObserverService.shared.start()
        return true
    }
}
