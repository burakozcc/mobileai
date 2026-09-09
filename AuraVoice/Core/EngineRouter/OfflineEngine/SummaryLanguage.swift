//
//  SummaryLanguage.swift
//  AuraVoice
//
//  Özetleme boru hattının dil modeli.
//
//  NEDEN YENİDEN YAZILDI: eski hâli `isTurkish: Bool` idi — yani dünyada iki
//  dil varmış gibi davranıyordu. Türkçe değilse İngilizce varsayıyordu.
//  Whisper large-v3-turbo 99 dil tanıyor; Almanca bir toplantı doğru
//  deşifre ediliyor, sonra özetleyici onu İngilizce sanıp İngilizce başlık
//  basıyor ve tek bir kararı yakalayamıyordu — Almanca ipucu listesi yok.
//
//  YENİ KURGU: dil bir KOD, profil ise o dil için elimizde ne olduğu.
//  Profili olmayan dil DESTEKLENMİYOR demek değil: özet yine çıkıyor,
//  başlıklar doğru dilde geliyor, yalnızca karar/aksiyon ayrımı yapılamıyor
//  ve saf skorlamaya düşülüyor. Sessizce yanlış dilde çıktı vermektense
//  daha az iddialı ama doğru bir özet vermek yeğdir.
//
//  Yeni bir dil eklemek artık VERİ işi: `Profile`'a bir case, üç tabloya
//  birer giriş. Kod akışına dokunulmuyor.
//

import Foundation

public struct SummaryLanguage: Sendable, Equatable {

    /// ISO 639-1 kodu, küçük harf. Tespit edilemediyse boş.
    public let code: String

    /// Elimizde ipucu listesi olan diller.
    ///
    /// Yeni dil eklemek artık VERİ işi: buraya bir case, `SummaryCues`
    /// tablolarına birer giriş. Kod akışına dokunulmuyor.
    public enum Profile: String, Sendable, Equatable, Hashable, CaseIterable {
        case turkish
        case english
        case spanish
        case french
        case arabic
        case hindi
        case bengali
        case simplifiedChinese
        /// Listesi olmayan her dil.
        case generic
    }

    public let profile: Profile

    public init(code: String) {
        let lowered = code.lowercased().trimmingCharacters(in: .whitespaces)
        self.code = lowered

        if lowered.isEmpty || lowered.hasPrefix("tr") {
            // Boş/bilinmeyen dilde Türkçe varsayılıyor: birincil kitle Türkçe
            // ve dil tespiti yalnızca konuşma çok kısa olduğunda boş dönüyor.
            self.profile = .turkish
        } else {
            // Yalnızca dil alt etiketine bakılıyor: "es-MX" da "es" gibi.
            let base = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first.map(String.init) ?? lowered
            self.profile = SummaryLanguage.profilesByCode[base] ?? .generic
        }
    }

    /// Geriye dönük kolaylık — eski çağrı noktaları bunu okuyordu.
    public var isTurkish: Bool { profile == .turkish }

