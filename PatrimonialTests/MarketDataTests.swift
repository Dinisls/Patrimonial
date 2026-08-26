import Foundation
import Testing
@testable import Patrimonial

struct FinnhubDecodingTests {

    // MARK: - Quote decoding

    @Test func fullQuoteDecodes() throws {
        let data = try fixtureData("finnhub_quote")
        let response = try JSONDecoder().decode(FinnhubQuoteResponse.self, from: data)
        #expect(response.c == 182.40)
        #expect(response.pc == 180.95)
        #expect(response.d == 1.45)
        #expect(response.dp == 0.8012)
        #expect(response.t == 1719936000)

        let quote = try #require(response.toQuote(symbol: "AAPL"))
        #expect(quote.symbol == "AAPL")
        #expect(quote.price == 182.40)
        #expect(quote.previousClose == 180.95)
        #expect(quote.changeAbsolute == 1.45)
        #expect(quote.source == .rest)
        // Not "USD". Finnhub's /quote reports no currency at all, and this
        // assertion used to pin the guess rather than the fact — which is how a
        // hardcoded "USD" survived here after the same bug was fixed in
        // /search. Empty means unknown; the recorded listing supplies it.
        #expect(quote.currency == "")
    }

    @Test func partialQuoteDecodesWithNils() throws {
        let data = try fixtureData("finnhub_quote_partial")
        let response = try JSONDecoder().decode(FinnhubQuoteResponse.self, from: data)
        #expect(response.c == 182.40)
        #expect(response.d == nil)
        #expect(response.dp == nil)
        #expect(response.h == nil)
        #expect(response.l == nil)
        #expect(response.o == nil)

        let quote = try #require(response.toQuote(symbol: "TEST"))
        #expect(quote.price == 182.40)
        // This assertion used to read `== 0`, and it was pinning the defect:
        // Finnhub sent no `d`/`dp`, and the parser turned that into a change of
        // exactly zero — a claim that the instrument did not move. Ponto I.
        // The previous close *is* present here, so the derived change is not
        // fabricated by the parser; it stays nil because Finnhub said nothing
        // and the caller can compute what it needs from `pc`.
        #expect(quote.previousClose == 180.95)
        #expect(quote.changeAbsolute == nil)
        #expect(quote.changePercent == nil)
    }

    /// The other half: no `pc` either, so there is no previous close to be had
    /// from anywhere, and the day change has to be unknown rather than zero.
    @Test func aQuoteWithNoPreviousCloseReportsNoDayChange() throws {
        let response = FinnhubQuoteResponse(
            c: 182.40, d: nil, dp: nil, h: nil, l: nil, o: nil, pc: nil, t: nil
        )
        let quote = try #require(response.toQuote(symbol: "TEST"))
        #expect(quote.price == 182.40)
        #expect(quote.previousClose == nil)

        var holding = Holding(
            assetSymbol: "TEST", accountID: "a", accountName: "Corretora",
            quantity: 1, totalCostEUR: 150, averagePriceEUR: 150,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        holding.currentPriceNative = quote.price
        holding.previousCloseNative = quote.previousClose
        holding.currency = "USD"
        holding.currentFXRate = FXRate(from: "USD", to: "EUR", value: 1)

        // Valued, and with a P/L — only the day change is missing, because only
        // the day change depended on the close that never arrived.
        #expect(holding.marketValueEUR != nil)
        #expect(holding.unrealizedPL != nil)
        #expect(holding.dayChangeEUR == nil)
    }

    /// Finnhub answers 200 with `{"c":0,"pc":0,…}` for anything outside its
    /// coverage — every European ETF on the free plan, QDVE included. That used
    /// to decode into a 0,00 quote, which showed as "0,00" in the search list
    /// and marked the symbol as covered so Alpha Vantage was never asked. A
    /// traded instrument is never worth zero: this must be no quote at all.
    @Test func emptyQuoteYieldsNoQuoteRatherThanZero() throws {
        let data = try fixtureData("finnhub_quote_empty")
        let response = try JSONDecoder().decode(FinnhubQuoteResponse.self, from: data)
        #expect(response.toQuote(symbol: "INVALID") == nil)
    }

    @Test func malformedQuoteThrows() {
        let bad = Data("not json".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FinnhubQuoteResponse.self, from: bad)
        }
    }

