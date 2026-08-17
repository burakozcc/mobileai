//
//  AuraVoiceApp.swift
//  AuraVoice
//

import SwiftUI
import SwiftData

@main
struct AuraVoiceApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
        // Yazma işleri `DatabaseManager` aktörü üzerinden gidiyor; bu konteyner
        // görünümlerin ileride `@Query` kullanabilmesi için bağlanıyor.
        .modelContainer(AuraModelContainer.shared)
    }
}
