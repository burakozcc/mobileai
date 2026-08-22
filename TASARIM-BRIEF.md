# AuraVoice — Tasarım Brief'i

> Bu dosyayı olduğu gibi bir tasarım aracına (Figma AI, v0, Claude, Midjourney vb.)
> yapıştırabilirsin. Kendi başına ayakta durur — projeyi bilmeyen birine de yeterli.
> Aracın İngilizce daha iyi çalışıyorsa söyle, İngilizce sürümünü de üretirim.

---

## KOPYALANACAK PROMPT — buradan aşağısı

Bir iOS uygulamasının arayüz tasarımını yapmanı istiyorum. Uygulamanın adı
**AuraVoice**. Aşağıda ürünün ne olduğunu, kimin kullandığını, hangi ekranların
gerektiğini ve mevcut tasarım sistemini bulacaksın.

### Ürün nedir

AuraVoice, toplantıları ve telefon görüşmelerini kaydeden, metne döken ve
özetleyen bir iPhone uygulaması. Onu benzerlerinden ayıran tek şey var:

**İki işleme modu var ve kullanıcı hangisini kullandığını her an bilir.**

- **Offline (Zero-Cloud):** Ses ve metin telefondan hiç çıkmaz. Transkripsiyon
  ve özetleme tamamen cihazda, Apple Neural Engine üzerinde yapılır. Uçak
  modunda bile çalışır. Bu modun rengi **mint yeşili**.
- **Online (Bulut):** Ses şifreli olarak sunucuya gider, çok daha hızlı işlenir.
  Bu modun rengi **indigo**.

Bu ikilik ürünün kalbi. Tasarımın en önemli işi, offline modun sadece bir ayar
değil bir **güven vaadi** olduğunu hissettirmek. Kullanıcı "verim nereye
gidiyor?" diye sormak zorunda kalmamalı — ekrana bakınca bilmeli.

### Kimin için

Türkiye'de çalışan profesyoneller: danışmanlar, avukatlar, satışçılar,
yöneticiler. Günde 2-5 toplantısı olan, not tutmaya vakti olmayan ama
konuştuklarının bir sunucuda durmasından da rahatsız olan insanlar. Uygulamayı
toplantı başlarken 2 saniyede açıp başlatmaları gerekiyor — kurcalamaya vakit yok.

### İki kritik ürün gerçeği

**1. Uygulama sürekli dinlemez.** Pil ve gizlilik nedeniyle arka planda pasif
dinleme yok. Kayıt her zaman bilinçli bir eylemle başlar. Tasarım asla
"seni dinliyorum" hissi vermemeli — bu bir güven ihlali olur. Bunun yerine
uygulama **proaktif**: takvimde toplantı görünce "başlatmak ister misin?" diye
bildirim atar, telefon görüşmesi bağlanınca hatırlatır.

**2. Dakika kotası gerçek bir kısıt.** Ücretsiz plan ayda 30 dakika, Pro plan
600-1200 dakika. Kullanıcı kalan dakikasını sürekli hissetmeli — ama bu bir
tehdit değil, bir gösterge gibi durmalı. Kota bittiğinde kayıt butonu kilitlenir.

### Platform ve teknik kısıtlar

- iPhone, iOS 17+, SwiftUI ile kodlanacak. Native iOS hissi olmalı; web
  uygulaması gibi durmamalı.
- **Karanlık tema öncelikli.** Aydınlık tema şimdilik yok.
- Dinamik tip (büyük yazı tipi ayarı) ve VoiceOver desteklenmeli — dokunma
  hedefleri en az 44×44 pt.
- Tek elle kullanılabilmeli: ana eylemler ekranın alt yarısında.

### Mevcut tasarım sistemi — bunlara sadık kal

Renkler (hex):

| Rol | Değer |
|---|---|
| Zemin | `#0B0D11` |
| Kart yüzeyi | `#161B22` |
| Yükseltilmiş yüzey (chip, alan) | `#1E252F` |
| **Offline / Zero-Cloud vurgusu** | `#00F5A0` (mint) |
| **Online / Bulut vurgusu** | `#6366F1` (indigo) |
| **Canlı kayıt** | `#FF3B30` (kırmızı) |
| Uyarı / kota kritik | `#FFB020` (amber) |
| Ana metin | `#F2F5F9` |
| İkincil metin | `#8B95A5` |
| Kart kenarı | Beyaz %7 opaklık |

Metrikler: kart köşe yarıçapı **22 pt**, kontrol yarıçapı **14 pt**, ekran kenar
boşluğu **20 pt**. Tipografi SF Pro; sayısal göstergelerde (süre, dakika)
`rounded` varyant ve monospaced rakam.

Kartlar düz renk değil: yüzey renginin üstüne çok hafif bir beyaz degrade
(%5.5 → %1.5) ve ince bir kenar çizgisi var — cam hissi, ama bulanıklık abartısı yok.

### Tasarlanacak ekranlar

