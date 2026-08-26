import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Budget

/// The 25-a-day pot shared between European quotes and Step 7's charts.
struct AlphaVantageBudgetTests {

    private func budget(
        dailyLimit: Int = 25,
        historyReserve: Int = 5,
        state: AlphaVantageBudgetState? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AlphaVantageBudget {
        let store = InMemoryBudgetStore(state ?? AlphaVantageBudgetState())
        return AlphaVantageBudget(
            dailyLimit: dailyLimit, historyReserve: historyReserve, store: store, now: now
        )
    }

    /// The core rationing rule: one call per symbol per day. A second ask on the
    /// same day is refused however it arrives — polling, pull-to-refresh, or a
    /// cold start.
    @Test func secondCallForSameSymbolSameDayIsRefused() async {
        let b = budget()
        #expect(await b.reserveQuote(symbol: "GALP.LS") == true)
        #expect(await b.reserveQuote(symbol: "GALP.LS") == false)
        #expect(await b.reserveQuote(symbol: "GALP.LS") == false)
        // Only the first one was ever charged.
        #expect(await b.remainingToday == 24)
    }

    /// Different symbols each get their own daily shot.
    @Test func differentSymbolsEachGetOneCall() async {
        let b = budget()
        #expect(await b.reserveQuote(symbol: "GALP.LS") == true)
        #expect(await b.reserveQuote(symbol: "IWDA.AS") == true)
        #expect(await b.remainingToday == 23)
    }

    /// A relaunch must not hand out a fresh 25. The counters are reloaded from
    /// the store, which is why they live in UserDefaults and not in memory.
    @Test func spentBudgetSurvivesRelaunch() async {
        let today = AlphaVantageBudget.dayKey(for: Date())
        let store = InMemoryBudgetStore(
            AlphaVantageBudgetState(day: today, used: 25, symbolDays: [:])
        )
        let b = AlphaVantageBudget(store: store)
        #expect(await b.remainingToday == 0)
        #expect(await b.reserveQuote(symbol: "GALP.LS") == false)
    }

    /// A symbol already fetched today stays refused across a relaunch too,
    /// otherwise killing the app would be a way to re-request it.
    @Test func perSymbolMarkSurvivesRelaunch() async {
        let today = AlphaVantageBudget.dayKey(for: Date())
        let store = InMemoryBudgetStore(
            AlphaVantageBudgetState(day: today, used: 1, symbolDays: ["GALP.LS": today])
        )
        let b = AlphaVantageBudget(store: store)
        #expect(await b.hasFetchedToday(symbol: "GALP.LS") == true)
        #expect(await b.reserveQuote(symbol: "GALP.LS") == false)
        #expect(await b.reserveQuote(symbol: "EDP.LS") == true)
    }

    /// A new day resets both the counter and the per-symbol marks.
    @Test func newDayResetsEverything() async {
        let yesterday = Date().addingTimeInterval(-86_400)
        let store = InMemoryBudgetStore(
            AlphaVantageBudgetState(
                day: AlphaVantageBudget.dayKey(for: yesterday),
                used: 25,
                symbolDays: ["GALP.LS": AlphaVantageBudget.dayKey(for: yesterday)]
            )
        )
        let b = AlphaVantageBudget(store: store)
        #expect(await b.remainingToday == 25)
        #expect(await b.reserveQuote(symbol: "GALP.LS") == true)
    }

    // MARK: - Priority: charts degrade before prices

    /// The explicit reserve: the last five requests of the day are quote-only.
    @Test func historyIsRefusedOnceOnlyTheReserveIsLeft() async {
        let today = AlphaVantageBudget.dayKey(for: Date())
        // 20 spent of 25 leaves exactly the 5-request reserve.
        let b = AlphaVantageBudget(
            store: InMemoryBudgetStore(
                AlphaVantageBudgetState(day: today, used: 20, symbolDays: [:])
            )
        )
        #expect(await b.remainingToday == 5)
        #expect(await b.reserveHistory() == false)
        // Prices keep going, all the way down.
        #expect(await b.reserveQuote(symbol: "GALP.LS") == true)
        #expect(await b.remainingToday == 4)
    }

    /// One below the boundary, history still goes — the reserve is five, not six.
    @Test func historyIsAllowedWhileAboveTheReserve() async {
        let today = AlphaVantageBudget.dayKey(for: Date())
        let b = AlphaVantageBudget(
            store: InMemoryBudgetStore(
                AlphaVantageBudgetState(day: today, used: 19, symbolDays: [:])
            )
        )
        #expect(await b.reserveHistory() == true)
        #expect(await b.remainingToday == 5)
        // And now it is done for the day.
        #expect(await b.reserveHistory() == false)
    }

    /// Quotes may spend the pot to zero; history may never touch the last five.
    @Test func quotesCanSpendTheReserveHistoryCannot() async {
        let b = budget()
        for i in 0..<25 {
            #expect(await b.reserveQuote(symbol: "SYM\(i).LS") == true)
        }
        #expect(await b.remainingToday == 0)
        #expect(await b.reserveQuote(symbol: "EXTRA.LS") == false)
    }

    /// A request that never reached them cost them nothing, so it must not cost
    /// the symbol its one shot for the day.
    @Test func releasingAfterAConnectivityFailureRestoresTheShot() async {
        let b = budget()
        #expect(await b.reserveQuote(symbol: "GALP.LS") == true)
        await b.releaseQuote(symbol: "GALP.LS")
        #expect(await b.remainingToday == 25)
        #expect(await b.reserveQuote(symbol: "GALP.LS") == true)
    }
}

// MARK: - Decoding

struct AlphaVantageDecodingTests {