    /// Yalnızca dil alt etiketi: "de-DE" -> "de", "fr_CA" -> "fr".
    ///
    /// `localizedString(forLanguageCode:)` bir DİL kodu bekliyor, yerel ayar
    /// tanımlayıcısı değil: "de-de" verildiğinde nil dönüyor ve modele hedef
    /// dil olarak "de-de" söylenmiş oluyordu.
    private var baseCode: String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
    }

    /// Dilin kendi adı ("Türkçe", "Deutsch"), bulunamazsa İngilizce adı.
    ///
    /// Nöral isteme hedef dili SÖYLEMEK için kullanılıyor: model zaten çok
    /// dilli, onu iki dile hapsetmek bizim eksikliğimizdi.
    public var displayName: String {
        guard !code.isEmpty else { return "Turkish" }
        let base = baseCode
        if let native = Locale(identifier: base).localizedString(forLanguageCode: base),
           !native.isEmpty {
            return native
        }
        return englishName
    }

    /// Modele verilecek İngilizce dil adı ("Turkish", "German").
    public var englishName: String {
        guard !code.isEmpty else { return "Turkish" }
        let base = baseCode
        return Locale(identifier: "en").localizedString(forLanguageCode: base) ?? base
    }

    // MARK: - Sözcük listeleri

    /// Durak kelimeler. Listesi olmayan dilde BOŞ.
    ///
    /// Boş liste kaliteyi düşürüyor ama bozmuyor: terim frekansı puanlaması
    /// yaygın kelimeleri her cümlede gördüğü için kısmen kendini dengeliyor.
    /// YANLIŞ bir dilin durak kelimelerini uygulamak ise gerçek içeriği
    /// eleyebilirdi — o yüzden boş bırakmak daha güvenli.
    public var stopwords: Set<String> { SummaryCues.stopwords[profile] ?? [] }

    /// Karar alındığını gösteren ipuçları. Listesi olmayan dilde boş →
    /// karar bölümü hiç basılmıyor.
    public var decisionCues: [SummaryCue] { SummaryCues.decision[profile] ?? [] }

    /// Yapılacak iş atandığını gösteren ipuçları.
    public var actionCues: [SummaryCue] { SummaryCues.action[profile] ?? [] }

    /// Cümleyi olumsuzlayan ipuçları: eşleşirse cümle ne karar ne aksiyon
    /// sayılıyor. "Bu konuda karar veremedik" bir karar değildir.
    public var negationCues: [SummaryCue] { SummaryCues.negation[profile] ?? [] }

    /// Dil kodundan profile. `init` bunu kullanıyor.
    static let profilesByCode: [String: Profile] = [
        "tr": .turkish, "en": .english, "es": .spanish, "fr": .french,
        "ar": .arabic, "hi": .hindi, "bn": .bengali, "zh": .simplifiedChinese
    ]

    // MARK: - Başlıklar

    /// Başlıklar DEŞİFRENİN dilinde yazılıyor, uygulamanın arayüz dilinde
    /// değil: Almanca bir toplantının özetinde Türkçe "Kararlar" görmek,
    /// notu paylaşan kullanıcı için kullanışsız.
    ///
    /// Çevirisi olmayan dilde İngilizce'ye düşülüyor — nötr ve yaygın.
    private var vocabulary: SummaryVocabulary {
        // Boş kod "dil tespit edilemedi" demek ve Türkçe varsayılıyor;
        // tabloya düşürülmüyor çünkü tabloda boş anahtar yok.
        if code.isEmpty { return .turkish }
        return SummaryVocabulary.table[baseCode] ?? .english
    }

    public func heading(for template: SummaryTemplate) -> String {
        switch template {
        case .meetingNotes:     return vocabulary.meetingHeading
        case .phoneCallSummary: return vocabulary.callHeading
        case .quickNotes:       return vocabulary.quickHeading
        }
    }

    public func keyPointsTitle(for template: SummaryTemplate) -> String {
        switch template {
        case .meetingNotes:     return vocabulary.keyPointsMeeting
        case .phoneCallSummary: return vocabulary.keyPointsCall
        case .quickNotes:       return vocabulary.keyPointsQuick
        }
    }

    public var decisionsTitle: String { vocabulary.decisions }
    public var ownerHint: String { vocabulary.ownerHint }
    public var speakerPrefix: String { vocabulary.speakerPrefix }
    public var truncationNotice: String { vocabulary.truncationNotice }
    public var actionsTitle: String { vocabulary.actions }
    public var emptyNotice: String { vocabulary.emptyNotice }

    public func metaLine(durationSeconds: Double) -> String {
        let minutes = max(1, Int((durationSeconds / 60).rounded()))
        return String(format: vocabulary.metaFormat, minutes)
    }
}


// MARK: - İpucu

/// Bir karar/aksiyon/olumsuzluk ipucu ve NASIL eşleştirileceği.
///
/// Eşleşme yöntemi eskiden ipucunun ŞEKLİNDEN tahmin ediliyordu: boşluk
/// varsa cümlede alt dize, "c" ile bitiyorsa Türkçe gelecek zaman eki,
/// yoksa sözcük öneki. İki dilde işe yarıyordu ama yeni dillerde sessizce
/// yanılıyordu — özellikle Çincede, çünkü boşluk olmadığı için her ipucu
/// sözcük yoluna düşüyor, oysa tokenizasyon bütün cümleyi tek parça
/// bırakıyor. Artık yöntem ipucunun kendisinde yazılı.
public struct SummaryCue: Sendable, Equatable, Hashable {

    public enum Matching: String, Sendable, Equatable, Hashable, CaseIterable {
        /// Normalleştirilmiş CÜMLEDE alt dize. Sözcük sınırı aramaz.
        /// Boşluksuz yazılan dillerde (Çince) tek geçerli yöntem.
        case phrase
        /// Alt dize, ama SÖZCÜK SINIRINDA. Boşluklu dillerde doğru seçim:
        /// `phrase` ile "si queda aprobado" ipucu "Así queda aprobado"
        /// cümlesinde de eşleşip GERÇEK bir kararı düşürüyordu.
        case words
        /// Sözcük ÖNEKİ. Çekimli dillerde bir kökün tüm çekimlerini yakalar.
        case prefix
        /// TAM sözcük eşleşmesi. En dar, en güvenli.
        case exact
        /// Türkçe fiil kökü + ÇEKİMLİ gelecek zaman eki. Serbest önek
        /// eşleşmesi "yapacağımızı hâlâ bilmiyoruz" cümlesini bir göreve
        /// çeviriyordu.
        case turkishFuture
    }

