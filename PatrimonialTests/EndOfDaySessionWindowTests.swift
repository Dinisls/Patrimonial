import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - A session has two ends

/// Third time on the same wound, and the first two fixes are both still right.
///
/// The per-lot rule stopped a share bought this morning from being credited with
/// a move that predates it. The session boundary stopped the weekend from making
/// Friday's purchase look old. Neither covers the case the device reported: an
/// Alpha Vantage close for a European venue, read on Monday afternoon while
/// XETRA is trading. The clock says the session began at Monday 00:00 and the
/// price on hand is still Friday's close, because the free plan has nothing
/// newer. A lot bought at 14:00 on Monday sits inside the clock's session and
/// gets measured against Thursday's close.
///
/// The missing piece is the *end* of the window: a purchase can be newer than
/// the price, not only older than it.
@MainActor
struct EndOfDaySessionWindowTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: y, month: m, day: d, hour: h, minute: min
        ))!
    }

    /// The reported afternoon: Monday 10 August 2026, 15:00 in Lisbon. XETRA is
    /// open (16:00 Berlin, closes 17:30) and the newest close available is
    /// Friday the 7th's.
    private var mondayAfternoon: Date { date(2026, 8, 10, 15) }
    private var fridayClose: Date { date(2026, 8, 7, 17, 30) }

    private var xetraNVD: AssetSearchResult {
        AssetSearchResult(
            symbol: "NVD", name: "NVIDIA Corporation", exchange: "XETR",
            assetClass: .stock, currency: "EUR", mic: "XETR"
        )
    }
    private var listing: ListingID { ListingID(symbol: "NVD", mic: "XETR") }

    private func makeAccount(in ctx: ModelContext) -> Account {
        let acc = Account(name: "Investimentos", type: .brokerage)
        ctx.insert(acc)
        try! ctx.save()
        return acc
    }

    private func makeVM(ctx: ModelContext, at instant: Date) -> (PortfolioViewModel, PriceStore) {
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.now = { instant }
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: MockFXRateProvider())
        return (vm, store)
    }

    /// Friday's close, fetched on Monday — which is exactly how Alpha Vantage
    /// answers: `timestamp` is when it arrived, `closeDate` is what it describes.
    private func endOfDayQuote(
        price: String, previousClose: String, fetchedAt: Date, closedOn: Date
    ) -> Quote {
        var q = Quote(
            symbol: "NVD",
            price: Decimal(string: price)!,
            previousClose: Decimal(string: previousClose)!,
            changeAbsolute: 0, changePercent: 0,
            currency: "EUR", timestamp: fetchedAt, source: .dailyClose
        )
        q.closeDate = closedOn
        return q
    }

    private func seed(
        _ ctx: ModelContext, _ store: PriceStore, _ vm: PortfolioViewModel
    ) {
        store.register(listing, currency: "EUR")
        store.applyQuote(
            endOfDayQuote(
                price: "192.14", previousClose: "189.16",
                fetchedAt: mondayAfternoon, closedOn: fridayClose
            ),
            as: listing
        )
    }

    // MARK: - The reported case

    /// Bought this morning, priced at Friday's close: the day change is zero.
    ///
    /// Not zero as a stand-in for unknown — zero as the fact. The position has
    /// not moved since it was bought, because there is no newer price for it to
    /// have moved to. Before the window had an end this came out as
    /// 192,14 − 192,50 = −0,36 against a positive P/L, which is the shape the
    /// header was showing.
    @Test func aLotBoughtAfterTheReportedCloseHasNoDayChange() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: mondayAfternoon)
        seed(ctx, store, vm)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 2,
            unitPrice: Decimal(string: "192.50")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 10, 14), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        #expect(
            total.value == 0,
            "mediu uma compra de hoje contra o fecho de quinta: \(total.value)"
        )
    }

    /// And it must not flatten everything. Bought the week before, the same
    /// position really did live through Thursday → Friday and is owed all of it.
    @Test func aLotHeldBeforeThatSessionKeepsTheFullMove() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: mondayAfternoon)
        seed(ctx, store, vm)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 2,
            unitPrice: Decimal(string: "170.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 31), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        // 2 × (192,14 − 189,16)
        #expect(total.value == Decimal(string: "5.96"))
    }

    /// Bought inside the session being reported — Friday lunchtime — the lot is
    /// measured from its own price, which is the rule that already existed. The
    /// window's end must not reclassify it.
    @Test func aLotBoughtInsideTheReportedSessionIsStillASessionLot() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: mondayAfternoon)
        seed(ctx, store, vm)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "191.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 7, 12), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        // Bought at 191,00, above Thursday's 189,16, so measured from its own
        // price: 192,14 − 191,00.
        #expect(total.value == Decimal(string: "1.14"))
    }

    /// Three lots at once, which is the only way to see that the three
    /// classifications are separate and not one rule accidentally covering two.
    @Test func theThreeKindsOfLotAreAddedSeparately() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: mondayAfternoon)
        seed(ctx, store, vm)

        // Older: owed 192,14 − 189,16 = 2,98.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "170.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 31), note: "", asset: xetraNVD
        )
        // Inside Friday's session at 191,00: owed 1,14.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "191.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 7, 12), note: "", asset: xetraNVD
        )
        // After it, on Monday: owed nothing.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "192.50")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 10, 14), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        #expect(total.value == Decimal(string: "4.12"))
    }

    // MARK: - A live quote must be unaffected

    /// The window only closes for an end-of-day price. A REST quote is the
    /// session in progress, so nothing can be newer than it and every purchase
    /// today is a session lot — the behaviour the previous two fixes established,
    /// which this one must leave alone.
    @Test func aLiveQuoteLeavesTheWindowOpen() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: mondayAfternoon)

        store.register(listing, currency: "EUR")
        store.applyQuote(
            Quote(
                symbol: "NVD", price: Decimal(string: "192.14")!,
                previousClose: Decimal(string: "189.16")!,
                changeAbsolute: 0, changePercent: 0,
                currency: "EUR", timestamp: mondayAfternoon, source: .rest
            ),
            as: listing
        )

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "191.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 10, 14), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        // Measured from its own price, not from Friday's close.
        #expect(total.value == Decimal(string: "1.14"))
    }

    // MARK: - The window itself

    @Test func theWindowForAnEndOfDayQuoteIsThatSessionAndNotTodays() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        store.register(listing, currency: "EUR")
        store.applyQuote(
            endOfDayQuote(
                price: "192.14", previousClose: "189.16",
                fetchedAt: mondayAfternoon, closedOn: fridayClose
            ),
            as: listing
        )

        let window = store.sessionWindow(for: listing, at: mondayAfternoon)
        var berlin = calendar
        berlin.timeZone = MarketCalendar.Exchange.xetra.timeZone

        #expect(window.start == berlin.startOfDay(for: date(2026, 8, 7, 12)))
        #expect(window.end == berlin.date(
            from: DateComponents(year: 2026, month: 8, day: 7, hour: 17, minute: 30)
        ))
        #expect(window.isAfter(date(2026, 8, 10, 14)))
        #expect(window.contains(date(2026, 8, 7, 12)))
    }

    /// A close dated to a day the venue did not trade belongs to the session
    /// before it, not to a session of its own.
    @Test func aCloseDatedToAHolidayBelongsToThePrecedingSession() {
        // 1 January 2027 is a Friday and XETRA is shut. So is the 31st —
        // Silvester is a XETRA holiday, which is the part that makes this worth
        // testing rather than asserting: the walk back has to skip two days and
        // land on Wednesday the 30th.
        let window = MarketCalendar.sessionWindow(.xetra, endingOn: date(2027, 1, 1, 12))
        var berlin = calendar
        berlin.timeZone = MarketCalendar.Exchange.xetra.timeZone

        #expect(window.start == berlin.startOfDay(for: date(2026, 12, 30, 12)))
    }
}
