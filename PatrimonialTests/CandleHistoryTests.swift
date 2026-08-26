import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Decoding, against payloads captured live

/// Fixtures are real responses, captured this session:
/// - `twelvedata_timeseries_aapl` — `/time_series?symbol=AAPL&interval=1day`
/// - `alphavantage_timeseries_qdve` — `TIME_SERIES_DAILY&symbol=QDVE.DE&outputsize=compact`
/// - `coingecko_market_chart_btc` — `/coins/bitcoin/market_chart?vs_currency=eur&days=30`
struct CandleDecodingTests {

    @Test func twelveDataDailySeriesDecodes() throws {
        let candles = try TwelveDataProvider.decodeCandles(try fixture("twelvedata_timeseries_aapl"))

        #expect(candles.count == 30)
        // Twelve Data answers newest-first; the store needs oldest-first.
        #expect(candles.first!.date < candles.last!.date)

        let last = try #require(candles.last)
        #expect(last.close == Decimal(string: "313.32999")!)
        #expect(last.open == Decimal(string: "311.45001")!)
        #expect(last.high == Decimal(string: "314.81000")!)
        #expect(last.low == Decimal(string: "310.73999")!)
        #expect(last.volume == 34_407_100)
    }

    /// Alpha Vantage caps `compact` at 100 sessions. That limit is the whole
    /// reason the cache may never delete: a chart longer than this exists only
    /// by accumulating across days.
    @Test func alphaVantageDailySeriesDecodesAndIsCappedAt100() throws {
        let candles = AlphaVantageProvider.decodeCandles(try fixture("alphavantage_timeseries_qdve"), symbol: "QDVE.DE")

        #expect(candles.count == 100)
        #expect(candles.first!.date < candles.last!.date)

        let last = try #require(candles.last)
        #expect(last.close == Decimal(string: "44.7950")!)
        #expect(last.open == Decimal(string: "44.5750")!)
        #expect(last.volume == 223_942)
    }

    /// CoinGecko's free tier gives closing prices, not OHLC. Open, high and low
    /// are set to the close rather than invented — a candlestick drawn from a
    /// fabricated range would be a picture of data that does not exist.
    @Test func coinGeckoMarketChartDecodesAsCloseOnlyPoints() throws {
        let candles = CoinGeckoProvider.decodeCandles(try fixture("coingecko_market_chart_btc"))

        #expect(candles.count == 30)
        let first = try #require(candles.first)
        #expect(first.open == first.close)
        #expect(first.high == first.close)
        #expect(first.low == first.close)
        #expect(first.volume == 0)
        // Milliseconds, not seconds: read as seconds this lands in 2026 + 54000
        // years and every chart would be empty.
        #expect(first.date.timeIntervalSince1970 == 1_783_641_600)
    }

    /// Every provider answers 200 for its refusals. None of them may throw on a
    /// chart path — an exhausted key is "nothing to add", not an error.
    @Test func refusalsDecodeToNothingRatherThanThrowing() throws {
        let exhausted = Data("""
        {"Information":"Thank you for using Alpha Vantage! ... 25 requests per day"}
        """.utf8)
        #expect(AlphaVantageProvider.decodeCandles(exhausted, symbol: "QDVE.DE").isEmpty)

        let notOnPlan = Data("""
        {"code":403,"message":"symbol QDVE is not available with your plan","status":"error"}
        """.utf8)
        #expect(try TwelveDataProvider.decodeCandles(notOnPlan).isEmpty)

        #expect(CoinGeckoProvider.decodeCandles(Data("{}".utf8)).isEmpty)
        #expect(AlphaVantageProvider.decodeCandles(Data("not json".utf8), symbol: "QDVE.DE").isEmpty)
        #expect(CoinGeckoProvider.decodeCandles(Data("not json".utf8)).isEmpty)
    }

