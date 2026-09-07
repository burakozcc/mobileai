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

/// İşleme ilerlemesini taşıyan küçük gözlemlenebilir kutu.
///
/// Motor ilerlemeyi `@Sendable` bir kapanıştan bildiriyor. `RecordingView` bir
/// struct ve `onFinish` kapanışı Sendable değil, dolayısıyla `self` o kapanışa
/// sokulamıyor. Bu sınıf sadece o sınırı geçmek için var.
@MainActor
@Observable
public final class ProcessingProgressModel {

    public var stage: ProcessingStage = .transcribing
    public var fraction: Double = 0

    public init() {}

    public nonisolated func report(_ stage: ProcessingStage, _ fraction: Double) {
        Task { @MainActor in
            self.stage = stage
            self.fraction = max(0, min(1, fraction))
        }
    }

    public func reset() {
        stage = .transcribing
        fraction = 0
    }
}

public struct RecordingView: View {

    // MARK: Girdi

    private let intent: RecordingIntent
    private let onFinish: (RecordingOutcome?) -> Void
    private let repository: any NoteRepository

    public init(
        intent: RecordingIntent,
        repository: any NoteRepository = DatabaseManager.shared,
        onFinish: @escaping (RecordingOutcome?) -> Void
    ) {
        self.intent = intent
        self.repository = repository
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
    /// Motor çalışmadan önce yazılan not. Hata durumunda tekrar denemek için
    /// elde tutuluyor.
    @State private var pendingNote: NoteSummary?
    @State private var progressModel = ProcessingProgressModel()
    @State private var processingTask: Task<Void, Never>?
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

                // Hata fazında duraklat/durdur anlamsız; kullanıcının burada
                // ihtiyacı olan şey çıkış yolu. Eskiden bu ekranda her düğme
                // devre dışıydı ve sheet de kapatılamıyordu — kullanıcının tek
                // seçeneği uygulamayı öldürmekti, ki kaydı kaybettiren tam
                // olarak o hareketti.
                if case .failed(let message) = phase {
                    failurePanel(message)
                } else {
                    // Şerit yalnızca canlı kayıtta anlamlı: işleme fazında
                    // kaplamanın altında asılı kalıyordu.
                    if recorder.resumeDidFail, recorder.isRecording { interruptionBanner }
                    templateSelector
                    controls
                }
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
        // Sistem kaynaklı duraklama (gelen arama, Siri) ekrana yansımalı.
        // Eskiden `RecordingView` `recorder.isPaused`'ı hiç gözlemiyordu ve
        // motor duraklamışken ekran "Kaydediliyor" yazmaya devam ediyordu.
        .onChange(of: recorder.isPaused) { _, paused in
            // Durdurma da `isPaused = false` yayınlıyor; onu "devam etti"
            // sanmak, kayıt biterken ekranı kısa süre "KAYDEDİLİYOR"a
            // çeviriyordu.
            guard recorder.isRecording else { return }
            if paused, phase == .recording { phase = .paused }
            if !paused, phase == .paused { phase = .recording }
        }
        .onChange(of: recorder.resumeDidFail) { _, failed in
            // Kesinti bitti ama motor geri gelemedi: kayıt fiilen durdu.
            if failed, phase == .recording { phase = .paused }
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
                // İşleme başlamışsa not zaten yazıldı; onu da temizle.
                Task { await discardFailedNote() }
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
            Text(statusText.uppercased(with: Locale.current))
                .font(AuraFont.labelCaps)
                .tracking(AuraFont.trackingSafe(1.4))
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
        case .preparing:     return String(localized: "Hazırlanıyor")
        case .recording:     return String(localized: "Kaydediliyor")
        case .paused:        return String(localized: "Duraklatıldı")
        case .processing:    return String(localized: "İşleniyor")
        // Hata metninin tamamı buraya gelirse 12pt tracked all-caps'e sokulup
        // Türkçe yazımı bozuluyordu. Ayrıntı artık kurtarma panelinde.
        case .failed:        return String(localized: "İşlenemedi")
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
            secondaryControl(icon: "trash", label: String(localized: "Kaydı sil")) {
                showCancelConfirm = true
            }
            .disabled(phase == .processing)

            // Ana buton mockup'ta duraklat/devam; durdurma yan tarafta.
            Button {
                if phase == .paused {
                    // Fazı KOŞULSUZ `.recording` yapmak m7'yi aynen geri
                    // getiriyordu: devam başarısızsa hiçbir @Published değer
                    // değişmiyor, gözlemciler tetiklenmiyor ve ekran
                    // "KAYDEDİLİYOR" yazarken WAV'a tek bayt gitmiyordu.
                    phase = recorder.resumeRecording() ? .recording : .paused
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

            secondaryControl(icon: "stop.fill", label: String(localized: "Kaydı bitir")) {
                Task { await stopAndProcess() }
            }
            .disabled(phase == .processing || phase == .preparing)
        }
    }

    // MARK: Kesinti uyarısı

    /// Kesinti sonrası motor geri gelemediğinde gösterilir.
    ///
    /// Sessiz bırakıldığında kullanıcı konuşmaya devam ediyor, WAV'a hiçbir
    /// şey yazılmıyor ve bunu ancak kaydı bitirince anlıyordu.
    private var interruptionBanner: some View {
        HStack(alignment: .top, spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(AuraTheme.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Kayıt kesildi")
                    .font(AuraFont.bodySmall.weight(.semibold))
                    .foregroundStyle(AuraTheme.onSurface)
                Text("Başka bir uygulama mikrofonu aldı. Devam etmek için oynat tuşuna bas ya da kaydı bitir.")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(AuraTheme.Spacing.gutter)
        .glassSurface(borderColor: AuraTheme.warning.opacity(0.30))
        .padding(.bottom, AuraTheme.Spacing.stackSM)
    }

    // MARK: Hata kurtarma

    private func failurePanel(_ message: String) -> some View {
        VStack(spacing: AuraTheme.Spacing.stackMD) {

            HStack(alignment: .top, spacing: AuraTheme.Spacing.gutter) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AuraTheme.warning)

                VStack(alignment: .leading, spacing: 4) {
                    Text("İşleme tamamlanamadı")
                        .font(AuraFont.bodyLarge)
                        .foregroundStyle(AuraTheme.onSurface)
                    // Hata metni gövde yazısı olarak veriliyor: eskiden tüm
                    // cümle 12pt tracked all-caps'e sokuluyordu ve Türkçe
                    // yazımı bozuluyordu.
                    Text(message)
                        .font(AuraFont.bodySmall)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Text("Kayıt notlarına kaydedildi, sesi duruyor. İstediğin zaman tekrar deneyebilirsin.")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AuraTheme.Spacing.gutter) {
                Button {
                    guard let pendingNote else { return }
                    startProcessing(pendingNote)
                } label: {
                    Text("TEKRAR DENE")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(AuraTheme.onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background {
                            RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                                .fill(AuraTheme.primary)
                        }
                }
                .buttonStyle(.plain)
                .disabled(pendingNote == nil)

                Button {
                    keepFailedNoteAndClose()
                } label: {
                    Text("NOTLARA GİT")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(AuraTheme.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background {
                            RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                                .fill(AuraTheme.surfaceContainerHigh)
                                .overlay {
                                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                                        .strokeBorder(AuraTheme.hairline, lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(borderColor: AuraTheme.warning.opacity(0.30))
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

                // Belirsiz spinner yerine gerçek yüzde: 45 dakikalık kayıtta
                // zamanın neredeyse tamamı transkripsiyonda geçiyor ve donuk
                // bir spinner kullanıcıya "takıldı" dedirtiyordu.
                ProgressView(value: progressModel.fraction)
                    .progressViewStyle(.linear)
                    .tint(accent)

                Text(progressModel.stage.label)
                    .font(AuraFont.bodyLarge)
                    .foregroundStyle(AuraTheme.onSurface)
                    .multilineTextAlignment(.center)

                Text("%\(Int((progressModel.fraction * 100).rounded()))")
                    .font(AuraFont.digitMono)
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.onSurfaceVariant)

                Text(intent.mode == .offlineZeroCloud
                     ? "Tüm işlem cihazında yapılıyor — veri dışarı çıkmıyor."
                     : "Ses şifreli kanal üzerinden işleniyor.")
                    .font(AuraFont.bodySmall)
                    .foregroundStyle(AuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)

                // İptal edilebilirlik şart: uzun bir işlemede tek çıkış yolu
                // uygulamayı öldürmek olmamalı.
                Button {
                    cancelProcessing()
                } label: {
                    Text("VAZGEÇ")
                        .font(AuraFont.labelCaps)
                        .tracking(AuraFont.labelCapsTracking)
                        .foregroundStyle(AuraTheme.onSurfaceVariant)
                        .padding(.horizontal, AuraTheme.Spacing.stackLG)
                        .padding(.vertical, 10)
                        .background {
                            Capsule().fill(AuraTheme.surfaceContainerHigh)
                                .overlay { Capsule().strokeBorder(AuraTheme.hairline, lineWidth: 1) }
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
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
            phase = .failed(AuraError.microphonePermissionDenied.errorDescription ?? String(localized: "Mikrofon izni yok"))
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

        // Motor çalışmadan ÖNCE notu yaz.
        //
        // Eskiden ses dosyası "kullanıcı tekrar denesin diye" korunuyordu ama
        // hiçbir NoteEntity onu referans etmediği için bir sonraki açılışta
        // prune siliyordu: uçakta işleme patlayan kullanıcı uygulamayı kapatıp
        // açtığında kaydını bulamıyordu. Artık bu noktadan sonra ne olursa
        // olsun (hata, çökme, kullanıcının uygulamayı öldürmesi) kayıt duruyor.
        let note = NoteSummary(
            title: intent.contextTitle ?? defaultTitle(),
            durationSeconds: result.duration,
            mode: intent.mode,
            template: template,
            summaryMarkdown: "",
            rawTranscript: "",
            waveformPreview: AudioWaveformProcessor.downsample(recorder.audioLevels, to: 24),
            audioFileName: fileURL.lastPathComponent,
            sourceTrigger: intent.source,
            processingState: .processing
        )
        pendingNote = note
        _ = try? await repository.insert(note)

        startProcessing(note)
    }

    /// İşlemeyi iptal edilebilir bir görevde başlatır.
    private func startProcessing(_ note: NoteSummary) {
        processingTask?.cancel()
        progressModel.reset()
        processingTask = Task { await process(note) }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
    }

    /// Transkripsiyon + özetleme. Hata sonrası "Tekrar dene" de buraya giriyor.
    private func process(_ note: NoteSummary) async {

        guard let fileName = note.audioFileName else { return }
        let fileURL = DatabaseManager.audioURL(for: fileName)

        phase = .processing

        // Kapanış yalnızca bu yerel referansı yakalıyor; `self` (View struct'ı)
        // Sendable olmadığı için oraya giremez.
        let reporter = progressModel

        var updated = note
        do {
            let output = try await router.execute(
                request: ProcessingRequest(
                    audioFileURL: fileURL,
                    durationSeconds: note.durationSeconds,
                    mode: intent.mode,
                    summaryTemplate: template
                ),
                progress: { stage, value in reporter.report(stage, value) }
            )

            updated.summaryMarkdown = output.summaryMarkdown
            updated.rawTranscript = output.rawTranscript
            updated.detectedLanguage = output.detectedLanguage
            updated.processingState = .ready
            updated.failureReason = nil

            // Son yazma DashboardViewModel'de: `insert` upsert olduğu için
            // aynı kimlik üzerine yazıyor, ikinci bir not oluşmuyor.
            onFinish(RecordingOutcome(note: updated, segments: output.segments))
            dismiss()

        } catch {
            // İptal kullanıcının kendi kararı; hata gibi sunulmamalı ama not
            // yine de tekrar denenebilir kalmalı.
            let reason = error is CancellationError
                ? String(localized: "İşleme durduruldu. Ses duruyor, istediğin zaman tekrar deneyebilirsin.")
                : error.localizedDescription

            updated.processingState = .failed
            updated.failureReason = reason
            pendingNote = updated
            _ = try? await repository.insert(updated)

            phase = .failed(reason)
        }
    }

    /// Başarısız notu listede bırakıp ekranı kapatır.
    private func keepFailedNoteAndClose() {
        onFinish(nil)
        dismiss()
    }

    /// Başarısız notu ve sesini tamamen siler.
    private func discardFailedNote() async {
        if let pendingNote {
            _ = try? await repository.delete(id: pendingNote.id)
        }
        onFinish(nil)
        dismiss()
    }

    private func defaultTitle() -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        switch template {
        case .meetingNotes:     return String(localized: "Toplantı · \(stamp)")
        case .phoneCallSummary: return String(localized: "Görüşme · \(stamp)")
        case .quickNotes:       return String(localized: "Hızlı Not · \(stamp)")
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
