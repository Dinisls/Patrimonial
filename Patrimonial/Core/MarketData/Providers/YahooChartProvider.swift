import Foundation

/// Last-resort quotes for the venues nothing else reaches.
///
/// Twelve Data's free plan is US-only, Finnhub the same, and Alpha Vantage
/// covers XETRA and Euronext but not Frankfurt, Munich, Düsseldorf, Hamburg,
/// Buenos Aires, Bogotá, Mexico City or Toronto. Those listings had no price at
/// all. This fills that gap and nothing else: it runs only after the other
/// three have failed, and it never displaces any of them.
///
/// It is an undocumented endpoint with no contract, no key and no promise, so
/// it is treated as one throughout — every failure returns nothing rather than
/// throwing something the portfolio would paint red, and `PriceStore` is wired
/// so that a Yahoo outage costs only the exotic venues.
///
/// Quotes only. Candles deliberately throw: this is not a history source.
struct YahooChartProvider: MarketDataProvider {
    let supportsStreaming = false

    /// Beyond this, a price is not published at all.
    ///
    /// Seven days, because that is the widest gap a *functioning* venue
    /// produces: a long weekend plus a public holiday closes a European
    /// exchange for four or five days at Easter and Christmas, and a thinly
    /// traded listing can go a couple of sessions without a print. Past a full
    /// week, the venue is not pricing the instrument, and the difference
    /// between "quiet" and "abandoned" stops mattering — QDVE.F's
    /// `regularMarketPrice` has been frozen since June 2023.
    ///
    /// Anything inside the window is still published as `.dailyClose` carrying
    /// its own date, so the row says which session it belongs to rather than
    /// implying it is current.
    static let maximumPriceAge: TimeInterval = 7 * 24 * 3600

    private let session: URLSession
    private let baseURL = "https://query1.finance.yahoo.com/v8/finance/chart"
    private let now: @Sendable () -> Date

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func quote(for symbol: String) async throws -> Quote {
        guard let quote = try await fetchQuote(symbol) else {
            throw MarketDataError.noData
        }
        return quote
    }

    /// Concurrent per symbol, and a failure anywhere is simply an absent
    /// result. Yahoo has no batch endpoint worth trusting, and one dead exotic
    /// listing must not cost the others their price.
    func quotes(for symbols: [String]) async throws -> [Quote] {
        await withTaskGroup(of: Quote?.self) { group in
            for symbol in symbols {
                group.addTask { try? await fetchQuote(symbol) }
            }
            var results: [Quote] = []
            for await q in group { if let q { results.append(q) } }
            return results
        }
    }

    /// Twelve Data already provides search with currency and MIC, and this
    /// endpoint is not a search API.
    func search(_ query: String) async throws -> [AssetSearchResult] { [] }

    /// Not a history source. Step 7's charts must not silently come to depend
    /// on an endpoint with no contract.
    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        throw MarketDataError.noData
    }

    // MARK: - Network

    private func fetchQuote(_ symbol: String) async throws -> Quote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "\(baseURL)/\(encoded)?interval=1d&range=5d") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Yahoo answers 429 to an unadorned client. This is not evasion of a
        // rate limit — there is no key or quota to respect — it is the minimum
        // the endpoint requires to answer at all.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return Self.decodeQuote(data, symbol: symbol, now: now())
    }

    // MARK: - Decoding

    /// Nil for anything that is not a usable, recent price. Never throws: the
    /// caller must not be able to turn a Yahoo problem into a portfolio error.
    static func decodeQuote(_ data: Data, symbol: String, now: Date = Date()) -> Quote? {
        guard let envelope = try? JSONDecoder().decode(YahooChartResponse.self, from: data),
              let result = envelope.chart.result?.first
        else { return nil }

        let meta = result.meta

        // The price, and the timestamp that price actually belongs to.
        //
        // `regularMarketPrice` cannot be trusted on its own. On QDVE.F it reads
        // 20,31 with a `regularMarketTime` of June 2023 while the series close
        // is 44,56 — a listing that stopped updating its "current" field years
        // ago. Reading it blind halves the position. So the two candidates are
        // compared on their timestamps and the more recent one wins.
        let lastClose = result.lastClose
        let candidates: [(price: Double, time: TimeInterval)] = [
            meta.regularMarketPrice.flatMap { p in
                meta.regularMarketTime.map { (p, TimeInterval($0)) }
            },
            lastClose,
        ].compactMap { $0 }

        guard let best = candidates.max(by: { $0.time < $1.time }),
              best.price > 0,
              let price = Decimal(string: String(best.price))
        else { return nil }

        // Stale beyond the window: no price at all rather than a price from
        // another year wearing today's date.
        let priceDate = Date(timeIntervalSince1970: best.time)
        guard now.timeIntervalSince(priceDate) <= YahooChartProvider.maximumPriceAge else {
            return nil
        }

        // Currency from the response, and only from the venue when the response
        // omits it. Never a default — a wrong currency applies a wrong FX rate.
        guard let rawCurrency = meta.currency.flatMap({ $0.isEmpty ? nil : $0 })
                ?? MarketCalendar.yahooCurrency(forSuffixOf: symbol)
        else { return nil }
        let norm = CurrencyNormalization.normalize(rawCurrency)
        let normalizedPrice = price / norm.divisor

        let previous = (result.closeBeforeSession(of: best.time)
            .flatMap { Decimal(string: String($0)) }
            ?? meta.chartPreviousClose.flatMap { Decimal(string: String($0)) })
            .map { $0 / norm.divisor }

        return Quote(
            symbol: symbol,
            price: normalizedPrice,
            previousClose: previous,
            changeAbsolute: previous.map { normalizedPrice - $0 },
            changePercent: previous.flatMap { $0 == 0 ? nil : ((normalizedPrice - $0) / $0) * 100 },
            currency: norm.code,
            timestamp: Date(),
            source: .dailyClose,
            closeDate: priceDate
        )
    }
}

