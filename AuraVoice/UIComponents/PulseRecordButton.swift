//
//  PulseRecordButton.swift
//  AuraVoice
//
//  Ana kayıt tetikleyicisi. Boştayken seçili modun rengini taşır (mint/indigo),
//  kayıt sırasında kırmızıya döner ve halkalar anlık ses seviyesiyle nabız atar.
//

import SwiftUI

public struct PulseRecordButton: View {

    public enum State: Equatable {
        case idle
        case recording
        case paused
        case processing
        case disabled
    }

    private let state: State
    private let tint: Color
    private let level: Float
    private let diameter: CGFloat
    private let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: State,
        tint: Color,
        level: Float = 0,
        diameter: CGFloat = 82,
        action: @escaping () -> Void
    ) {
        self.state = state
        self.tint = tint
        self.level = level
        self.diameter = diameter
        self.action = action
    }

    private var activeColor: Color {
        switch state {
        case .recording, .paused: return AuraTheme.recordRed
        case .disabled:           return AuraTheme.textSecondary
        default:                  return tint
        }
    }

    private var symbol: String {
        switch state {
        case .idle:       return "mic.fill"
        case .recording:  return "stop.fill"
        case .paused:     return "play.fill"
        case .processing: return "sparkles"
        case .disabled:   return "lock.fill"
        }
    }

    /// Ses seviyesi halkayı büyütür; hareket azaltma açıkken sabit kalır.
    private var pulseScale: CGFloat {
        guard state == .recording, !reduceMotion else { return 1.0 }
        return 1.0 + CGFloat(min(1, max(0, level))) * 0.42
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                // Dış nabız halkaları
                Circle()
                    .fill(activeColor.opacity(0.10))
                    .frame(width: diameter * 1.75, height: diameter * 1.75)
                    .scaleEffect(pulseScale)

                Circle()
                    .fill(activeColor.opacity(0.16))
                    .frame(width: diameter * 1.35, height: diameter * 1.35)
                    .scaleEffect(1 + (pulseScale - 1) * 0.6)

                // Gövde
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [activeColor, activeColor.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: activeColor.opacity(0.45), radius: 22, x: 0, y: 8)

                if state == .processing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black.opacity(0.8))
                        .scaleEffect(1.2)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.34, weight: .bold))
                        .foregroundStyle(state == .idle ? Color.black.opacity(0.85) : .white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: diameter * 1.75, height: diameter * 1.75)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .disabled || state == .processing)
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: pulseScale)
        .animation(.easeInOut(duration: 0.22), value: state)
        .sensoryFeedback(.impact(weight: .medium), trigger: state)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle:       return String(localized: "Kaydı başlat")
        case .recording:  return String(localized: "Kaydı durdur")
        case .paused:     return String(localized: "Kayda devam et")
        case .processing: return String(localized: "İşleniyor")
        case .disabled:   return String(localized: "Kayıt kullanılamıyor")
        }
    }
}

#Preview {
    ZStack {
        AuraTheme.background.ignoresSafeArea()
        HStack(spacing: 24) {
            PulseRecordButton(state: .idle, tint: AuraTheme.mint) {}
            PulseRecordButton(state: .recording, tint: AuraTheme.mint, level: 0.7) {}
            PulseRecordButton(state: .processing, tint: AuraTheme.indigo) {}
        }
    }
    .preferredColorScheme(.dark)
}