    @Test func unexpectedFieldsAreIgnored() throws {
        let json = """
        {"c": 100, "pc": 99, "t": 1000, "unknown_field": "hello", "extra": 42}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(FinnhubQuoteResponse.self, from: json)
        #expect(response.c == 100)
    }

    // MARK: - Search decoding

    @Test func searchDecodes() throws {
        let data = try fixtureData("finnhub_search")
        let response = try JSONDecoder().decode(FinnhubSearchResponse.self, from: data)
        #expect(response.count == 4)
        #expect(response.result.count == 4)

        let results = response.result.compactMap { $0.toSearchResult() }
        #expect(results.count == 4)

        let apple = results.first { $0.symbol == "AAPL" }
        #expect(apple?.name == "Apple Inc")
        #expect(apple?.assetClass == .stock)

        let voo = results.first { $0.symbol == "VOO" }
        #expect(voo?.assetClass == .etf)
    }

    @Test func emptySearchDecodes() throws {
        let data = try fixtureData("finnhub_search_empty")
        let response = try JSONDecoder().decode(FinnhubSearchResponse.self, from: data)
        #expect(response.count == 0)
        #expect(response.result.isEmpty)
    }

    // MARK: - Candle decoding

    @Test func candlesDecodes() throws {
        let data = try fixtureData("finnhub_candles")
        let response = try JSONDecoder().decode(FinnhubCandleResponse.self, from: data)
        #expect(response.s == "ok")

        let candles = response.toCandles()
        #expect(candles.count == 3)
        #expect(candles[0].close == 180.50)
        #expect(candles[2].close == 182.40)
        #expect(candles[1].volume == 48_000_000)
    }

    @Test func noDataCandlesReturnsEmpty() throws {
        let data = try fixtureData("finnhub_candles_nodata")
        let response = try JSONDecoder().decode(FinnhubCandleResponse.self, from: data)
        let candles = response.toCandles()
        #expect(candles.isEmpty)
    }

    // MARK: - Quote freshness

    @Test func liveFreshnessWithinThreshold() {
        let quote = Quote(
            symbol: "AAPL", price: 100, previousClose: 99,
            changeAbsolute: 1, changePercent: 1,
            currency: "USD", timestamp: Date(),
            source: .websocket
        )
        #expect(quote.freshness == .live)
    }

    @Test func staleFreshnessWhenOld() {
        let quote = Quote(
            symbol: "AAPL", price: 100, previousClose: 99,
            changeAbsolute: 1, changePercent: 1,
            currency: "USD",
            timestamp: Date().addingTimeInterval(-120),
            source: .websocket
        )
        #expect(quote.freshness == .stale)
    }

    @Test func cacheFreshnessAlwaysStale() {
        let quote = Quote(
            symbol: "AAPL", price: 100, previousClose: 99,
            changeAbsolute: 1, changePercent: 1,
            currency: "USD", timestamp: Date(),
            source: .cache
        )
        #expect(quote.freshness == .stale)
    }

    @Test func restFreshnessDelayedWhenRecent() {
        let quote = Quote(
            symbol: "AAPL", price: 100, previousClose: 99,
            changeAbsolute: 1, changePercent: 1,
            currency: "USD", timestamp: Date(),
            source: .rest
        )
        #expect(quote.freshness == .delayed(15))
    }

    // MARK: - Mock provider

    @Test func mockProviderReturnsDefaultQuotes() async throws {
        var provider = MockMarketDataProvider()
        provider.answersOnlyKnownSymbols = false
        let quote = try await provider.quote(for: "AAPL")
        #expect(quote.symbol == "AAPL")
        #expect(quote.price == 182.40)
    }

    @Test func mockProviderRefusesUnknownSymbol() async throws {
        let provider = MockMarketDataProvider()
        await #expect(throws: MarketDataError.self) {
            try await provider.quote(for: "UNKNOWN")
        }
    }

    @Test func mockProviderSearchFilters() async throws {
        let provider = MockMarketDataProvider()
        let results = try await provider.search("Apple")
        #expect(results.count == 1)
        #expect(results[0].symbol == "AAPL")
    }

    @Test func mockProviderFailMode() async {
        var provider = MockMarketDataProvider()
        provider.shouldFail = true
        provider.failError = .rateLimited
        do {
            _ = try await provider.quote(for: "AAPL")
            Issue.record("Should have thrown")
        } catch {
            #expect(error is MarketDataError)
        }
    }

    @Test func mockProviderCustomQuotes() async throws {
        var provider = MockMarketDataProvider()
        provider.mockQuotes["TEST"] = Quote(
            symbol: "TEST", price: 42, previousClose: 40,
            changeAbsolute: 2, changePercent: 5,
            currency: "EUR", timestamp: Date(), source: .rest
        )
        let quote = try await provider.quote(for: "TEST")
        #expect(quote.price == 42)
        #expect(quote.currency == "EUR")
    }

    @Test func mockProviderBatchQuotes() async throws {
        var provider = MockMarketDataProvider()
        provider.answersOnlyKnownSymbols = false
        let quotes = try await provider.quotes(for: ["AAPL", "MSFT", "NVDA"])
        #expect(quotes.count == 3)
        let symbols = Set(quotes.map(\.symbol))
        #expect(symbols == ["AAPL", "MSFT", "NVDA"])
    }

    // MARK: - AssetClass

    @Test func assetClassCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for cls in AssetClass.allCases {
            let data = try encoder.encode(cls)
            let decoded = try decoder.decode(AssetClass.self, from: data)
            #expect(decoded == cls)
        }
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: nil)
                ?? bundle.url(forResource: name, withExtension: "json") else {
            struct FixtureNotFound: Error {}
            throw FixtureNotFound()
        }
        return try Data(contentsOf: url)
    }
}

private class BundleToken {}
