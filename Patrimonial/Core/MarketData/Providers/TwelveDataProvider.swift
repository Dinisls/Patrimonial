import Foundation

/// Primary quote source. Chosen over Finnhub because its `/quote` reports the
/// listing's own **currency** and **MIC**, so a EUR-quoted Amsterdam line is
/// never mistaken for a USD one.
///
/// Free tier budget: 800 credits/day, 8 requests/minute. `/quote` costs one
/// credit per symbol, but a comma-separated batch is a single HTTP request —
/// which is what the per-minute limit actually counts.
struct TwelveDataProvider: MarketDataProvider {
    let supportsStreaming = false

    private let apiKey: String
    private let session: URLSession
    private let budget: TwelveDataBudget
    private let searchProvider: TwelveDataSearchProvider
    private let baseURL = "https://api.twelvedata.com"

    init(
        apiKey: String = AppConfig.twelveDataAPIKey,
        session: URLSession = .shared,
        budget: TwelveDataBudget = .shared
    ) {
        self.apiKey = apiKey
        self.session = session
        self.budget = budget
        self.searchProvider = TwelveDataSearchProvider(session: session)
    }

    // MARK: - Quote

    func quote(for symbol: String) async throws -> Quote {
        let quotes = try await quotes(for: [symbol])
        guard let quote = quotes.first else { throw MarketDataError.noData }
        return quote
    }

