import Foundation

struct MockMarketDataProvider: MarketDataProvider {
    let supportsStreaming = false

    var mockQuotes: [String: Quote] = [:]
    var mockSearchResults: [AssetSearchResult] = []
    var mockCandles: [Candle] = []
    var shouldFail = false
    var failError: MarketDataError = .noData

    /// When true, only symbols present in `mockQuotes` are answered — the way a
    /// real provider covers part of a batch and refuses the rest.
    var answersOnlyKnownSymbols = true

    func quote(for symbol: String) async throws -> Quote {
        if shouldFail { throw failError }
        if let q = mockQuotes[symbol] { return q }
        if answersOnlyKnownSymbols { throw MarketDataError.noData }
        return Self.defaultQuote(symbol: symbol)
    }

    func quotes(for symbols: [String]) async throws -> [Quote] {
        if shouldFail { throw failError }
        if answersOnlyKnownSymbols {
            return symbols.compactMap { mockQuotes[$0] }
        }
        return symbols.map { mockQuotes[$0] ?? Self.defaultQuote(symbol: $0) }
    }

    func search(_ query: String) async throws -> [AssetSearchResult] {
        if shouldFail { throw failError }
        if !mockSearchResults.isEmpty {
            return mockSearchResults.filter {
                $0.symbol.localizedCaseInsensitiveContains(query) ||
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        return Self.defaultSearchResults.filter {
            $0.symbol.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        if shouldFail { throw failError }
        if !mockCandles.isEmpty { return mockCandles }
        throw MarketDataError.noData
    }

    // MARK: - Default fixtures

    static func defaultQuote(symbol: String) -> Quote {
        let prices: [String: (price: Decimal, prevClose: Decimal, currency: String)] = [
            "AAPL": (182.40, 180.95, "USD"),
            "MSFT": (415.20, 412.50, "USD"),
            "NVDA": (135.60, 131.20, "USD"),
            "AMZN": (186.50, 185.10, "USD"),
            "VOO": (482.30, 480.10, "USD"),
            "IWDA.AS": (85.42, 85.10, "EUR"),
            "BTC": (67_420.00, 66_850.00, "USD"),
            "ETH": (3_520.00, 3_480.00, "USD"),
        ]
        let data = prices[symbol] ?? (100.00, 99.50, "USD")
        let change = data.price - data.prevClose
        let pct = data.prevClose != 0 ? (change / data.prevClose) * 100 : 0
        return Quote(
            symbol: symbol,
            price: data.price,
            previousClose: data.prevClose,
            changeAbsolute: change,
            changePercent: pct,
            currency: data.currency,
            timestamp: Date(),
            source: .rest
        )
    }

    static let defaultSearchResults: [AssetSearchResult] = [
        AssetSearchResult(symbol: "AAPL", name: "Apple Inc", exchange: "NASDAQ", assetClass: .stock, currency: "USD"),
        AssetSearchResult(symbol: "MSFT", name: "Microsoft Corporation", exchange: "NASDAQ", assetClass: .stock, currency: "USD"),
        AssetSearchResult(symbol: "NVDA", name: "NVIDIA Corporation", exchange: "NASDAQ", assetClass: .stock, currency: "USD"),
        AssetSearchResult(symbol: "VOO", name: "Vanguard S&P 500 ETF", exchange: "NYSE", assetClass: .etf, currency: "USD"),
        AssetSearchResult(symbol: "IWDA.AS", name: "iShares Core MSCI World UCITS ETF", exchange: "AMS", assetClass: .etf, currency: "EUR"),
        AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "", assetClass: .crypto, currency: "USD", coingeckoID: "bitcoin"),
        AssetSearchResult(symbol: "ETH", name: "Ethereum", exchange: "", assetClass: .crypto, currency: "USD", coingeckoID: "ethereum"),
    ]

    static func generateCandles(count: Int, basePrice: Decimal) -> [Candle] {
        let cal = Calendar.current
        let now = Date()
        return (0..<count).map { i in
            let date = cal.date(byAdding: .day, value: -(count - 1 - i), to: now)!
            let offset = Decimal(i % 5) - 2
            let close = basePrice + offset
            return Candle(
                date: date,
                open: close - 1,
                high: close + 2,
                low: close - 2,
                close: close,
                volume: 1_000_000 + i * 10_000
            )
        }
    }
}