    private let galpJSON = """
    {"Global Quote":{"01. symbol":"GALP.LS","02. open":"19.6900","03. high":"19.8100",
     "04. low":"19.6400","05. price":"19.7500","06. volume":"1234567",
     "07. latest trading day":"2026-08-06","08. previous close":"19.6900",
     "09. change":"0.0600","10. change percent":"0.3047%"}}
    """

    @Test func decodesGlobalQuote() throws {
        let q = try #require(AlphaVantageProvider.decodeQuote(Data(galpJSON.utf8), symbol: "GALP.LS"))
        #expect(q.symbol == "GALP.LS")
        #expect(q.price == Decimal(string: "19.7500"))
        #expect(q.previousClose == Decimal(string: "19.6900"))
    }

    /// The percent sign is part of the value Alpha Vantage sends.
    @Test func stripsPercentSignFromChange() throws {
        let q = try #require(AlphaVantageProvider.decodeQuote(Data(galpJSON.utf8), symbol: "GALP.LS"))
        #expect(q.changePercent == Decimal(string: "0.3047"))
    }

    /// GLOBAL_QUOTE reports no currency. Guessing one is how a EUR price gets a
    /// USD→EUR rate applied, so it comes from the venue instead.
    @Test func derivesCurrencyFromTheVenue() throws {
        let q = try #require(AlphaVantageProvider.decodeQuote(Data(galpJSON.utf8), symbol: "GALP.LS"))
        #expect(q.currency == "EUR")
    }

    /// The session the price closed on, which the position row has to show.
    @Test func carriesTheCloseDate() throws {
        let q = try #require(AlphaVantageProvider.decodeQuote(Data(galpJSON.utf8), symbol: "GALP.LS"))
        let closeDate = try #require(q.closeDate)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let comps = cal.dateComponents([.year, .month, .day], from: closeDate)
        #expect(comps.year == 2026)
        #expect(comps.month == 8)
        #expect(comps.day == 6)
    }

    /// End-of-day data can never be dressed up as live, however fresh the fetch.
    @Test func freshnessIsAlwaysDailyCloseNeverLive() throws {
        let q = try #require(AlphaVantageProvider.decodeQuote(Data(galpJSON.utf8), symbol: "GALP.LS"))
        #expect(q.source == .dailyClose)
        guard case .dailyClose = q.freshness else {
            Issue.record("Uma cotação de fecho apareceu como \(q.freshness)")
            return
        }
    }

    /// An unknown symbol comes back as an empty object with status 200 — not an
    /// error worth raising, just nothing.
    @Test func emptyQuoteObjectDecodesToNil() {
        let json = #"{"Global Quote":{}}"#
        #expect(AlphaVantageProvider.decodeQuote(Data(json.utf8), symbol: "XXXX.LS") == nil)
    }

    /// An exhausted key answers 200 with a note, not an HTTP error.
    @Test func rateLimitNoteDecodesToNil() {
        let json = #"{"Note":"Thank you for using Alpha Vantage! Our standard API rate limit is 25 requests per day."}"#
        #expect(AlphaVantageProvider.decodeQuote(Data(json.utf8), symbol: "GALP.LS") == nil)
    }

