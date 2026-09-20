//
//  QuotaSnapshotPublisher.swift
//  AuraVoice
//
//  Kota durumunu widget'ın okuyabileceği App Group alanına yazar.
//
//  Uzantı kotayı yeniden hesaplamıyor; tek doğruluk kaynağı uygulama.
//  Ücretsiz hediye, imzalı bilet ve abonelik yenilemesi kurallarının iki
//  yerde yaşaması, iki farklı sayı gösterilmesi demek olurdu.
//

import Foundation
import WidgetKit

public enum QuotaSnapshotPublisher {

    /// Değer gerçekten değiştiyse yazar ve widget'ları yeniler.
    ///
    /// Her tazelemede körlemesine `reloadAllTimelines` çağırmak iOS'un widget
    /// yenileme bütçesini tüketiyor ve bir süre sonra widget'ı bayat
    /// bırakıyor — bu yüzden değişiklik kontrolü var.
    /// - Parameter lane: Widget'ın büyük sayı olarak göstereceği havuz.
    ///   `nil` → yayında duran havuz KORUNUR. Modu bilmeyen ekranlar (Ayarlar
    ///   içindeki model indirme gibi) bunu kullanmalı; sabit bir havuz
    ///   geçmeleri, bulut modundaki kullanıcının widget'ını sessizce cihaz içi
    ///   havuza çevirirdi.
    @discardableResult
    public static func publish(
        lane: QuotaLane?,
        offlineRemainingMinutes: Double,
        offlinePlanMinutes: Double,
        onlineRemainingMinutes: Double,
        onlinePlanMinutes: Double,
        offlineAvailable: Bool = OfflineModelManager.isOfflineReady(),
        now: Date = Date()
    ) -> Bool {

        let existing = SharedQuotaSnapshot.read()
        let snapshot = SharedQuotaSnapshot(
            lane: lane ?? existing?.lane ?? .offline,
            offlineRemainingMinutes: max(0, offlineRemainingMinutes),
            offlinePlanMinutes: max(0, offlinePlanMinutes),
            onlineRemainingMinutes: max(0, onlineRemainingMinutes),
            onlinePlanMinutes: max(0, onlinePlanMinutes),
            updatedAt: now,
            offlineAvailable: offlineAvailable
        )

        // Karşılaştırma İKİ havuzu ve etkin havuzun kimliğini de kapsıyor.
        // Yalnızca gösterilen sayıya bakılsaydı, iki havuzun bakiyesi eşitken
        // yapılan mod değişimi yayınlanmaz ve widget yanlış etiketle kalırdı.
        if let existing,
           existing.lane == snapshot.lane,
           existing.offlineAvailable == snapshot.offlineAvailable,
           abs(existing.offlineRemainingMinutes - snapshot.offlineRemainingMinutes) < 0.01,
           abs(existing.offlinePlanMinutes - snapshot.offlinePlanMinutes) < 0.01,
           abs(existing.onlineRemainingMinutes - snapshot.onlineRemainingMinutes) < 0.01,
           abs(existing.onlinePlanMinutes - snapshot.onlinePlanMinutes) < 0.01 {
            return false
        }

        snapshot.write()

        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
}
