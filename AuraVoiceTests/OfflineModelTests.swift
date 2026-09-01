//
//  OfflineModelTests.swift
//  AuraVoiceTests
//
//  Varyant secim politikasi ve paketlenmis tokenizer'lar.
//

import Testing
import Foundation
@testable import AuraVoice

private typealias Variant = WhisperKitEngine.Variant

@Suite("Model varyant politikasi")
struct VariantSelectionTests {

    @Test("A12/A13 sinifinda small bile yok, base seciliyor")
    func lowTierPicksBase() {
        #expect(Variant.best(from: [
            "openai_whisper-tiny",
            "openai_whisper-base"
        ]) == .base)
    }

    @Test("A14 sinifinda small seciliyor")
    func midTierPicksSmall() {
        #expect(Variant.best(from: [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small"
        ]) == .small)
    }

    @Test("A15 ve ustu turbo seciyor")
    func highTierPicksTurbo() {
        #expect(Variant.best(from: [
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB"
        ]) == .largeV3Turbo)
    }

    @Test("Kume bossa guvenli varsayilana dusuyor")
    func emptySetFallsBack() {
        #expect(Variant.best(from: []) == .base)
    }

    @Test("Taninmayan degerler secimi bozmuyor")
    func unknownEntriesIgnored() {
        #expect(Variant.best(from: ["gelecekteki-model", "openai_whisper-small"]) == .small)
    }

    @Test("Boyutlar Hugging Face'in bildirdigi gercek degerler")
    func sizesMatchHuggingFace() {
        // Tahmin degil: argmaxinc/whisperkit-coreml agac ucundan toplandi.
        #expect(Variant.tiny.approximateMegabytes == 77)
        #expect(Variant.base.approximateMegabytes == 147)
        #expect(Variant.small.approximateMegabytes == 487)
        #expect(Variant.largeV3Turbo.approximateMegabytes == 627)
    }

    @Test("Her varyantin tokenizer deposu tanimli")
    func everyVariantHasTokenizerRepo() {
        for variant in Variant.allCases {
            #expect(variant.tokenizerRepoID.hasPrefix("openai/whisper-"))
        }
    }

    @Test("large-v3 ailesi kendi tokenizer deposunu kullaniyor")
    func turboUsesLargeV3Tokenizer() {
        // Vocab 51866; digerleri 51865. Yanlis depo sessiz bozuk transkript verir.
        #expect(Variant.largeV3Turbo.tokenizerRepoID == "openai/whisper-large-v3")
        #expect(Variant.small.tokenizerRepoID == "openai/whisper-small")
    }

    @Test("rawValue tam klasor adi")
    func rawValuesAreFullFolderNames() {
        // WhisperKit.download "*<rawValue>/*" glob'uyla ariyor; kisaltilmis bir
        // ad birden cok klasorle eslesip indirmeyi hataya dusururdu.
        for variant in Variant.allCases {
            #expect(variant.rawValue.hasPrefix("openai_whisper-"))
        }
    }
}

@Suite("Paketlenmis tokenizer")
struct BundledTokenizerTests {

    @Test("Tokenizer klasoru uygulama paketine kopyalanmis")
    func tokenizerFolderIsBundled() throws {
        // Bu test kirmizi yaniyorsa project.yml'deki `type: folder` referansi
        // kaybolmustur ve offline mod ucak modunda calismaz.
        let root = try #require(BundledTokenizers.root)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Duz kokte 51865-vocab tokenizer var")
    func flatTokenizerExists() throws {
        let flat = try #require(BundledTokenizers.flatTokenizerJSON)
        let data = try Data(contentsOf: flat)
        // Byte esitligi bilerek: Git-LFS isaretcisi ya da yarim checkout
        // sessizce aga dusuyor, cunku yerel dal do/catch ile yutuluyor.
        #expect(data.count == 2_480_466)
    }

    @Test("Tokenizer yapilandirmasi WhisperTokenizer bildiriyor")
    func tokenizerConfigDeclaresClass() throws {
        let root = try #require(BundledTokenizers.root)
        let data = try Data(contentsOf: root.appendingPathComponent("tokenizer_config.json"))
        #expect(data.count == 282_683)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["tokenizer_class"] as? String == "WhisperTokenizer")
    }

    @Test("large-v3 tokenizer'i ayri klasorde")
    func largeV3TokenizerIsSeparate() throws {
        let folder = try #require(BundledTokenizers.folder(forRepoID: "openai/whisper-large-v3"))
        let tokenizer = try Data(contentsOf: folder.appendingPathComponent("tokenizer.json"))
        let config = try Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json"))

        // 51866 vocab: duz koktekinden farkli olmali.
        #expect(tokenizer.count == 2_480_617)
        #expect(config.count == 282_843)
    }

    @Test("Her varyant icin tokenizer cozulebiliyor")
    func everyVariantResolves() {
        for variant in Variant.allCases {
            #expect(BundledTokenizers.hasTokenizer(forRepoID: variant.tokenizerRepoID))
        }
    }
}

@Suite("Noral model deposu")
struct NeuralModelStoreTests {