    /// A price of zero must never become a 0,00 € line in the totals.
    @Test func zeroPriceIsDropped() {
        let json = """
        {"Global Quote":{"01. symbol":"GALP.LS","05. price":"0.0000","08. previous close":"19.69"}}
        """
        #expect(AlphaVantageProvider.decodeQuote(Data(json.utf8), symbol: "GALP.LS") == nil)
    }
}

// MARK: - Routing

/// Whether the third fallback fires at all, and for which symbols.
struct AlphaVantageRoutingTests {

    @MainActor
    private func quote(_ symbol: String, price: Decimal, currency: String) -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: price,
            changeAbsolute: 0, changePercent: 0, currency: currency,
            timestamp: Date(), source: .rest
        )
    }

    @Test func europeanSuffixesAreRecognised() {
        #expect(MarketCalendar.isEuropean("GALP.LS"))
        #expect(MarketCalendar.isEuropean("IWDA.AS"))
        #expect(MarketCalendar.isEuropean("MC.PA"))
        #expect(MarketCalendar.isEuropean("SAP.DE"))
    }

    @Test func usSymbolsAreNotEuropean() {
        #expect(!MarketCalendar.isEuropean("NVDA"))
        #expect(!MarketCalendar.isEuropean("AAPL"))
        #expect(!MarketCalendar.isEuropean("VOO"))
    }

    /// The requirement stated plainly: the Alpha Vantage fallback must only ever
    /// see European symbols. Spending a 25-a-day budget on US tickers that two
    /// other providers already cover would starve the positions that need it.
    @MainActor
    @Test func fallbackOnlyReceivesEuropeanSymbols() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)

        var primary = MockMarketDataProvider()
        primary.answersOnlyKnownSymbols = true
        primary.mockQuotes = [:]   // covers nothing
        var fallback = MockMarketDataProvider()
        fallback.answersOnlyKnownSymbols = true
        fallback.mockQuotes = [:]

        let european = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: primary,
            fallbackProvider: fallback,
            europeanProvider: european,
            modelContext: container.mainContext
        )
        await store.refresh([ListingID(symbol: "NVDA"), ListingID(symbol: "GALP.LS"), ListingID(symbol: "AAPL"), ListingID(symbol: "IWDA.AS")])

        #expect(european.received == ["GALP.LS", "IWDA.AS"])
    }

    /// And it is skipped entirely when the other providers already answered.
    @MainActor
    @Test func fallbackIsNotCalledWhenPrimaryCoversTheSymbol() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)

        var primary = MockMarketDataProvider()
        primary.answersOnlyKnownSymbols = true
        primary.mockQuotes = ["GALP.LS": quote("GALP.LS", price: 19.75, currency: "EUR")]

        let european = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: primary,
            fallbackProvider: primary,
            europeanProvider: european,
            modelContext: container.mainContext
        )
        await store.refresh([ListingID(symbol: "GALP.LS")])

        #expect(european.received.isEmpty)
        #expect(store.quote(for: ListingID(symbol: "GALP.LS"))?.price == Decimal(string: "19.75"))
    }

    /// The provider refuses non-European symbols itself, not only by routing —
    /// so a future caller cannot quietly burn the budget on a US ticker.
    @Test func providerItselfIgnoresNonEuropeanSymbols() async throws {
        let budget = AlphaVantageBudget(store: InMemoryBudgetStore(AlphaVantageBudgetState()))
        let provider = AlphaVantageProvider(apiKey: "TEST", budget: budget)

        // No network call can happen: every symbol is filtered out first.
        let quotes = try await provider.quotes(for: ["NVDA", "AAPL"])
        #expect(quotes.isEmpty)
        #expect(await budget.remainingToday == 25)
    }

    // MARK: - Exhausted budget stays quiet

    /// The requirement: when the day is spent, the cached close keeps showing
    /// and nothing turns red. A budget that ran out is the expected steady
    /// state, not a failure.
    @MainActor
    @Test func exhaustedBudgetServesCacheWithoutNoisyError() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        // Yesterday's close, already in the cache.
        let cached = Quote(
            symbol: "GALP.LS", price: Decimal(string: "19.75")!,
            previousClose: Decimal(string: "19.69")!,
            changeAbsolute: Decimal(string: "0.06")!, changePercent: Decimal(string: "0.3")!,
            currency: "EUR", timestamp: Date().addingTimeInterval(-86_400),
            source: .dailyClose, closeDate: Date().addingTimeInterval(-86_400)
        )
        ctx.insert(PriceSnapshot(quote: cached, listing: ListingID(symbol: cached.symbol)))
        try ctx.save()

        var primary = MockMarketDataProvider()
        primary.answersOnlyKnownSymbols = true
        primary.mockQuotes = [:]

        // Budget spent: the provider returns nothing rather than throwing.
        let european = RecordingProvider(returns: [])

        let store = PriceStore()
        store.configure(
            provider: primary,
            fallbackProvider: primary,
            europeanProvider: european,
            modelContext: ctx
        )
        store.hydrateFromCache()
        await store.refresh([ListingID(symbol: "GALP.LS")])

        // The close is still on screen…
        let served = try #require(store.quote(for: ListingID(symbol: "GALP.LS")))
        #expect(served.price == Decimal(string: "19.75"))
        // …still marked as a close, not as merely stale…
        guard case .dailyClose = served.freshness else {
            Issue.record("O fecho em cache perdeu a marcação: \(served.freshness)")
            return
        }
        // …and nothing was raised.
        #expect(store.lastError == nil)
    }

    /// A symbol with no cached price and no provider that can serve it is still
    /// a real error — the quiet path must not swallow everything.
    @MainActor
    @Test func symbolWithNoPriceAtAllStillReportsAnError() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)

        var primary = MockMarketDataProvider()
        primary.answersOnlyKnownSymbols = true
        primary.mockQuotes = [:]

        let store = PriceStore()
        store.configure(
            provider: primary,
            fallbackProvider: primary,
            europeanProvider: RecordingProvider(returns: []),
            modelContext: container.mainContext
        )
        await store.refresh([ListingID(symbol: "GALP.LS")])

        #expect(store.quote(for: ListingID(symbol: "GALP.LS")) == nil)
        #expect(store.lastError != nil)
    }

    /// A daily close must come back from a relaunch still labelled as a close,
    /// with its session date, or the position row has nothing to show.
    @MainActor
    @Test func closeSurvivesHydrationWithItsDate() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let closeDate = try #require(
            AlphaVantageGlobalQuote.parseTradingDay("2026-08-06")
        )
        let original = Quote(
            symbol: "GALP.LS", price: Decimal(string: "19.75")!,
            previousClose: Decimal(string: "19.69")!,
            changeAbsolute: 0, changePercent: 0, currency: "EUR",
            timestamp: Date(), source: .dailyClose, closeDate: closeDate
        )
        ctx.insert(PriceSnapshot(quote: original, listing: ListingID(symbol: original.symbol)))
        try ctx.save()

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        store.hydrateFromCache()

        let hydrated = try #require(store.quote(for: ListingID(symbol: "GALP.LS")))
        #expect(hydrated.source == .dailyClose)
        guard case .dailyClose(let date) = hydrated.freshness else {
            Issue.record("Perdeu a marcação de fecho ao hidratar: \(hydrated.freshness)")
            return
        }
        #expect(date == closeDate)
    }
}

