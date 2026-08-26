import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// Fixtures are the four real payloads, verbatim, captured live at `range=5d`
/// — `meta`, `timestamp` and `indicators` exactly as Yahoo returned them.
struct YahooChartDecodingTests {

    /// Reference "now" for the staleness window: 2026-08-08, the day the
    /// payloads were captured. Fixed so the tests do not rot.
    private let now = Date(timeIntervalSince1970: 1786190000)

    private func decode(_ fixture: String, symbol: String, now: Date? = nil) throws -> Quote? {
        YahooChartProvider.decodeQuote(
            try fixtureData(fixture), symbol: symbol, now: now ?? self.now
        )
    }

    // MARK: - The QDVE.F trap

    /// The one that would have cost real money. `regularMarketPrice` is 20,31
    /// with a `regularMarketTime` of 1688130685 — June 2023 — while the series
    /// close is 44,56 from this week. Frankfurt stopped updating the "current"
    /// field years ago. Reading it blind values the position at less than half.
    ///
    /// The later timestamp wins, so the close does.
    @Test func staleRegularMarketPriceLosesToTheRecentClose() throws {
        let quote = try #require(try decode("yahoo_qdve_f", symbol: "QDVE.F"))

        #expect(quote.price == Decimal(string: "44.564998626708984")!)
        #expect(quote.price != Decimal(string: "20.31")!)
        #expect(quote.currency == "EUR")
        // And it is labelled for the session it belongs to, not as live.
        #expect(quote.source == .dailyClose)
        #expect(quote.closeDate == Date(timeIntervalSince1970: 1786082400))

        // Previous close is the bar before, 44,68 — not meta's 42,69, which at
        // range=5d is the close before the window and at range=1d was 20,105.
        // The same field, two values, neither of them yesterday.
        #expect(quote.previousClose == Decimal(string: "44.68000030517578")!)
        #expect(quote.previousClose != Decimal(string: "42.69")!)
    }

    /// The converse: when `regularMarketTime` is the more recent of the two, it
    /// is the one that wins. The rule is "later timestamp", not "always the
    /// close" — otherwise a genuinely live venue would go a day stale.
    @Test func freshRegularMarketPriceWinsOverAnOlderClose() throws {
        let json = """
        {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"X.DE",
        "regularMarketPrice":50.0,"regularMarketTime":1786180000,
        "chartPreviousClose":49.0},"timestamp":[1786105800],
        "indicators":{"quote":[{"close":[48.0]}]}}],"error":null}}
        """.data(using: .utf8)!

        let quote = try #require(YahooChartProvider.decodeQuote(json, symbol: "X.DE", now: now))
        #expect(quote.price == 50)
    }

    /// Both candidates older than the window: nothing is published. A price
    /// from 2023 must not appear under today's date in any form.
    @Test func aPriceOlderThanTheWindowIsNotPublished() throws {
        let json = """
        {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"DEAD.F",
        "regularMarketPrice":20.31,"regularMarketTime":1688130685,
        "chartPreviousClose":20.105},"timestamp":[1688130685],
        "indicators":{"quote":[{"close":[20.31]}]}}],"error":null}}
        """.data(using: .utf8)!

        #expect(YahooChartProvider.decodeQuote(json, symbol: "DEAD.F", now: now) == nil)
    }

    /// The window is seven days: wide enough for a long weekend plus a holiday
    /// on a thin venue, narrow enough that a dormant listing is caught.
    @Test func theStalenessWindowIsSevenDays() throws {
        let sixDays = now.addingTimeInterval(-6 * 24 * 3600).timeIntervalSince1970
        let eightDays = now.addingTimeInterval(-8 * 24 * 3600).timeIntervalSince1970

        func payload(_ time: TimeInterval) -> Data {
            """
            {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"X.MU",
            "regularMarketPrice":44.71,"regularMarketTime":\(Int(time)),
            "chartPreviousClose":44.5},"timestamp":[\(Int(time))],
            "indicators":{"quote":[{"close":[44.71]}]}}],"error":null}}
            """.data(using: .utf8)!
        }

        #expect(YahooChartProvider.decodeQuote(payload(sixDays), symbol: "X.MU", now: now) != nil)
        #expect(YahooChartProvider.decodeQuote(payload(eightDays), symbol: "X.MU", now: now) == nil)
    }

