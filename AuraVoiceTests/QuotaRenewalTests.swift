//
//  QuotaRenewalTests.swift
//  AuraVoiceTests
//
//  Aylık kota yenilemesi, kurulum sırası ve kayıt aşımı toleransı.
//

import Testing
import Foundation
@testable import AuraVoice

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    utcCalendar().date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

// MARK: - Dönem hesabı

@Suite("Dönem hesabı")
struct QuotaPeriodTests {

    private let calendar = utcCalendar()

    @Test("Dönem içindeyken başlangıç değişmez")
    func staysWithinPeriod() {
        let anchor = day(2026, 3, 10)
        let start = QuotaManager.currentPeriodStart(anchor: anchor, now: day(2026, 3, 28), calendar: calendar)
        #expect(start == anchor)
    }

    @Test("Bir ay geçince sınır ilerler")
    func advancesOneMonth() {
        let anchor = day(2026, 3, 10)
        let start = QuotaManager.currentPeriodStart(anchor: anchor, now: day(2026, 4, 12), calendar: calendar)
        #expect(start == day(2026, 4, 10))
    }

    @Test("Uzun süre uykuda kalan kullanıcı biriktiremez")
    func dormantUserGetsOnePeriod() {
        // Beş ay sonra dönen kullanıcı beş dönemlik bakiye almamalı; sınır
        // doğrudan bugüne en yakın aya taşınıyor.
        let anchor = day(2026, 1, 15)
        let start = QuotaManager.currentPeriodStart(anchor: anchor, now: day(2026, 6, 20), calendar: calendar)
        #expect(start == day(2026, 6, 15))
    }

    @Test("Saat geriye alınsa da dönem geri gitmez")
    func clockRollbackDoesNotRewind() {
        let anchor = day(2026, 5, 1)
        let start = QuotaManager.currentPeriodStart(anchor: anchor, now: day(2026, 2, 1), calendar: calendar)
        #expect(start == anchor)
    }

    @Test("Kısa aylarda sınır kaybolmaz")
    func handlesShortMonths() {
        // 31 Ocak + 1 ay = 28 Şubat; takvim bunu kendi çözüyor, biz sonucun
        // geçerli ve ileri olduğunu doğruluyoruz.
        let anchor = day(2026, 1, 31)
        let start = QuotaManager.currentPeriodStart(anchor: anchor, now: day(2026, 3, 15), calendar: calendar)
        #expect(start > anchor)
        #expect(start <= day(2026, 3, 15))
    }
}

// MARK: - Aylık yenileme

@Suite("Aylık yenileme", .serialized)
struct QuotaRenewalTests {

    private func makeManager(
        seconds: Double,
        periodStart: Date,
        planMinutes: Double = 30
    ) -> (QuotaManager, InMemoryQuotaStorage) {
        let storage = InMemoryQuotaStorage(
            initialSeconds: seconds,
            bootstrapped: true,
            periodStart: periodStart,
            planMinutes: planMinutes
        )
        return (QuotaManager(storage: storage, calendar: utcCalendar()), storage)
    }

    @Test("Ay dolunca bakiye plan dakikasına döner")
    func renewsAfterOneMonth() {
        let (quota, _) = makeManager(seconds: 0, periodStart: day(2026, 3, 10))
        #expect(quota.getRemainingMinutes(now: day(2026, 4, 11)) == 30)
    }

    @Test("Dönem içinde bakiye korunur")
    func doesNotRenewEarly() {
        let (quota, _) = makeManager(seconds: 300, periodStart: day(2026, 3, 10))
        #expect(quota.getRemainingSeconds(now: day(2026, 3, 25)) == 300)
    }

    @Test("Yenileme bakiyeyi artırmaz, eşitler")
    func renewalResetsRatherThanAdds() {
        // Kalan 20 dakikası olan kullanıcı yeni ayda 50 değil 30 dakika görür.
        let (quota, _) = makeManager(seconds: 20 * 60, periodStart: day(2026, 3, 10))
        #expect(quota.getRemainingMinutes(now: day(2026, 4, 15)) == 30)
    }