// MARK: - Test doubles

/// Records which symbols the third fallback was actually asked for.
/// A class, not a struct, because the assertion is about the call itself.
final class RecordingProvider: MarketDataProvider, @unchecked Sendable {
    let supportsStreaming = false

    private let lock = NSLock()
    private var _received: [String] = []
    private let stubbed: [Quote]

    init(returns: [Quote] = []) {
        self.stubbed = returns
    }

    var received: [String] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    func quote(for symbol: String) async throws -> Quote {
        let quotes = try await quotes(for: [symbol])
        guard let first = quotes.first else { throw MarketDataError.noData }
        return first
    }

    func quotes(for symbols: [String]) async throws -> [Quote] {
        lock.lock()
        _received.append(contentsOf: symbols)
        lock.unlock()
        return stubbed.filter { symbols.contains($0.symbol) }
    }

    func search(_ query: String) async throws -> [AssetSearchResult] { [] }
    func candles(symbol: String, range: ChartRange) async throws -> [Candle] { [] }
}

final class InMemoryBudgetStore: AlphaVantageBudgetStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: AlphaVantageBudgetState

    init(_ state: AlphaVantageBudgetState = AlphaVantageBudgetState()) {
        self.state = state
    }

    func load() -> AlphaVantageBudgetState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func save(_ state: AlphaVantageBudgetState) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}