    // MARK: - The other three payloads

    /// Munich: thin (volume 1) and, crucially, a **single bar** even at
    /// range=5d. There is no earlier session in the series, so this is the one
    /// case where `meta.chartPreviousClose` is the only previous close there
    /// is — and the only case where it is used.
    ///
    /// Its `regularMarketTime` and its one bar carry the *same* stamp, and on a
    /// tie the meta price is taken — the two agree to float precision anyway
    /// (44,71 against 44,709999084472656), so this only decides which spelling
    /// of the same number is published.
    @Test func munichDecodesAndFallsBackToMetaForTheSingleBar() throws {
        let quote = try #require(try decode("yahoo_qdve_mu", symbol: "QDVE.MU"))
        #expect(quote.price == Decimal(string: "44.71")!)
        #expect(quote.currency == "EUR")
        #expect(quote.previousClose == Decimal(string: "44.24")!)
    }

    /// Buenos Aires, in pesos. The CEDEAR is 1/20 of a share and is not
    /// comparable with the NASDAQ line — nothing here tries to reconcile them,
    /// and the currency is carried through exactly as reported so the FX
    /// conversion is the only thing that touches the number.
    @Test func buenosAiresDecodesInPesos() throws {
        let quote = try #require(try decode("yahoo_aapl_ba", symbol: "AAPL.BA"))
        #expect(quote.price == Decimal(string: "24800.0")!)
        #expect(quote.currency == "ARS")

        // The live price (1786132787) and today's bar (1786111200) are the same
        // session six hours apart. Treating the bar as "previous" would report a
        // day change of zero; the real previous close is the day before.
        #expect(quote.previousClose == Decimal(string: "24610.0")!)
        #expect(quote.changeAbsolute == Decimal(string: "190.0")!)
        // And not meta.chartPreviousClose, which is the close before the whole
        // 5-day window.
        #expect(quote.previousClose != Decimal(string: "24310.0")!)
    }

    @Test func lisbonDecodes() throws {
        let quote = try #require(try decode("yahoo_galp_ls", symbol: "GALP.LS"))
        #expect(quote.price == Decimal(string: "19.825")!)
        #expect(quote.currency == "EUR")

        // Yesterday's close, 19,92 — Galp is down on the day. Reading
        // meta.chartPreviousClose would give 19,75, the close before the
        // window, and turn a fall into a rise.
        #expect(quote.previousClose == Decimal(string: "19.920000076293945")!)
        #expect((quote.changeAbsolute ?? 0) < 0)
        #expect(quote.previousClose != Decimal(string: "19.75")!)
    }

    // MARK: - Currency

    /// Absent `meta.currency` falls back to the venue implied by the suffix —
    /// from the same table that built the symbol, never a default.
    @Test func missingCurrencyComesFromTheVenue() throws {
        let quote = try #require(try decode("yahoo_no_currency", symbol: "XXXX.DE"))
        #expect(quote.currency == "EUR")
    }

    /// And when the suffix is not in the table either, there is no currency to
    /// be had, so there is no quote. Assuming USD here is what applies a
    /// USD→EUR rate to a euro price.
    @Test func missingCurrencyOnAnUnknownVenueYieldsNoQuote() throws {
        let data = try fixtureData("yahoo_no_currency")
        #expect(YahooChartProvider.decodeQuote(data, symbol: "XXXX.ZZ", now: now) == nil)
    }

    // MARK: - Failure shapes

    @Test func aDelistedSymbolYieldsNoQuote() throws {
        let data = try fixtureData("yahoo_not_found")
        #expect(YahooChartProvider.decodeQuote(data, symbol: "NOPE.F", now: now) == nil)
    }

    @Test func malformedJSONYieldsNoQuoteAndDoesNotThrow() {
        #expect(YahooChartProvider.decodeQuote(Data("not json".utf8), symbol: "X.F", now: now) == nil)
    }