    /// One HTTP request for the whole batch. Credits are charged per symbol, so
    /// the daily budget is reserved per symbol, but only one slot is taken from
    /// the per-minute allowance.
    func quotes(for symbols: [String]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        guard !apiKey.isEmpty else { throw MarketDataError.missingAPIKey }
        guard await budget.reserve(credits: symbols.count) else {
            throw MarketDataError.rateLimited
        }

        guard var comps = URLComponents(string: "\(baseURL)/quote") else {
            throw MarketDataError.invalidResponse
        }
        comps.queryItems = [
            URLQueryItem(name: "symbol", value: symbols.joined(separator: ",")),
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

        return try Self.decodeQuotes(data, requested: symbols)
    }

    /// A single symbol comes back as a flat object; several come back keyed by
    /// symbol. Both shapes have to be accepted.
    ///
    /// A batch is **partially successful**: symbols outside the free plan (any
    /// European venue) come back as per-symbol error objects alongside the ones
    /// that worked. Each entry is therefore decoded independently — one refused
    /// symbol must not discard the quotes that did arrive.
    static func decodeQuotes(_ data: Data, requested: [String]) throws -> [Quote] {
        let decoder = JSONDecoder()
        if requested.count == 1 {
            do {
                let single = try decoder.decode(TwelveDataQuoteResponse.self, from: data)
                return [single.toQuote()].compactMap { $0 }
            } catch {
                throw MarketDataError.decodingFailed(error)
            }
        }
        do {
            let keyed = try decoder.decode([String: TwelveDataQuoteEntry].self, from: data)
            return keyed.values.compactMap { $0.quote?.toQuote() }
        } catch {
            throw MarketDataError.decodingFailed(error)
        }
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [AssetSearchResult] {
        try await searchProvider.search(query)
    }

    // MARK: - Candles

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        try await dailyCandles(symbol: symbol, since: range.fromDate)
    }

    /// Daily candles from `since` to today.
    ///
    /// `start_date` is what makes the refresh incremental: with a cache holding
    /// everything up to Friday, Monday asks for Friday onward and gets three
    /// rows instead of thirty. Twelve Data charges one credit either way, but
    /// the smaller reply is the honest request.
    func dailyCandles(symbol: String, since: Date) async throws -> [Candle] {
        guard !apiKey.isEmpty else { throw MarketDataError.missingAPIKey }
        guard await TwelveDataBudget.shared.reserve(credits: 1) else {
            throw MarketDataError.rateLimited
        }

        let start = Self.dateFormatter.string(from: since)
        guard let url = URL(string:
            "\(baseURL)/time_series?symbol=\(symbol)&interval=1day&start_date=\(start)&apikey=\(apiKey)"
        ) else { throw MarketDataError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 { throw MarketDataError.rateLimited }
            throw MarketDataError.httpError(http.statusCode)
        }
        return try Self.decodeCandles(data)
    }

    /// Twelve Data returns newest-first; the store keeps series ascending.
    ///
    /// The series is normalized on the same rule as the quote. `meta.currency`
    /// is present on this endpoint (verified live against the real response),
    /// so a London listing reports `GBp` here exactly as it does on `/quote`
    /// and the divisor comes from the payload rather than from a guess.
    ///
    /// Normalizing history is not cosmetic. The chart and the quote have to be
    /// on the same scale, and `PriceStore.isPlausible` compares the published
    /// price against the last cached close: a series left in pence sits 100×
    /// above a correctly normalized quote, the ratio blows past ten, and the
    /// *good* price is the one refused. The position would show a dash with
    /// nothing visibly wrong on either side.
    static func decodeCandles(_ data: Data) throws -> [Candle] {
        guard let response = try? JSONDecoder().decode(TwelveDataTimeSeriesResponse.self, from: data),
              let values = response.values
        else {
            // A per-symbol error object decodes to no values. That is "nothing
            // to add", not a failure worth surfacing on a chart.
            return []
        }
        let divisor = CurrencyNormalization.normalize(response.meta?.currency ?? "").divisor
        return values.compactMap { $0.toCandle(divisor: divisor) }.sorted { $0.date < $1.date }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Time series wire format

nonisolated struct TwelveDataTimeSeriesResponse: Decodable {
    let meta: TwelveDataTimeSeriesMeta?
    let values: [TwelveDataCandle]?
}

/// The header Twelve Data puts on a series. Only the currency is read: it is
/// what says whether the closes below are pounds or pence.
nonisolated struct TwelveDataTimeSeriesMeta: Decodable {
    let currency: String?
    let mic_code: String?
}

nonisolated struct TwelveDataCandle: Decodable {
    let datetime: String
    let open: String?
    let high: String?
    let low: String?
    let close: String?
    let volume: String?

    /// Nil unless the row has a usable date and close. A candle without a close
    /// is not a candle, and a zero would draw the chart to the floor.
    ///
    /// `divisor` is the sub-unit divisor from the series' own currency — 100
    /// for a London listing quoted in pence, 1 for everything else. Applied to
    /// all four prices, never to the volume.
    func toCandle(divisor: Decimal = 1) -> Candle? {
        guard let date = TwelveDataProvider.dateFormatter.date(from: datetime),
              let rawClose = close.flatMap({ Decimal(string: $0) }), rawClose > 0
        else { return nil }

        let closeValue = rawClose / divisor
        let openValue = (open.flatMap { Decimal(string: $0) }).map { $0 / divisor } ?? closeValue
        return Candle(
            date: date,
            open: openValue,
            high: (high.flatMap { Decimal(string: $0) }).map { $0 / divisor }
                ?? max(openValue, closeValue),
            low: (low.flatMap { Decimal(string: $0) }).map { $0 / divisor }
                ?? min(openValue, closeValue),
            close: closeValue,
            volume: volume.flatMap { Int($0) } ?? 0
        )
    }
}

// MARK: - Budget

/// Twelve Data's free tier has two independent ceilings, so one token bucket is
/// not enough: 8 requests per minute and 800 credits per day.
actor TwelveDataBudget {
    static let shared = TwelveDataBudget()

    private let perMinute: RateLimiter
    private let perDay: RateLimiter

    init(requestsPerMinute: Int = 8, creditsPerDay: Int = 800) {
        self.perMinute = RateLimiter(maxTokens: requestsPerMinute, refillInterval: 60)
        self.perDay = RateLimiter(maxTokens: creditsPerDay, refillInterval: 86_400)
    }

    /// Never blocks. A refused call must fall back or serve cache rather than
    /// queue up behind a budget that may not refill for hours.
    func reserve(credits: Int) async -> Bool {
        guard await perMinute.tryAcquire() else { return false }
        for _ in 0..<credits {
            guard await perDay.tryAcquire() else { return false }
        }
        return true
    }

    var remainingToday: Int {
        get async { await perDay.availableTokens }
    }
}

// MARK: - Wire format

/// One slot of a batch response: either a quote, or Twelve Data's per-symbol
/// error object (`{"code":404,"status":"error",…}`) for symbols the free plan
/// does not cover.
nonisolated struct TwelveDataQuoteEntry: Decodable {
    let quote: TwelveDataQuoteResponse?

    init(from decoder: Decoder) throws {
        quote = try? TwelveDataQuoteResponse(from: decoder)
    }
}

nonisolated struct TwelveDataQuoteResponse: Decodable {
    let symbol: String
    let currency: String?
    let close: String?
    let previous_close: String?
    let change: String?
    let percent_change: String?
    let timestamp: Int?
    /// The venue this price is from. Twelve Data has always sent it; nothing
    /// read it, which is how a NASDAQ answer passed for a XETRA position.
    /// `exchange` is the human name ("NASDAQ") and is kept only as a fallback
    /// for the rare reply that omits the MIC.
    let mic_code: String?
    let exchange: String?

    func toQuote() -> Quote? {
        guard let close, let rawPrice = Decimal(string: close), rawPrice > 0 else { return nil }
        let norm = CurrencyNormalization.normalize(currency ?? "")
        let price = rawPrice / norm.divisor
        let prev = previous_close.flatMap { Decimal(string: $0) }.map { $0 / norm.divisor }
        return Quote(
            symbol: symbol,
            price: price,
            previousClose: prev,
            changeAbsolute: change.flatMap { Decimal(string: $0) }.map { $0 / norm.divisor }
                ?? prev.map { price - $0 },
            changePercent: percent_change.flatMap { Decimal(string: $0) }
                ?? prev.flatMap { $0 == 0 ? nil : ((price - $0) / $0) * 100 },
            currency: norm.code,
            timestamp: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(),
            source: .rest,
            venueMIC: mic_code.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
