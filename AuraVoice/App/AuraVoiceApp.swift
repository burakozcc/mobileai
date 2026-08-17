//
//  AuraVoiceApp.swift
//  AuraVoice
//

import SwiftUI

@main
struct AuraVoiceApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
    }
}
