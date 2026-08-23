//
//  NeuralModelStore.swift
//  AuraVoice
//
//  Nöral özetleyici modelinin diskteki yeri ve kurulum durumu.
//
//  KRİTİK KURAL: `OfflineModelManager.isOfflineReady()` bu modeli ASLA şart
//  koşmuyor. Offline modun taze kurulumda çalışması garantisi, çıkarımsal
//  özetleyicinin bağımlılıksız olmasına dayanıyor; nöral model tamamen
//  isteğe bağlı bir yükseltme.
//

import Foundation

public extension OfflineModelManager {

    /// Seçilen model: Qwen3-1.7B-Instruct, Q4_K_M kuantizasyonu.
    ///
    /// Boyut Hugging Face API'sinin bildirdiği gerçek değer, tahmin değil.
    /// Qwen3.5-2B de aday ama IFEval'de geride (61,2 vs 68,2) — ki `K:/D:/A:`
    /// gibi katı bir biçimi tutturmakta en kritik yetenek talimat izleme.
    /// İkisinin gerçek Türkçe deşifreyle yan yana koşulması gönderim öncesi
    /// bir kapı; masa başı kararı değil.
    enum NeuralModel {
        public static let fileName = "Qwen3-1.7B-Q4_K_M.gguf"
        public static let repositoryID = "unsloth/Qwen3-1.7B-GGUF"
        public static let expectedBytes = 1_107_409_472
        public static let approximateMegabytes = 1_056

        public static var downloadURL: URL? {
            URL(string: "https://huggingface.co/\(repositoryID)/resolve/main/\(fileName)")
        }
    }

    nonisolated static var neuralModelFolder: URL {
        modelsDirectory.appendingPathComponent("LLM", isDirectory: true)
    }

    nonisolated static var neuralModelURL: URL {
        neuralModelFolder.appendingPathComponent(NeuralModel.fileName)
    }

    /// Kurulu sayılmak için dosyanın VAR OLMASI yetmiyor, tam boyutta olması
    /// gerekiyor: yarım kalmış 1 GB'lık bir indirme "kurulu" görünüp her
    /// özetlemede sessizce çıkarımsala düşürürdü.
    nonisolated static func isNeuralSummarizerReady() -> Bool {
        let url = neuralModelURL
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return false }
        return size == NeuralModel.expectedBytes
    }

    /// Yarım kalmış indirmeyi temizler.
    @discardableResult
    nonisolated static func discardIncompleteNeuralModel() -> Bool {
        let url = neuralModelURL
        guard FileManager.default.fileExists(atPath: url.path), !isNeuralSummarizerReady() else {
            return false
        }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
