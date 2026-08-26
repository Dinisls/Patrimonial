import Foundation

/// Third fallback, European listings only.
///
/// Neither Twelve Data nor Finnhub covers Euronext or XETRA on a free plan —
/// Twelve Data refuses them and Finnhub answers 403 — so without this every
/// Lisbon and Amsterdam position shows a dash forever. Alpha Vantage's
/// `GLOBAL_QUOTE` does answer for `.LS`/`.AS`/`.PA`/`.DE`, verified live.
///
/// What it gives up: the price is the **previous session's close**, not
/// intraday. It is published as `.dailyClose` so the UI can never dress it up as
/// live, and it is rationed to one call per symbol per day out of the 25-a-day
/// budget shared with Step 7's charts.
struct AlphaVantageProvider: MarketDataProvider {
    let supportsStreaming = false

    private let apiKey: String
    private let session: URLSession
    private let budget: AlphaVantageBudget
    private let baseURL = "https://www.alphavantage.co/query"

    init(
        apiKey: String = AppConfig.alphaVantageAPIKey,
        session: URLSession = .shared,
        budget: AlphaVantageBudget = .shared
    ) {
        self.apiKey = apiKey
        self.session = session
        self.budget = budget
    }

    // MARK: - Quote

    func quote(for symbol: String) async throws -> Quote {
        let quotes = try await quotes(for: [symbol])
        guard let quote = quotes.first else { throw MarketDataError.noData }
        return quote
    }

    /// `GLOBAL_QUOTE` takes one symbol per request — there is no batch form — so
    /// each symbol costs one of the day's 25.
    ///
    /// Returns only what it could get. A symbol skipped because it is not
    /// European, because it was already fetched today, or because the day is
    /// spent is simply absent: the caller keeps serving the cached close, which
    /// is the intended outcome and not an error.
    func quotes(for symbols: [String]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        guard !apiKey.isEmpty else { throw MarketDataError.missingAPIKey }

        var results: [Quote] = []
        for symbol in symbols {
            guard MarketCalendar.isEuropean(symbol) else { continue }
            guard await budget.reserveQuote(symbol: symbol) else { continue }
            do {
                if let quote = try await fetchQuote(symbol) { results.append(quote) }
            } catch is URLError {
                // Never reached them, so it cost them nothing and must not cost
                // us the symbol's one shot for today.
                await budget.releaseQuote(symbol: symbol)
            } catch {
                // An HTTP or decoding failure still counted against the quota on
                // their side. Keep the reservation spent and stay quiet.
            }
        }
        return results
    }

    private func fetchQuote(_ symbol: String) async throws -> Quote? {
        guard var comps = URLComponents(string: baseURL) else {
            throw MarketDataError.invalidResponse
        }
        comps.queryItems = [
            URLQueryItem(name: "function", value: "GLOBAL_QUOTE"),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        guard let url = comps.url else { throw MarketDataError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 { throw MarketDataError.rateLimited }
            throw MarketDataError.httpError(http.statusCode)
        }

        return Self.decodeQuote(data, symbol: symbol)
    }

    /// Alpha Vantage answers 200 for everything, including refusals: an unknown
    /// symbol comes back as an empty `Global Quote` object and an exhausted key
    /// as a `Note`/`Information` string. Both decode to nil rather than throwing,
    /// because neither is worth surfacing to the user.
    static func decodeQuote(_ data: Data, symbol: String) -> Quote? {
        guard let wrapper = try? JSONDecoder().decode(AlphaVantageGlobalQuoteResponse.self, from: data),
              let raw = wrapper.quote
        else { return nil }
        return raw.toQuote(requested: symbol)
    }

    /// How to read this provider's numbers for a given symbol: which currency
    /// they are in, and what to divide them by.
    ///
    /// One place, because the quote and the series must agree. They are
    /// compared against each other by `PriceStore.isPlausible`, and a chart in
    /// pence beside a price in pounds is a 100× gap that gets the *good* price
    /// refused.
    ///
    /// **Nil when the symbol does not say.** This is point G, and the fallback
    /// it used to have was `exchangeForSymbol(symbol).nativeCurrency`, which
    /// answers `.nyse` — and therefore USD — for anything it does not
    /// recognise. A European price stamped USD is a wrong number with a wrong
    /// rate applied on top; refusing is a dash. The dash is the correct
    /// failure, and this provider is only ever asked about symbols whose suffix
    /// it does know.
    static func normalization(forSymbol symbol: String) -> CurrencyNormalization.Result? {
        MarketCalendar.alphaVantageCurrency(forSuffixOf: symbol)
            .map(CurrencyNormalization.normalize)
    }

    // MARK: - Search

    /// Alpha Vantage's `SYMBOL_SEARCH` costs a request out of the same 25, and
    /// Twelve Data's search is free and reports currency and MIC. Spending the
    /// European quote budget on search would be a bad trade.
    func search(_ query: String) async throws -> [AssetSearchResult] {
        []
    }

    // MARK: - Candles

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        try await dailyCandles(symbol: symbol, since: range.fromDate)
    }

