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
| Router | `Core/EngineRouter/ProcessingRouter.swift` | Arayüz tam, motorlar yer tutucu |
| Depolama | `Core/Storage/NoteStore.swift` | Geçici (SwiftData'ya taşınacak) |
| Ekran | `Features/Dashboard/*`, `Features/Recording/*`, `Features/NoteDetail/*` | Tam |

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

1. `OfflineEngine/WhisperKitEngine.swift` + `LocalLLMEngine.swift` (WhisperKit / ExecuTorch)
2. `OnlineEngine/CloudASRClient.swift` + `CloudLLMClient.swift`
3. `Storage/DatabaseManager.swift` + SwiftData `NoteEntity` / `TranscriptSegmentEntity`
   (`NoteStore` bu noktada emekli edilecek)
4. `Quota/SecureTicketStore.swift` — Ed25519 imzalı dakika bileti doğrulaması
5. `Paywall/SubscriptionPaywallView.swift` — RevenueCat
6. Widget / App Intents (Kilit Ekranı, Eylem Butonu, Siri)