    @Test("Pro planında yenileme plan dakikasını kullanır")
    func renewalUsesPlanMinutes() {
        let (quota, _) = makeManager(seconds: 0, periodStart: day(2026, 3, 10), planMinutes: 1_200)
        #expect(quota.getRemainingMinutes(now: day(2026, 4, 11)) == 1_200)
    }

    @Test("Yenileme sonrası aynı dönemde tekrar yenilenmez")
    func renewalIsIdempotentWithinNewPeriod() {
        let (quota, _) = makeManager(seconds: 0, periodStart: day(2026, 3, 10))
        let now = day(2026, 4, 11)

        #expect(quota.getRemainingMinutes(now: now) == 30)
        try? quota.deductUsage(durationSeconds: 600, now: now)
        // Aynı dönemde tekrar okumak harcanan dakikayı geri getirmemeli.
        #expect(quota.getRemainingMinutes(now: now) == 20)
    }

    @Test("Bakiye yazılamazsa dönem ilerlemez")
    func failedWriteKeepsPeriod() {
        // Dönem ilerleyip bakiye yazılamasaydı kullanıcı o ayı tamamen
        // kaybederdi; sıra bilinçli olarak bakiye-önce.
        let storage = FailingQuotaStorage(periodStart: day(2026, 3, 10), planMinutes: 30)
        let quota = QuotaManager(storage: storage, calendar: utcCalendar())

        _ = quota.getRemainingSeconds(now: day(2026, 4, 11))
        #expect(storage.readPeriodStart() == day(2026, 3, 10))
    }

    @Test("Sonraki yenileme tarihi bir ay ileride")
    func nextRenewalDateIsOneMonthOut() {
        let (quota, _) = makeManager(seconds: 300, periodStart: day(2026, 3, 10))
        #expect(quota.nextRenewalDate(now: day(2026, 3, 20)) == day(2026, 4, 10))
    }

    @Test("Plan değişimi bakiyeyi ve dönemi birlikte yazar")
    func setPlanWritesBoth() {
        let (quota, storage) = makeManager(seconds: 0, periodStart: day(2026, 3, 10))

        #expect(quota.setPlan(monthlyMinutes: 1_200, now: day(2026, 3, 20)))
        #expect(quota.getRemainingMinutes(now: day(2026, 3, 21)) == 1_200)
        #expect(quota.planMonthlyMinutes() == 1_200)
        #expect(storage.readPeriodStart() == day(2026, 3, 20))
    }
}

// MARK: - Kurulum sırası

@Suite("Kota kurulumu")
struct QuotaBootstrapOrderTests {

    @Test("İlk açılışta ücretsiz dakika ve dönem yazılır")
    func bootstrapGrantsAndStartsPeriod() {
        let storage = InMemoryQuotaStorage()
        let quota = QuotaManager(storage: storage, calendar: utcCalendar())

        #expect(quota.getRemainingMinutes(now: day(2026, 3, 10)) == 30)
        #expect(storage.readPeriodStart() == day(2026, 3, 10))
        #expect(storage.isBootstrapped())
    }

    @Test("Bakiye yazılamazsa kurulum tamamlandı sayılmaz")
    func failedGrantIsRetriable() {
        // Eski sıra (önce bayrak, sonra bakiye) yüzünden Keychain yazımı
        // başarısız olan bir cihazda hediye bir daha ASLA verilmiyordu.
        let storage = FailingQuotaStorage()
        let quota = QuotaManager(storage: storage, calendar: utcCalendar())

        _ = quota.getRemainingSeconds(now: day(2026, 3, 10))
        #expect(!storage.isBootstrapped())

        storage.writesFail = false
        #expect(quota.getRemainingMinutes(now: day(2026, 3, 10)) == 30)
        #expect(storage.isBootstrapped())
    }
}