    public let text: String
    public let matching: Matching

    /// Metin KURUCUDA normalleştiriliyor.
    ///
    /// Cümle eşleşme anında normalleştiriliyor ama ipucu eskiden
    /// geçmiyordu; bu yüzden Türkçe ipuçları elle aksansız yazılmak
    /// zorundaydı ("kararlastir") ve bu, yazanın dikkatine bağlı sessiz
    /// bir tuzaktı. Artık doğal yazımla yazılabiliyor.
    public init(_ text: String, _ matching: Matching) {
        self.text = MeetingKeywordMatcher.normalize(text)
        self.matching = matching
    }

    public static func phrase(_ text: String) -> SummaryCue { .init(text, .phrase) }
    public static func words(_ text: String) -> SummaryCue { .init(text, .words) }
    public static func prefix(_ text: String) -> SummaryCue { .init(text, .prefix) }
    public static func exact(_ text: String) -> SummaryCue { .init(text, .exact) }
    public static func turkishFuture(_ stem: String) -> SummaryCue { .init(stem, .turkishFuture) }
}

// MARK: - Başlık tabloları

/// Bir dilin özet başlıkları. Yeni dil eklemek buraya bir giriş yazmak.
public struct SummaryVocabulary: Sendable, Equatable {

    public let meetingHeading: String
    public let callHeading: String
    public let quickHeading: String
    public let keyPointsMeeting: String
    public let keyPointsCall: String
    public let keyPointsQuick: String
    public let decisions: String
    public let actions: String
    public let emptyNotice: String
    /// Aksiyon maddesinde sorumlu yer tutucusu — bulut iskeletinde geçiyor.
    public let ownerHint: String
    /// Konuşmacı ayrıştırmasında etiket öneki: "Konuşmacı 1", "Speaker 1".
    ///
    /// Deşifrenin İÇİNDE görünüyor, dolayısıyla arayüz dilinde değil KAYDIN
    /// dilinde olmalı — tıpkı bölüm başlıkları gibi.
    public let speakerPrefix: String
    /// Bulut özeti jeton sınırına takıldığında sonuna eklenen not.
    public let truncationNotice: String
    /// `%ld` dakika yerine geçiyor. (`%d` C'de 32 bit bekliyor; Swift `Int`
    /// 64 bit gönderiyor.) Yerel ayar verilmediği için rakamlar ASCII kalıyor.
    public let metaFormat: String

    // Aksansız yazılmış: karşılaştırma `normalize` sonrası yapılıyor.
    static let turkishStopwords: Set<String> = [
        "ama", "ancak", "artik", "asla", "bana", "bazi", "belki", "ben", "beni",
        "benim", "bile", "bir", "biraz", "birkac", "birsey", "biz", "bize",
        "bizim", "bu", "buna", "bunda", "bundan", "bunu", "bunun", "burada",
        "cok", "cunku", "daha", "dahi", "de", "defa", "diger", "diye", "eger",
        "gibi", "hala", "hangi", "hani", "hem", "henuz", "hep", "hepsi", "her",
        "hic", "icin", "ile", "ise", "kadar", "karsin", "kendi", "ki", "kim",
        "mi", "mu", "mu", "nasil", "ne", "neden", "nerede", "niye", "o", "olan",
        "olarak", "oldu", "oldugu", "olur", "onlar", "onu", "onun", "oysa",
        "sadece", "sanki", "sen", "senin", "siz", "sizin", "sonra", "sey",
        "seyler", "simdi", "tum", "tabi", "ve", "veya", "ya", "yani",
        "yine", "yoksa", "zaten", "zira", "var", "yok", "evet", "hayir",
        "tamam", "peki", "iste", "acaba", "bakin"
    ]

