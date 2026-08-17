# AuraVoice — Kurulum Notları (Adım 1)

Online (Bulut) / Offline (Zero-Cloud) çift motorlu, dakika kotalı akıllı toplantı
ve ses kayıt uygulaması. Bu adımda **Dashboard**, **Recording + canlı dalga formu**
ve **takvim entegre bildirim yöneticisi** tam çalışır halde yazıldı.

## Bu adımda üretilenler

| Katman | Dosya | Durum |
|---|---|---|
| Tema | `UIComponents/AuraTheme.swift` | Tam |
| Bileşen | `UIComponents/GlassCardView.swift`, `PulseRecordButton.swift` | Tam |
| Ses | `Core/Audio/AudioRecorderService.swift` | Tam (şablon düzeltildi) |
| Tetikleyici | `Core/Triggers/CalendarTriggerService.swift` | Tam (actor'a taşındı) |
| Tetikleyici | `Core/Triggers/NotificationManager.swift` | Tam |
| Tetikleyici | `Core/Triggers/CallObserverService.swift` | Tam |
| Kota | `Core/Quota/QuotaManager.swift` | Tam (Sendable düzeltmesi) |
| Router | `Core/EngineRouter/ProcessingRouter.swift` | Tam |
| Offline motor | `EngineRouter/OfflineEngine/*` | ASR + çıkarımsal özetleme tam |
| Online motor | `EngineRouter/OnlineEngine/*` | Yer tutucu |
| Depolama | `Core/Storage/DatabaseManager.swift` + `Entities/*` | Tam (SwiftData, `@ModelActor`) |
| Depolama | `Core/Storage/NoteSummary.swift` | DTO + bellek içi test sahtesi |
| Ekran | `Features/Dashboard/*`, `Features/Recording/*`, `Features/NoteDetail/*` | Tam |
| Test | `AuraVoiceTests/*` | 5 suite, Swift Testing |
| CI | `.github/workflows/ios-build.yml` | macOS runner'da xcodebuild + test |

## Projeyi açma

`.xcodeproj` depoda tutulmuyor (pbxproj birleştirme çatışmaları yüzünden).
Bir Mac'te:

```bash
brew install xcodegen && xcodegen generate && open AuraVoice.xcodeproj
```

Test çalıştırma:

```bash
xcodebuild test -project AuraVoice.xcodeproj -scheme AuraVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```

`.github/workflows/ios-build.yml` aynı adımları macOS runner'ında koşturur —
Mac erişimi olmadan da gerçek `xcodebuild` doğrulaması alınabilir.

## Xcode projesi ayarları

- **iOS Deployment Target:** 17.0
- **Swift Language Version:** Swift 6 (`SWIFT_STRICT_CONCURRENCY = complete`)
- **Signing & Capabilities → Background Modes:** `Audio, AirPlay, and Picture in Picture`
- **Capabilities:** Keychain Sharing (kota bileti için)
- **Capabilities → Time Sensitive Notifications:** Toplantı hatırlatmaları
  `interruptionLevel = .timeSensitive` kullanıyor. Bu entitlement olmadan bildirim
  yine gider ama Odaklanma modunda susturulur — `NotificationManager` içindeki
  `.timeSensitive` satırları entitlement eklenene kadar `.active` yapılabilir.

### Info.plist anahtarları (zorunlu)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Toplantı ve görüşmelerini kaydedip özet çıkarabilmek için mikrofona erişiyoruz. Offline modda ses cihazdan hiç çıkmaz.</string>

<key>NSCalendarsFullAccessUsageDescription</key>
<string>Yaklaşan toplantılarını cihazda tarayıp kayıt hatırlatması gönderebilmek için takvimine erişiyoruz. Etkinlik verisi hiçbir sunucuya gönderilmez.</string>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

> `NSRemindersFullAccessUsageDescription` gerekmez — yalnızca `EKEntityType.event` okunuyor.

## Bilinen sonraki adımlar

1. Nöral cihaz içi özetleyici — `LocalSummarizer` protokolüne ExecuTorch /
   llama.cpp / Apple Foundation Models arka ucu takılacak. `ExtractiveSummarizer`
   yedek olarak kalacak (model indirilmemişken ve bellek baskısında kullanılır).
2. `OnlineEngine/CloudASRClient.swift` + `CloudLLMClient.swift`
3. `Quota/SecureTicketStore.swift` — Ed25519 imzalı dakika bileti doğrulaması
4. `Paywall/SubscriptionPaywallView.swift` — RevenueCat
5. Widget / App Intents (Kilit Ekranı, Eylem Butonu, Siri)
