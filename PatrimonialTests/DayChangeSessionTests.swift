import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - The session a price belongs to is not the calendar day

/// The per-lot rule landed and the header still read "Hoje +5,46 €".
///
/// The rule was right and the boundary it measured from was wrong: `sessionLots`
/// were the purchases made since `startOfDay(now)`. Read on Saturday, the latest
/// quote is Friday's close and the previous close is Thursday's, so a position
/// opened on Friday at the closing price fell *outside* the session by the
/// calendar-day test, counted as an older holding, and was credited with the
/// Thursday → Friday move it had not been alive for.
struct SessionBoundaryTests {

    /// Lisbon time throughout, which is what the device is on.
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

    /// 2026-08-07 is a Friday, 2026-08-08 a Saturday, 2026-08-09 a Sunday.
    /// Everything below is anchored on those three real days.

    @Test func aWeekendBelongsToFridaysSession() {
        let saturday = date(2026, 8, 8, 11)
        let start = MarketCalendar.currentSessionStart(.xetra, at: saturday)

        var cal = calendar
        cal.timeZone = MarketCalendar.Exchange.xetra.timeZone
        #expect(cal.startOfDay(for: date(2026, 8, 7, 12)) == start)
    }

    @Test func sundayBelongsToFridaysSessionToo() {
        let sunday = date(2026, 8, 9, 11)
        let start = MarketCalendar.currentSessionStart(.nyse, at: sunday)

        var cal = calendar
        cal.timeZone = MarketCalendar.Exchange.nyse.timeZone
        #expect(cal.startOfDay(for: date(2026, 8, 7, 20)) == start)
    }

    /// After the close the session is still today's: today's close is what the
    /// quote now reports, and the previous close is yesterday's.
    @Test func afterTheCloseTheSessionIsStillTodays() {
        let fridayEvening = date(2026, 8, 7, 20)
        let start = MarketCalendar.currentSessionStart(.euronextLisbon, at: fridayEvening)

        #expect(calendar.startOfDay(for: fridayEvening) == start)
    }

    /// Before the opening bell the current price is still the previous
    /// session's, so the boundary must not have moved yet.
    @Test func beforeTheOpenTheSessionIsStillThePreviousOne() {
        // 07:00 in Lisbon, an hour before Euronext Lisbon opens at 08:00.
        let mondayDawn = date(2026, 8, 10, 7)
        let start = MarketCalendar.currentSessionStart(.euronextLisbon, at: mondayDawn)

        #expect(calendar.startOfDay(for: date(2026, 8, 7, 12)) == start)
    }

    /// Once it has opened, the boundary moves to today.
    @Test func afterTheOpenTheSessionIsTodays() {
        let mondayMorning = date(2026, 8, 10, 9)
        let start = MarketCalendar.currentSessionStart(.euronextLisbon, at: mondayMorning)

        #expect(calendar.startOfDay(for: mondayMorning) == start)
    }

    /// A holiday is not a session. 25 December 2026 is a Friday and XETRA is
    /// shut, so the session in force is Thursday the 24th's.
    @Test func aHolidayIsNotASession() {
        let christmas = date(2026, 12, 25, 15)
        let start = MarketCalendar.currentSessionStart(.xetra, at: christmas)

        var cal = calendar
        cal.timeZone = MarketCalendar.Exchange.xetra.timeZone
        #expect(cal.startOfDay(for: date(2026, 12, 24, 12)) == start)
    }

    /// Crypto never closes, so its session is simply the day.
    @Test func cryptoSessionIsTheDay() {
        let saturday = date(2026, 8, 8, 11)
        var cal = calendar
        cal.timeZone = MarketCalendar.Exchange.crypto.timeZone

        #expect(MarketCalendar.currentSessionStart(.crypto, at: saturday)
                == cal.startOfDay(for: saturday))
    }

    /// The unknown-venue boundary errs early, never late. Late is the direction
    /// that credits a position with a move that predates it.
    @Test func theWidestBoundaryIsNoLaterThanAnyVenues() {
        let sunday = date(2026, 8, 9, 11)
        let widest = MarketCalendar.widestSessionStart(at: sunday)

        for exchange in MarketCalendar.Exchange.allCases where exchange != .crypto {
            #expect(widest <= MarketCalendar.currentSessionStart(exchange, at: sunday))
        }
    }
}

// MARK: - The same thing, through the ViewModel the screen actually reads

