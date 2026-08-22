//
//  BundledTokenizers.swift
//  AuraVoice
//
//  Uygulama paketine gömülü Whisper tokenizer'ları.
//
//  NEDEN VAR: WhisperKit'in `download: false` bayrağı YALNIZCA Core ML
//  ağırlıklarını kapsıyor. Tokenizer ayrı bir yoldan (`loadTokenizerIfNeeded`)
//  yükleme anında Hugging Face'ten çekiliyor ve `tokenizerFolder` verilmezse
//  `?? downloadBase` de nil olduğu için HubApi varsayılanına düşüyor.
//
//  Sonuç: model diskte kurulu olsa bile uçak modunda transkripsiyon
//  başlamıyordu. Kullanıcı WiFi'da modeli indiriyor, uçağa biniyor, kayıt
//  yapıyor ve "Model yüklenemedi" alıyordu. Uygulamanın tek vaadi olan
//  "uçuş modunda dahi çalışır" cümlesi bu yüzden doğru değildi.
//
//  Ayrıca `argmaxinc/whisperkit-coreml` model klasörlerinde hiç tokenizer
//  dosyası yok — yalnızca `.mlmodelc` dizinleri ve iki config. Yani indirilen
//  klasörde tokenizer HİÇBİR ZAMAN bulunmuyor.
//
//  DOSYA YERLEŞİMİ: WhisperKit'in arama sırası (`ModelUtilities.loadTokenizer`)
//  önce `<kök>/models/<repoID>`, sonra düz `<kök>` bakıyor. `tokenizer.json`
//  ve `tokenizer_config.json` tiny/base/small/medium/large-v2 arasında birebir
//  aynı (aynı git blob), yalnızca large-v3 ailesi farklı (vocab 51866). Bu
//  yüzden 51865'lik set düz köke, large-v3'ünki adlandırılmış klasöre kondu:
//  varyant başına klasör açmaktan hem küçük hem de yeni varyant eklerken
//  dokunma gerektirmiyor.
//

import Foundation

/// `Bundle(for:)` için sabit nokta.
///
/// `Bundle.main` kullanılmıyor: birim test hedefi uygulamayı host alarak
/// koştuğunda `Bundle.main` test koşucusunu gösterebiliyor.
private final class AuraBundleToken {}

public enum BundledTokenizers {

    public static let directoryName = "Tokenizers"

    /// `WhisperKitConfig(tokenizerFolder:)` alanına verilecek kök.
    ///
    /// nil dönerse kaynak klasörü pakete kopyalanmamış demektir — bu sessizce
    /// yutulmamalı, çünkü sonucu "uçakta çalışmayan offline mod" oluyor.
    public static let root: URL? = {
        guard let resources = Bundle(for: AuraBundleToken.self).resourceURL else { return nil }
        let url = resources.appendingPathComponent(directoryName, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        return url
    }()

    /// Düz kök: 51865 vocab (tiny / base / small / medium / large-v2).
    public static var flatTokenizerJSON: URL? {
        root?.appendingPathComponent("tokenizer.json")
    }

    /// `HubApi.localRepoLocation` şemasını taklit eden adlandırılmış klasör.
    public static func folder(forRepoID repoID: String) -> URL? {
        root?
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    /// Verilen depo kimliği için `tokenizer.json` gerçekten pakette mi?
    public static func hasTokenizer(forRepoID repoID: String) -> Bool {
        guard let named = folder(forRepoID: repoID)?.appendingPathComponent("tokenizer.json") else {
            return false
        }
        if FileManager.default.fileExists(atPath: named.path) { return true }

        // Adlandırılmış klasör yoksa düz kök devreye giriyor.
        guard let flat = flatTokenizerJSON else { return false }
        return FileManager.default.fileExists(atPath: flat.path)
    }
}