    @Test("Indirme adresi model deposuyla tutarli")
    func downloadURLMatchesRepository() throws {
        let url = try #require(OfflineModelManager.NeuralModel.downloadURL)
        #expect(url.absoluteString.contains(OfflineModelManager.NeuralModel.repositoryID))
        #expect(url.absoluteString.hasSuffix(OfflineModelManager.NeuralModel.fileName))
        #expect(url.scheme == "https")
    }

    @Test("Beklenen boyut Hugging Face'in bildirdigi deger")
    func expectedBytesMatchHuggingFace() {
        // Tahmin degil: unsloth/Qwen3-1.7B-GGUF agac ucundan alindi.
        #expect(OfflineModelManager.NeuralModel.expectedBytes == 1_107_409_472)
    }

    @Test("Model yokken kurulu sayilmiyor")
    func missingModelIsNotReady() {
        // CI'da model hic indirilmiyor; dogru cevap "kurulu degil".
        #expect(!OfflineModelManager.isNeuralSummarizerReady())
    }

    @Test("Kurulu degilken disk kullanimi sifir")
    func diskUsageIsZeroWhenAbsent() {
        #expect(NeuralModelInstaller.shared.diskUsageBytes() == 0)
    }

    @Test("Model klasoru ASR modelleriyle ayni koke bagli")
    func modelFolderLivesUnderModelsDirectory() {
        #expect(OfflineModelManager.neuralModelFolder.path
            .hasPrefix(OfflineModelManager.modelsDirectory.path))
    }

    @Test("Noral model offline hazirligin sarti DEGIL")
    func neuralModelIsNotRequiredForOffline() {
        // Taze kurulumda offline modun calismasi garantisi cikarimsal
        // ozetleyicinin bagimliliksiz olmasina dayaniyor. Bu test o garantiyi
        // koruyor: noral model yokken de fabrika bir ozetleyici veriyor.
        #expect(!OfflineModelManager.isNeuralSummarizerReady())
        _ = LocalSummarizerFactory.makeDefault()
    }

    @Test("Arka plan oturumu kimligi sabit")
    func sessionIdentifierIsStable() {
        // Degisirse sistemin devrettigi yarim indirmeler sahipsiz kalir.
        #expect(NeuralModelDownloader.sessionIdentifier == "com.auravoice.neural-model-download")
    }
}

@Suite("Yarım kalan indirme temizliği", .serialized)
struct IncompleteDownloadCleanupTests {

    /// Gerçek model dizinine dokunmamak için izole bir kök.
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeArtifacts(for variant: Variant, in root: URL, bytes: Int = 2_048) throws {
        for folder in OfflineModelManager.speechArtifacts(for: variant, in: root) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes)
                .write(to: folder.appendingPathComponent("parca.bin"))
        }
    }

    @Test("Yerleşim swift-transformers'ın kullandığı yol")
    func layoutMatchesHubApi() throws {
        // HubApi.localRepoLocation = downloadBase/<repo.type>/<repo.id>
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoRoot = OfflineModelManager.speechRepositoryRoot(in: root)
        #expect(repoRoot.path.hasSuffix("models/argmaxinc/whisperkit-coreml"))

        let artifacts = OfflineModelManager.speechArtifacts(for: .base, in: root)
        #expect(artifacts.count == 2)
        #expect(artifacts[0].lastPathComponent == Variant.base.rawValue)
        // Yarım dosyalar ve metadata aynı göreli yolu izliyor.
        #expect(artifacts[1].path.contains(".cache/huggingface/download"))
        #expect(artifacts[1].lastPathComponent == Variant.base.rawValue)
    }

    @Test("Yarım kalan indirme siliniyor")
    func removesIncompleteDownload() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeArtifacts(for: .base, in: root)
        let freed = OfflineModelManager.discardIncompleteSpeechDownload(variant: .base, in: root)

        #expect(freed >= 4_096)
        for folder in OfflineModelManager.speechArtifacts(for: .base, in: root) {
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test("Temizlik komşu varyantı bozmuyor")
    func doesNotTouchOtherVariants() throws {
        // Kör bir `.cache` silme bunu bozardı; temizlik varyantla sınırlı.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeArtifacts(for: .base, in: root)
        try writeArtifacts(for: .small, in: root)

        OfflineModelManager.discardIncompleteSpeechDownload(variant: .base, in: root)

        for folder in OfflineModelManager.speechArtifacts(for: .small, in: root) {
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test("Silinecek bir şey yoksa iş yapılmıyor")
    func noOpWhenNothingOnDisk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OfflineModelManager.discardIncompleteSpeechDownload(variant: .tiny, in: root) == 0)
    }
}
