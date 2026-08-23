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
        // Yol raporu ilk saniyelerde geliyor; erken başlatmak panelin açılışta
        // "bilinmiyor" göstermesini engelliyor.
        NetworkMonitor.shared.start()

        Task.detached(priority: .utility) {
            // JSON tabanlı geçici depodan SwiftData'ya bir kereye mahsus taşıma.
            let migrated = (try? await DatabaseManager.shared.migrateLegacyNotesIfNeeded()) ?? 0
            if migrated > 0 {
                print("[AuraVoice] \(migrated) eski not SwiftData'ya taşındı.")
            }
            // Önceki oturum işleme ortasında öldürülmüşse notu kurtar.
            // Temizlikten ÖNCE çalışmalı: kurtarılan not sesini referans
            // ediyor ve o referans olmadan dosya yetim sayılırdı.
            let recovered = (try? await DatabaseManager.shared.recoverInterruptedProcessing()) ?? 0
            if recovered > 0 {
                print("[AuraVoice] \(recovered) yarım kalmış işleme kurtarıldı.")
            }

            // Notu silinmiş ama diskte kalmış ses dosyalarını temizle.
            _ = try? await DatabaseManager.shared.pruneOrphanedRecordings()
        }

        return true
    }

    /// 1,11 GB'lık model indirmesi arka plan oturumunda sürüyor; uygulama
    /// öldürülmüş olsa bile sistem onu yeniden başlatıp dosyayı teslim ediyor.
    /// Bu geri çağrı bağlanmazsa sistem uygulamayı "takıldı" sayıyor.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == NeuralModelDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        NeuralModelDownloader.shared.attachSystemCompletionHandler(SystemCompletionBox(completionHandler))
    }
}