    /// Yahoo pads the series with nulls for sessions with no print, and on a
    /// thin venue the last slot is null more often than not. The last *real*
    /// close is what counts.
    @Test func trailingNullClosesAreSkipped() throws {
        let json = """
        {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"X.HM",
        "chartPreviousClose":44.0},"timestamp":[1786019400,1786105800],
        "indicators":{"quote":[{"close":[44.5,null]}]}}],"error":null}}
        """.data(using: .utf8)!

        let quote = try #require(YahooChartProvider.decodeQuote(json, symbol: "X.HM", now: now))
        #expect(quote.price == Decimal(string: "44.5")!)
        #expect(quote.closeDate == Date(timeIntervalSince1970: 1786019400))
    }

    /// Not a history source, and it must not quietly become one.
    @Test func candlesAreRefused() async {
        let provider = YahooChartProvider()
        await #expect(throws: (any Error).self) {
            try await provider.candles(symbol: "GALP.LS", range: .oneMonth)
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: YahooBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            struct FixtureNotFound: Error { let name: String }
            throw FixtureNotFound(name: name)
        }
        return try Data(contentsOf: url)
    }
}

private class YahooBundleToken {}

// MARK: - The MIC table

struct YahooVenueTableTests {

    /// Every venue the last resort is meant to cover, by MIC. Nothing is
    /// derived from a ticker.
    @Test func everyCoveredVenueMapsToItsSuffix() {
        let expected: [(String, String, String)] = [
            ("XETR", ".DE", "EUR"), ("XFRA", ".F", "EUR"), ("XMUN", ".MU", "EUR"),
            ("XDUS", ".DU", "EUR"), ("XHAM", ".HM", "EUR"), ("XLIS", ".LS", "EUR"),
            ("XAMS", ".AS", "EUR"), ("XPAR", ".PA", "EUR"), ("XBUE", ".BA", "ARS"),
            ("XMEX", ".MX", "MXN"), ("XTSE", ".TO", "CAD"),
        ]
        for (mic, suffix, currency) in expected {
            let venue = MarketCalendar.yahooVenue(for: mic)
            #expect(venue?.suffix == suffix, "\(mic)")
            #expect(venue?.currency == currency, "\(mic)")
        }
    }

    @Test func anUnknownMICHasNoSuffix() {
        #expect(MarketCalendar.yahooVenue(for: "XNGS") == nil)
        #expect(MarketCalendar.yahooSymbol("AAPL", mic: "XNGS") == nil)
        #expect(MarketCalendar.yahooSymbol("QDVE", mic: "ZZZZ") == nil)
    }

    @Test func theSymbolIsBuiltFromTheMIC() {
        #expect(MarketCalendar.yahooSymbol("QDVE", mic: "XFRA") == "QDVE.F")
        #expect(MarketCalendar.yahooSymbol("AAPL", mic: "XBUE") == "AAPL.BA")
        // Idempotent: a symbol already carrying the suffix is not doubled.
        #expect(MarketCalendar.yahooSymbol("GALP.LS", mic: "XLIS") == "GALP.LS")
    }
}

// MARK: - Routing: last means last

@MainActor
struct LastResortRoutingTests {

