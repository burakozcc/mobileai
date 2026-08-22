//
//  RecordingLaunchInbox.swift
//  AuraVoice
//
//  Uygulama dışından gelen "kaydı başlat" isteklerinin bırakıldığı kutu.
//
//  NEDEN KUTU: Siri, Kısayollar, Action Button ve widget uygulamayı ön plana
//  getirip bir niyet bırakıyor; kaydı fiilen başlatan yer ise Dashboard.
//  Kayıt için AVAudioEngine, mikrofon izni, kota kontrolü ve ekran gerekiyor —
//  bunları bir intent'in kısa ömürlü çalışma bağlamında yapmak kırılgan olurdu.
//  Kutu bu iki tarafı birbirinden ayırıyor.
//
//  BAYATLIK: İstek okunmadan uygulama kapanırsa (kullanıcı vazgeçti, iOS
//  süreci sonlandırdı) o istek günler sonra açılışta kayıt başlatmamalı.
//  Bu yüzden istekler zaman damgalı ve pencere dışında kalanlar atılıyor.
//

import Foundation

public struct RecordingLaunchRequest: Codable, Sendable, Equatable {

    public let source: RecordingTriggerSource
    public let template: SummaryTemplate
    /// nil → kullanıcının panelde seçili olan modu kullanılır.
    public let mode: ProcessingMode?
    public let contextTitle: String?
    public let createdAt: Date

    public init(
        source: RecordingTriggerSource,
        template: SummaryTemplate = .meetingNotes,
        mode: ProcessingMode? = nil,
        contextTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.source = source
        self.template = template
        self.mode = mode
        self.contextTitle = contextTitle
        self.createdAt = createdAt
    }
}

public final class RecordingLaunchInbox: Sendable {

    /// Widget uzantısı eklendiğinde bu App Group'a taşınacak; şu an ana
    /// uygulamanın kendi alanı yeterli çünkü intent'ler uygulama sürecinde
    /// çalışıyor.
    public static let appGroupIdentifier = "group.com.auravoice.shared"

    public static let shared = RecordingLaunchInbox()

    /// Bu süreden eski istekler yok sayılır.
    public static let freshnessWindow: TimeInterval = 5 * 60

    private let key = "aura.recording.launchRequest"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// İsteği bırakır. Bekleyen bir istek varsa üzerine yazar — kullanıcının
    /// en son söylediği şey geçerlidir.
    public func submit(_ request: RecordingLaunchRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        defaults.set(data, forKey: key)
    }

    /// İsteği okur ve kutuyu boşaltır. Bayat istek nil döner.
    public func take(now: Date = Date()) -> RecordingLaunchRequest? {
        guard let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)

        guard let request = try? JSONDecoder().decode(RecordingLaunchRequest.self, from: data) else {
            return nil
        }
        // Gelecekten gelen damga da şüpheli (saat oynatılmış): mutlak farka bak.
        guard abs(now.timeIntervalSince(request.createdAt)) <= Self.freshnessWindow else {
            return nil
        }
        return request
    }

    /// Okumadan bakmak isteyenler için (teşhis).
    public func peek() -> RecordingLaunchRequest? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecordingLaunchRequest.self, from: data)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