    static let englishStopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
        "his", "how", "its", "new", "now", "old", "see", "two", "way", "who",
        "boy", "did", "she", "use", "man", "too", "with", "that", "this",
        "have", "from", "they", "will", "would", "there", "their", "what",
        "about", "which", "when", "make", "like", "time", "just", "know",
        "take", "into", "your", "some", "them", "than", "then", "look",
        "only", "come", "over", "also", "back", "after", "work", "well",
        "even", "want", "because", "these", "give", "most", "yeah", "okay",
        "right", "really", "actually", "basically", "kind", "sort", "gonna"
    ]

    public static let turkish = SummaryVocabulary(
        meetingHeading: "Toplantı Özeti",
        callHeading: "Görüşme Özeti",
        quickHeading: "Hızlı Not",
        keyPointsMeeting: "Ana Başlıklar",
        keyPointsCall: "Konuşulanlar",
        keyPointsQuick: "Notlar",
        decisions: "Kararlar",
        actions: "Aksiyonlar",
        emptyNotice: "Özetlenecek konuşma bulunamadı.",
        ownerHint: "sorumlu",
        speakerPrefix: "Konuşmacı",
        truncationNotice: "_(Özet jeton sınırına takıldı ve kısaltıldı.)_",
        metaFormat: "Cihaz içi · %ld dk"
    )

    public static let english = SummaryVocabulary(
        meetingHeading: "Meeting Summary",
        callHeading: "Call Summary",
        quickHeading: "Quick Note",
        keyPointsMeeting: "Key Points",
        keyPointsCall: "Topics Discussed",
        keyPointsQuick: "Notes",
        decisions: "Decisions",
        actions: "Action Items",
        emptyNotice: "No speech found to summarize.",
        ownerHint: "owner",
        speakerPrefix: "Speaker",
        truncationNotice: "_(The summary reached the token limit and was truncated.)_",
        metaFormat: "On-device · %ld min"
    )

    public static let spanish = SummaryVocabulary(
        meetingHeading: "Resumen de la reunión",
        callHeading: "Resumen de la conversación",
        quickHeading: "Nota rápida",
        keyPointsMeeting: "Puntos clave",
        keyPointsCall: "Temas tratados",
        keyPointsQuick: "Notas",
        decisions: "Decisiones",
        actions: "Acciones",
        emptyNotice: "No se ha detectado voz para resumir.",
        ownerHint: "responsable",
        speakerPrefix: "Hablante",
        truncationNotice: "_(El resumen ha alcanzado el límite de tokens y se ha truncado.)_",
        metaFormat: "En el dispositivo · %ld min"
    )

    public static let french = SummaryVocabulary(
        meetingHeading: "Résumé de la réunion",
        callHeading: "Résumé de l’appel",
        quickHeading: "Note rapide",
        keyPointsMeeting: "Points clés",
        keyPointsCall: "Sujets abordés",
        keyPointsQuick: "Notes",
        decisions: "Décisions",
        actions: "Actions à mener",
        emptyNotice: "Aucune parole à résumer n’a été détectée.",
        ownerHint: "responsable",
        speakerPrefix: "Intervenant",
        truncationNotice: "_(Le résumé a atteint la limite de jetons et a été tronqué.)_",
        metaFormat: "Sur l’appareil · %ld min"
    )

    public static let arabic = SummaryVocabulary(
        meetingHeading: "ملخص الاجتماع",
        callHeading: "ملخص المكالمة",
        quickHeading: "ملاحظة سريعة",
        keyPointsMeeting: "النقاط الرئيسية",
        keyPointsCall: "محاور النقاش",
        keyPointsQuick: "الملاحظات",
        decisions: "القرارات",
        actions: "المهام",
        emptyNotice: "لم يُعثر على كلام لتلخيصه.",
        ownerHint: "المسؤول",
        speakerPrefix: "المتحدث",
        truncationNotice: "_(بلغ الملخص حد الرموز فتم اختصاره.)_",
        metaFormat: "على الجهاز · %ld د"
    )

    public static let hindi = SummaryVocabulary(
        meetingHeading: "मीटिंग का सारांश",
        callHeading: "कॉल का सारांश",
        quickHeading: "क्विक नोट",
        keyPointsMeeting: "मुख्य बिंदु",
        keyPointsCall: "मुख्य बातें",
        keyPointsQuick: "नोट्स",
        decisions: "निर्णय",
        actions: "एक्शन आइटम",
        emptyNotice: "सारांश बनाने के लिए कोई बातचीत नहीं मिली।",
        ownerHint: "ज़िम्मेदार",
        speakerPrefix: "वक्ता",
        truncationNotice: "_(सारांश टोकन सीमा तक पहुँच गया और छोटा कर दिया गया।)_",
        metaFormat: "ऑन-डिवाइस · %ld मिनट"
    )

    public static let bengali = SummaryVocabulary(
        meetingHeading: "মিটিংয়ের সারাংশ",
        callHeading: "কলের সারাংশ",
        quickHeading: "দ্রুত নোট",
        keyPointsMeeting: "মূল বিষয়",
        keyPointsCall: "আলোচিত বিষয়",
        keyPointsQuick: "মূল কথা",
        decisions: "সিদ্ধান্ত",
        actions: "করণীয়",
        emptyNotice: "সারাংশ তৈরি করার মতো কোনও কথা পাওয়া যায়নি।",
        ownerHint: "দায়িত্বপ্রাপ্ত",
        speakerPrefix: "বক্তা",
        truncationNotice: "_(সারাংশ টোকেন সীমায় পৌঁছানোয় সংক্ষিপ্ত করা হয়েছে।)_",
        metaFormat: "ডিভাইসেই · %ld মিনিট"
    )

    public static let simplifiedChinese = SummaryVocabulary(
        meetingHeading: "会议摘要",
        callHeading: "通话摘要",
        quickHeading: "快速笔记",
        keyPointsMeeting: "要点",
        keyPointsCall: "讨论内容",
        keyPointsQuick: "主要内容",
        decisions: "决定事项",
        actions: "待办事项",
        emptyNotice: "未找到可供摘要的语音内容。",
        ownerHint: "负责人",
        speakerPrefix: "说话人",
        truncationNotice: "_（已达到 Token 上限，摘要已截断。）_",
        metaFormat: "设备端 · %ld 分钟"
    )

    /// Bilinen bütün sözlükler.
    ///
    /// Bölüm ikonu eşleştirmesi buradan yürüyor; yeni bir dil eklendiğinde
    /// ikon kodunu ayrıca güncellemek gerekmesin diye tek liste tutuluyor.
    public static let all: [SummaryVocabulary] = [
        .turkish, .english, .spanish, .french, .arabic, .hindi, .bengali,
        .simplifiedChinese
    ]

    /// Dil kodundan sözlüğe. Burada olmayan dil İngilizce'ye düşüyor.
    ///
    /// Anahtarlar yalnızca dil alt etiketi: "zh-Hant" da "zh" üzerinden
    /// Basitleştirilmiş Çince'ye düşüyor. Geleneksel Çince yayınlanmadığı
    /// için bu bilinçli bir sadeleştirme; zh-Hant eklenirse burada
    /// ayrıştırmak gerekir.
    static let table: [String: SummaryVocabulary] = [
        "tr": .turkish,
        "en": .english,
        "es": .spanish,
        "fr": .french,
        "ar": .arabic,
        "hi": .hindi,
        "bn": .bengali,
        "zh": .simplifiedChinese
    ]
}


