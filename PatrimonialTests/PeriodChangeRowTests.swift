import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// The figure under each position, once it started following the period picker.
///
/// The header total was already period-aware; the row was not, and showed the
/// lifetime P/L whatever the picker said. Testing the total proves nothing about
/// the row — they are two call sites — so what is pinned here is the property
/// that ties them: **the rows sum to the total**, for every period and every
/// shape of position.
@MainActor
struct PeriodChangeRowTests {

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

    private func makeVM(ctx: ModelContext) -> (PortfolioViewModel, PriceStore) {
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.now = { now }
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: MockFXRateProvider())
        return (vm, store)
    }

    private var xetraNVD: AssetSearchResult {
        AssetSearchResult(
            symbol: "NVD", name: "NVIDIA", exchange: "XETR",
            assetClass: .stock, currency: "EUR", mic: "XETR"
        )
    }

    private var xetraSAP: AssetSearchResult {
        AssetSearchResult(
            symbol: "SAP", name: "SAP", exchange: "XETR",
            assetClass: .stock, currency: "EUR", mic: "XETR"
        )
    }

    private func quote(
        _ symbol: String, price: Decimal, previousClose: Decimal, at instant: Date
    ) -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: previousClose,
            changeAbsolute: 0, changePercent: 0,
            currency: "EUR", timestamp: instant, source: .rest
        )
    }

    /// Two positions: one bought long before every cutoff, one bought inside the
    /// short periods and outside the long ones. Both priced, both with a
    /// reference close, so nothing is excluded and the total is not partial.
    private func portfolio(ctx: ModelContext) throws -> (PortfolioViewModel, ListingID, ListingID) {
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx)

        let nvd = ListingID(symbol: "NVD", mic: "XETR")
        let sap = ListingID(symbol: "SAP", mic: "XETR")
        store.register(nvd, currency: "EUR")
        store.register(sap, currency: "EUR")
        store.applyQuote(quote("NVD", price: 200, previousClose: 190, at: now), as: nvd)
        store.applyQuote(quote("SAP", price: 120, previousClose: 118, at: now), as: sap)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 2,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: acc, date: date(2025, 3, 10), note: "", asset: xetraNVD
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "SAP", quantity: 3,
            unitPrice: 110, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 20), note: "", asset: xetraSAP
        )
        vm.loadHoldings()
        return (vm, nvd, sap)
    }

    // MARK: - As linhas somam o total

    /// The cartesian product: every period, against a portfolio holding one
    /// position older than all of them and one bought in the middle of them.
    ///
    /// A row computed from its own rule would pass a single-period test and
    /// disagree with the header the moment the user tapped a different tag.
    @Test(arguments: PerformancePeriod.allCases)
    func theRowsSumToTheHeaderTotal(period: PerformancePeriod) throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _, _) = try portfolio(ctx: ctx)

        vm.selectedPeriod = period
        // Flat reference for both listings, whatever the cutoff: what is under
        // test is the agreement between row and total, not the candle lookup.
        vm.referenceCloseLookup = { listing, _ in
            listing.symbol == "NVD" ? 178 : 115
        }

        let total = try #require(vm.periodChangeTotal, "\(period.rawValue): sem total")
        let rows = vm.openHoldings.compactMap { vm.periodChange(for: $0)?.eur }
        #expect(rows.count == vm.openHoldings.count, "\(period.rawValue): uma linha sem valor")
        #expect(rows.reduce(Decimal(0), +) == total.value, "\(period.rawValue)")
    }

    // MARK: - Sem histórico é um travessão

    /// No candle inside the period means no figure. Not zero, not the lifetime
    /// P/L — a number under a "1M" tag has to be a month's move or nothing.
    @Test(arguments: PerformancePeriod.allCases.filter { $0 != .oneDay })
    func aPositionWithoutAReferenceCloseHasNoRowFigure(period: PerformancePeriod) throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _, _) = try portfolio(ctx: ctx)

        vm.selectedPeriod = period
        vm.referenceCloseLookup = { listing, _ in
            // Only NVD has history. SAP must come back nil.
            listing.symbol == "NVD" ? 178 : nil
        }

        for holding in vm.openHoldings {
            let change = vm.periodChange(for: holding)
            if holding.assetSymbol == "SAP" {
                #expect(change == nil, "\(period.rawValue): SAP inventou uma variação")
            } else {
                #expect(change != nil, "\(period.rawValue): NVD perdeu a variação")
            }
        }
    }

    /// With no lookup wired at all, every non-1D period is a dash. 1D keeps
    /// working: it reads the previous close off the quote, not the candles.
    @Test func withoutAnyHistoryOnlyTheDayPeriodSurvives() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _, _) = try portfolio(ctx: ctx)
        vm.referenceCloseLookup = nil

        vm.selectedPeriod = .oneDay
        #expect(vm.openHoldings.allSatisfy { vm.periodChange(for: $0) != nil })

        for period in PerformancePeriod.allCases where period != .oneDay {
            vm.selectedPeriod = period
            #expect(
                vm.openHoldings.allSatisfy { vm.periodChange(for: $0) == nil },
                "\(period.rawValue) devolveu um valor sem histórico"
            )
        }
    }

    // MARK: - O valor é o do período, não o P/L de sempre

    /// The regression this feature exists to fix, stated as a number.
    ///
    /// NVD: 2 units bought at 160, now 200. Lifetime P/L is +25,00 %. Over a
    /// month whose reference close is 178 the move is +12,36 %. If the row ever
    /// prints 25 % again under a "1M" tag, this fails.
    @Test func theRowReportsThePeriodNotTheLifetimeReturn() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _, _) = try portfolio(ctx: ctx)

        vm.selectedPeriod = .oneMonth
        vm.referenceCloseLookup = { listing, _ in
            listing.symbol == "NVD" ? 178 : 115
        }

        let nvd = try #require(vm.openHoldings.first { $0.assetSymbol == "NVD" })
        let change = try #require(vm.periodChange(for: nvd))

        // 2 × (200 − 178) = 44, against a base of 2 × 178 = 356.
        #expect(change.eur == 44)
        #expect(change.percent == (Decimal(44) / Decimal(356)) * 100)

        let lifetime = try #require(nvd.unrealizedPLPercent)
        #expect(lifetime == 25)
        #expect(change.percent != lifetime)
    }

    /// Switching the picker changes the row, which is the entire user-visible
    /// promise. Two periods with different references must not produce the same
    /// figure.
    @Test func changingThePeriodChangesTheRow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _, _) = try portfolio(ctx: ctx)

        // The reference now depends on the cutoff, so each period sees a
        // different starting price — as it does in the real cache.
        vm.referenceCloseLookup = { listing, cutoff in
            guard listing.symbol == "NVD" else { return 115 }
            return cutoff < self.date(2026, 7, 1) ? 150 : 178
        }

        let nvd = try #require(vm.openHoldings.first { $0.assetSymbol == "NVD" })

        vm.selectedPeriod = .oneMonth
        let month = try #require(vm.periodChange(for: nvd))
        vm.selectedPeriod = .oneYear
        let year = try #require(vm.periodChange(for: nvd))

        #expect(month.eur == 44)      // 2 × (200 − 178)
        #expect(year.eur == 100)      // 2 × (200 − 150)
        #expect(month.percent != year.percent)
    }
}
