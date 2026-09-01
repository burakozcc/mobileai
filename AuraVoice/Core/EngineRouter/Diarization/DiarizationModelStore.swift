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

    /// Ağırlıkların gerçekten diskte olduğu kabul edilebilmesi için gereken
    /// en küçük boyut.
    ///
    /// Pyannote paketi ~92 MB; 20 MB'ın altı kesinlikle yarım kalmış bir
    /// indirmedir. Tam boyutu şart koşmuyoruz çünkü paket sürümle değişebilir.
    nonisolated static var diarizationMinimumBytes: Int64 { 20 * 1024 * 1024 }

    /// Kurulu mu.
    ///
    /// İşaret dosyasının VARLIĞI yetmiyordu: `markDiarizationInstalled`
    /// klasörü kendisi yaratıyor ve 1 baytlık işareti yazıyor, içeriği ise
    /// hiç denetlenmiyordu. SpeakerKit ağırlıkları başka bir yere koyduğunda
    /// Ayarlar "KURULU" diyor, `isAvailable` true dönüyor ve her ayrıştırma
    /// denemesi `SpeakerLabeler` tarafından sessizce yutuluyordu — kullanıcı
    /// hiç konuşmacı etiketi görmüyordu ve sebebini öğrenemiyordu.
    nonisolated static func isDiarizationInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: diarizationMarker.path),
              fm.fileExists(atPath: diarizationFolder.path)
        else { return false }

        return directorySize(at: diarizationFolder) >= diarizationMinimumBytes
    }

    /// Kurulum tamamlandığında çağrılır.
    ///
    /// İşareti yazmadan ÖNCE ağırlıkların gerçekten indiğini doğruluyor;
    /// aksi halde boş bir klasör "kurulu" sayılırdı.
    @discardableResult
    func markDiarizationInstalled() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.diarizationFolder, withIntermediateDirectories: true)
            Self.excludeFromBackup(Self.diarizationFolder)

            guard Self.directorySize(at: Self.diarizationFolder) >= Self.diarizationMinimumBytes else {
                print("[AuraVoice] Ayrıştırma modeli eksik indirilmiş, kurulu sayılmıyor.")
                return false
            }

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