// MARK: - İpucu tabloları

/// Dil başına ipucu ve durak kelime tabloları.
///
/// Ayrı bir tip: `SummaryLanguage` üzerindeki `switch`'ler yeni dil
/// eklendiğinde kapsam dışı kalıyordu. Sözlük araması bu bakım yükünü
/// kaldırıyor — tabloda olmayan dil boş liste alıyor, yani özet yine
/// çıkıyor, sadece bölüm ayrımı yapılmıyor.
enum SummaryCues {

    /// Karar ipuçları.
    static let decision: [SummaryLanguage.Profile: [SummaryCue]] = [
        .turkish: [
            .prefix("kararlastir"), .phrase("karar verildi"), .phrase("karar verdik"),
            .phrase("karar alindi"), .phrase("karara bagl"), .prefix("anlastik"),
            .prefix("onaylandi"), .prefix("onayland"), .phrase("kabul edildi"),
            .prefix("netlesti"), .prefix("belirlendi"), .prefix("sonuclandi"),
            .prefix("mutabik")
        ],
        .english: [
            .prefix("decided"), .prefix("agreed"), .prefix("approved"),
            .prefix("conclusion"), .prefix("resolved"), .phrase("we will go with"),
            .prefix("consensus")
        ],

        // İspanyolca
        .spanish: [
            .phrase("hemos decidido"), .phrase("se ha decidido"),
            .phrase("queda decidido"), .phrase("hemos acordado"),
            .phrase("quedamos en que"), .phrase("queda aprobado"),
            .phrase("hemos optado por")
        ],

        // Fransızca
        .french: [
            .phrase("on a decide"), .phrase("nous avons decide"), .phrase("a ete decide"),
            .phrase("ete convenu"), .phrase("on acte"), .phrase("on a tranche"),
            .phrase("on a choisi"), .phrase("on opte pour"), .prefix("enterin")
        ],

        // Arapça
        .arabic: [
            .phrase("تم الاتفاق"), .phrase("اتفقنا على"), .phrase("قررنا"),
            .phrase("تقرر"), .phrase("تم اتخاذ القرار"), .phrase("تمت الموافقة"),
            .phrase("وافقنا على"), .phrase("تم اعتماد"), .phrase("استقر الرأي")
        ],

        // Hintçe
        .hindi: [
            .phrase("तय हुआ कि"), .phrase("तय हो गय"), .phrase("तय किया गया"),
            .phrase("तय कर लिया"), .phrase("फैसला हुआ कि"), .phrase("फैसला लिया गया"),
            .phrase("निर्णय लिया गया"), .phrase("सहमति बनी"), .phrase("सहमत हो गए"),
            .phrase("मंज़ूरी मिल गई"), .phrase("अप्रूव हो गय"), .phrase("फाइनल हो गय")
        ],

        // Bengalce
        .bengali: [
            .phrase("সিদ্ধান্ত হয়েছে"), .phrase("সিদ্ধান্ত নেওয়া হয়েছে"),
            .phrase("সিদ্ধান্ত হলো"), .phrase("চূড়ান্ত করা হয়েছে"),
            .phrase("অনুমোদন করা হয়েছে"), .phrase("অনুমোদিত হয়েছে"),
            .phrase("একমত হয়েছে"), .phrase("রাজি হয়েছে"), .phrase("নির্ধারণ করা হয়েছে"),
            .phrase("গৃহীত হয়েছে")
        ],

        // Basitleştirilmiş Çince
        .simplifiedChinese: [
            .phrase("我们决定"), .phrase("就这么定了"), .phrase("达成了共识"), .phrase("达成了一致"),
            .phrase("一致同意"), .phrase("我们同意")
        ]
    ]

