# AuraVoice

Online (Bulut) / Offline (Zero-Cloud) çift motorlu, dakika kotalı toplantı ve
ses kayıt uygulaması. iOS 17+, Swift 6 katı eşzamanlılık, SwiftUI + SwiftData.

**Durum:** 211 test / 34 suite, GitHub Actions'ta gerçek `xcodebuild` ile yeşil.
Uygulama henüz bir cihazda veya simülatörde **çalıştırılmadı** — geliştirme
Windows'ta yapıldığı için doğrulama CI üzerinden yürüdü. İlk çalıştırma bir Mac
gerektiriyor (aşağıda).

---

## Projeyi açma

`.xcodeproj` depoda tutulmuyor (pbxproj birleştirme çatışmaları yüzünden).
Bir Mac'te:

```bash
brew install xcodegen && xcodegen generate && open AuraVoice.xcodeproj
```

Testler:

```bash
xcodebuild test -project AuraVoice.xcodeproj -scheme AuraVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```

`.github/workflows/ios-build.yml` aynı adımları macOS runner'ında koşturur.

### İlk çalıştırmadan önce yapılması gerekenler

1. **Takım kimliği.** `project.yml` içinde iki hedefte de `DEVELOPMENT_TEAM: ""`
   duruyor. Kendi takım kimliğini gir ya da Xcode'da her iki hedef için
   "Automatically manage signing" işaretle.

