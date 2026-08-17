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

        Task.detached(priority: .utility) {
            // JSON tabanlı geçici depodan SwiftData'ya bir kereye mahsus taşıma.
            let migrated = (try? await DatabaseManager.shared.migrateLegacyNotesIfNeeded()) ?? 0
            if migrated > 0 {
                print("[AuraVoice] \(migrated) eski not SwiftData'ya taşındı.")
            }
            // Notu silinmiş ama diskte kalmış ses dosyalarını temizle.
            _ = try? await DatabaseManager.shared.pruneOrphanedRecordings()
        }

        return true
    }
}