    /// Aksiyon ipuçları.
    static let action: [SummaryLanguage.Profile: [SummaryCue]] = [
        .turkish: [
            .turkishFuture("yapac"), .turkishFuture("hazirlayac"),
            .turkishFuture("gonderec"), .turkishFuture("paylasac"),
            .turkishFuture("iletec"), .turkishFuture("guncelleyec"),
            .turkishFuture("olusturac"), .turkishFuture("yazac"), .turkishFuture("arayac"),
            .turkishFuture("bakac"), .phrase("takip edec"), .phrase("kontrol edec"),
            .prefix("sorumlu"), .prefix("gorevlendir"), .prefix("atandi"),
            .phrase("son tarih"), .prefix("deadline"), .prefix("yapilmali"),
            .prefix("hazirlanmali"), .prefix("ustlendi")
        ],
        .english: [
            .phrase("action item"), .prefix("todo"), .phrase("to-do"),
            .phrase("follow up"), .phrase("follow-up"), .phrase("will send"),
            .phrase("will prepare"), .phrase("will review"), .prefix("assign"),
            .prefix("responsible"), .prefix("deadline"), .phrase("due by")
        ],

        // İspanyolca
        .spanish: [
            .phrase("se compromete a"), .phrase("nos comprometemos a"),
            .phrase("queda pendiente"), .phrase("queda a cargo de")
        ],

        // Fransızca
        .french: [
            .phrase("se charge de"), .phrase("se chargera"), .phrase("occupe de"),
            .prefix("enverr"), .phrase("je vous envoie"), .prefix("preparer"),
            .prefix("relancer"), .phrase("au plus tard"), .phrase("date limite"),
            .prefix("echeance"), .prefix("deadline"), .phrase("reste a faire")
        ],

        // Arapça
        .arabic: [
            .phrase("سيقوم"), .phrase("سنقوم"), .phrase("سأقوم"), .phrase("سيتولى"),
            .phrase("سيتابع"), .phrase("سيرسل"), .phrase("مطلوب من"), .phrase("تكليف"),
            .phrase("في موعد أقصاه")
        ],

        // Hintçe
        .hindi: [
            .phrase("एक्शन आइटम"), .prefix("डेडलाइन"), .phrase("समय सीमा"),
            .words("ज़िम्मे"), .prefix("असाइन"), .phrase("फॉलो अप"), .phrase("फॉलोअप"),
            .words("सौंप"), .phrase("भेज देंगे"), .phrase("अंतिम तिथि")
        ],

        // Bengalce
        .bengali: [
            .phrase("করতে হবে"), .phrase("দিতে হবে"), .phrase("পাঠাতে হবে"),
            .phrase("দায়িত্ব দেওয়া হয়েছে"), .phrase("জমা দেব"), .phrase("পাঠিয়ে দেব"),
            .phrase("তৈরি করব"), .phrase("যোগাযোগ করব"), .phrase("ব্যবস্থা করব"),
            .phrase("নিশ্চিত করব")
        ],

        // Basitleştirilmiş Çince
        .simplifiedChinese: [
            .phrase("行动项"), .phrase("待办事项"), .phrase("跟进一下"), .phrase("务必"),
            .phrase("整理一份"), .phrase("输出一份")
        ]
    ]

