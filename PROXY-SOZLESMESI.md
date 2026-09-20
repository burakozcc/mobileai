# AuraVoice Proxy Sözleşmesi

Sunucuyu yazacak kişi için. Buradaki her uç nokta, başlık ve gövde biçimi
**uygulamanın bugün gönderdiği şeyden** çıkarıldı — tasarım önerisi değil,
mevcut istemcinin dayattığı sözleşme. Her maddenin yanında kaynağı yazılı;
şüphe duyduğunda koda bak, bu belgeye değil.

Belgenin sonunda **henüz iki tarafta da olmayan** iki akış var (oturum jetonu
ve bilet dağıtımı). Onlar öneri; gerisi zorunluluk.

---

## 1. Neden proxy var

Sağlayıcı API anahtarını uygulama ikilisine gömmek kırılmış bir tasarım. IPA
herkese açık; anahtar `strings` ile çıkarılıp senin hesabına fatura edilir.
Daha kötüsü: anahtar cihazdayken kullanıcı dakika kotasını tamamen atlayıp
doğrudan sağlayıcıya gidebilir, yani ürünün gelir modeli çöker.

Gerekçenin tamamı `AuraVoice/Core/EngineRouter/OnlineEngine/CloudCredentials.swift`
başında.

**Kurumsal/bireysel ayrımı bir arayüz ayrımıdır, arka planda bir ayrım
değildir.** Uygulama her iki durumda da yalnızca proxy ile konuşur. Kurumsal
müşterinin anahtarı sunucuda, kuruma bağlı saklanır; uygulama yalnızca giriş
yüzeyidir, anahtarın deposu değil.

---

## 2. Bağlanma ve temel kurallar

| | |
|---|---|
| Taban adres | `Info.plist` → `AuraCloudProxyBaseURL` |
| Şema | **Yalnızca `https`**. `http` başlayan adres reddediliyor, rota BYOK'a düşüyor. |
| Kimlik | Her istekte `Authorization: Bearer <oturum-jetonu>` |
| Zaman aşımı | Sağlayıcı geçişinde **120 sn**, kurumsal uç noktalarda **30 sn** |

Taban adres tanımlı değilse `CloudRoute.makeDefault()` `.userProvidedKey`
döner ve uygulama proxy'ye hiç gitmez. **Bugünkü durum bu** — adres
`project.yml` içinde yok, dolayısıyla bulut modu uçtan uca çalışmıyor.

Kaynak: `CloudCredentialValidator.swift:69-79`, `CloudCredentials.swift` →
`CloudRequestBuilder.makeRequest`.

### 2.1 Yeniden deneme — sunucunun bilmesi şart

İstemci şu durum kodlarında **kendiliğinden 3 kez** deniyor:

```
408, 409, 429, 500, 502, 503, 504, 529
```

Kaynak: `CloudHTTP.swift:14-16`.

Bunun iki sonucu var ve ikisi de sunucuyu bağlıyor:

1. **Bu kodları dönen her uç nokta idempotent olmalı.** Aynı ses üç kez
   işlenip üç kez dakika düşerse kullanıcı bir kaydı üç kez ödemiş olur.
   Sunucu istek kimliğine göre tekilleştirmeli.
2. **Kota tükenmesi bu kodlardan biriyle bildirilmemeli.** Gerekçesi §7.1'de.

Kurumsal uç noktalarda yeniden deneme **yok** (`maxAttempts: 1`).

---

## 3. Sağlayıcı geçişi

Sunucunun asıl işi: isteği al, `Authorization` başlığını gerçek sağlayıcı
anahtarıyla değiştir, ilet, yanıtı **olduğu gibi** geri ver.

Yol şöyle kuruluyor: `taban + sağlayıcı öneki + istemci yolu`.

### 3.1 Deşifre — Groq

```
POST {taban}/v1/proxy/groq/v1/audio/transcriptions
Authorization: Bearer <oturum-jetonu>
Content-Type: multipart/form-data; boundary=AuraVoice-<UUID>
```

Multipart alanları:

| Alan | Değer |
|---|---|
| `model` | `whisper-large-v3` veya `whisper-large-v3-turbo` |
| `response_format` | `verbose_json` (sabit) |
| `language` | ISO dil ipucu — **isteğe bağlı**, yoksa hiç gönderilmiyor |
| `file` | Ses dosyası (m4a/AAC ya da wav) |

Yanıt, Groq'un `verbose_json` biçimi olduğu gibi bekleniyor:

```json
{ "text": "...", "language": "tr",
  "segments": [ { "start": 0.0, "end": 3.2, "text": "..." } ] }
```

İstemci `segments` alanını zaman eksenli transkript için kullanıyor; düşürme.
Kaynak: `CloudASRClient.swift:95-135`.

