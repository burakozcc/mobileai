//
//  NetworkMonitor.swift
//  AuraVoice
//
//  Ağ erişilebilirliği.
//
//  NEDEN GEREKLİ: Depoda bugüne kadar hiç ağ farkındalığı yoktu. Sonucu şuydu:
//  uçak modundaki kullanıcı Online modu "hazır" görüyor, 45 dakika kaydediyor,
//  işleme aşamasında bağlantı hatası alıyordu — üstelik diskte çalışır bir
//  cihaz içi model dururken. Kayıt artık kaybolmuyor (not `.failed` olarak
//  yazılıyor) ama kullanıcıyı bu duvara hiç götürmemek daha doğru.
//
//  KAPSAM: `NWPathMonitor` yalnızca YOLUN varlığını söylüyor, karşı tarafın
//  cevap verdiğini değil. Otel Wi-Fi'ı ya da captive portal "bağlı" görünür.
//  Bu yüzden monitör bir GARANTİ değil, bir İPUCU: `.unsatisfied` iken buluta
//  gitmek kesinlikle boşuna, `.satisfied` iken gitmek muhtemelen işe yarar.
//  Gerçek hata yolu yine de duruyor.
//

import Foundation
import Network

public enum NetworkReachability: String, Sendable, Equatable {

    case reachable
    case unreachable
    /// Henüz ilk yol raporu gelmedi. Bilinmiyorken engellemiyoruz.
    case unknown

    public var isDefinitelyOffline: Bool { self == .unreachable }
}

public final class NetworkMonitor: @unchecked Sendable {

    public static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.auravoice.network-monitor")
    private let lock = NSLock()

    private var state: NetworkReachability = .unknown
    private var isStarted = false
    private var observers: [UUID: @Sendable (NetworkReachability) -> Void] = [:]

    private init() {}

    // MARK: Yaşam döngüsü

    public func start() {
        lock.lock()
        guard !isStarted else { lock.unlock(); return }
        isStarted = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.apply(path.status == .satisfied ? .reachable : .unreachable)
        }
        monitor.start(queue: queue)
    }

    private func apply(_ new: NetworkReachability) {
        lock.lock()
        guard state != new else { lock.unlock(); return }
        state = new
        let handlers = Array(observers.values)
        lock.unlock()

        for handler in handlers { handler(new) }
    }

    // MARK: Okuma

    public var reachability: NetworkReachability {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Buluta gitmenin kesinlikle boşuna olduğu durum.
    public var isDefinitelyOffline: Bool {
        reachability.isDefinitelyOffline
    }

    // MARK: Gözlem

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (NetworkReachability) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = handler
        let current = state
        lock.unlock()

        handler(current)
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: token)
    }
}

// MARK: - Test ikamesi

/// Testlerde ve önizlemede gerçek `NWPathMonitor` yerine geçen sabit durum.
public struct StaticReachability: Sendable {

    public let value: NetworkReachability

    public init(_ value: NetworkReachability) {
        self.value = value
    }

    public var isDefinitelyOffline: Bool { value.isDefinitelyOffline }
}
