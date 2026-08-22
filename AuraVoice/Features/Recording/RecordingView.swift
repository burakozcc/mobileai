//
//  RecordingView.swift
//  AuraVoice
//
//  Aktif kayıt ekranı — mockup düzeni: nefes alan kırmızı arka plan parıltısı,
//  büyük süre sayacı, canlı dalga formu, şablon seçici ve üç kontrol.
//
//  NOT: Mockup'ta dalga formu merkeze doğru yükselen dekoratif bir zarf
//  kullanıyor (rastgele veriyle çizildiği için). Bizde çubuklar GERÇEK ses
//  seviyesini gösteriyor ve soldan sağa akıyor; dekoratif zarfı uygulamak
//  veriyi çarpıtırdı, o yüzden yalnızca renk ve ölçü mockup'a uyarlandı.
//

import SwiftUI
import AVFoundation

/// Kayıt ekranının sonucu: not + zaman damgalı transkript parçaları.
public struct RecordingOutcome: Sendable {
    public let note: NoteSummary
    public let segments: [TranscriptSegment]

    public init(note: NoteSummary, segments: [TranscriptSegment]) {
        self.note = note
        self.segments = segments
    }
}

public struct RecordingView: View {

    // MARK: Girdi

    private let intent: RecordingIntent
    private let onFinish: (RecordingOutcome?) -> Void

    public init(intent: RecordingIntent, onFinish: @escaping (RecordingOutcome?) -> Void) {
        self.intent = intent
        self.onFinish = onFinish
        _template = State(initialValue: intent.template)
    }

    // MARK: Durum

    private enum Phase: Equatable {
        case preparing
        case recording
        case paused
        case processing
        case failed(String)
    }

    @StateObject private var recorder = AudioRecorderService()
    @State private var phase: Phase = .preparing
    @State private var template: SummaryTemplate
    @State private var allowanceSeconds: Double = 0
    @State private var showCancelConfirm = false
    @State private var processingStatus = "Hazırlanıyor…"
    @State private var isBreathing = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // `let` olsaydı SwiftUI her geçersizleştirmede struct'ı yeniden kurup yeni
    // bir ProcessingRouter — dolayısıyla yeni bir WhisperKitEngine aktörü —
    // üretirdi. Dalga formu `currentDuration`'ı saniyede onlarca kez
    // tetiklediği için bu, kayıt boyunca sürekli yeni Core ML yükleme demekti.
    @State private var router = ProcessingRouter()

    private var accent: Color { AuraTheme.accent(for: intent.mode) }
    private var isLive: Bool { phase == .recording }

    private var remainingAllowance: Double {
        max(0, allowanceSeconds - recorder.currentDuration)
    }

    private var isAllowanceCritical: Bool {
        remainingAllowance <= 60 && allowanceSeconds > 0
    }

    // MARK: Gövde

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()
            ambientGlow

            VStack(spacing: 0) {
                header
                Spacer(minLength: AuraTheme.Spacing.stackMD)
                statusBlock
                durationCounter
                waveform
                Spacer(minLength: AuraTheme.Spacing.stackMD)
                templateSelector
                controls
            }
            .padding(.horizontal, AuraTheme.Spacing.screenMargin)
            .padding(.bottom, AuraTheme.Spacing.stackLG)

