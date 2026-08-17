//
//  LiveWaveformView.swift
//  AuraVoice
//
//  Gerçek zamanlı dalga formu. `Canvas` kullanır: 25 fps'lik seviye akışında
//  56 çubuk için ayrı ayrı `View` oluşturmak yerine tek çizim geçişi yapılır
//  (SwiftUI diff maliyeti ~sıfır, pil dostu).
//
//  Seviye yumuşatma (attack/release) `AudioRecorderService` tarafında yapılır;
//  bu görünüm saf ve durumsuzdur → önizleme ve testte kolayca beslenebilir.
//

import SwiftUI

public struct LiveWaveformView: View {

    // MARK: Girdi

    /// 0...1 aralığında normalize edilmiş seviye penceresi (soldan sağa: eski → yeni).
    public var levels: [Float]
    public var tint: Color
    public var isActive: Bool
    public var barWidth: CGFloat
    public var spacing: CGFloat
    /// Sessizlikte bile görünen minimum çubuk yüksekliği oranı.
    public var floorRatio: CGFloat

    public init(
        levels: [Float],
        tint: Color,
        isActive: Bool = true,
        barWidth: CGFloat = 3.5,
        spacing: CGFloat = 3.5,
        floorRatio: CGFloat = 0.045
    ) {
        self.levels = levels
        self.tint = tint
        self.isActive = isActive
        self.barWidth = barWidth
        self.spacing = spacing
        self.floorRatio = floorRatio
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size, date: timeline.date)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Ses seviyesi göstergesi")
        .accessibilityValue(isActive ? "Kayıt sürüyor" : "Beklemede")
    }

    // MARK: Çizim

    private func draw(in context: inout GraphicsContext, size: CGSize, date: Date) {
        guard size.width > 0, size.height > 0, !levels.isEmpty else { return }

        let midY = size.height / 2
        let slot = barWidth + spacing
        let visibleCount = max(1, Int(size.width / slot))
        let window = Array(levels.suffix(visibleCount))
        // Genişlik çubuk sayısına tam bölünmediğinde sağa yaslayarak
        // yeni verinin daima aynı kenarda doğmasını sağlarız.
        let totalWidth = CGFloat(window.count) * slot - spacing
        let originX = max(0, size.width - totalWidth)

        // Sessizlikte hafif "nefes alma" — kullanıcı donmuş sanmasın.
        let breath = isActive
            ? 1.0 + 0.12 * sin(date.timeIntervalSinceReferenceDate * 3.0)
            : 1.0

        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [tint, tint.opacity(0.55), tint.opacity(0.85)]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: size.width, y: 0)
        )

        for (index, rawLevel) in window.enumerated() {
            let level = CGFloat(max(0, min(1, rawLevel)))
            // En yeni çubuklar tam parlak, eskiler hafifçe soluklaşır.
            let recency = CGFloat(index) / CGFloat(max(1, window.count - 1))
            let opacity = 0.35 + 0.65 * recency

            let amplitude = max(floorRatio, level) * breath
            let barHeight = min(size.height, amplitude * size.height)
            let x = originX + CGFloat(index) * slot
            let rect = CGRect(
                x: x,
                y: midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )

            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)
            context.opacity = opacity
            context.fill(path, with: shading)
        }

        context.opacity = 1

        // Merkez çizgisi — sessiz anlarda dalga formunu bir "zaman ekseni" gibi tutar.
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(
            baseline,
            with: .color(tint.opacity(0.10)),
            style: StrokeStyle(lineWidth: 0.75)
        )
    }
}

// MARK: - Kart içi minik dalga formu (statik özet)

public struct WaveformThumbnail: View {

    public var levels: [Float]
    public var tint: Color

    public init(levels: [Float], tint: Color) {
        self.levels = levels
        self.tint = tint
    }

    public var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty, size.width > 0 else { return }
            let slot = size.width / CGFloat(levels.count)
            let barWidth = max(1.2, slot * 0.55)
            let midY = size.height / 2

            for (index, level) in levels.enumerated() {
                let height = max(2, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * slot,
                    y: midY - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous),
                    with: .color(tint.opacity(0.65))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Canlı Dalga Formu") {
    struct PreviewHost: View {
        @State private var levels: [Float] = (0..<56).map { _ in Float.random(in: 0.05...0.9) }
        var body: some View {
            ZStack {
                AuraTheme.background.ignoresSafeArea()
                VStack(spacing: 32) {
                    LiveWaveformView(levels: levels, tint: AuraTheme.mint)
                        .frame(height: 120)
                    LiveWaveformView(levels: levels, tint: AuraTheme.recordRed)
                        .frame(height: 80)
                    WaveformThumbnail(levels: Array(levels.prefix(24)), tint: AuraTheme.indigo)
                        .frame(height: 28)
                }
                .padding()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    levels.removeFirst()
                    levels.append(Float.random(in: 0.05...0.95))
                }
            }
        }
    }
    return PreviewHost().preferredColorScheme(.dark)
}