    private func quote(_ symbol: String, _ price: Decimal, _ currency: String) -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: price, changeAbsolute: 0,
            changePercent: 0, currency: currency, timestamp: Date(), source: .dailyClose,
            closeDate: Date()
        )
    }

    /// The condition stated plainly: Yahoo is asked only after Twelve Data,
    /// Finnhub and Alpha Vantage have all failed to serve the symbol.
    @Test func yahooIsCalledOnlyAfterTheOtherThreeFail() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        refuses.mockQuotes = [:]
        let yahoo = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: refuses, lastResortProvider: yahoo,
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "QDVE", mic: "XFRA"), currency: "EUR")

        await store.refresh([ListingID(symbol: "QDVE", mic: "XFRA")])

        #expect(yahoo.received == ["QDVE.F"])
    }

    /// And it is not called at all when any earlier provider answered — it must
    /// never displace one of them.
    ///
    /// The listing here is a US one, and that is not incidental. This test used
    /// to register QDVE on **XFRA** and have the primary answer for the bare
    /// ticker — which is exactly the behaviour that produced the NVD bug, a
    /// US-only provider answering about a German listing. The premise was the
    /// defect. The ordering rule it was written to protect is real, so it is
    /// kept on a venue where the primary is legitimately the source; the
    /// European half of the same rule is covered by
    /// `alphaVantageStillWinsOnTheVenuesItCovers`.
    @Test func yahooIsSkippedWhenAnEarlierProviderAnswers() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.answersOnlyKnownSymbols = true
        primary.mockQuotes = ["AAPL": quote("AAPL", Decimal(string: "313.33")!, "USD")]
        let yahoo = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: primary, fallbackProvider: primary,
            europeanProvider: primary, lastResortProvider: yahoo,
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "AAPL", mic: "XNAS"), currency: "USD")

        await store.refresh([ListingID(symbol: "AAPL", mic: "XNAS")])

        #expect(yahoo.received.isEmpty)
        #expect(store.quote(for: ListingID(symbol: "AAPL", mic: "XNAS"))?.price == Decimal(string: "313.33")!)
    }

    /// Alpha Vantage first for a venue it covers; Yahoo only picks up what is
    /// left. XETRA is in both tables, and the order between them is what this
    /// pins.
    @Test func alphaVantageStillWinsOnTheVenuesItCovers() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        var av = MockMarketDataProvider()
        av.answersOnlyKnownSymbols = true
        av.mockQuotes = ["QDVE.DE": quote("QDVE.DE", Decimal(string: "44.795")!, "EUR")]
        let yahoo = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: av, lastResortProvider: yahoo,
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "QDVE", mic: "XETR"), currency: "EUR")

        await store.refresh([ListingID(symbol: "QDVE", mic: "XETR")])

        #expect(yahoo.received.isEmpty)
        #expect(store.quote(for: ListingID(symbol: "QDVE", mic: "XETR"))?.price == Decimal(string: "44.795")!)
    }

    /// A position with no recorded MIC is never guessed at — no suffix is
    /// invented from the ticker.
    @Test func aPositionWithoutAMICIsNotSentToYahoo() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        let yahoo = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: refuses, lastResortProvider: yahoo,
            modelContext: container.mainContext
        )

        await store.refresh([ListingID(symbol: "QDVE")])

        #expect(yahoo.received.isEmpty)
    }

    /// A Yahoo outage costs the exotic venues their price and nothing else — in
    /// particular it must not light the portfolio's error banner.
    @Test func aYahooFailureNeverRaisesAPortfolioError() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        var broken = MockMarketDataProvider()
        broken.shouldFail = true

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: refuses, lastResortProvider: broken,
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "AAPL", mic: "XBUE"), currency: "ARS")

        await store.refresh([ListingID(symbol: "AAPL", mic: "XBUE")])

        #expect(store.quote(for: ListingID(symbol: "AAPL", mic: "XBUE")) == nil)
        // `.noData` is the honest state for "nothing could price this", but it
        // must be that and not a Yahoo-specific failure surfaced to the user.
        if case .noData = store.lastError {} else { Issue.record("expected .noData, got \(String(describing: store.lastError))") }
    }

    /// The reply is filed under the held symbol, in the venue's currency.
    @Test func theQuoteComesBackUnderTheHeldSymbol() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        var yahoo = MockMarketDataProvider()
        yahoo.answersOnlyKnownSymbols = true
        yahoo.mockQuotes = ["AAPL.BA": quote("AAPL.BA", 24800, "ARS")]

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: refuses, lastResortProvider: yahoo,
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "AAPL", mic: "XBUE"), currency: "ARS")

        await store.refresh([ListingID(symbol: "AAPL", mic: "XBUE")])

        let stored = try #require(store.quote(for: ListingID(symbol: "AAPL", mic: "XBUE")))
        #expect(stored.price == 24800)
        #expect(stored.currency == "ARS")
        #expect(store.quote(for: ListingID(symbol: "AAPL.BA")) == nil)
    }

    /// Search rows on venues nothing else covers stop showing a dash.
    @Test func searchRowsOnExoticVenuesArePriced() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        var yahoo = MockMarketDataProvider()
        yahoo.answersOnlyKnownSymbols = true
        yahoo.mockQuotes = ["QDVE.F": quote("QDVE.F", Decimal(string: "44.564998")!, "EUR")]

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: refuses, lastResortProvider: yahoo,
            modelContext: container.mainContext
        )

        let frankfurt = AssetSearchResult(
            symbol: "QDVE", name: "iShares S&P 500 IT UCITS ETF", exchange: "FSX",
            assetClass: .etf, currency: "EUR", mic: "XFRA"
        )
        let priced = await store.quotesForSearch([frankfurt])

        #expect(priced[frankfurt.id]?.price == Decimal(string: "44.564998")!)
    }
}