            if case .processing = phase {
                processingOverlay.transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: phase)
        .task {
            await beginRecording()
            if !reduceMotion { isBreathing = true }
        }
        .onChange(of: recorder.currentDuration) { _, duration in
            // Kota bittiği anda kaydı otomatik kapat — kullanıcı ödemediği
            // dakikayı kaydetmiş olmasın.
            if allowanceSeconds > 0, duration >= allowanceSeconds, phase == .recording {
                Task { await stopAndProcess() }
            }
        }
        .confirmationDialog(
            "Kayıt silinsin mi?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Kaydı sil ve çık", role: .destructive) {
                recorder.cancelRecording()
                onFinish(nil)
                dismiss()
            }
            Button("Kayda devam et", role: .cancel) {}
        } message: {
            Text("Bu kaydın sesi ve metni kalıcı olarak silinir. Dakikan düşülmez.")
        }
    }

    // MARK: Arka plan parıltısı

    private var ambientGlow: some View {
        Circle()
            .fill((isLive ? AuraTheme.error : accent).opacity(0.10))
            .frame(width: 260, height: 260)
            .blur(radius: 90)
            .scaleEffect(isBreathing && isLive ? 1.25 : 1.0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 3).repeatForever(autoreverses: true),
                value: isBreathing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: Üst bar

    private var header: some View {
        HStack {
            Button {
                if recorder.currentDuration > 1 {
                    showCancelConfirm = true
                } else {
                    recorder.cancelRecording()
                    onFinish(nil)
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .disabled(phase == .processing)
            .accessibilityLabel("Kapat")

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: intent.mode.systemImage)
                    .font(.system(size: 11, weight: .bold))
                Text(intent.mode == .offlineZeroCloud ? "ZERO-CLOUD" : "BULUT")
                    .font(AuraFont.labelCaps)
                    .tracking(AuraFont.labelCapsTracking)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, AuraTheme.Spacing.gutter)
            .padding(.vertical, 7)
            .glassSurface(cornerRadius: 20, borderColor: accent.opacity(0.20))

            Spacer()

            // Dengeleyici boşluk.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.vertical, AuraTheme.Spacing.gutter)
    }

    // MARK: Durum

    private var statusBlock: some View {
        VStack(spacing: 4) {
            Text(statusText.uppercased())
                .font(AuraFont.labelCaps)
                .tracking(AuraFont.labelCapsTracking + 0.8)
                .foregroundStyle(isLive ? AuraTheme.error : AuraTheme.onSurfaceVariant)

            if let context = intent.contextTitle {
                Text(context)
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .lineLimit(1)
            }

            if allowanceSeconds > 0 {
                Text("\(AuraFormat.clock(remainingAllowance)) kota kaldı")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(isAllowanceCritical ? AuraTheme.warning : AuraTheme.onSurfaceVariant)
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .preparing:     return "Hazırlanıyor"
        case .recording:     return "Kaydediliyor"
        case .paused:        return "Duraklatıldı"
        case .processing:    return "İşleniyor"
        case .failed(let m): return m
        }
    }

    // MARK: Sayaç

    private var durationCounter: some View {
        Text(AuraFormat.clock(recorder.currentDuration))
            .font(AuraFont.durationDisplay)
            .tracking(AuraFont.durationTracking)
            .monospacedDigit()
            .foregroundStyle(AuraTheme.onSurface)
            .contentTransition(.numericText(countsDown: false))
            .animation(.linear(duration: 0.15), value: Int(recorder.currentDuration))
            .padding(.vertical, AuraTheme.Spacing.stackLG)
            .accessibilityLabel("Kayıt süresi")
            .accessibilityValue(AuraFormat.clock(recorder.currentDuration))
    }

    // MARK: Dalga formu

    private var waveform: some View {
        LiveWaveformView(
            levels: recorder.audioLevels,
            tint: isLive ? AuraTheme.error : accent,
            isActive: isLive,
            barWidth: 4,
            spacing: 4
        )
        .frame(height: 96)
    }

    // MARK: Şablon seçici

    private var templateSelector: some View {
        HStack(spacing: 4) {
            ForEach(SummaryTemplate.allCases) { candidate in
                Button {
                    template = candidate
                } label: {
                    Text(candidate.shortTitle)
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(template == candidate ? AuraTheme.onSurface : AuraTheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if template == candidate {
                                RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                                    .fill(AuraTheme.surfaceBright)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                                            .strokeBorder(AuraTheme.hairline, lineWidth: 1)
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(template == candidate ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: AuraTheme.Radius.extraLarge, style: .continuous)
                .fill(AuraTheme.surfaceContainerLow)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AuraTheme.Radius.extraLarge, style: .continuous)
                .strokeBorder(AuraTheme.hairline, lineWidth: 1)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: template)
        .disabled(phase == .processing)
        .padding(.bottom, AuraTheme.Spacing.stackLG)
    }

    // MARK: Kontroller

    private var controls: some View {
        HStack(spacing: AuraTheme.Spacing.stackLG) {
            secondaryControl(icon: "trash", label: "Kaydı sil") {
                showCancelConfirm = true
            }
            .disabled(phase == .processing)

            // Ana buton mockup'ta duraklat/devam; durdurma yan tarafta.
            Button {
                if phase == .paused {
                    recorder.resumeRecording()
                    phase = .recording
                } else {
                    recorder.pauseRecording()
                    phase = .paused
                }
            } label: {
                Image(systemName: phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AuraTheme.onError)
                    .frame(width: 80, height: 80)
                    .background { Circle().fill(AuraTheme.error) }
                    .auraGlow(AuraTheme.error, radius: 24, opacity: 0.25)
            }
            .buttonStyle(.plain)
            .disabled(phase == .processing || phase == .preparing)
            .sensoryFeedback(.impact(weight: .medium), trigger: phase)
            .accessibilityLabel(phase == .paused ? "Devam et" : "Duraklat")

            secondaryControl(icon: "stop.fill", label: "Kaydı bitir") {
                Task { await stopAndProcess() }
            }
            .disabled(phase == .processing || phase == .preparing)
        }
    }

    private func secondaryControl(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .frame(width: 56, height: 56)
                .background { Circle().fill(AuraTheme.surfaceContainer) }
                .overlay { Circle().strokeBorder(AuraTheme.hairline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: İşleme katmanı

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: AuraTheme.Spacing.stackMD) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(accent)
                    .scaleEffect(1.3)

                Text(processingStatus)
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurface)
                    .multilineTextAlignment(.center)

                Text(intent.mode == .offlineZeroCloud
                     ? "Tüm işlem cihazında yapılıyor — veri dışarı çıkmıyor."
                     : "Ses şifreli kanal üzerinden işleniyor.")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .padding(AuraTheme.Spacing.stackLG)
            .frame(maxWidth: .infinity)
            .glassSurface(borderColor: accent.opacity(0.30))
            .padding(.horizontal, 44)
        }
    }

    // MARK: Akış

    private func beginRecording() async {
        guard phase == .preparing else { return }

        let granted = await AudioRecorderService.requestMicrophonePermission()
        guard granted else {
            phase = .failed(AuraError.microphonePermissionDenied.errorDescription ?? "Mikrofon izni yok")
            return
        }

        allowanceSeconds = QuotaManager.shared.getRemainingSeconds()

        do {
            try recorder.startRecording()
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopAndProcess() async {
        guard phase == .recording || phase == .paused else { return }

        let result = recorder.stopRecording()
        guard let fileURL = result.fileURL, result.duration >= 1.0 else {
            // 1 saniyeden kısa kayıtları not olarak saklamanın anlamı yok.
            if let url = result.fileURL { try? FileManager.default.removeItem(at: url) }
            onFinish(nil)
            dismiss()
            return
        }

        let waveformPreview = AudioWaveformProcessor.downsample(recorder.audioLevels, to: 24)
        phase = .processing
        processingStatus = intent.mode == .offlineZeroCloud
            ? "Cihaz içi transkripsiyon…"
            : "Buluta yükleniyor…"

        let request = ProcessingRequest(
            audioFileURL: fileURL,
            durationSeconds: result.duration,
            mode: intent.mode,
            summaryTemplate: template
        )

        do {
            processingStatus = "Özet çıkarılıyor…"
            let output = try await router.execute(request: request)

            let note = NoteSummary(
                title: intent.contextTitle ?? defaultTitle(),
                durationSeconds: result.duration,
                mode: intent.mode,
                template: template,
                summaryMarkdown: output.summaryMarkdown,
                rawTranscript: output.rawTranscript,
                detectedLanguage: output.detectedLanguage,
                waveformPreview: waveformPreview,
                audioFileName: fileURL.lastPathComponent,
                sourceTrigger: intent.source
            )

            onFinish(RecordingOutcome(note: note, segments: output.segments))
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
            // Ses dosyası korunur: kullanıcı tekrar deneyebilsin diye silinmez.
            processingStatus = error.localizedDescription
        }
    }

    private func defaultTitle() -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        switch template {
        case .meetingNotes:     return "Toplantı · \(stamp)"
        case .phoneCallSummary: return "Görüşme · \(stamp)"
        case .quickNotes:       return "Hızlı Not · \(stamp)"
        }
    }
}

#Preview {
    RecordingView(
        intent: RecordingIntent(
            mode: .offlineZeroCloud,
            template: .meetingNotes,
            source: .calendar,
            contextTitle: "Haftalık Ürün Sync"
        )
    ) { _ in }
}
