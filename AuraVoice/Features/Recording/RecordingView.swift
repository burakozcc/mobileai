//
//  RecordingView.swift
//  AuraVoice
//
//  Aktif kayıt ekranı: canlı dalga formu, süre, kalan kota geri sayımı ve
//  kayıt sonrası işleme akışı (ProcessingRouter → NoteSummary).
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

    @Environment(\.dismiss) private var dismiss

    private let router = ProcessingRouter()

    private var accent: Color { AuraTheme.accent(for: intent.mode) }

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
            backdropGlow

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                timerBlock
                waveformBlock
                Spacer(minLength: 12)
                templatePicker
                controls
            }
            .padding(.horizontal, AuraTheme.screenPadding)
            .padding(.vertical, 22)

            if case .processing = phase {
                processingOverlay
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: phase)
        .task { await beginRecording() }
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

    private var backdropGlow: some View {
        RadialGradient(
            colors: [
                (phase == .recording ? AuraTheme.recordRed : accent)
                    .opacity(0.16 + Double(recorder.peakLevel) * 0.16),
                .clear
            ],
            center: .center,
            startRadius: 10,
            endRadius: 330
        )
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: recorder.peakLevel)
    }

    // MARK: Üst Bar

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                AuraBadge(
                    intent.mode == .offlineZeroCloud ? "Zero-Cloud · Cihaz İçi" : "Bulut · Hızlı",
                    systemImage: intent.mode.systemImage,
                    tint: accent
                )
                if let context = intent.contextTitle {
                    Text(context)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button {
                if recorder.currentDuration > 1 {
                    showCancelConfirm = true
                } else {
                    recorder.cancelRecording()
                    onFinish(nil)
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AuraTheme.surface))
            }
            .buttonStyle(.plain)
            .disabled(phase == .processing)
            .accessibilityLabel("Kaydı iptal et")
        }
    }

    // MARK: Sayaç

    private var timerBlock: some View {
        VStack(spacing: 10) {
            Text(AuraFormat.clock(recorder.currentDuration))
                .font(.system(size: 58, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText(countsDown: false))
                .animation(.linear(duration: 0.15), value: Int(recorder.currentDuration))

            HStack(spacing: 8) {
                Circle()
                    .fill(phase == .recording ? AuraTheme.recordRed : AuraTheme.textSecondary)
                    .frame(width: 8, height: 8)
                    .opacity(phase == .recording ? 0.35 + Double(recorder.peakLevel) * 0.65 : 0.5)
                    .animation(.easeOut(duration: 0.15), value: recorder.peakLevel)

                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(phase == .recording ? AuraTheme.recordRed : AuraTheme.textSecondary)
            }

            if allowanceSeconds > 0 {
                Text("Kota: \(AuraFormat.clock(remainingAllowance)) kaldı")
                    .font(.system(size: 12, weight: isAllowanceCritical ? .semibold : .regular))
                    .foregroundStyle(isAllowanceCritical ? AuraTheme.warning : AuraTheme.textSecondary)
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .preparing:      return "Mikrofon hazırlanıyor"
        case .recording:      return "Kaydediliyor"
        case .paused:         return "Duraklatıldı"
        case .processing:     return "İşleniyor"
        case .failed(let m):  return m
        }
    }

    // MARK: Dalga Formu

    private var waveformBlock: some View {
        LiveWaveformView(
            levels: recorder.audioLevels,
            tint: phase == .recording ? AuraTheme.recordRed : accent,
            isActive: phase == .recording
        )
        .frame(height: 150)
        .padding(.vertical, 18)
    }

    // MARK: Şablon Seçici

    private var templatePicker: some View {
        HStack(spacing: 8) {
            ForEach(SummaryTemplate.allCases) { candidate in
                Button {
                    template = candidate
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: candidate.systemImage)
                            .font(.system(size: 10, weight: .bold))
                        Text(candidate.shortTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        Capsule().fill(template == candidate ? accent.opacity(0.18) : AuraTheme.surface)
                    }
                    .overlay {
                        Capsule().strokeBorder(
                            template == candidate ? accent.opacity(0.5) : AuraTheme.hairline,
                            lineWidth: 1
                        )
                    }
                    .foregroundStyle(template == candidate ? accent : AuraTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(phase == .processing)
        .padding(.bottom, 24)
    }

    // MARK: Kontroller

    private var controls: some View {
        HStack(spacing: 34) {
            // Duraklat / Devam
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
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(AuraTheme.surface))
                    .overlay { Circle().strokeBorder(AuraTheme.hairline, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(phase == .processing || phase == .preparing)
            .accessibilityLabel(phase == .paused ? "Devam et" : "Duraklat")

            // Durdur & işle
            PulseRecordButton(
                state: pulseState,
                tint: accent,
                level: recorder.peakLevel,
                diameter: 78
            ) {
                Task { await stopAndProcess() }
            }

            // İptal
            Button {
                showCancelConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(AuraTheme.surface))
                    .overlay { Circle().strokeBorder(AuraTheme.hairline, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(phase == .processing)
            .accessibilityLabel("Kaydı sil")
        }
    }

    private var pulseState: PulseRecordButton.State {
        switch phase {
        case .preparing:  return .disabled
        case .recording:  return .recording
        case .paused:     return .paused
        case .processing: return .processing
        case .failed:     return .idle
        }
    }

    // MARK: İşleme Katmanı

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            GlassCardView(padding: 26, borderTint: accent, isHighlighted: true) {
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(accent)
                        .scaleEffect(1.3)
                    Text(processingStatus)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AuraTheme.textPrimary)
                    Text(intent.mode == .offlineZeroCloud
                         ? "Tüm işlem cihazında yapılıyor — veri dışarı çıkmıyor."
                         : "Ses şifreli kanal üzerinden işleniyor.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AuraTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 40)
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
