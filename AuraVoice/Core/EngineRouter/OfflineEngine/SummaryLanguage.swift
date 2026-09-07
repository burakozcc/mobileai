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

    /// Elimizde ipucu ve durak kelime listesi olan diller.
    public enum Profile: String, Sendable, Equatable, CaseIterable {
        case turkish
        case english
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
        } else if lowered.hasPrefix("en") {
            self.profile = .english
        } else {
            self.profile = .generic
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

    /// Durak kelimeler. Profili olmayan dilde BOŞ.
    ///
    /// Boş liste kaliteyi düşürüyor ama bozmuyor: terim frekansı puanlaması
    /// yaygın kelimeleri her cümlede gördüğü için kısmen kendini dengeliyor.
    /// Yanlış bir dilin durak kelimelerini uygulamak ise gerçek içeriği
    /// eleyebilirdi — o yüzden boş bırakmak daha güvenli.
    public var stopwords: Set<String> {
        switch profile {
        case .turkish: return SummaryVocabulary.turkishStopwords
        case .english: return SummaryVocabulary.englishStopwords
        case .generic: return []
        }
    }

    /// Karar ipuçları. Profili olmayan dilde boş → karar bölümü çıkmıyor.
    public var decisionCues: [String] {
        switch profile {
        case .turkish:
            return ["kararlastir", "karar verildi", "karar verdik", "karar alindi",
                    "karara bagl", "anlastik", "onaylandi", "onayland", "kabul edildi",
                    "netlesti", "belirlendi", "sonuclandi", "mutabik"]
        case .english:
            return ["decided", "agreed", "approved", "conclusion", "resolved",
                    "we will go with", "consensus"]
        case .generic:
            return []
        }
    }

    public var actionCues: [String] {
        switch profile {
        case .turkish:
            return ["yapac", "hazirlayac", "gonderec", "paylasac", "iletec",
                    "guncelleyec", "olusturac", "yazac", "arayac", "bakac",
                    "takip edec", "kontrol edec", "sorumlu", "gorevlendir",
                    "atandi", "son tarih", "deadline", "yapilmali",
                    "hazirlanmali", "ustlendi"]
        case .english:
            return ["action item", "todo", "to-do", "follow up", "follow-up",
                    "will send", "will prepare", "will review", "assign",
                    "responsible", "deadline", "due by"]
        case .generic:
            return []
        }
    }

    public var negationPrefixes: [String] {
        switch profile {
        case .turkish:
            return ["degil", "veremedik", "alamadik", "edemedik", "yapamadik",
                    "kalamadik", "kararsiz", "belirsiz", "netlesmedi", "olmadi",
                    "olmayacak", "vazgectik", "verilmedi", "bilmiyoruz"]
        case .english, .generic:
            return []
        }
    }

    public var negationExact: [String] {
        switch profile {
        case .english:
            return ["not", "never", "no", "cannot", "couldn", "didn", "wont",
                    "unclear", "undecided", "postponed"]
        case .turkish, .generic:
            return []
        }
    }

    public var negationPhrases: [String] {
        switch profile {
        case .turkish:
            return ["karar yok", "netlik yok", "karar verilmedi", "karar ertelendi",
                    "karara varilamadi"]
        case .english:
            return ["no decision", "not decided", "no agreement"]
        case .generic:
            return []
        }
    }

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