    /// Olumsuzluk ipuçları. Burada cömert olmak GÜVENLİ: yanlış bir olumsuzluk yalnızca cümleyi Ana Başlıklar'da bırakır.
    static let negation: [SummaryLanguage.Profile: [SummaryCue]] = [
        .turkish: [
            .phrase("karar yok"), .phrase("netlik yok"), .phrase("karar verilmedi"),
            .phrase("karar ertelendi"), .phrase("karara varilamadi"), .prefix("degil"),
            .prefix("veremedik"), .prefix("alamadik"), .prefix("edemedik"),
            .prefix("yapamadik"), .prefix("kalamadik"), .prefix("kararsiz"),
            .prefix("belirsiz"), .prefix("netlesmedi"), .prefix("olmadi"),
            .prefix("olmayacak"), .prefix("vazgectik"), .prefix("verilmedi"),
            .prefix("bilmiyoruz")
        ],
        .english: [
            .phrase("no decision"), .phrase("not decided"), .phrase("no agreement"),
            .exact("not"), .exact("never"), .words("no"), .exact("cannot"),
            .exact("couldn"), .exact("didn"), .exact("wont"), .exact("unclear"),
            .exact("undecided"), .exact("postponed")
        ],

        // İspanyolca
        .spanish: [
            .phrase("no hemos decidido"), .phrase("no se ha decidido"),
            .phrase("no hemos acordado"), .phrase("nos hemos acordado"),
            .phrase("no quedamos en que"), .phrase("no queda decidido"),
            .phrase("no queda aprobado"), .phrase("no hemos optado"),
            .phrase("no se compromete"), .phrase("no nos comprometemos"),
            .phrase("si nos comprometemos"), .phrase("no queda pendiente"),
            .phrase("no hace falta"), .phrase("sin decidir"),
            .phrase("no estamos de acuerdo"), .phrase("no llegamos a un acuerdo"),
            .phrase("no hay acuerdo"), .phrase("no hay consenso"),
            .phrase("no está claro"), .phrase("por definir"), .phrase("lo dejamos para"),
            .phrase("habrá que ver"), .phrase("todavía no"), .phrase("aún no"),
            .words("no queda a cargo"), .words("nadie queda"),
            .words("nadie se compromete"), .words("nada queda"), .prefix("ningun"),
            .exact("nunca"), .exact("tampoco"), .words("si queda aprobado"),
            .words("si se compromete"), .words("si hemos decidido")
        ],

        // Fransızca
        .french: [
            .exact("pas"), .prefix("aucun"), .exact("jamais"), .exact("rien"),
            .phrase("en attente"), .phrase("en suspens"), .prefix("trancher"),
            .phrase("a confirmer"), .phrase("a definir"), .phrase("a valider"),
            .prefix("decider"), .prefix("hesit"), .prefix("provisoire"),
            .phrase("sous reserve"), .phrase("en reparle"), .phrase("on verra"),
            .phrase("est reporte"), .prefix("incert"),
            .words("est-ce qu"), .words("si"), .words("doit encore"), .words("n'est plus"),
            .phrase("personne n"), .words("ni"), .words("y a plus"), .prefix("inutile"),
            .words("sans date")
        ],

        // Arapça
        .arabic: [
            .phrase("لم يتم"), .phrase("يتم الاتفاق"), .phrase("يتم اتخاذ"),
            .phrase("يتم اعتماد"), .phrase("سيتقرر"), .phrase("لم يتقرر"), .phrase("إذا"),
            .phrase("إذا قررنا"), .phrase("لو قررنا"), .phrase("لو تم"), .phrase("في حال"),
            .phrase("هل تم"), .phrase("هل تمت"), .phrase("هل تقرر"), .phrase("هل قررنا"),
            .phrase("هل اتفقنا"), .phrase("هل وافقنا"), .phrase("من سيقوم"),
            .phrase("هل سيقوم"), .phrase("من سيتولى"), .phrase("غير مطلوب"),
            .phrase("ما قررنا"), .phrase("لم نتفق"), .phrase("لم نتوصل"),
            .phrase("لم نقرر"), .phrase("لم نتمكن"), .phrase("لم يتحدد"),
            .phrase("قيد النقاش"), .phrase("قيد الدراسة"), .phrase("غير محسوم"),
            .phrase("لسنا متأكدين"), .phrase("تراجعنا عن"), .phrase("مزيد من النقاش"),
            .words("هل"), .words("من سيتابع"), .words("من سيرسل"), .words("لو"),
            .words("ما اتفقنا"), .words("ما وافقنا"), .words("ما تمت"), .words("لن يتقرر"),
            .words("لا يوجد"), .exact("دون")
        ],

        // Hintçe
        .hindi: [
            .phrase("तय नहीं"), .phrase("फैसला नहीं"), .phrase("सहमति नहीं"),
            .phrase("नहीं हु"), .phrase("नहीं हो"), .phrase("नहीं करेंगे"),
            .phrase("नहीं है"), .phrase("नहीं ल"), .phrase("या नहीं"), .phrase("पता नहीं"),
            .phrase("क्लियर नहीं"), .phrase("स्पष्ट नहीं"), .words("क्या"), .exact("अगर"),
            .words("यदि"), .phrase("गया तो"), .phrase("गई तो"), .phrase("गए तो"),
            .phrase("मान लीजिए"), .words("किस"), .phrase("हो चुक"), .phrase("बीत चुक"),
            .phrase("निकल चुक"), .phrase("पूरा हो गया"), .phrase("पूरे हो गए"),
            .prefix("अनिश्चित"), .exact("असमंजस"), .exact("शायद"),
            .phrase("बाद में तय कर"), .phrase("टाल दिया गया"),
            .words("नहीं किया"), .words("अभी तक नहीं"), .words("ज़िम्मे नहीं"),
            .words("आइटम नहीं"), .words("डेडलाइन नहीं"), .words("ज़रूरत नहीं"),
            .words("नहीं की गई"), .words("तय की जाएगी"), .words("तय कर लिया जाएगा"),
            .words("पलट दिया गया"), .words("हो गया?")
        ],

        // Bengalce
        .bengali: [
            .phrase("সিদ্ধান্ত হয়নি"), .phrase("সিদ্ধান্ত নেওয়া হয়নি"),
            .phrase("সিদ্ধান্ত নেই"), .phrase("চূড়ান্ত হয়নি"), .phrase("ঠিক হয়নি"),
            .phrase("একমত ন"), .phrase("নিশ্চিত ন"), .exact("পারিনি"), .phrase("পারছি না"),
            .prefix("স্থগিত"), .phrase("আলোচনা চলছে"), .phrase("পরে সিদ্ধান্ত"),
            .phrase("দরকার নেই"), .words("নেই"), .phrase("হবে না"), .phrase("বে না"),
            .phrase("ব না"), .phrase("হলো না"), .words("কি"), .phrase("কিনা"),
            .phrase("কি না"), .words("যদি"), .phrase("জানি না"), .phrase("মনে হয় না"),
            .phrase("শুনেছি"),
            .words("নাকি"), .words("হয়নি"), .words("নয়"), .words("জানে না"),
            .words("মনে হচ্ছে না"), .words("শোনা যাচ্ছে"), .words("হলে"), .words("বলেনি")
        ],

        // Basitleştirilmiş Çince
        .simplifiedChinese: [
            .phrase("吗"), .phrase("是不是"), .phrase("有没有"), .phrase("如果"), .phrase("要是"),
            .phrase("假如"), .phrase("的话"), .phrase("不是"), .phrase("不能"), .phrase("不用"),
            .phrase("不需要"), .phrase("还没"), .phrase("尚未"), .phrase("无法"), .phrase("未能"),
            .phrase("等他们"), .phrase("等对方"), .phrase("还没决定"), .phrase("没有决定"),
            .phrase("决定不了"), .phrase("还没定"), .phrase("没定下来"), .phrase("不确定"),
            .phrase("待定"), .phrase("再议"), .phrase("悬而未决"), .phrase("暂缓"), .phrase("还在讨论"),
            .phrase("没必要"), .phrase("先不"), .phrase("不用做"),
            .phrase("没有行动项"), .phrase("没有待办"), .phrase("要不要"), .phrase("谁来"),
            .phrase("同意不了"), .phrase("别就这么定"), .phrase("了没有"), .phrase("没有一致同意"),
            .phrase("推翻"), .phrase("已经完成"), .phrase("已经取消")
        ]
    ]

    /// Durak kelimeler.
    static let stopwords: [SummaryLanguage.Profile: Set<String>] = [
        .turkish: SummaryVocabulary.turkishStopwords,
        .english: SummaryVocabulary.englishStopwords
    ]
}
