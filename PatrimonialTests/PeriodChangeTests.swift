import Foundation
import Testing
import SwiftData
@testable import Patrimonial

@MainActor
struct PeriodChangeTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { date(2026, 8, 7, 15) }

    private func makeAccount(in ctx: ModelContext) -> Account {
        let acc = Account(name: "IBKR", type: .brokerage)
        ctx.insert(acc)
        try! ctx.save()
        return acc
    }

    private func makeVM(
        ctx: ModelContext,
        at instant: Date
    ) -> (PortfolioViewModel, PriceStore) {
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.now = { instant }
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: MockFXRateProvider())
        return (vm, store)
    }

    private var xetraNVD: AssetSearchResult {
        AssetSearchResult(
            symbol: "NVD", name: "NVIDIA", exchange: "XETR",
            assetClass: .stock, currency: "EUR", mic: "XETR"
        )
    }

    private var xnasAAPL: AssetSearchResult {
        AssetSearchResult(
            symbol: "AAPL", name: "Apple", exchange: "XNAS",
            assetClass: .stock, currency: "USD", mic: "XNAS"
        )
    }

    private func quote(
        _ symbol: String, price: Decimal, previousClose: Decimal,
        currency: String = "EUR", at instant: Date
    ) -> Quote {
        Quote(
            symbol: symbol, price: price,
            previousClose: previousClose,
            changeAbsolute: 0, changePercent: 0,
            currency: currency, timestamp: instant, source: .rest
        )
    }

    // MARK: - Mid-period purchase counts from lot price

    @Test func aPurchaseMidPeriodCountsFromTheLotPrice() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now),
            as: listing
        )

        // 1-month cutoff from 2026-08-07 is 2026-07-07.
        // Lot 1: bought 2026-06-15 — before the cutoff → uses reference close.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 6, 15), note: "", asset: xetraNVD
        )
        // Lot 2: bought 2026-08-02 — within the period → uses lot price.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 195, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 2), note: "", asset: xetraNVD
        )

        let refCloseAtCutoff: Decimal = 178

        vm.selectedPeriod = .oneMonth
        vm.referenceCloseLookup = { lid, _ in
            lid == listing ? refCloseAtCutoff : nil
        }

        let total = try #require(vm.periodChangeTotal)
        // Lot 1 (before cutoff): 200 - 178 = 22
        // Lot 2 (within period): 200 - 195 = 5 (from lot price, not reference)
        #expect(total.value == 27)
        #expect(total.excludedCount == 0)
    }

    // MARK: - One position doesn't reach the period → partial

    @Test func aPositionThatDoesNotReachThePeriodMarksPartial() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let nvdListing = ListingID(symbol: "NVD", mic: "XETR")
        let aaplListing = ListingID(symbol: "AAPL", mic: "XNAS")
        store.register(nvdListing, currency: "EUR")
        store.register(aaplListing, currency: "USD")

        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now),
            as: nvdListing
        )
        store.applyQuote(
            quote("AAPL", price: 320, previousClose: 315, currency: "USD", at: now),
            as: aaplListing
        )
        vm.setCurrentFXRateForTesting(
            FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.87")!)!
        )

        // 1-year cutoff from 2026-08-07 is 2025-08-07.
        // NVD: bought 2025-03-01 — before cutoff → uses reference close.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 140, fxRate: 1, commission: 0,
            account: acc, date: date(2025, 3, 1), note: "", asset: xetraNVD
        )
        // AAPL: bought 2 months ago — no reference close available.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 1,
            unitPrice: 300, fxRate: Decimal(string: "0.87")!, commission: 0,
            account: acc, date: date(2026, 6, 1), note: "", asset: xnasAAPL
        )

        vm.selectedPeriod = .oneYear
        vm.referenceCloseLookup = { lid, _ in
            if lid == nvdListing { return 170 }
            return nil
        }

        let total = try #require(vm.periodChangeTotal)
        // NVD: 200 - 170 = 30 (from reference close, lot predates period)
        #expect(total.value == 30)
        #expect(total.includedCount == 1)
        #expect(total.excludedCount == 1)
        #expect(total.isPartial)
    }

    // MARK: - Nobody reaches the period → nil (empty state)

    @Test func noPriceDataForAnyoneReturnsNil() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now),
            as: listing
        )

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 1), note: "", asset: xetraNVD
        )

        vm.selectedPeriod = .oneYear
        vm.referenceCloseLookup = { _, _ in nil }

        #expect(vm.periodChangeTotal == nil)
    }

    // MARK: - Switching period does not trigger a network request

    /// `periodChangeTotal` is a synchronous computed property that reads cached
    /// holdings and the caller-supplied `referenceCloseLookup`. Switching periods
    /// never awaits anything — if it did, this non-async test would not compile.
    /// The assertion is that every period returns a value from cache, proving no
    /// fetch is needed.
    @Test func switchingPeriodUsesOnlyCachedData() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now),
            as: listing
        )

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 2, 1), note: "", asset: xetraNVD
        )

        vm.referenceCloseLookup = { lid, _ in
            lid == listing ? 170 : nil
        }

        for period in PerformancePeriod.allCases {
            vm.selectedPeriod = period
            let total = vm.periodChangeTotal
            #expect(total != nil, "\(period.label) devolveu nil com dados em cache")
        }
    }

    // MARK: - 1 Dia ≡ old "Hoje"

    @Test func oneDayGivesExactlyTheSameAsTheOldDayChangeTotal() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let saturday = date(2026, 8, 8, 11)
        let (vm, store) = makeVM(ctx: ctx, at: saturday)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: Decimal(string: "194.22")!,
                  previousClose: Decimal(string: "189.16")!, at: saturday),
            as: listing
        )

        // One lot before Friday's session, one during it.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 170, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 31), note: "", asset: xetraNVD
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 7, 15), note: "", asset: xetraNVD
        )

        let dayChange = vm.dayChangeTotal
        vm.selectedPeriod = .oneDay
        let periodChange = vm.periodChangeTotal

        #expect(dayChange == periodChange)
    }

    // MARK: - Guard mutation tests

    @Test func periodChangeIsNilWithoutAReferenceCloseLookup() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now),
            as: listing
        )

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 2, 1), note: "", asset: xetraNVD
        )

        vm.selectedPeriod = .oneMonth
        vm.referenceCloseLookup = nil

        #expect(vm.periodChangeTotal == nil)
    }

    @Test func periodChangeIsNilWithoutAPrice() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, _) = makeVM(ctx: ctx, at: now)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 2, 1), note: "", asset: xetraNVD
        )

        vm.selectedPeriod = .oneMonth
        vm.referenceCloseLookup = { _, _ in 170 }

        #expect(vm.periodChangeTotal == nil)
    }

    @Test func periodChangeIsNilWithoutAnFXRate() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "AAPL", mic: "XNAS")
        store.register(listing, currency: "USD")
        store.applyQuote(
            quote("AAPL", price: 320, previousClose: 315, currency: "USD", at: now),
            as: listing
        )
        // No FX rate set for USD.

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 1,
            unitPrice: 300, fxRate: Decimal(string: "0.87")!, commission: 0,
            account: acc, date: date(2026, 2, 1), note: "", asset: xnasAAPL
        )

        vm.selectedPeriod = .oneMonth
        vm.referenceCloseLookup = { _, _ in 310 }

        #expect(vm.periodChangeTotal == nil)
    }

    @Test func oneDayFallsBackToDayChangeTotalEvenWithoutLookup() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now),
            as: listing
        )

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 2, 1), note: "", asset: xetraNVD
        )

        vm.selectedPeriod = .oneDay
        vm.referenceCloseLookup = nil

        let total = try #require(vm.periodChangeTotal)
        #expect(total.value == 10)
    }

    // MARK: - Header consumption: value, partial, empty across period switches

    @Test func headerReadsCorrectValueAndPartialWhenSwitchingPeriods() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let nvd = ListingID(symbol: "NVD", mic: "XETR")
        let aapl = ListingID(symbol: "AAPL", mic: "XNAS")
        store.register(nvd, currency: "EUR")
        store.register(aapl, currency: "USD")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now), as: nvd
        )
        store.applyQuote(
            quote("AAPL", price: 320, previousClose: 315, currency: "USD", at: now), as: aapl
        )
        vm.setCurrentFXRateForTesting(
            FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.87")!)!
        )

        // NVD bought well before any cutoff.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 140, fxRate: 1, commission: 0,
            account: acc, date: date(2025, 1, 15), note: "", asset: xetraNVD
        )
        // AAPL bought 3 months ago — won't reach 1A cutoff.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 1,
            unitPrice: 300, fxRate: Decimal(string: "0.87")!, commission: 0,
            account: acc, date: date(2026, 5, 10), note: "", asset: xnasAAPL
        )

        vm.referenceCloseLookup = { lid, _ in
            if lid == nvd { return 175 }
            return nil
        }

        // 1M: NVD has reference, AAPL has reference → both included if lookup returns.
        // But our lookup only returns for NVD, so AAPL is excluded → partial.
        vm.selectedPeriod = .oneMonth
        let oneMonth = try #require(vm.periodChangeTotal)
        #expect(oneMonth.value == 25) // 200 - 175
        #expect(oneMonth.isPartial)
        #expect(oneMonth.excludedCount == 1)

        // 1D: falls back to dayChangeTotal, both have previousClose → full.
        vm.selectedPeriod = .oneDay
        let oneDay = try #require(vm.periodChangeTotal)
        #expect(!oneDay.isPartial)
        #expect(oneDay.includedCount == 2)
    }

    @Test func headerShowsEmptyStateWhenNoPeriodDataExists() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: now)

        let listing = ListingID(symbol: "NVD", mic: "XETR")
        store.register(listing, currency: "EUR")
        store.applyQuote(
            quote("NVD", price: 200, previousClose: 190, at: now), as: listing
        )

        // Bought recently — no candle history at all.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: 195, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 5), note: "", asset: xetraNVD
        )

        vm.referenceCloseLookup = { _, _ in nil }

        // 1A: no reference close for anyone → nil (empty state).
        vm.selectedPeriod = .oneYear
        #expect(vm.periodChangeTotal == nil)

        // 1D: still works via dayChangeTotal (previousClose exists).
        // Lot bought 2026-08-05 predates session on 2026-08-07 → uses previousClose.
        vm.selectedPeriod = .oneDay
        let oneDay = try #require(vm.periodChangeTotal)
        #expect(oneDay.value == 10) // 200 - 190 (previousClose)
    }

    @Test func periodIsPersistedAcrossInstances() {
        UserDefaults.standard.removeObject(forKey: "selectedPerformancePeriod")
        let vm1 = PortfolioViewModel()
        #expect(vm1.selectedPeriod == .oneDay)

        vm1.selectedPeriod = .threeMonths
        let vm2 = PortfolioViewModel()
        #expect(vm2.selectedPeriod == .threeMonths)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "selectedPerformancePeriod")
    }
}