### 3.2 Özetleme — Anthropic

```
POST {taban}/v1/proxy/anthropic/v1/messages
Authorization: Bearer <oturum-jetonu>
Content-Type: application/json
```

```json
{ "model": "claude-sonnet-5",
  "max_tokens": 16000,
  "system": "...",
  "messages": [ { "role": "user", "content": "..." } ],
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "medium" } }
```

`max_tokens` varsayılanı **16000**. `effort`: `low` | `medium` | `high`.
Kullanılan model kimlikleri: `claude-sonnet-5`, `claude-opus-5`,
`claude-haiku-4-5`. Sunucu bir izin listesi tutacaksa bu üçü olmalı.

İstemci `stop_reason == "max_tokens"` durumunu ayrıca ele alıyor; sunucu
yanıtı kırpmamalı.

**Anthropic'in reddi HTTP 200 ile geliyor** — gövde 200 ama `content` boş.
İstemci bunu ayrıca yakalıyor (`cloudRefused`). Sunucu 200'ü olduğu gibi
geçirmeli, kendi hatasına çevirmemeli. Kaynak: `CloudLLMClient.swift:150-190`.

### 3.3 Geçişte sunucunun sorumluluğu

- Gerçek sağlayıcı anahtarını **yalnızca sunucu** bilir.
- İstek **bulut havuzundan** ölçülür (§5).
- Yanıt gövdesi değiştirilmez; istemci sağlayıcının biçimini çözüyor.
- Sağlayıcının durum kodu olduğu gibi aktarılır (§7 haritası buna dayanıyor).

---

## 4. Kurumsal anahtar yönetimi

Bu dört uç nokta **istemcide yazılı ve test edilmiş**; sunucu tarafı eksik.
Kaynak: `EnterpriseCredentials.swift`.

### `GET /v1/org/access`

```json
{ "canManageProviderKeys": true, "organizationName": "Acme A.Ş." }
```

Yetki kaynağı **sunucu**. İstemcide bir bayrakla karar verilseydi ekranı
açmak için uygulamayı kurcalamak yeterdi. Ulaşılamadığında istemci
`unauthorized` varsayıyor — **kapalı tarafa düşüyor**, yani yanıt
veremiyorsan yüzey hiç açılmıyor.

### `POST /v1/org/credentials`

```json
→ { "provider": "anthropic", "key": "sk-ant-..." }
← { "masked": "…4f2a" }
```

- Anahtar **gövdede**, URL'de değil. Günlüğe yazma.
- Yanıtta yalnızca maskeli kuyruk dönüyor; tam anahtar asla geri verilmiyor.
- **Hata metinleri anahtarı yankılamamalı.** İstemci sunucunun hata metnini
  doğrudan kullanıcıya gösteriyor.
- `provider`: `anthropic` | `groq`.

### `GET /v1/org/credentials`

```json
{ "anthropic": "…4f2a", "groq": "…9b1c" }
```

Kurulu anahtarların maskeli kuyrukları. Kurulu değilse anahtar hiç olmamalı.

### `DELETE /v1/org/credentials/{provider}`

Gövdesiz. 2xx = silindi.

---

## 5. Kota: iki havuz

Kota **iki ayrı havuz** (`QuotaLane`): cihaz içi ve bulut. Gerekçesi
`QuotaManager.swift` başında. Sunucu tarafını bağlayan kısım:

### 5.1 Yetki dağılımı

| | Nerede | Neden orada olmak zorunda |
|---|---|---|
| **İnfaz** | Cihaz (Keychain) | Cihaz içi mod ağsız çalışıyor; sunucuya soracak kimse yok. |
| **Verme** | Sunucu | Cihaz kendine dakika veremez. Bugünkü açık tam olarak bu. |

Bugün uygulama aylık yenilemeyi **cihaz saatinden** yapıyor
(`QuotaManager.renewIfNeeded`). Saati ileri alan kullanıcı erken yenileme
alıyor. Cihazda güvenilir saat kaynağı yok; gerçek savunma imzalı bilet (§6).

### 5.2 Bulut havuzu — sunucu yetkili

Her sağlayıcı geçişi sunucudan geçtiği için bulut dakikasının **tek doğru
sayacı sunucu**. Sunucu her istekte:

1. Kullanıcının bulut bakiyesini kontrol eder.
2. İşi yapar.
3. **Gerçekleşen** süreyi düşer (istemcinin beyanını değil).

İstemcinin faturalandırma birimi **6 saniye**, yukarı yuvarlanıyor
(`ProcessingRouter.billingIncrementSeconds`). Sunucu aynı birimi kullanmalı,
yoksa iki taraf sürekli birkaç saniye ayrışır.

### 5.3 Cihaz içi havuz — sunucu yalnızca verir