/// Point L, and the third time in this project that the arithmetic was right
/// while the screen showed the old number.
///
/// `DayChangeTests` exercises `PortfolioCalculator` directly and passed while
/// the phone showed +5,46 €, because the calculator was never what was broken —
/// what was broken was the date the ViewModel handed it. So these go through
/// `PortfolioViewModel.dayChangeTotal`, which is the exact property
/// `PortfolioScreen.dayChangeChip` renders: transactions in SwiftData, a quote
/// in the `PriceStore`, and the total read off the ViewModel.
@MainActor
struct PortfolioViewModelDayChangeTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The Saturday the header was read on, and the Friday session it reports.
    private var saturday: Date { date(2026, 8, 8, 11) }
    private var fridayAfternoon: Date { date(2026, 8, 7, 15) }

    private func makeAccount(in ctx: ModelContext) -> Account {
        let acc = Account(name: "IBKR", type: .brokerage)
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

    /// The listing these tests are about, recorded exactly as a real purchase
    /// records it — the venue is what makes the session boundary Frankfurt's
    /// rather than the widest one.
    private var xetraNVD: AssetSearchResult {
        AssetSearchResult(
            symbol: "NVD", name: "NVIDIA Corporation", exchange: "XETR",
            assetClass: .stock, currency: "EUR", mic: "XETR"
        )
    }

    private func quote(
        _ symbol: String, price: String, previousClose: String, at instant: Date
    ) -> Quote {
        Quote(
            symbol: symbol,
            price: Decimal(string: price)!,
            previousClose: Decimal(string: previousClose)!,
            changeAbsolute: 0, changePercent: 0,
            currency: "EUR", timestamp: instant, source: .rest
        )
    }

    /// The reported bug, end to end. NVIDIA on XETRA, 1 share bought on Friday
    /// at 194,22 — Friday's close — and the header read on Saturday, when the
    /// quote is still 194,22 against a previous close of 189,16.
    ///
    /// P/L is exactly zero. The day change has to be zero too: the position did
    /// not live through the 189,16 → 194,22 move.
    @Test func aPositionOpenedInTheReportedSessionShowsNoDayChange() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: saturday)

        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")
        store.applyQuote(quote("NVD", price: "194.22", previousClose: "189.16", at: saturday), as: ListingID(symbol: "NVD", mic: "XETR"))

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: fridayAfternoon, note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        #expect(vm.totalUnrealizedPL == 0)
        #expect(total.value == 0, "creditou a sessão de sexta a uma posição aberta nessa sessão")
        #expect(total.excludedCount == 0)
    }

    /// The other half: the fix must not flatten every day change to zero. The
    /// same instrument bought the week before really did gain 5,06 on Friday,
    /// and the header must still say so on Saturday.
    @Test func aPositionHeldBeforeThatSessionKeepsItsFullDayChange() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: saturday)

        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")
        store.applyQuote(quote("NVD", price: "194.22", previousClose: "189.16", at: saturday), as: ListingID(symbol: "NVD", mic: "XETR"))

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "170.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 31), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        #expect(total.value == Decimal(string: "5.06"))
    }

    /// Read during the session it was bought in, not after it: same answer, and
    /// the one the calculator-level tests were already covering.
    @Test func aPositionOpenedDuringAnOpenSessionShowsNoDayChange() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        // Friday 16:00, XETRA still open (closes 17:30 Berlin = 16:30 Lisbon…
        // read at 15:30 Lisbon to stay inside it either way).
        let duringSession = date(2026, 8, 7, 15)
        let (vm, store) = makeVM(ctx: ctx, at: duringSession)

        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")
        store.applyQuote(
            quote("NVD", price: "194.22", previousClose: "189.16", at: duringSession)
        , as: ListingID(symbol: "NVD", mic: "XETR"))

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 8, 7, 14), note: "", asset: xetraNVD
        )

        let total = try #require(vm.dayChangeTotal)
        #expect(total.value == 0)
    }

    /// Both lots, through the ViewModel: one from last week carrying the full
    /// 5,06, one opened in the reported session carrying nothing. A blended
    /// average purchase price would give 2 × (194,22 − 182,11) = 24,22.
    @Test func todaysLotDoesNotContaminateTheOlderOneThroughTheViewModel() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: saturday)

        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")
        store.applyQuote(quote("NVD", price: "194.22", previousClose: "189.16", at: saturday), as: ListingID(symbol: "NVD", mic: "XETR"))

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "170.00")!, fxRate: 1, commission: 0,
            account: acc, date: date(2026, 7, 31), note: "", asset: xetraNVD
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: fridayAfternoon, note: "", asset: xetraNVD
        )

        #expect(vm.openHoldings.count == 1)
        #expect(vm.openHoldings[0].quantity == 2)
        let total = try #require(vm.dayChangeTotal)
        #expect(total.value == Decimal(string: "5.06"))
    }

    /// The whole reported header, as the phone had it: 1 NVD and 0,5 AAPL, both
    /// opened in the session being reported, both at that session's close. It
    /// showed +5,46 €.
    @Test func theReportedHeaderReadsZeroThroughTheViewModel() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = makeAccount(in: ctx)
        let (vm, store) = makeVM(ctx: ctx, at: saturday)

        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")
        store.register(ListingID(symbol: "AAPL", mic: "XNAS"), currency: "USD")
        store.applyQuote(quote("NVD", price: "194.22", previousClose: "189.16", at: saturday), as: ListingID(symbol: "NVD", mic: "XETR"))
        store.applyQuote(Quote(
            symbol: "AAPL", price: Decimal(string: "313.33")!,
            previousClose: Decimal(string: "312.41")!,
            changeAbsolute: 0, changePercent: 0,
            currency: "USD", timestamp: saturday, source: .rest
        ), as: ListingID(symbol: "AAPL", mic: "XNAS"))
        vm.setCurrentFXRateForTesting(
            FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.86693")!)!
        )

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: fridayAfternoon, note: "", asset: xetraNVD
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: Decimal(string: "0.5")!,
            unitPrice: Decimal(string: "313.33")!, fxRate: Decimal(string: "0.86693")!,
            commission: 0, account: acc, date: fridayAfternoon, note: "",
            asset: AssetSearchResult(
                symbol: "AAPL", name: "Apple Inc", exchange: "XNAS",
                assetClass: .stock, currency: "USD", mic: "XNAS"
            )
        )

        let total = try #require(vm.dayChangeTotal)
        #expect(total.includedCount == 2)
        #expect(total.excludedCount == 0)
        #expect(total.value == 0)
    }
}