// MARK: - Wire format

nonisolated struct YahooChartResponse: Decodable {
    let chart: YahooChart
}

nonisolated struct YahooChart: Decodable {
    let result: [YahooChartResult]?
    /// Present and non-null when the symbol is unknown or delisted. Decoded so
    /// the shape is accounted for, not to be surfaced.
    let error: YahooChartError?
}

nonisolated struct YahooChartError: Decodable {
    let code: String?
    let description: String?
}

nonisolated struct YahooChartResult: Decodable {
    let meta: YahooChartMeta
    let timestamp: [Int]?
    let indicators: YahooChartIndicators?

    /// The most recent non-null close in the series, with the timestamp that
    /// belongs to it.
    ///
    /// Yahoo pads the arrays with nulls for sessions with no print, and the
    /// last slot is null more often than not on a thin venue — so this walks
    /// backwards to the last real value rather than taking `.last`.
    var lastClose: (price: Double, time: TimeInterval)? {
        guard let timestamp, let closes = indicators?.quote.first?.close else { return nil }
        for index in stride(from: min(timestamp.count, closes.count) - 1, through: 0, by: -1) {
            if let close = closes[index], close > 0 {
                return (close, TimeInterval(timestamp[index]))
            }
        }
        return nil
    }

    /// The last close on a session *earlier* than the one containing `time`.
    ///
    /// Compared by trading day in the venue's own offset, because the published
    /// price and that day's bar are the same session: Buenos Aires stamps the
    /// bar at the open (1786111200) and the live price six hours later
    /// (1786132787). Treating the bar as "previous" would report a day change
    /// of zero; the real previous close is the day before, 24 610.
    ///
    /// Nil when the series has no earlier session — Munich returns a single
    /// bar even at range=5d.
    func closeBeforeSession(of time: TimeInterval) -> Double? {
        guard let timestamp, let closes = indicators?.quote.first?.close else { return nil }
        let offset = TimeInterval(meta.gmtoffset ?? 0)
        let referenceDay = Self.tradingDay(time, offset: offset)

        var previous: Double?
        for index in 0..<min(timestamp.count, closes.count) {
            let day = Self.tradingDay(TimeInterval(timestamp[index]), offset: offset)
            guard day < referenceDay else { break }
            if let close = closes[index], close > 0 { previous = close }
        }
        return previous
    }

    /// Days since the epoch in the venue's local offset — enough to compare two
    /// stamps for "same session", without a calendar.
    private static func tradingDay(_ time: TimeInterval, offset: TimeInterval) -> Int {
        Int(floor((time + offset) / 86_400))
    }
}

nonisolated struct YahooChartIndicators: Decodable {
    let quote: [YahooChartQuote]
}

nonisolated struct YahooChartQuote: Decodable {
    let close: [Double?]?
}

nonisolated struct YahooChartMeta: Decodable {
    let currency: String?
    let symbol: String?
    let fullExchangeName: String?
    let regularMarketPrice: Double?
    let regularMarketTime: Int?
    /// The close before the chart's *range* begins, not before the last
    /// session — it changes with `range`, so it is only a fallback. See
    /// `closeBeforeSession(of:)`.
    let chartPreviousClose: Double?
    /// The venue's UTC offset, used to decide which bars share a trading day.
    let gmtoffset: Int?
}