// MARK: - previousClose comes from the series, not from meta

/// `meta.chartPreviousClose` is the close before the chart's *range* starts, so
/// the same field for the same instrument changes with the range: QDVE.F
/// reports 20,105 at range=1d and 42,69 at range=5d. Neither is yesterday.
/// Trusting it silently mis-states every day change.
struct YahooPreviousCloseTests {

    private let now = Date(timeIntervalSince1970: 1786190000)

    /// The field genuinely differs between ranges for the same instrument on
    /// the same day — captured from both responses.
    @Test func metaPreviousCloseIsRangeDependentAndSoUntrustworthy() throws {
        func chartPreviousClose(_ json: String) throws -> Double {
            let data = json.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            return try #require(decoded.chart.result?.first?.meta.chartPreviousClose)
        }

        let oneDay = """
        {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"QDVE.F","range":"1d",
        "chartPreviousClose":20.105,"gmtoffset":7200}}],"error":null}}
        """
        let fiveDay = """
        {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"QDVE.F","range":"5d",
        "chartPreviousClose":42.69,"gmtoffset":7200}}],"error":null}}
        """
        #expect(try chartPreviousClose(oneDay) == 20.105)
        #expect(try chartPreviousClose(fiveDay) == 42.69)
    }

    /// The series is read in the venue's own offset, so a bar and an intraday
    /// price on the same local day are one session. Buenos Aires stamps the bar
    /// at 1786111200 and the price at 1786132787 — six hours later, same day.
    @Test func theSameLocalDayCountsAsOneSession() throws {
        // Two bars a day apart, plus a live price later on the second day.
        let json = """
        {"chart":{"result":[{"meta":{"currency":"ARS","symbol":"T.BA","gmtoffset":-10800,
        "regularMarketPrice":24800.0,"regularMarketTime":1786132787,
        "chartPreviousClose":24310.0},
        "timestamp":[1786024800,1786111200],
        "indicators":{"quote":[{"close":[24610.0,24800.0]}]}}],"error":null}}
        """.data(using: .utf8)!

        let quote = try #require(YahooChartProvider.decodeQuote(json, symbol: "T.BA", now: now))
        #expect(quote.price == Decimal(string: "24800.0")!)
        #expect(quote.previousClose == Decimal(string: "24610.0")!)
    }

    /// With no earlier session in the series, `meta` is the only source left —
    /// and is used. This is the Munich case.
    @Test func aSingleBarFallsBackToMeta() throws {
        let json = """
        {"chart":{"result":[{"meta":{"currency":"EUR","symbol":"T.MU","gmtoffset":7200,
        "regularMarketPrice":44.71,"regularMarketTime":1786105907,
        "chartPreviousClose":44.24},
        "timestamp":[1786105907],
        "indicators":{"quote":[{"close":[44.709999084472656]}]}}],"error":null}}
        """.data(using: .utf8)!

        let quote = try #require(YahooChartProvider.decodeQuote(json, symbol: "T.MU", now: now))
        #expect(quote.previousClose == Decimal(string: "44.24")!)
    }
}
