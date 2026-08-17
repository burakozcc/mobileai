//
//  CallObserverService.swift
//  AuraVoice
//
//  CallKit üzerinden telefon görüşmesi durumu izlenir. CallKit görüşme SESİNE
//  erişim vermez; bu yüzden kullanıcıya "hoparlörü aç" ipucu gösterip kaydı
//  cihaz mikrofonundan alırız.
//
//  Swift 6 notu: `CXCallObserverDelegate` geri çağrısı verilen kuyrukta çalışır.
//  Sınıf aktöre bağlanmaz; olaylar `AsyncStream` ile MainActor tarafına taşınır.
//

import Foundation
import CallKit

public struct CallState: Sendable, Equatable {
    public let isConnected: Bool
    public let isOutgoing: Bool
    public let hasEnded: Bool
}

public final class CallObserverService: NSObject, CXCallObserverDelegate, @unchecked Sendable {

    public static let shared = CallObserverService()

    private let callObserver = CXCallObserver()
    private let continuation: AsyncStream<CallState>.Continuation

    /// Görüşme durum akışı. `DashboardViewModel` bunu dinleyip banner gösterir.
    public let states: AsyncStream<CallState>

    private override init() {
        let (stream, continuation) = AsyncStream<CallState>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        self.states = stream
        self.continuation = continuation
        super.init()
    }

    /// `AppDelegate` içinde bir kez çağrılır.
    public func start() {
        callObserver.setDelegate(self, queue: DispatchQueue.main)
    }

    /// Şu an bağlı bir görüşme var mı?
    public var hasActiveCall: Bool {
        callObserver.calls.contains { $0.hasConnected && !$0.hasEnded }
    }

    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let state = CallState(
            isConnected: call.hasConnected && !call.hasEnded,
            isOutgoing: call.isOutgoing,
            hasEnded: call.hasEnded
        )
        continuation.yield(state)

        // Görüşme bağlandığında kullanıcıya eyleme dönüştürülebilir bildirim gönder.
        if state.isConnected {
            Task { await NotificationManager.shared.notifyCallConnected() }
        } else if state.hasEnded {
            Task { await NotificationManager.shared.cancelCallPrompts() }
        }
    }
}
