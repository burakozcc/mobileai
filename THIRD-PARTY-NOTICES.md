# Üçüncü Taraf Bildirimleri

AuraVoice, aşağıdaki üçüncü taraf bileşenleri kullanır. Bir kısmı uygulama
paketiyle **birlikte dağıtılır** (depoda dosya olarak duranlar), bir kısmı
derleme sırasında paket yöneticisiyle çekilir.

---

## Uygulama paketiyle dağıtılanlar

### OpenAI Whisper — tokenizer dosyaları

`AuraVoice/Resources/Tokenizers/` altındaki altı JSON dosyası
`openai/whisper-base` ve `openai/whisper-large-v3` depolarından **birebir**
alınmıştır; değiştirilmemişlerdir. Nasıl indirildikleri
`Tools/fetch-tokenizers.sh` içinde belgelidir.

- Kaynak: <https://huggingface.co/openai/whisper-base>,
  <https://huggingface.co/openai/whisper-large-v3>
- Telif: Copyright (c) 2022 OpenAI
- Lisans: MIT

Bu dosyalar uygulamaya gömülüdür çünkü WhisperKit, tokenizer'ı çalışma
anında Hugging Face'ten indirmeye çalışıyor; uçak modunda model diskte
dururken bile yükleme bu yüzden başarısız oluyordu.

> MIT License
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

### llama.cpp — `Vendor/llama.xcframework`

Depoda tutulmaz; `Tools/fetch-llama.sh` ile `b10456` etiketinden derlenir.
Uygulama paketine **dinamik çerçeve olarak gömülür**.

- Kaynak: <https://github.com/ggml-org/llama.cpp>
- Telif: Copyright (c) 2023-2024 The ggml authors
- Lisans: MIT

---

## Derleme sırasında çekilenler

### WhisperKit ve SpeakerKit (`argmax-oss-swift`)

- Kaynak: <https://github.com/argmaxinc/argmax-oss-swift>
- Lisans: MIT

### swift-transformers

`argmax-oss-swift` üzerinden dolaylı bağımlılık olarak geliyor.

- Kaynak: <https://github.com/huggingface/swift-transformers>
- Telif: Copyright 2022 Hugging Face SAS
- Lisans: Apache 2.0

`OfflineModelManager` içindeki bazı yorumlar bu kütüphanenin
`HubApi.swift` dosyasındaki satırlara atıf yapar; atıflar sabitlenmiş bir
commit'e (`573e5c9`) bağlıdır.

---

## Modeller

Uygulama, kullanıcı isterse çalışma anında model indirir. Bu modeller
depoda ya da uygulama paketinde **bulunmaz**; kullanıcının cihazına
doğrudan iner.

| Model | Kaynak | Lisans |
|---|---|---|
| Whisper (CoreML) | `argmaxinc/whisperkit-coreml` | MIT |
| Pyannote v4 (konuşmacı ayrıştırma) | SpeakerKit üzerinden | Kendi koşullarına tabi |
| Qwen3.5-2B GGUF | `unsloth/Qwen3.5-2B-GGUF` | Apache 2.0 |