// MARK: - Aşım toleransı

@Suite("Kayıt aşımı toleransı")
struct ProcessingOverrunTests {

    private func makeRouter(seconds: Double) -> (ProcessingRouter, QuotaManager) {
        let quota = QuotaManager(storage: InMemoryQuotaStorage(initialSeconds: seconds, bootstrapped: true))
        let router = ProcessingRouter(
            offlineEngine: OverrunStubEngine(),
            onlineEngine: OverrunStubEngine(),
            quotaManager: quota
        )
        return (router, quota)
    }

    private func request(_ duration: Double) -> ProcessingRequest {
        ProcessingRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/aura-overrun-test.wav"),
            durationSeconds: duration,
            mode: .offlineZeroCloud,
            summaryTemplate: .meetingNotes
        )
    }

    @Test("Otomatik durdurmadaki milisaniyelik aşım kaydı çöpe atmaz")
    func slightOverrunStillProcesses() async throws {
        // Kota 600 sn; kaydı 600'de kapatıyoruz ama dosyaya 600.4 sn yazılmış.
        // Eskiden bu fark 45 dakikalık toplantıyı "yetersiz kota" ile siliyordu.
        let (router, quota) = makeRouter(seconds: 600)

        let result = try await router.execute(request: request(600.4))

        // Sahip olmadığı dakika harcanmıyor: bakiye tam sıfırlanıyor.
        #expect(quota.getRemainingSeconds() == 0)
        #expect(result.usedMinutes == 10)
    }

    @Test("Gerçek yetersizlik hâlâ reddediliyor")
    func realShortfallStillRejected() async {
        let (router, quota) = makeRouter(seconds: 60)

        await #expect(throws: AuraError.self) {
            _ = try await router.execute(request: request(600))
        }
        #expect(quota.getRemainingSeconds() == 60)
    }

    @Test("Tolerans içinde kalan kayıt bakiyeyi eksiye düşürmez")
    func billingNeverGoesNegative() async throws {
        let (router, quota) = makeRouter(seconds: 100)
        _ = try await router.execute(request: request(101.5))
        #expect(quota.getRemainingSeconds() == 0)
    }
}

// MARK: - Test yardımcıları

/// Yazma işlemleri başarısız olan depo — Keychain'in reddettiği durumu taklit eder.
private final class FailingQuotaStorage: QuotaStorage, @unchecked Sendable {

    private let lock = NSLock()
    private var balance: Double?
    private var bootstrapped = false
    private var periodStart: Date?
    private var planMinutes: Double?
    private var failing = true

    var writesFail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }

    init(periodStart: Date? = nil, planMinutes: Double? = nil) {
        self.periodStart = periodStart
        self.planMinutes = planMinutes
    }

    func readBalanceSeconds() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return balance
    }

    @discardableResult
    func writeBalanceSeconds(_ seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failing else { return false }
        balance = max(0, seconds)
        return true
    }

    func isBootstrapped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bootstrapped
    }

    @discardableResult
    func markBootstrapped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        bootstrapped = true
        return true
    }

    func readPeriodStart() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return periodStart
    }

    @discardableResult
    func writePeriodStart(_ date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failing else { return false }
        periodStart = date
        return true
    }

    func readPlanMinutes() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return planMinutes
    }

    @discardableResult
    func writePlanMinutes(_ minutes: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failing else { return false }
        planMinutes = minutes
        return true
    }
}

private struct OverrunStubEngine: ProcessingEngineProtocol {

    var isConfigured: Bool { true }

    func process(request: ProcessingRequest) async throws -> ProcessingResult {
        ProcessingResult(
            rawTranscript: "test",
            summaryMarkdown: "### Test\n- madde",
            detectedLanguage: "tr",
            usedMinutes: 0,
            processingTimeSeconds: 0
        )
    }
}
