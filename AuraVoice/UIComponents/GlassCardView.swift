//
//  GlassCardView.swift
//  AuraVoice
//
//  Koyu tema üzerinde kullanılan standart kart konteyneri.
//

import SwiftUI

public struct GlassCardView<Content: View>: View {

    private let content: Content
    private let padding: CGFloat
    private let borderTint: Color?
    private let isHighlighted: Bool

    public init(
        padding: CGFloat = 18,
        borderTint: Color? = nil,
        isHighlighted: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.borderTint = borderTint
        self.isHighlighted = isHighlighted
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AuraTheme.cardRadius, style: .continuous)
                    .fill(AuraTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: AuraTheme.cardRadius, style: .continuous)
                            .fill(AuraTheme.glassGradient)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AuraTheme.cardRadius, style: .continuous)
                    .strokeBorder(
                        borderTint?.opacity(isHighlighted ? 0.55 : 0.22) ?? AuraTheme.hairline,
                        lineWidth: isHighlighted ? 1.4 : 1
                    )
            }
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
            .shadow(
                color: (borderTint ?? .clear).opacity(isHighlighted ? 0.25 : 0),
                radius: 22, x: 0, y: 0
            )
    }
}

// MARK: - Etiket / Rozet

public struct AuraBadge: View {

    private let text: String
    private let systemImage: String?
    private let tint: Color

    public init(_ text: String, systemImage: String? = nil, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous).fill(tint.opacity(0.14))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Bölüm Başlığı

public struct AuraSectionHeader: View {

    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AuraTheme.textPrimary)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
        .padding(.horizontal, 2)
    }
}

#Preview {
    ZStack {
        AuraTheme.background.ignoresSafeArea()
        VStack(spacing: 16) {
            AuraSectionHeader("Son Kayıtlar", actionTitle: "Tümü") {}
            GlassCardView(borderTint: AuraTheme.mint, isHighlighted: true) {
                VStack(alignment: .leading, spacing: 10) {
                    AuraBadge("Zero-Cloud", systemImage: "lock.shield.fill", tint: AuraTheme.mint)
                    Text("Haftalık Ürün Sync")
                        .font(.headline)
                        .foregroundStyle(AuraTheme.textPrimary)
                }
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
