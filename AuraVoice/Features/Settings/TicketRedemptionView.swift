//
//  TicketRedemptionView.swift
//  AuraVoice
//
//  İmzalı dakika biletini bozdurma ekranı.
//
//  NEDEN VAR: `SecureTicketStore` yazıldı, Ed25519 doğrulaması ve tekrar
//  kullanım defteri test edildi, ama hiçbir yerden ÇAĞRILMIYORDU — sistemin
//  tamamı ölü koddu. Bu ekran onu kullanıcıya bağlıyor.
//
//  NEDEN YAPIŞTIRMA: bilet OFFLINE bozdurulabilmeli. Bütün mesele o zaten —
//  kullanıcı uçakta, kotası bitmiş, elinde sunucunun daha önce imzaladığı bir
//  bilet var. Bir ağ çağrısı gerektiren akış bu senaryoyu karşılamazdı.
//  (QR okuma aynı `redeem(payload:)` yüzeyine bağlanabilir.)
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class TicketRedemptionViewModel {

    public enum Outcome: Equatable, Sendable {
        case idle
        case success(minutes: Double)
        case failure(String)
    }

    public var payload = ""
    public private(set) var outcome: Outcome = .idle
    public private(set) var isWorking = false

    /// Bilet altyapısı bu derlemede etkin mi.
    ///
    /// `Info.plist`'te açık anahtar yoksa `makeDefault` nil dönüyor: özellik
    /// sessizce kapalı, uygulama çalışmaya devam ediyor.
    public private(set) var isAvailable = false

    @ObservationIgnored private let makeStore: @MainActor () -> SecureTicketStore?
    @ObservationIgnored private var store: SecureTicketStore?

    public init(makeStore: @escaping @MainActor () -> SecureTicketStore? = { SecureTicketStore.makeDefault() }) {
        self.makeStore = makeStore
    }

    public func prepare() {
        store = makeStore()
        isAvailable = store != nil
    }

    public func redeem() async {
        guard !isWorking else { return }
        guard let store else {
            outcome = .failure(TicketError.verifierUnavailable.errorDescription ?? String(localized: "Bilet doğrulama kapalı."))
            return
        }

        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outcome = .failure(String(localized: "Önce bilet metnini yapıştır."))
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let ticket = try await store.redeem(payload: Data(trimmed.utf8))
            payload = ""
            outcome = .success(minutes: ticket.minutes)
        } catch let error as TicketError {
            outcome = .failure(error.errorDescription ?? String(localized: "Bilet kabul edilmedi."))
        } catch let error as AuraError {
            outcome = .failure(error.errorDescription ?? String(localized: "Bilet kabul edilmedi."))
        } catch {
            outcome = .failure(error.localizedDescription)
        }
    }

    public func pasteFromClipboard() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string {
            payload = text
        }
        #endif
    }
}

public struct TicketRedemptionView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = TicketRedemptionViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackMD) {
                    header

                    if viewModel.isAvailable {
                        editor
                        actions
                    } else {
                        unavailableNotice
                    }

                    if case let .success(minutes) = viewModel.outcome {
                        resultCard(
                            icon: "checkmark.circle.fill",
                            tint: AuraTheme.primary,
                            text: "\(Int(minutes)) dakika hesabına eklendi."
                        )
                    }
                    if case let .failure(reason) = viewModel.outcome {
                        resultCard(icon: "exclamationmark.triangle.fill", tint: AuraTheme.warning, text: reason)
                    }
                }
                .padding(AuraTheme.Spacing.screenMargin)
            }
        }
        .navigationTitle("Dakika Bileti")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.prepare() }
    }

    // MARK: Parçalar

    private var header: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.stackSM) {
            Text("Bilet, dakikanın sunucudan geldiğini kanıtlar.")
                .font(AuraFont.bodyLarge)
                .foregroundStyle(AuraTheme.onSurface)
            Text("İmza cihazda doğrulanıyor, yani bağlantı olmadan da kullanılabilir. Aynı bilet ikinci kez bozdurulamaz.")
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var editor: some View {
        TextEditor(text: $viewModel.payload)
            .font(AuraFont.bodySmall)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 140)
            .padding(AuraTheme.Spacing.stackSM)
            .glassSurface()
            .overlay(alignment: .topLeading) {
                if viewModel.payload.isEmpty {
                    Text("Bilet metnini buraya yapıştır")
                        .font(AuraFont.bodySmall)
                        .foregroundStyle(AuraTheme.onSurfaceVariant.opacity(0.6))
                        .padding(AuraTheme.Spacing.stackMD)
                        .allowsHitTesting(false)
                }
            }
    }

    private var actions: some View {
        HStack(spacing: AuraTheme.Spacing.gutter) {
            Button("YAPIŞTIR") { viewModel.pasteFromClipboard() }
                .font(AuraFont.labelCaps)
                .foregroundStyle(AuraTheme.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .fill(AuraTheme.surfaceContainerHigh)
                }
                .buttonStyle(.plain)

            Button {
                Task { await viewModel.redeem() }
            } label: {
                Group {
                    if viewModel.isWorking {
                        ProgressView().tint(AuraTheme.onPrimary)
                    } else {
                        Text("KULLAN").font(AuraFont.labelCaps)
                    }
                }
                .foregroundStyle(AuraTheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.large, style: .continuous)
                        .fill(AuraTheme.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWorking)
        }
    }

    private var unavailableNotice: some View {
        resultCard(
            icon: "lock.slash.fill",
            tint: AuraTheme.onSurfaceVariant,
            text: "Bu sürümde bilet doğrulama anahtarı tanımlı değil, dolayısıyla özellik kapalı."
        )
    }

    private func resultCard(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: AuraTheme.Spacing.gutter) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
            Text(text)
                .font(AuraFont.bodySmall)
                .foregroundStyle(AuraTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AuraTheme.Spacing.stackMD)
        .glassSurface(borderColor: tint.opacity(0.30))
    }
}
