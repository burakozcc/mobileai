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

public struct RecordingLaunchRequest: Sendable, Equatable {

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

    // MARK: Uzantı sınırı

    /// Uygulama enum'larından düz String'lere. Uzantı bu biçimi okuyor.
    public var shared: SharedLaunchRequest {
        SharedLaunchRequest(
            source: source.rawValue,
            template: template.rawValue,
            mode: mode?.rawValue,
            contextTitle: contextTitle,
            createdAt: createdAt
        )
    }

    /// Tanınmayan değerler güvenli varsayılana düşüyor: uzantı ile uygulama
    /// sürümleri farklı olabilir (kullanıcı güncellemeyi yarım bırakabilir) ve
    /// bu yüzden kayıt hiç başlamaması kabul edilemez.
    public init(_ shared: SharedLaunchRequest) {
        self.source = RecordingTriggerSource(rawValue: shared.source) ?? .widget
        self.template = SummaryTemplate(rawValue: shared.template) ?? .meetingNotes
        self.mode = shared.mode.flatMap(ProcessingMode.init(rawValue:))
        self.contextTitle = shared.contextTitle
        self.createdAt = shared.createdAt
    }
}

/// `UserDefaults` Sendable olarak işaretlenmemiş ama belgelenmiş şekilde
/// iş parçacığı güvenli; kutunun kendi durumu yok, o yüzden `@unchecked`.
public final class RecordingLaunchInbox: @unchecked Sendable {

    public static let shared = RecordingLaunchInbox()

    /// Bu süreden eski istekler yok sayılır.
    public static let freshnessWindow: TimeInterval = 5 * 60

    private let defaults: UserDefaults

    /// Varsayılan olarak App Group konteyneri kullanılıyor: widget uzantısı
    /// ayrı bir süreçte çalıştığı için standart alan ikisini buluşturmaz.
    /// Yetki verilmemişse `sharedDefaults()` standart alana düşüyor —
    /// uygulama içi tetikleyiciler (Siri, Action Button) yine çalışır.
    public init(defaults: UserDefaults = AuraSharedContract.sharedDefaults()) {
        self.defaults = defaults
    }

    // MARK: Yazma

    /// İsteği bırakır. Bekleyen bir istek varsa üzerine yazar — kullanıcının
    /// en son söylediği şey geçerlidir.
    public func submit(_ request: RecordingLaunchRequest) {
        request.shared.write(to: defaults)
    }

    // MARK: Okuma

    /// İsteği okur ve kutuyu boşaltır. Bayat istek nil döner.
    public func take(now: Date = Date()) -> RecordingLaunchRequest? {
        let request = decode()
        defaults.removeObject(forKey: AuraSharedContract.launchRequestKey)

        guard let request else { return nil }
        // Gelecekten gelen damga da şüpheli (saat oynatılmış): mutlak farka bak.
        guard abs(now.timeIntervalSince(request.createdAt)) <= Self.freshnessWindow else {
            return nil
        }
        return request
    }

    /// Okumadan bakmak isteyenler için (teşhis).
    public func peek() -> RecordingLaunchRequest? {
        decode()
    }

    public func clear() {
        defaults.removeObject(forKey: AuraSharedContract.launchRequestKey)
    }

    private func decode() -> RecordingLaunchRequest? {
        guard let data = defaults.data(forKey: AuraSharedContract.launchRequestKey),
              let shared = try? JSONDecoder().decode(SharedLaunchRequest.self, from: data)
        else { return nil }
        return RecordingLaunchRequest(shared)
    }
}