Cihaz içi işleme sunucuya hiç uğramıyor. Sunucu bu havuzu **ölçemez**,
yalnızca verir. Cihaz harcar ve bağlantı geldiğinde raporlar.

### 5.4 Karar bekleyen tek şey

Bir cihaz ne kadar süre çevrimdışı kalabilir?

Hiç bağlanmayan bir cihaz cihaz içi bakiyesini sonsuza kadar kendi başına
harcar ve sunucu bunu hiç görmez. Tamamen kapatmak offline modun vaadini
("uçakta çalışır") yok eder; tamamen açık bırakmak kotayı isteğe bağlı kılar.

Yaygın orta yol: raporlanmamış kullanım bir eşiği geçerse ya da cihaz N gündür
senkron olmadıysa uygulama yeni **işlemeyi** durdurup "bir kez bağlan" der.
Kayıt yine alınır, yalnızca işleme bekler.

**Bu bir ürün kararı ve henüz verilmedi.** Sunucu sözleşmesine yazılmadan önce
bir sayı gerekiyor (örn. 7 gün ya da 60 dakika raporlanmamış kullanım).

---

## 6. İmzalı dakika bileti

Sunucunun dakikayı **kanıtlayarak** vermesinin yolu. Özel anahtar sunucuda
kalır, cihaza hiç inmez; uygulamada yalnızca doğrulayan açık anahtar var
(`Info.plist` → `AuraTicketPublicKey`, base64, 32 bayt Ed25519 açık anahtarı).

**Bugün boş.** Boş olduğu sürece `TicketVerifier.makeDefault()` `nil` dönüyor
ve bilet özelliği tamamen kapalı.

### Kanonik imza gövdesi

Alanlar `|` ile birleşir, UTF-8 kodlanır, Ed25519 ile imzalanır:

```
aura.ticket.v2|<id>|<subject>|<plan>|<lane>|<milliminutes>|<issuedAtMs>|<expiresAtMs>
```

| Alan | Anlam |
|---|---|
| `id` | Tekil kimlik (nonce). Tekrar kullanımı defter engelliyor. |
| `subject` | Biletin geçerli olduğu cihaz/hesap. `*` = her cihaz (**yalnızca geliştirme**). |
| `plan` | Plan etiketi — kayıt ve destek için, doğrulamada rol oynamaz. |
| `lane` | `offline` \| `online` — dakikanın yazılacağı havuz |
| `milliminutes` | `Int64((dakika * 1000).rounded())` |
| `issuedAtMs` / `expiresAtMs` | epoch'tan beri milisaniye, tamsayı |

Her sayısal alan tamsayıya indirgendi: ondalık ayraç ve tarih biçimi tartışması
olmasın, yerel ayarlar imzayı bozamasın.

`lane` **v2 ile geldi ve sürüm bilerek yükseltildi**: alanı sessizce eklemek,
eski bir sunucunun ürettiği biletin yeni bir anlamla doğrulanması demekti.
Sürüm dizgesi imzalanan gövdenin parçası olduğu için v1 bilet artık geçmez.

### Aktarım biçimi

```json
{ "ticket": { "id": "...", "subject": "...", "plan": "pro",
              "lane": "online", "minutes": 45,
              "issuedAtMs": 1760000000000, "expiresAtMs": 1760003600000 },
  "signature": "<base64, 64 bayt>" }
```

`lane` alanının **varsayılanı yok**: eksikse bilet bozuk sayılıyor. Sunucunun
söylemediği bir havuzu uydurmak, yarı zamanlı yanlış olurdu.

### İstemci tarafındaki savunmalar

- **Tekrar kullanım**: bozdurulan bilet kimlikleri deftere yazılıyor.
- **Saat geri alma**: defterde "en ileri görülen zaman" tutuluyor ve bu değer
  **yalnızca imzalı `issuedAt`** ile ilerliyor. Cihaz saatiyle ilerleseydi,
  saatini 2030'a alan kullanıcı uygulamasını kalıcı olarak kilitlerdi.

Kaynak: `MinuteTicket.swift`, `SecureTicketStore.swift`.

---

## 7. Hata sözleşmesi

İstemcinin durum kodlarını nasıl yorumladığı (`CloudHTTP.mapError`) ve **her
yorumun sonucu**:

| Kod | İstemci hatası | Yeniden dener | Cihaz içi motora düşer |
|---|---|---|---|
| 401, 403 | `cloudAuthenticationFailed` | hayır | **hayır** |
| 413 | `engineFailure` ("istek çok büyük") | hayır | evet |
| 429 | `cloudRateLimited` | **evet, 3 kez** | evet |
| 5xx | `engineFailure` | **evet, 3 kez** | evet |
| diğer | `engineFailure` | hayır | evet |

