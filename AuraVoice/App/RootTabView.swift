//
//  RootTabView.swift
//  AuraVoice
//
//  Kök navigasyon — mockup'taki alt sekme çubuğu.
//
//  Sistem sekme çubuğu gizlenip yerine özel bir çubuk çiziliyor: tasarım
//  yüzey rengini (%90 opak + blur), aktif sekmede mint rengi, dolu ikon ve
//  %10 büyüme istiyor; bunların hiçbiri UIKit sekme çubuğunda ayarlanamıyor.
//  `TabView` yine de altta duruyor, böylece her sekmenin navigasyon yığını
//  ve durumu korunuyor.
//

import SwiftUI

public enum AuraTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case notes
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "Panel"
        case .notes:     return "Notlar"
        case .settings:  return "Ayarlar"
        }
    }

    /// Pasif durumda çizgisel, aktif durumda dolu ikon.
    public func systemImage(isActive: Bool) -> String {
        switch self {
        case .dashboard: return isActive ? "square.grid.2x2.fill" : "square.grid.2x2"
        case .notes:     return isActive ? "doc.text.fill" : "doc.text"
        case .settings:  return isActive ? "gearshape.fill" : "gearshape"
        }
    }
}

public struct RootTabView: View {

    @State private var selection: AuraTab = .dashboard

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tag(AuraTab.dashboard)
                .toolbar(.hidden, for: .tabBar)

            NotesListView()
                .tag(AuraTab.notes)
                .toolbar(.hidden, for: .tabBar)

            SettingsView()
                .tag(AuraTab.settings)
                .toolbar(.hidden, for: .tabBar)
        }
        .overlay(alignment: .bottom) {
            AuraTabBar(selection: $selection)
        }
        .auraBackground()
    }
}

// MARK: - Sekme çubuğu

public struct AuraTabBar: View {

    @Binding var selection: AuraTab

    public init(selection: Binding<AuraTab>) {
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(AuraTab.allCases) { tab in
                item(for: tab)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.screenMargin)
        .padding(.top, AuraTheme.Spacing.stackSM)
        .background {
            // surface/90 + backdrop-blur karşılığı.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(AuraTheme.background.opacity(0.75))
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AuraTheme.hairline)
                .frame(height: 1)
        }
    }

    private func item(for tab: AuraTab) -> some View {
        let isActive = selection == tab

        return Button {
            guard selection != tab else { return }
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage(isActive: isActive))
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .frame(height: 22)

                Text(tab.title)
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
            }
            .foregroundStyle(isActive ? AuraTheme.primary : AuraTheme.onSurfaceVariant)
            .scaleEffect(isActive ? 1.1 : 1.0)
            .frame(maxWidth: .infinity)
            // Dokunma hedefi en az 44pt olmalı (erişilebilirlik).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isActive)
        .sensoryFeedback(.selection, trigger: isActive)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    RootTabView()
}
