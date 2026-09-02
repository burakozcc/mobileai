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

    /// Seçilen model: Qwen3.5-2B, Q4_K_M kuantizasyonu.
    ///
    /// Boyut Hugging Face API'sinin bildirdiği gerçek değer, tahmin değil.
    ///
    /// SEÇİM GEREKÇESİ VE RİSKİ: çok dilli testlerde Qwen3-1.7B'nin önünde
    /// (INCLUDE 55,4 vs 51,8; Global PIQA 69,3 vs 63,1) ve uygulama tek dile
    /// değil bütün dillere hizmet edecek. Buna karşılık IFEval'de GERİDE
    /// (61,2 vs 68,2) — ki `K:/D:/A:` gibi katı bir biçimi tutturmakta en
    /// kritik yetenek talimat izleme. Gramer biçimi yapısal olarak zorluyor
    /// ama gramer İÇİNDEKİ anlam kalitesini zorlayamıyor. Gerçek Türkçe
    /// deşifreyle iki modelin yan yana koşulması hâlâ açık bir iş.
    ///
    /// Alternatif, tek satır değiştirilerek dönülebilir:
    ///   fileName "Qwen3-1.7B-Q4_K_M.gguf" · repo "unsloth/Qwen3-1.7B-GGUF"
    ///   · expectedBytes 1_107_409_472
    ///
    /// DOĞRULANMAMIŞ: mimari `Qwen3_5ForConditionalGeneration` (görsel-dil).
    /// `mmproj` dosyasını indirmiyoruz, yani metin-only çalışıyor; llama.cpp
    /// `qwen35`'i destekliyor ama M-RoPE'un mmproj'suz yüklemede metin
    /// konumları için doğru kurulduğu koddan doğrulanmadı. Uzun bağlamda
    /// tutarsızlık görülürse ilk şüpheli bu.
    enum NeuralModel {
        public static let fileName = "Qwen3.5-2B-Q4_K_M.gguf"
        public static let repositoryID = "unsloth/Qwen3.5-2B-GGUF"
        public static let expectedBytes = 1_280_835_840
        public static let approximateMegabytes = 1_221

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