    /// A zero close is not a price here either — the same rule the quote path
    /// enforces, applied to history so a chart cannot dive to the floor.
    @Test func zeroClosesAreDropped() throws {
        let json = Data("""
        {"values":[{"datetime":"2026-08-07","open":"0","high":"0","low":"0","close":"0","volume":"0"},
                   {"datetime":"2026-08-06","open":"10","high":"11","low":"9","close":"10.5","volume":"5"}]}
        """.utf8)
        let candles = try TwelveDataProvider.decodeCandles(json)
        #expect(candles.count == 1)
        #expect(candles.first?.close == Decimal(string: "10.5")!)
    }

    // MARK: - Sub-unit currencies in history

    /// The rule, stated before the cases: **a candle is in the same unit as a
    /// quote for the same listing.** Everything below is that one sentence
    /// checked per provider.
    ///
    /// It is not a cosmetic rule. `PriceStore.isPlausible` compares the
    /// published price against the last cached close and refuses anything more
    /// than 10× apart. A London series left in pence sits exactly 100× above a
    /// correctly normalized quote, so the *correct* price is the one thrown
    /// out and the position shows a dash — with the chart and the quote each
    /// looking individually reasonable.

    /// Twelve Data reports the unit: `meta.currency` is `GBp` on a London
    /// series. Verified live — the real `/time_series` response carries meta
    /// with currency and mic_code.
    @Test func twelveDataPenceSeriesIsNormalizedToPounds() throws {
        let json = Data("""
        {"meta":{"symbol":"VOD","interval":"1day","currency":"GBp","exchange":"LSE","mic_code":"XLON"},
         "values":[{"datetime":"2026-08-13","open":"118.80","high":"119.90","low":"118.00","close":"120.15","volume":"43498216"}]}
        """.utf8)
        let candle = try #require(try TwelveDataProvider.decodeCandles(json).first)
        #expect(candle.close == Decimal(string: "1.2015")!)
        #expect(candle.open == Decimal(string: "1.1880")!)
        #expect(candle.high == Decimal(string: "1.1990")!)
        #expect(candle.low == Decimal(string: "1.18")!)
        // Volume is a count of shares, not a price. Dividing it would be a
        // second bug wearing the first one's clothes.
        #expect(candle.volume == 43_498_216)
    }

    /// A USD series is untouched: the divisor is 1, not "some number".
    @Test func twelveDataMajorUnitSeriesIsUnchanged() throws {
        let json = Data("""
        {"meta":{"symbol":"AAPL","currency":"USD","mic_code":"XNGS"},
         "values":[{"datetime":"2026-08-13","open":"304.25","high":"306","low":"302.04","close":"305.26","volume":"38492546"}]}
        """.utf8)
        let candle = try #require(try TwelveDataProvider.decodeCandles(json).first)
        #expect(candle.close == Decimal(string: "305.26")!)
    }