    /// Daily candles, `compact` — the last 100 sessions.
    ///
    /// `since` is not sent: Alpha Vantage's daily endpoint has no start date,
    /// only `compact` (100) or `full` (20+ years, a much heavier response on a
    /// 25-a-day budget). So the request is always the same 100 points and the
    /// incremental part happens on merge, where the cache keeps everything it
    /// already had. That is exactly why the cache must never delete: 100
    /// sessions is all this provider will ever hand over at once, and a longer
    /// chart is only ever built by accumulating them.
    func dailyCandles(symbol: String, since: Date) async throws -> [Candle] {
        guard !apiKey.isEmpty else { throw MarketDataError.missingAPIKey }
        // Charts yield to quotes: refused as soon as spending would eat the
        // reserve. Refusal is normal and silent — the caller serves cache.
        guard await budget.reserveHistory() else { throw MarketDataError.rateLimited }

        guard let url = URL(string:
            "\(baseURL)?function=TIME_SERIES_DAILY&symbol=\(symbol)&outputsize=compact&apikey=\(apiKey)"
        ) else { throw MarketDataError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MarketDataError.invalidResponse
        }
        return Self.decodeCandles(data, symbol: symbol)
    }

    /// Never throws: an exhausted key answers 200 with a `Note`/`Information`
    /// string, and a bad symbol with an empty object. Both mean "nothing to
    /// add", which is not a chart error.
    ///
    /// `symbol` is required, not decorative: the response says nothing about
    /// its own units, so the suffix that was asked for is the only thing that
    /// can tell pounds from pence.
    static func decodeCandles(_ data: Data, symbol: String) -> [Candle] {
        guard let response = try? JSONDecoder().decode(AlphaVantageTimeSeriesResponse.self, from: data),
              let series = response.series
        else { return [] }

        // Same refusal as the quote path, and for the same reason: a series
        // whose unit is unknown is not a series, and one scaled by a guess is
        // worse — `PriceStore.isPlausible` compares the two, so a chart in the
        // wrong unit gets the *correct* price refused.
        guard let divisor = normalization(forSymbol: symbol)?.divisor else { return [] }
        return series.compactMap { key, value -> Candle? in
            guard let date = AlphaVantageGlobalQuote.tradingDayFormatter.date(from: key),
                  let rawClose = Decimal(string: value.close), rawClose > 0
            else { return nil }
            let close = rawClose / divisor
            let open = Decimal(string: value.open).map { $0 / divisor } ?? close
            return Candle(
                date: date,
                open: open,
                high: Decimal(string: value.high).map { $0 / divisor } ?? max(open, close),
                low: Decimal(string: value.low).map { $0 / divisor } ?? min(open, close),
                close: close,
                volume: Int(value.volume) ?? 0
            )
        }
        .sorted { $0.date < $1.date }
    }
}