**1. Dashboard (ana ekran)**
Üstte kalan dakika göstergesi — dairesel bir halka ve büyük rakam. Altında
Offline/Online mod seçici: iki kart yan yana, seçili olan kendi rengiyle
vurgulanıyor ve altında o modun gizlilik vaadi tek satır yazıyor. Sonra
yaklaşan toplantılar listesi (saat, başlık, süre, "devam ediyor" veya
"birazdan" rozeti, sağda hızlı kayıt butonu). En altta son kayıtlar — her kart
başlık, tek satır özet, küçük dalga formu, süre ve "2 saat önce" gibi zaman.
Ekranın altında yüzen büyük yuvarlak kayıt butonu.

**2. Kayıt ekranı (tam ekran)**
Ortada büyük süre sayacı. Altında **canlı dalga formu** — ses seviyesine göre
gerçek zamanlı hareket eden, merkezden simetrik çubuklar. Kayıt sırasında
her şey kırmızıya döner. Kalan kota geri sayımı görünür. Altta şablon seçici
(Toplantı / Görüşme / Hızlı Not) ve üç kontrol: duraklat, durdur, sil.
Arka planda ses seviyesiyle nefes alan hafif bir parıltı.

**3. Not detayı**
Markdown özet: başlık, "Ana Başlıklar", "Kararlar", "Aksiyonlar" bölümleri.
Aksiyonlar işaretlenebilir kutular. Altta açılıp kapanan ham transkript.
Üstte hangi modda işlendiğini gösteren rozet.

**4. Model indirme (YENİ — ürünün en kritik anı)**
Offline mod çalışması için kullanıcının 145–480 MB'lık bir yapay zekâ modelini
indirmesi gerekiyor. Bu büyük bir taahhüt — ekran bunu haklı çıkarmalı:
neden gerektiğini, karşılığında ne kazandığını (uçak modunda çalışma, veri
cihazdan çıkmaması) anlatmalı. Üç model seçeneği var (Hızlı ~78 MB / Dengeli
~145 MB / Yüksek doğruluk ~480 MB), her biri boyut ve kalite dengesiyle.
İndirme sırasında ilerleme, indirildikten sonra "kurulu" durumu ve silme seçeneği.

**5. Ayarlar (YENİ)**
Bölümler: hesap ve abonelik, offline modeller, bulut erişimi (API anahtarı veya
oturum), izinler (mikrofon / takvim / bildirim — her biri durumuyla), depolama
kullanımı ve temizleme, gizlilik açıklaması.

**6. Onboarding / izinler (YENİ)**
3-4 ekranlık kısa akış. Ürünün vaadini anlat, sonra izinleri **teker teker ve
gerekçesiyle** iste — hepsini bir anda isteme. Mikrofon zorunlu; takvim ve
bildirim opsiyonel ama değeri anlatılmalı ("toplantın başlamadan hatırlatayım").

**7. Paywall (YENİ)**
Ücretsiz 30 dakika bitince veya kullanıcı Pro'ya bakınca. Planlar, dakika
karşılıkları, offline modun ücretsiz planda da çalıştığı vurgusu.

### Her ekran için gereken durumlar

Bunları atlarsan tasarım eksik kalır:

- **Kota:** normal / kritik (5 dakikadan az, amber) / bitmiş (kayıt kilitli)
- **Offline model:** indirilmemiş / indiriliyor (%) / kurulu
- **Kayıt:** boşta / kaydediyor / duraklatıldı / işleniyor / hata
- **İzin:** sorulmadı / verildi / reddedildi (Ayarlar'a yönlendirme)
- **Boş durumlar:** hiç kayıt yok, hiç toplantı yok
- **Hata durumları:** ağ yok, model eksik, işleme başarısız
- **Görüşme banner'ı:** telefon görüşmesi bağlandığında "hoparlörü açarak
  kaydı başlatabilirsiniz" uyarısı

### Ne teslim etmeni istiyorum

Yukarıdaki 7 ekranın karanlık tema tasarımı, belirtilen durum varyasyonlarıyla.
Mevcut renk paletine ve metriklere sadık kal. Her ekran için kısa bir gerekçe
yaz — özellikle offline modun güvenilirliğini nasıl görselleştirdiğini anlat.

Kaçınılması gerekenler: jenerik yapay zekâ estetiği (mor gradyanlar, Inter/Roboto
gibi aşırı kullanılmış fontlar, tahmin edilebilir kart dizilimleri), gereksiz
cam bulanıklığı, "dinliyorum" hissi veren pasif mikrofon ikonografisi.

## KOPYALANACAK PROMPT — buraya kadar

---

## Notlar (bunları prompt'a dahil etme)

- Prompt'u kısaltmak istersen çıkarabileceğin ilk şey "Mevcut tasarım sistemi"
  tablosu — ama o zaman gelen tasarımı mevcut koda uyarlamak bana daha çok iş çıkarır.
- Aracın tek seferde 7 ekran üretemiyorsa, ekranları tek tek iste ve her
  seferinde "Ürün nedir" + "Tasarım sistemi" bölümlerini başa kopyala.
- Gelen tasarımı bana ekran görüntüsü olarak gönder; hangi ekran olduğunu ve
  neyini beğendiğini yazarsan SwiftUI'ya çevirirken isabet oranı artar.