    /// Alpha Vantage reports **no** unit — verified live: `TIME_SERIES_DAILY`'s
    /// "Meta Data" is information, symbol, last refreshed, output size and time
    /// zone, and `GLOBAL_QUOTE` has no currency field at all.
    ///
    /// This test used to assert that the `.LON` suffix meant pence, on the
    /// strength of `VOD.LON` answering 120,15 for a share trading at 1,20 £.
    /// The premise is false, and two live calls on 2026-08-14 settle it:
    /// `VOD.LON` → 120,15 (pence) and `3GOL.LON` → 155,48 (**dollars** — the
    /// same instrument reads 158,47 USD on Yahoo the next morning, and its
    /// pence line on the LSE is a different ticker, `3LGO`, near 10 950 GBp).
    /// One suffix, two units, no way to tell from the string.
    ///
    /// So the provider refuses: no reading of the unit, no series and no quote.
    /// A dash heals when a route is added; a series scaled by a guess gets the
    /// *correct* price refused by the plausibility guard and looks like a data
    /// problem somewhere else entirely.
    @Test func alphaVantageRefusesLondonBecauseTheSuffixDoesNotGiveTheUnit() throws {
        let series = Data("""
        {"Meta Data":{"1. Information":"Daily Prices","2. Symbol":"VOD.LON","3. Last Refreshed":"2026-08-13","4. Output Size":"Compact","5. Time Zone":"US/Eastern"},
         "Time Series (Daily)":{"2026-08-13":{"1. open":"118.8000","2. high":"119.9000","3. low":"118.0000","4. close":"120.1500","5. volume":"43498216"}}}
        """.utf8)
        #expect(AlphaVantageProvider.decodeCandles(series, symbol: "VOD.LON").isEmpty)

        let quote = Data("""
        {"Global Quote":{"01. symbol":"3GOL.LON","05. price":"155.4800","08. previous close":"162.3350"}}
        """.utf8)
        #expect(AlphaVantageProvider.decodeQuote(quote, symbol: "3GOL.LON") == nil)

        // Point G, the same refusal from the other end: a bare ticker used to
        // fall back to `.nyse` and come out labelled USD.
        #expect(AlphaVantageProvider.normalization(forSymbol: "VOD") == nil)
        #expect(AlphaVantageProvider.normalization(forSymbol: "VOD.LON") == nil)
        // The venues it does serve are unchanged.
        #expect(AlphaVantageProvider.normalization(forSymbol: "QDVE.DE")?.code == "EUR")
    }

