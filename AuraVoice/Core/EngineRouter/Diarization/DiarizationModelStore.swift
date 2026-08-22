//
//  DiarizationModelStore.swift
//  AuraVoice
//
//  Ayrıştırma modelinin kurulum takibi. ASR modelleriyle aynı mantık:
//  kurulum kaydı bir işaret dosyasında tutulur, klasör silinirse kurulu
//  sayılmaz.
//
//  Ayrıştırma modeli ASR modelinden BAĞIMSIZ indirilir — kullanıcı konuşmacı
//  etiketleri istemiyorsa fazladan indirme yapmasın diye.
//

import Foundation

public extension OfflineModelManager {

    nonisolated static var diarizationFolder: URL {
        modelsDirectory.appendingPathComponent("diarization", isDirectory: true)
    }

    private nonisolated static var diarizationMarker: URL {
        diarizationFolder.appendingPathComponent(".installed")
    }

    /// Yaklaşık indirme boyutu (kullanıcıya gösterilir).
    nonisolated static var diarizationApproximateMegabytes: Int { 92 }

    nonisolated static func isDiarizationInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: diarizationMarker.path)
            && fm.fileExists(atPath: diarizationFolder.path)
    }

    /// Kurulum tamamlandığında çağrılır.
    @discardableResult
    func markDiarizationInstalled() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.diarizationFolder, withIntermediateDirectories: true)
            try Data([1]).write(to: Self.diarizationMarker, options: .atomic)
            return true
        } catch {
            print("[AuraVoice] Ayrıştırma kurulum kaydı yazılamadı: \(error.localizedDescription)")
            return false
        }
    }

    func removeDiarization() throws {
        try? FileManager.default.removeItem(at: Self.diarizationFolder)
    }

    func diarizationDiskUsageBytes() -> Int64 {
        Self.directorySize(at: Self.diarizationFolder)
    }
}
