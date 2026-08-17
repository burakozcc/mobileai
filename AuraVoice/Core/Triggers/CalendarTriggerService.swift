//
//  CalendarTriggerService.swift
//  AuraVoice
//
//  Cihaz takvimini YEREL olarak tarar. Hiçbir etkinlik verisi cihazdan çıkmaz.
//
//  Swift 6 notu: `EKEventStore` ve `EKEvent` Sendable değildir. Servis bir
//  `actor` olarak izole edildi ve dışarıya yalnızca Sendable DTO
//  (`MeetingCandidate`) verilir — böylece EventKit nesneleri aktör sınırını
//  hiç geçmez.
//

import Foundation
import EventKit

// MARK: - Sendable DTO

public struct MeetingCandidate: Identifiable, Hashable, Sendable, Codable {

    /// Yinelenen etkinliklerde `eventIdentifier` tüm tekrarlarda aynıdır;
    /// bu yüzden kimlik başlangıç zamanıyla birleştirilir.
    public let id: String
    public let eventIdentifier: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    /// Zoom / Teams / Meet bağlantısı tespit edildiyse true.
    public let isVirtual: Bool
    public let locationHint: String?
    /// Eşleşmeyi tetikleyen anahtar kelime (kullanıcıya "neden bildirim aldım" der).
    public let matchedKeyword: String

    public var durationMinutes: Int {
        max(1, Int(endDate.timeIntervalSince(startDate) / 60))
    }

    /// Henüz başlamamış ama 5 dakika içinde başlayacak.
    public var isImminent: Bool {
        let untilStart = startDate.timeIntervalSinceNow
        return untilStart > 0 && untilStart <= 300
    }

    public var isOngoing: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }

    public init(
        id: String,
        eventIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isVirtual: Bool,
        locationHint: String?,
        matchedKeyword: String
    ) {
        self.id = id
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isVirtual = isVirtual
        self.locationHint = locationHint
        self.matchedKeyword = matchedKeyword
    }
}

// MARK: - Eşleştirme (saf mantık — birim testlerle doğrulanır)

public enum MeetingKeywordMatcher {

    /// Başlıkta aranan tetikleyici kelimeler.
    public static let keywords: [String] = [
        "toplantı", "meeting", "sync", "1-on-1", "1:1", "one-on-one",
        "zoom", "teams", "meet", "görüşme", "standup", "stand-up",
        "retro", "review", "demo", "kickoff", "workshop", "mülakat",
        "interview", "call", "webinar", "sunum", "brief"
    ]

    /// Sanal toplantı bağlantısı arayan alan adları.
    public static let virtualHosts: [String] = [
        "zoom.us", "teams.microsoft.com", "meet.google.com", "webex.com",
        "whereby.com", "gotomeeting.com", "bluejeans.com", "chime.aws", "slack.com"
    ]

    /// Türkçe harfleri ASCII karşılıklarına indirger: "TOPLANTI" ≡ "toplantı".
    ///
    /// `.diacriticInsensitive` tek başına yetmiyor: 'ı' (U+0131) ayrıştırılabilir
    /// bir karakter değil, dolayısıyla Unicode aksan kaldırma onu 'i' yapmaz.
    /// Türkçe'ye özel eşleme bu yüzden elle yapılıyor; ardından kalan aksanlar
    /// (é, ñ …) için standart katlama uygulanıyor.
    public static func normalize(_ text: String) -> String {
        let turkishFolding: [Character: Character] = [
            "ı": "i", "İ": "i", "I": "i",
            "ş": "s", "Ş": "s",
            "ğ": "g", "Ğ": "g",
            "ü": "u", "Ü": "u",
            "ö": "o", "Ö": "o",
            "ç": "c", "Ç": "c"
        ]
        let mapped = String(text.map { turkishFolding[$0] ?? $0 })
        // Türkçe locale'de "I".lowercased() → "ı" olur; yukarıda zaten
        // çözdüğümüz için burada POSIX locale kullanmak doğru davranışı verir.
        return mapped.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Başlıkta geçen ilk tetikleyici kelimeyi döner.
    public static func matchedKeyword(inTitle title: String) -> String? {
        let haystack = normalize(title)
        return keywords.first { haystack.contains(normalize($0)) }
    }

    /// Verilen metinlerden herhangi birinde video konferans bağlantısı arar.
    public static func virtualHost(in sources: [String?]) -> String? {
        for source in sources.compactMap({ $0 }) {
            let lowered = source.lowercased()
            if let host = virtualHosts.first(where: { lowered.contains($0) }) {
                return host
            }
        }
        return nil
    }
}

// MARK: - Servis

public actor CalendarTriggerService {

    public static let shared = CalendarTriggerService()

    private let eventStore = EKEventStore()

    public init() {}

    // MARK: İzin

    public nonisolated var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public nonisolated var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    @discardableResult
    public func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    // MARK: Tarama

    /// İzin ister ve önümüzdeki `hours` saat içindeki toplantı adaylarını döner.
    public func requestAccessAndScanUpcomingMeetings(withinHours hours: Int = 12) async -> [MeetingCandidate] {
        guard await requestAccess() else { return [] }
        return upcomingMeetings(withinHours: hours)
    }

    /// İzin istemeden tarar (izin yoksa boş döner).
    public func upcomingMeetings(withinHours hours: Int = 12) -> [MeetingCandidate] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }

        let now = Date()
        // Devam eden toplantıları da yakalamak için 1 saat geriden başla.
        let windowStart = Calendar.current.date(byAdding: .hour, value: -1, to: now) ?? now
        let windowEnd = Calendar.current.date(byAdding: .hour, value: hours, to: now) ?? now

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)

        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .compactMap(Self.makeCandidate(from:))
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Belirli bir etkinliğin hâlâ takvimde ve aynı saatte olup olmadığını doğrular
    /// (bildirim gönderilmeden önce "iptal edilmiş toplantı" kontrolü).
    public func isStillValid(_ candidate: MeetingCandidate) -> Bool {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let event = eventStore.event(withIdentifier: candidate.eventIdentifier)
        else { return false }
        return event.status != .canceled && abs(event.startDate.timeIntervalSince(candidate.startDate)) < 60
    }

    // MARK: Eşleştirme

    private static func makeCandidate(from event: EKEvent) -> MeetingCandidate? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let rawTitle = event.title ?? ""

        let virtualLink = MeetingKeywordMatcher.virtualHost(in: [
            event.url?.absoluteString, event.location, event.notes
        ])
        let keyword = MeetingKeywordMatcher.matchedKeyword(inTitle: rawTitle)

        // Başlıkta anahtar kelime yoksa ama sanal toplantı bağlantısı varsa da tetikle.
        guard let matched = keyword ?? (virtualLink != nil ? "video-link" : nil) else { return nil }

        return MeetingCandidate(
            id: "\(event.eventIdentifier ?? UUID().uuidString)#\(Int(start.timeIntervalSince1970))",
            eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
            title: rawTitle.isEmpty ? "İsimsiz Toplantı" : rawTitle,
            startDate: start,
            endDate: end,
            isVirtual: virtualLink != nil,
            locationHint: virtualLink ?? event.location,
            matchedKeyword: matched
        )
    }
}