    /// The property both providers have to satisfy, over the product of
    /// (provider) × (venue): quote and candle land on the same scale, so the
    /// plausibility ratio never fires on a correctly-fetched pair.
    ///
    /// Pinning one example per provider would not catch the failure — the bug
    /// is precisely that two functions disagreed while each looked right.
    @MainActor
    @Test func quoteAndCandleAgreeOnScaleForEveryVenue() throws {
        // symbol, currency as each provider reports it, raw wire price.
        // Only the venues Alpha Vantage is actually asked about, which is the
        // set whose unit its suffix table can read. London left this list when
        // the suffix turned out not to give the unit (see the test above);
        // Twelve Data still handles pence there, because it reports `GBp` on
        // the wire and needs no table.
        let cases: [(symbol: String, twelveDataCurrency: String, raw: String)] = [
            ("QDVE.DE", "EUR", "44.79"),    // major unit
            ("GALP.LS", "EUR", "17.42"),    // major unit
            ("IWDA.AS", "EUR", "108.63"),   // major unit
        ]

        for c in cases {
            let series = Data("""
            {"meta":{"symbol":"\(c.symbol)","currency":"\(c.twelveDataCurrency)"},
             "values":[{"datetime":"2026-08-13","open":"\(c.raw)","high":"\(c.raw)","low":"\(c.raw)","close":"\(c.raw)","volume":"1"}]}
            """.utf8)
            let twelveDataClose = try #require(try TwelveDataProvider.decodeCandles(series).first).close

            let avSeries = Data("""
            {"Meta Data":{"2. Symbol":"\(c.symbol)"},
             "Time Series (Daily)":{"2026-08-13":{"1. open":"\(c.raw)","2. high":"\(c.raw)","3. low":"\(c.raw)","4. close":"\(c.raw)","5. volume":"1"}}}
            """.utf8)
            let avClose = try #require(
                AlphaVantageProvider.decodeCandles(avSeries, symbol: c.symbol).first
            ).close

            let avQuote = try #require(AlphaVantageProvider.decodeQuote(Data("""
            {"Global Quote":{"01. symbol":"\(c.symbol)","05. price":"\(c.raw)","08. previous close":"\(c.raw)"}}
            """.utf8), symbol: c.symbol))

            #expect(twelveDataClose == avClose,
                    "\(c.symbol): the two history providers disagree on scale")
            #expect(avQuote.price == avClose,
                    "\(c.symbol): quote and candle disagree on scale")

            // And the consequence, stated as the check that would have caught
            // it: the ratio the plausibility guard uses stays at 1.
            let ratio = avQuote.price / twelveDataClose
            #expect(ratio < PriceStore.implausibleRatio,
                    "\(c.symbol): a \(ratio)× gap would get the good price refused")
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CandleBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            struct FixtureNotFound: Error { let name: String }
            throw FixtureNotFound(name: name)
        }
        return try Data(contentsOf: url)
    }
}

private class CandleBundleToken {}

// MARK: - Cache behaviour

/// Counts calls and answers from a fixed series, so "did we ask?" is provable.
final class RecordingCandleProvider: MarketDataProvider, @unchecked Sendable {
    let supportsStreaming = false
    var candlesToReturn: [Candle] = []
    private(set) var callCount = 0
    private(set) var requestedRanges: [ChartRange] = []
    var shouldFail = false

    init(candlesToReturn: [Candle] = []) {
        self.candlesToReturn = candlesToReturn
    }

    func quote(for symbol: String) async throws -> Quote { throw MarketDataError.noData }
    func quotes(for symbols: [String]) async throws -> [Quote] { [] }
    func search(_ query: String) async throws -> [AssetSearchResult] { [] }

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        callCount += 1
        requestedRanges.append(range)
        if shouldFail { throw MarketDataError.rateLimited }
        return candlesToReturn
    }
}

@MainActor
struct CandleStoreTests {

    /// A fixed "today" so the cache-currency logic is deterministic.
    private let today = Date(timeIntervalSince1970: 1_786_060_800)  // 2026-08-08 00:00 UTC

    private func day(_ offset: Int) -> Date {
        CandleStore.sessionDate(today.addingTimeInterval(TimeInterval(offset) * 86_400))
    }

    private func candle(_ offset: Int, close: Decimal) -> Candle {
        Candle(date: day(offset), open: close, high: close, low: close, close: close, volume: 1)
    }

    private func makeStore(
        _ ctx: ModelContext, provider: RecordingCandleProvider
    ) -> CandleStore {
        let store = CandleStore(
            usProvider: provider,
            europeanProvider: provider,
            cryptoProvider: provider,
            now: { [today] in today }
        )
        store.bind(modelContext: ctx)
        return store
    }

    /// The point of the cache: a closed session is fetched once. With today's
    /// candle already held, a refresh costs nothing at all.
    @Test func aCurrentCacheCostsNoRequest() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        let store = makeStore(container.mainContext, provider: provider)

        store.merge([candle(-1, close: 100), candle(0, close: 101)],
                    listing: ListingID(symbol: "AAPL"), source: "test")

        await store.refresh(listing: ListingID(symbol: "AAPL"), route: .unitedStates(symbol: "AAPL"))

        #expect(provider.callCount == 0)
        #expect(store.series(for: ListingID(symbol: "AAPL")).count == 2)
    }

    /// And when it is behind, only the gap is asked for — not the whole range.
    @Test func onlyTheMissingDaysAreRequested() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        let store = makeStore(container.mainContext, provider: provider)

        store.merge([candle(-30, close: 90), candle(-3, close: 99)],
                    listing: ListingID(symbol: "AAPL"), source: "test")

        let missing = try #require(store.earliestMissingDate(for: ListingID(symbol: "AAPL"), range: .max))
        // The day after the last one held, so nothing already cached is re-read.
        #expect(missing == day(-3).addingTimeInterval(86_400))

        await store.refresh(listing: ListingID(symbol: "AAPL"), route: .unitedStates(symbol: "AAPL"))
        #expect(provider.callCount == 1)
        // Three days missing asks for a week, not for max.
        #expect(provider.requestedRanges == [.oneWeek])
    }

    /// An empty cache asks for the whole range.
    @Test func anEmptyCacheAsksForEverything() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider(candlesToReturn: [
            candle(-2, close: 10), candle(-1, close: 11), candle(0, close: 12),
        ])
        let store = makeStore(container.mainContext, provider: provider)

        await store.refresh(listing: ListingID(symbol: "BTC"), route: .crypto(coinID: "bitcoin"), range: .max)

        #expect(provider.callCount == 1)
        #expect(store.series(for: ListingID(symbol: "BTC")).count == 3)
    }

    /// The rule that makes long history possible: merging adds, and never
    /// removes or rewrites. A provider returning a shorter window — or a
    /// revised close — cannot shorten what the user has accumulated.
    @Test func refreshingNeverDropsOrRewritesOlderCandles() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        let store = makeStore(container.mainContext, provider: provider)

        // A year of history already accumulated.
        store.merge((0..<200).map { candle(-$0 - 1, close: Decimal(100 + $0)) },
                    listing: ListingID(symbol: "QDVE"), source: "alphavantage")
        #expect(store.series(for: ListingID(symbol: "QDVE")).count == 200)

        // A later refresh returns only the last 100 sessions, one of them with a
        // different close for a day already held.
        provider.candlesToReturn = (0..<100).map { candle(-$0, close: Decimal(999)) }
        await store.refresh(listing: ListingID(symbol: "QDVE"), route: .european(symbol: "QDVE.DE"))

        let series = store.series(for: ListingID(symbol: "QDVE"))
        // 200 held + only the one genuinely new day (offset 0).
        #expect(series.count == 201)
        // And the previously cached close is untouched by the revision.
        let cached = try #require(series.first { $0.date == day(-1) })
        #expect(cached.close == 100)
    }

    /// An exhausted budget throws inside the provider, and the store serves the
    /// cache without publishing an error.
    @Test func anExhaustedBudgetServesCacheSilently() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        provider.shouldFail = true
        let store = makeStore(container.mainContext, provider: provider)

        store.merge([candle(-5, close: 44), candle(-4, close: 45)],
                    listing: ListingID(symbol: "QDVE"), source: "alphavantage")

        await store.refresh(listing: ListingID(symbol: "QDVE"), route: .european(symbol: "QDVE.DE"))

        #expect(provider.callCount == 1)
        // Still there, still drawable.
        #expect(store.series(for: ListingID(symbol: "QDVE")).count == 2)
        #expect(!store.isLoading)
    }

    /// An asset nobody has history for does not crash and does not cache junk.
    @Test func anAssetWithNoHistoryIsEmptyNotBroken() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider(candlesToReturn: [])
        let store = makeStore(container.mainContext, provider: provider)

        await store.refresh(listing: ListingID(symbol: "NOPE"), route: .unitedStates(symbol: "NOPE"))

        #expect(store.series(for: ListingID(symbol: "NOPE")).isEmpty)
        #expect(store.series(for: ListingID(symbol: "NOPE"), range: .oneYear).isEmpty)
        #expect(store.series(for: ListingID(symbol: "NOPE"), range: .oneYear).valueBounds == nil)
    }

    /// Two providers describing the same session must not cache it twice:
    /// Twelve Data sends a date string, CoinGecko milliseconds mid-afternoon.
    @Test func thesameSessionFromDifferentProvidersIsStoredOnce() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = makeStore(container.mainContext, provider: RecordingCandleProvider())

        let midnight = day(-1)
        let midAfternoon = midnight.addingTimeInterval(15 * 3600)

        store.merge([Candle(date: midnight, open: 1, high: 1, low: 1, close: 1, volume: 0)],
                    listing: ListingID(symbol: "BTC"), source: "twelvedata")
        store.merge([Candle(date: midAfternoon, open: 2, high: 2, low: 2, close: 2, volume: 0)],
                    listing: ListingID(symbol: "BTC"), source: "coingecko")

        #expect(store.series(for: ListingID(symbol: "BTC")).count == 1)
    }

    /// All four ranges come off one daily series — they are filters, not
    /// fetches.
    @Test func everyRangeIsDerivedFromTheSameSeries() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        let store = makeStore(container.mainContext, provider: provider)

        store.merge((0..<400).map { candle(-$0, close: Decimal(100 + $0)) },
                    listing: ListingID(symbol: "AAPL"), source: "test")

        #expect(store.series(for: ListingID(symbol: "AAPL"), range: .oneWeek).candles.count <= 8)
        #expect(store.series(for: ListingID(symbol: "AAPL"), range: .oneMonth).candles.count <= 32)
        #expect(store.series(for: ListingID(symbol: "AAPL"), range: .oneYear).candles.count <= 367)
        #expect(store.series(for: ListingID(symbol: "AAPL"), range: .max).candles.count == 400)

        // Reading never fetches.
        #expect(provider.callCount == 0)
    }

    /// 1D is not offered: every range comes from daily candles, and one day of
    /// those is a single point.
    @Test func theChartOffersNoOneDayRange() {
        #expect(!ChartRange.chartSelectable.contains(.oneDay))
        #expect(ChartRange.chartSelectable == [.oneWeek, .oneMonth, .oneYear, .max])
    }
}

// MARK: - Short series

@MainActor
struct ChartSeriesTests {

    private let today = Date(timeIntervalSince1970: 1_786_060_800)

    private func candle(_ offset: Int, close: Decimal) -> Candle {
        let date = CandleStore.sessionDate(today.addingTimeInterval(TimeInterval(offset) * 86_400))
        return Candle(date: date, open: close, high: close, low: close, close: close, volume: 1)
    }

    private func store(_ ctx: ModelContext) -> CandleStore {
        let s = CandleStore(
            usProvider: RecordingCandleProvider(),
            europeanProvider: RecordingCandleProvider(),
            cryptoProvider: RecordingCandleProvider(),
            now: { [today] in today }
        )
        s.bind(modelContext: ctx)
        return s
    }

    /// A position added last week, asked for a year: show the ten days that
    /// exist and say since when. The window is never padded — drawing the
    /// missing eleven months as zero would be a crash that never happened.
    @Test func aSeriesShorterThanTheRangeShowsWhatExistsAndSaysSoo() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)
        s.merge((0..<10).map { candle(-$0, close: Decimal(40 + $0)) },
                listing: ListingID(symbol: "QDVE"), source: "test")

        let series = s.series(for: ListingID(symbol: "QDVE"), range: .oneYear)

        #expect(series.candles.count == 10)
        #expect(!series.coversFullRange)
        #expect(series.firstDate != nil)
        // No zero-valued padding smuggled in.
        #expect(series.candles.allSatisfy { $0.close > 0 })
        // And the axis is bounded by the data, not anchored at zero.
        let bounds = try #require(series.valueBounds)
        #expect(bounds.low > 0)
        #expect(bounds.low < 40)
    }

    /// A series that does cover its range says so.
    @Test func aFullSeriesReportsFullCoverage() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)
        s.merge((0..<40).map { candle(-$0, close: 100) }, listing: ListingID(symbol: "AAPL"), source: "test")

        #expect(s.series(for: ListingID(symbol: "AAPL"), range: .oneMonth).coversFullRange)
    }

    /// One point is not a line. Better no chart than a dot read as a trend.
    @Test func aSinglePointIsNotAChart() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)
        s.merge([candle(0, close: 100)], listing: ListingID(symbol: "ONE"), source: "test")

        #expect(s.series(for: ListingID(symbol: "ONE"), range: .oneMonth).isEmpty)
    }

    @Test func changeIsMeasuredAcrossTheVisibleWindow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)
        s.merge([candle(-2, close: 100), candle(-1, close: 105), candle(0, close: 110)],
                listing: ListingID(symbol: "AAPL"), source: "test")

        let change = try #require(s.series(for: ListingID(symbol: "AAPL"), range: .oneMonth).change)
        #expect(change.absolute == 10)
        #expect(change.percent == 10)
    }
}