"Cihaz içi motora düşer" sütunu kritik: düşen istek cihaz içi motorda
işleniyor ve **cihaz içi havuzdan** faturalanıyor.

### 7.1 Kota tükenmesi için ayrı kod gerekiyor

Sunucu "bulut dakikan bitti" demek için 429 ya da 5xx kullanırsa şu olur:

1. İstemci üç kez daha dener — sunucu üç kez daha reddeder.
2. Sonra sessizce cihaz içi motora düşer.
3. Ve kaydı **cihaz içi havuzdan** faturalar.

Kullanıcı bulut dakikasının bittiğini hiç öğrenmez, cihaz içi dakikası da
sebepsiz erir. Bu yüzden kota tükenmesi:

- **Yeniden denenen kodlardan biri OLMAMALI** (408/409/429/5xx listesi dışı).
- Tercihen **402 Payment Required** ya da 4xx içinde ayrı bir kod.

Bugün istemcide bu kodun bir karşılığı **yok**: `default` dalına düşer,
`engineFailure` olur ve yine cihaz içi motora düşer — sessizce ama en azından
tekrar denemeden. Sözleşme kesinleşince istemciye `cloudQuotaExhausted`
eklenmeli ve `isRecoverableCloudFailure` içinde **yedeklenemez** sayılmalı;
`insufficientQuota` zaten öyle.

### 7.2 Hata gövdesi

İstemci hata gövdesini kullanıcıya gösterebiliyor. İki kural:

- Sağlayıcı anahtarını, oturum jetonunu ya da kurumsal anahtarı **yankılama**.
- Metin son kullanıcıya gösterilebilir olmalı; yığın izi gönderme.

---

## 8. Eksik iki akış

Bunlar **istemcide de yok**. Sunucuyla birlikte tasarlanmaları gerekiyor.

### 8.1 Oturum jetonu — en acil eksik

Her proxy isteği `Authorization: Bearer <oturum-jetonu>` istiyor, ama:

```
grep -rn "setSessionToken" AuraVoice/
```

yalnızca **tanımları** buluyor, tek bir **çağrı yeri** yok. Yani jetonu
depolayacak yüzey var, jetonu alacak akış yok. Proxy adresi bugün
tanımlansaydı bile her istek `cloudCredentialsMissing` ile düşerdi.

Önerilen en küçük akış:

```
POST /v1/session
→ { "appUserId": "<RevenueCat App User ID>", "deviceId": "<cihaz kimliği>" }
← { "token": "...", "expiresAtMs": 1760003600000 }
```

Karara bağlanması gerekenler: jeton ömrü, yenileme (401 alınca sessiz yenileme
mi, kullanıcıya mı sorulacak), ve cihaz kimliğinin uygulama silinince
değişmesinin hesaba nasıl bağlanacağı.

### 8.2 Bilet dağıtımı

Bugün bilet **elle yapıştırılıyor** (`TicketRedemptionView`, JSON metni).
Bu, geliştirme ve destek için yeterli ama ürün akışı değil.

```
GET /v1/minutes/tickets
← { "tickets": [ { "ticket": {...}, "signature": "..." } ] }
```

Sunucu, cihazın henüz bozdurmadığı biletleri döner; istemci `SecureTicketStore`
üzerinden bozdurur (defter tekrar kullanımı zaten engelliyor, sunucunun aynı
bileti tekrar döndürmesi zararsız).

---

## 9. Sırayla yapılacaklar

1. **Oturum jetonu** (§8.1) — bu olmadan hiçbir proxy isteği çalışmıyor.
2. **Sağlayıcı geçişi** (§3) — bulut modunu ayağa kaldıran asıl iş.
3. **Kota muhasebesi** (§5) — bulut havuzu sunucuda; §5.4'teki sayıya karar ver.
4. **Bilet imzalama** (§6) — `AuraTicketPublicKey`'i doldur, cihaz içi havuzu
   verebilir hale gel.
5. **Kurumsal uç noktalar** (§4) — istemci hazır, yalnız sunucu eksik.
6. **Bilet dağıtımı** (§8.2) — elle yapıştırmayı akışa çevir.

---

## 10. İstemci tarafında kalan işler

Sunucu geldiğinde uygulamada şunlar gerekiyor:

- `project.yml` → `Info.plist` içine `AuraCloudProxyBaseURL` eklenmesi.
- `AuraTicketPublicKey`'in doldurulması.
- Oturum jetonu akışının yazılması (§8.1) — **bugün hiç yok**.
- `cloudQuotaExhausted` hatasının eklenmesi ve yedeklenemez sayılması (§7.1).
- Çevrimdışı kullanımın raporlanması (§5.3) — bugün hiç yok.
