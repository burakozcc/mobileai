//
//  LlamaTextGenerator.swift
//  AuraVoice
//
//  llama.cpp arka ucu — cihaz içi nöral özetleme.
//
//  llama.cpp'ye dokunan TEK dosya burasıdır; `TextGenerator` protokolü sınırı
//  çiziyor ve `NeuralSummarizer` bu dosyayı hiç görmüyor (sahte üreticiyle
//  test ediliyor). API değişirse düzeltme yüzeyi buraya sıkışıyor.
//
//  BAĞIMLILIK: Vendor/llama.xcframework. `Tools/fetch-llama.sh` üretiyor.
//  Hazır release artifact'ı KULLANILAMIYOR: güncel sürümlerde iOS simülatör
//  dilimi yok (PR #27252) ve testlerimiz simülatörde koşuyor.
//
//  EŞZAMANLILIK: llama.h yalnızca tokenizasyonun thread-safe olduğunu söylüyor
//  (satır 1152), gerisi garantisiz. Bu yüzden tüm handle'lar tek bir aktörün
//  private alanlarında duruyor ve sınırdan asla geçmiyor.
//

import Foundation
import llama

public actor LlamaTextGenerator: TextGenerator {

    // MARK: Yapılandırma

    public struct Configuration: Sendable {

        /// Bağlam penceresi. 4096, 1.400 token'lık parça + talimat + üretim
        /// için rahat; büyütmek KV önbelleğini doğrusal büyütüyor.
        public var contextTokens: UInt32 = 4_096
        public var batchTokens: UInt32 = 512
        /// Negatif = tüm katmanlar GPU'da. Simülatörde Metal yok, orada
        /// sessizce CPU'ya düşüyor.
        public var gpuLayers: Int32 = 99

        /// Özetleme yaratıcılık istemiyor: düşük sıcaklık uydurmayı azaltıyor.
        public var temperature: Float = 0.3
        public var topK: Int32 = 40
        public var topP: Float = 0.9
        public var repeatPenalty: Float = 1.1
        public var repeatLastN: Int32 = 64

        /// İstem biçimi. Qwen3 ChatML kullanıyor ve varsayılan olarak
        /// DÜŞÜNME modunda; boş bir `<think></think>` bloğu ön-doldurmak
        /// modeli doğrudan cevaba geçiriyor. Gramer zaten `<think>` üretmesini
        /// engelliyor ama düşünmeye alışkın bir modeli hazırlıksız yakalamak
        /// kaliteyi düşürüyor — sinyali açıkça veriyoruz.
        public var wrapsInChatML = true

        public init() {}
    }

    /// Ham istemi Qwen3'ün beklediği ChatML biçimine sarar.
    ///
    /// `SummaryPrompt` modelden bağımsız kalsın diye bu dönüşüm burada:
    /// başka bir arka uç başka bir şablon isteyecek.
    static func chatML(_ prompt: String) -> String {
        """
        <|im_start|>user
        \(prompt)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
    }

    // MARK: Durum

    private let modelURL: URL
    private let configuration: Configuration

    // `llama_vocab` / `llama_model` / `llama_context` llama.h'ta yalnızca ileri
    // bildirim — Swift bunları OpaquePointer olarak alıyor.
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?

    public init(modelURL: URL, configuration: Configuration = Configuration()) {
        self.modelURL = modelURL
        self.configuration = configuration
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    // MARK: Kurulum

    /// Süreç ömrü boyunca bir kez. `llama_backend_init` ve `llama_log_set`
    /// global durum yazıyor; header açıkça "NOT thread safe" diyor.
    private static let bootstrap: Void = {
        // Varsayılan logger her şeyi stderr'e döküyor ve uygulama loglarını
        // kullanılamaz hale getiriyor. Yakalamasız @convention(c) şart:
        // callback aktör durumuna dokunamaz.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    // MARK: TextGenerator

    public var isReady: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    public func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
    }

    public func tokenCount(_ text: String) async -> Int {
        guard let handles = try? loadedHandles() else {
            // Model yüklenemiyorsa tahmine düşüyoruz; çağıran yalnızca parça
            // bütçesi hesaplıyor ve yaklaşık değer işini görüyor.
            return TranscriptChunker.estimateTokens(text)
        }
        return tokenize(text, addSpecial: false, vocab: handles.vocab).count
    }

    public func generate(prompt: String, grammar: String?, maxTokens: Int) async throws -> String {

        let handles = try loadedHandles()
        let formatted = configuration.wrapsInChatML ? Self.chatML(prompt) : prompt
        var tokens = tokenize(formatted, addSpecial: true, vocab: handles.vocab)

        guard !tokens.isEmpty else {
            throw AuraError.engineFailure("İstem jetonlanamadı.")
        }

        // Prefill + üretim bağlama sığmalı. Sığmıyorsa istem kırpılmaz —
        // sessizce yarım bağlamla özet üretmektense açıkça hata veriyoruz;
        // `NeuralSummarizer` bunu yakalayıp çıkarımsala düşüyor.
        let room = Int(configuration.contextTokens) - maxTokens
        guard tokens.count < room else {
            throw AuraError.engineFailure(
                "İstem bağlama sığmıyor (\(tokens.count) jeton, sınır \(room))."
            )
        }

        // Her üretim temiz bağlamla başlıyor: aksi halde önceki parçanın KV'si
        // bir sonraki parçanın çıktısına sızıyor.
        llama_memory_clear(llama_get_memory(handles.context), true)

        guard let sampler = makeSampler(grammar: grammar, vocab: handles.vocab) else {
            throw AuraError.engineFailure("Örnekleyici kurulamadı.")
        }
        defer { llama_sampler_free(sampler) }

        // `llama_batch_get_one` diziyi KOPYALAMIYOR, yalnızca işaretçi tutuyor
        // (llama.h:940). Swift dizisinin geçici tamponunu vermek tanımsız
        // davranış olurdu; bu yüzden `llama_decode` dönene kadar sabit adreste
        // duran bir tampon elle ayrılıyor.
        let promptBuffer = UnsafeMutableBufferPointer<llama_token>.allocate(capacity: tokens.count)
        defer { promptBuffer.deallocate() }
        _ = promptBuffer.update(fromContentsOf: tokens)

        guard llama_decode(handles.context, llama_batch_get_one(promptBuffer.baseAddress, Int32(tokens.count))) == 0 else {
            throw AuraError.engineFailure("İstem işlenemedi.")
        }

        let stepBuffer = UnsafeMutableBufferPointer<llama_token>.allocate(capacity: 1)
        defer { stepBuffer.deallocate() }

        // Jeton parçaları UTF-8 dizisini ORTASINDAN bölebiliyor. Türkçe'de bu
        // kural değil istisna: her parçayı tek tek String'e çevirmek "ğ" ve
        // "ş" yerine kırık karakter üretirdi. Bayt biriktirip sonda bir kez
        // çözüyoruz.
        var bytes: [UInt8] = []

        for _ in 0..<maxTokens {
            try Task.checkCancellation()

            // `llama_sampler_sample` jetonu ZATEN kabul ediyor (llama.h:1520-1530).
            // Ayrıca `llama_sampler_accept` çağırmak gramer durumunu iki kez
            // ilerletir ve dilbilgisini bozar.
            let token = llama_sampler_sample(sampler, handles.context, -1)
            if llama_vocab_is_eog(handles.vocab, token) { break }

            bytes.append(contentsOf: pieceBytes(token, vocab: handles.vocab))

            stepBuffer[0] = token
            guard llama_decode(handles.context, llama_batch_get_one(stepBuffer.baseAddress, 1)) == 0 else {
                break
            }
        }

        tokens.removeAll()
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Model

    private struct Handles {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
    }

    private func loadedHandles() throws -> Handles {
        if let model, let context, let vocab {
            return Handles(model: model, context: context, vocab: vocab)
        }

        _ = Self.bootstrap

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw AuraError.offlineModelMissing
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = configuration.gpuLayers

        guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw AuraError.engineFailure("Nöral model yüklenemedi: \(modelURL.lastPathComponent)")
        }
        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            throw AuraError.engineFailure("Model sözlüğü okunamadı.")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = configuration.contextTokens
        contextParams.n_batch = configuration.batchTokens

        // Tüm çekirdekleri almak termal kısıtlamayı hızlandırıyor ve arayüzü
        // takıyor; ASR zaten ANE'yi doyurmuş olabiliyor.
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads

        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        // KV önbelleğini yarıya indiriyor — 4096 bağlamda telefonda fark ediliyor.
        contextParams.type_k = GGML_TYPE_Q8_0
        contextParams.type_v = GGML_TYPE_Q8_0

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw AuraError.engineFailure("Çıkarım bağlamı kurulamadı.")
        }

        model = loadedModel
        context = loadedContext
        vocab = loadedVocab

        return Handles(model: loadedModel, context: loadedContext, vocab: loadedVocab)
    }

    // MARK: Örnekleyici

    private func makeSampler(grammar: String?, vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler>? {

        var params = llama_sampler_chain_default_params()
        params.no_perf = true

        guard let chain = llama_sampler_chain_init(params) else { return nil }

        // GRAMER EN BAŞTA: geçersiz jetonlar daha logit aşamasında elensin.
        // Sonraya konursa top-k/top-p onları önce eleyip grameri boş bir
        // adaya mahkûm edebiliyor.
        if let grammar, !grammar.isEmpty {
            guard let grammarSampler = llama_sampler_init_grammar(vocab, grammar, "root") else {
                // Gramer ayrıştırılamadıysa kısıtsız üretmektense hata veriyoruz:
                // biçimsiz çıktı `SummaryDocument` tarafından sessizce maddeye
                // çevrilir ve kullanıcı bunu fark edemez.
                llama_sampler_free(chain)
                return nil
            }
            llama_sampler_chain_add(chain, grammarSampler)
        }

        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            llama_vocab_n_tokens(vocab),
            configuration.repeatLastN,
            configuration.repeatPenalty,
            0,
            0
        ))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(configuration.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(configuration.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(configuration.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(LLAMA_DEFAULT_SEED)))

        // Not: zincire eklenen örnekleyicilerin sahipliği zincire geçiyor
        // (llama.h:1341); ayrıca `llama_sampler_free` ETME.
        return chain
    }

    // MARK: Jetonlama

    private func tokenize(_ text: String, addSpecial: Bool, vocab: OpaquePointer) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        guard utf8Count > 0 else { return [] }

        // Jeton sayısı bayt sayısını asla aşamaz; tek geçişte bitiyor.
        let capacity = Int(utf8Count) + 8
        var tokens = [llama_token](repeating: 0, count: capacity)

        let written = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_tokenize(vocab, text, utf8Count, buffer.baseAddress, Int32(capacity), addSpecial, true)
        }

        guard written > 0 else { return [] }
        return Array(tokens.prefix(Int(written)))
    }

    private func pieceBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)

        var written = buffer.withUnsafeMutableBufferPointer {
            llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
        }

        if written < 0 {
            // Negatif dönüş gereken tampon boyutunu bildiriyor.
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = buffer.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
            }
        }

        guard written > 0 else { return [] }
        return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }
}