2. **App Group.** Widget uzantısı ana uygulamayla `group.com.auravoice.shared`
   konteynerini paylaşıyor. Xcode'da **her iki hedefte** Signing & Capabilities
   → App Groups altında bu kimliği ekle. Eklemezsen uygulama yine çalışır
   (kod standart `UserDefaults`'a düşüyor), yalnızca widget düğmesi uygulamaya
   ulaşamaz.

3. **Time Sensitive Notifications** (isteğe bağlı). Toplantı hatırlatmaları
   `interruptionLevel = .timeSensitive` kullanıyor. Entitlement onayı yoksa
   `Support/AuraVoice.entitlements` içindeki ilgili anahtarı silip
   `NotificationManager` içinde `.timeSensitive` → `.active` yap; bildirim yine
   gider, yalnızca Odaklanma modunda susturulur.

Mikrofon, takvim ve arka plan ses ayarları `project.yml` içinden üretiliyor,
elle Info.plist düzenlemeye gerek yok.

---

## Mimari

```
AuraVoice/
├── App/                     Giriş noktası, kök sekme çubuğu, AppDelegate
├── Core/
│   ├── Audio/               AVAudioEngine kaydı (16 kHz mono PCM, donanım AEC)
│   ├── EngineRouter/        Mod yönlendirme + iki motorun ortak sözleşmesi
│   │   ├── OfflineEngine/   WhisperKit ASR + çıkarımsal özetleme
│   │   ├── OnlineEngine/    Groq Whisper + Anthropic özetleme, yükleme hazırlığı
│   │   └── Diarization/     SpeakerKit (Pyannote v4) — her iki modda cihazda
│   ├── Intents/             Siri / Kısayol / widget niyetleri + App Group sözleşmesi
│   ├── Quota/               Dakika bakiyesi, Ed25519 imzalı biletler
│   ├── Storage/             SwiftData (@ModelActor), not ve segment varlıkları
│   └── Triggers/            Takvim taraması, bildirimler, CallKit gözlemcisi
├── Features/                Dashboard, Recording, Notes, NoteDetail, Settings, Onboarding
├── UIComponents/            Tema jetonları ve paylaşılan bileşenler
└── Resources/               Asset katalogu, PrivacyInfo.xcprivacy

AuraVoiceWidget/             Kilit ekranı kotası + Kontrol Merkezi kaydı (iOS 18)
```

### Bilinçli kararlar

**Sağlayıcı anahtarları uygulamada taşınmaz.** Üretim rotası `.proxy`:
anahtarlar ve kota doğrulaması sunucuda. Sunucu yokken `.userProvidedKey`
(kullanıcının kendi anahtarı, Keychain'de) devreye giriyor. `Info.plist`
içindeki `AuraCloudProxyBaseURL` rotayı seçiyor.

**Dakika bileti sunucudan gelir.** Bakiye cihazda ve uygulama offline
çalışabildiği için Keychain tek başına yeterli değil. Ed25519 imzalı bilet
dakikanın sunucudan geldiğini kanıtlıyor; özel anahtar cihaza hiç inmiyor.
Tekrar kullanım defteri ve "en ileri görülen zaman" saat geri almaya karşı
koruyor. Kanonik imza gövdesi `MinuteTicket.swift` başında birebir belgelendi —
sunucu tarafını yazarken tahmine yer yok.

**Uzun kayıtlar için sıkıştırma + parçalama.** Ham PCM saniyede ~32 KB; 25 MB
yükleme sınırı bunu ~13 dakikaya çeviriyordu. Sınırı aşan kayıt AAC'ye
kodlanıyor (~100 dakika), o da yetmezse bindirmeli parçalara bölünüyor ve
transkriptler tek zaman eksenine dikiliyor.

**Widget kotayı yeniden hesaplamaz.** Uygulama App Group'a anlık görüntü
yazıyor, uzantı okuyor. Kota kuralları iki yerde yaşasaydı iki farklı sayı
görürdük.

**Kayıt intent'in içinde başlamaz.** Siri / Action Button / widget yalnızca
niyeti kutuya bırakıp uygulamayı açıyor; kaydı Dashboard başlatıyor. Kayıt
ekranının açılması aynı zamanda kullanıcıya görsel onaydır.

---

## Tamamlananlar

| Alan | Durum |
|---|---|
| Kayıt (AVAudioEngine, 16 kHz mono, donanım AEC, kesinti kurtarma) | Tam |
| Canlı dalga formu | Tam |
| Offline motor (WhisperKit ASR + çıkarımsal özetleme) | Tam |
| Online motor (Groq Whisper + Anthropic özetleme, cihaz içi yedek) | Tam |
| Konuşmacı ayrıştırma (SpeakerKit / Pyannote v4) | Tam, her iki modda |
| Uzun kayıt yüklemesi (AAC sıkıştırma + bindirmeli parçalama) | Tam |
| Takvim tetikleyicisi + eylemli bildirimler | Tam |
| CallKit görüşme algılama | Tam |
| SwiftData depolama, arama, göç, yetim temizliği | Tam |
| Kota yönetimi (Keychain, hata yutmayan) | Tam |
| Ed25519 imzalı dakika biletleri + tekrar kullanım defteri | Tam (sunucu bekliyor) |
| Model indirme ekranı, ayarlar, onboarding | Tam |
| Not detayı: bölümler, işaretlenebilir görevler, transkript akordeonu | Tam |
| Siri / Kısayollar / Action Button (App Intents) | Tam |
| Widget: kilit ekranı kotası + Kontrol Merkezi kaydı | Tam |
| Uygulama ikonu, asset katalogu, `PrivacyInfo.xcprivacy` | Tam |
| GitHub Actions CI (gerçek `xcodebuild` + test) | Tam |

## Kalanlar

1. **Uygulamayı bir kez çalıştırmak.** Mac gerekiyor; ekran görüntüsü ve
   cihazda doğrulama henüz yok.
2. **Backend proxy.** `.proxy` rotası ve bilet imzalama için. Bilet doğrulama
   tarafı hazır, imzalayan taraf yok.
3. **RevenueCat paywall.** App Store Connect hesabı ve RevenueCat API anahtarı
   gerekiyor.
4. **Nöral cihaz içi özetleyici.** `LocalSummarizer` protokolü hazır;
   ExecuTorch / llama.cpp / Apple Foundation Models arka ucu takılacak.
   `ExtractiveSummarizer` yedek olarak kalacak.
5. **Yerelleştirme.** Metinler şu an sabit Türkçe.

### App Store için dikkat

Görüşme kaydı özelliği inceleme riski taşıyor: bazı ülkelerde her iki tarafın
rızası zorunlu. `CallObserverService` kaydı kendiliğinden başlatmıyor, yalnızca
kullanıcıya "hoparlörü açarak kaydı başlatabilirsiniz" diyor — bu ayrım
inceleme notunda açıkça anlatılmalı.
