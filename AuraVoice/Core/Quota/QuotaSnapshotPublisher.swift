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
    @discardableResult
    public static func publish(
        remainingMinutes: Double,
        planMinutes: Double,
        now: Date = Date()
    ) -> Bool {

        let existing = SharedQuotaSnapshot.read()
        if let existing,
           abs(existing.remainingMinutes - remainingMinutes) < 0.01,
           abs(existing.planMinutes - planMinutes) < 0.01 {
            return false
        }

        SharedQuotaSnapshot(
            remainingMinutes: max(0, remainingMinutes),
            planMinutes: max(0, planMinutes),
            updatedAt: now
        ).write()

        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
}