// MARK: - Time series wire format

nonisolated struct AlphaVantageTimeSeriesResponse: Decodable {
    let series: [String: AlphaVantageDailyBar]?

    enum CodingKeys: String, CodingKey {
        case series = "Time Series (Daily)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        series = try? container.decode([String: AlphaVantageDailyBar].self, forKey: .series)
    }
}

/// The numbered keys are Alpha Vantage's own field names, verbatim.
nonisolated struct AlphaVantageDailyBar: Decodable {
    let open: String
    let high: String
    let low: String
    let close: String
    let volume: String

    enum CodingKeys: String, CodingKey {
        case open = "1. open"
        case high = "2. high"
        case low = "3. low"
        case close = "4. close"
        case volume = "5. volume"
    }
}

// MARK: - Wire format

nonisolated struct AlphaVantageGlobalQuoteResponse: Decodable {
    let quote: AlphaVantageGlobalQuote?

    enum CodingKeys: String, CodingKey {
        case quote = "Global Quote"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quote = try? container.decode(AlphaVantageGlobalQuote.self, forKey: .quote)
    }
}

/// The numbered keys are Alpha Vantage's own field names, verbatim.
nonisolated struct AlphaVantageGlobalQuote: Decodable {
    let symbol: String
    let price: String
    let previousClose: String?
    let change: String?
    let changePercent: String?
    let latestTradingDay: String?

    enum CodingKeys: String, CodingKey {
        case symbol = "01. symbol"
        case price = "05. price"
        case latestTradingDay = "07. latest trading day"
        case previousClose = "08. previous close"
        case change = "09. change"
        case changePercent = "10. change percent"
    }

    func toQuote(requested: String) -> Quote? {
        // A quote without a usable price is not a quote. Letting a zero through
        // would put a fake 0,00 € into the portfolio totals.
        guard let rawValue = Decimal(string: price), rawValue > 0 else { return nil }

        // GLOBAL_QUOTE does not report a currency. Guessing one is how a EUR
        // price ends up with a USD→EUR rate applied, so it is derived from the
        // suffix instead — and through the same normalization the reporting
        // providers get, so a venue quoting in a sub-unit divides here rather
        // than arriving 100× high.
        // No reading of the unit, no quote. See `normalization(forSymbol:)`.
        guard let norm = AlphaVantageProvider.normalization(forSymbol: requested) else {
            return nil
        }
        let value = rawValue / norm.divisor

        // Ponto I. `?? value` here produced a previous close identical to the
        // close, i.e. a settled session that reportedly did not move at all.
        let prev = previousClose.flatMap { Decimal(string: $0) }.map { $0 / norm.divisor }
        // "0.3047%" — the percent sign is part of the value. A percentage is
        // scale-free, so it is never divided.
        let pct = changePercent
            .map { $0.replacingOccurrences(of: "%", with: "") }
            .flatMap { Decimal(string: $0) }

        return Quote(
            symbol: symbol.isEmpty ? requested : symbol,
            price: value,
            previousClose: prev,
            changeAbsolute: change.flatMap { Decimal(string: $0) }.map { $0 / norm.divisor }
                ?? prev.map { value - $0 },
            changePercent: pct ?? prev.flatMap { $0 == 0 ? nil : ((value - $0) / $0) * 100 },
            currency: norm.code,
            timestamp: Date(),
            source: .dailyClose,
            closeDate: latestTradingDay.flatMap(Self.parseTradingDay)
        )
    }

    /// Parsed at midday UTC so that formatting it in any European timezone lands
    /// on the same calendar day it was published for.
    static func parseTradingDay(_ raw: String) -> Date? {
        guard let day = tradingDayFormatter.date(from: raw) else { return nil }
        return day.addingTimeInterval(12 * 3600)
    }

    static let tradingDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
