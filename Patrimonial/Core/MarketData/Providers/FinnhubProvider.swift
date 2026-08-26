import Foundation

struct FinnhubProvider: MarketDataProvider {
    let supportsStreaming = true

    private let apiKey: String
    private let session: URLSession
    private let baseURL = "https://finnhub.io/api/v1"

    init(apiKey: String = AppConfig.finnhubAPIKey, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Quote

    func quote(for symbol: String) async throws -> Quote {
        let url = URL(string: "\(baseURL)/quote?symbol=\(symbol)&token=\(apiKey)")!
        let response: FinnhubQuoteResponse = try await fetch(url)
        // Finnhub answers 200 with an all-zero body for symbols it does not
        // cover — QDVE comes back as {"c":0,"pc":0,…}. Publishing that put a
        // 0,00 on screen and, worse, marked the symbol as covered so the
        // Alpha Vantage European fallback was never tried. No price is an
        // error, not a zero.
        guard let quote = response.toQuote(symbol: symbol) else {
            throw MarketDataError.noData
        }
        return quote
    }

    /// One dead symbol must not take the batch down with it: the task group
    /// collects what resolved and lets `PriceStore` route the rest to the next
    /// provider.
    func quotes(for symbols: [String]) async throws -> [Quote] {
        await withTaskGroup(of: Quote?.self) { group in
            for symbol in symbols {
                group.addTask { try? await quote(for: symbol) }
            }
            var results: [Quote] = []
            for await q in group { if let q { results.append(q) } }
            return results
        }
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [AssetSearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "\(baseURL)/search?q=\(encoded)&token=\(apiKey)")!
        let response: FinnhubSearchResponse = try await fetch(url)
        return response.result.compactMap { $0.toSearchResult() }
    }

    // MARK: - Candles

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        let from = Int(range.fromDate.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let resolution = range.finnhubResolution
        let url = URL(string: "\(baseURL)/stock/candle?symbol=\(symbol)&resolution=\(resolution)&from=\(from)&to=\(to)&token=\(apiKey)")!
        let response: FinnhubCandleResponse = try await fetch(url)
        return response.toCandles()
    }

    // MARK: - Network

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw MarketDataError.rateLimited
            }
            throw MarketDataError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MarketDataError.decodingFailed(error)
        }
    }
}

// MARK: - Errors

enum MarketDataError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case rateLimited
    case decodingFailed(Error)
    case noData
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Resposta inválida do servidor"
        case .httpError(let code): "Erro HTTP \(code)"
        case .rateLimited: "Limite de pedidos excedido"
        case .decodingFailed: "Erro ao processar dados"
        case .noData: "Sem dados disponíveis"
        case .missingAPIKey: "Chave de API em falta"
        }
    }
}

// MARK: - Finnhub Response Types

nonisolated struct FinnhubQuoteResponse: Decodable {
    let c: Decimal?   // current price
    let d: Decimal?   // change
    let dp: Decimal?  // percent change
    let h: Decimal?   // high
    let l: Decimal?   // low
    let o: Decimal?   // open
    let pc: Decimal?  // previous close
    let t: TimeInterval? // timestamp

    /// Nil when Finnhub reports no usable price. A traded instrument is never
    /// worth zero, so `c` of 0 means "not covered", not "free".
    func toQuote(symbol: String) -> Quote? {
        guard let c, c > 0 else { return nil }
        return Quote(
            symbol: symbol,
            price: c,
            // Ponto I: `?? c` used to close this, making "Finnhub sent no
            // previous close" and "the instrument closed exactly here
            // yesterday" the same value. A zero `pc` is already treated as
            // absent for the same reason a zero price is.
            previousClose: pc.flatMap { $0 > 0 ? $0 : nil },
            changeAbsolute: d,
            changePercent: dp,
            // Finnhub's `/quote` reports no currency. It was hardcoded to
            // "USD", which is the same mistake its `/search` was corrected for
            // and which survived here for months because the guess is right
            // often enough to look like a fact.
            //
            // Empty means unknown, and unknown is answered by the recorded
            // listing in `PriceStore.rekeyed`. Where nothing is recorded — a
            // position bought before venues were stored — the position now
            // shows a dash instead of a dollar price that may not be dollars.
            // That is the rule: absence never becomes a value.
            currency: "",
            timestamp: t.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            source: .rest
        )
    }
}

nonisolated struct FinnhubSearchResponse: Decodable {
    let count: Int
    let result: [FinnhubSearchItem]
}

nonisolated struct FinnhubSearchItem: Decodable {
    let description: String
    let displaySymbol: String
    let symbol: String
    let type: String

    func toSearchResult() -> AssetSearchResult? {
        let assetClass: AssetClass
        switch type.uppercased() {
        case "Common Stock", "COMMON STOCK", "EQS": assetClass = .stock
        case "ETF", "ETP": assetClass = .etf
        case "Crypto", "CRYPTO": assetClass = .crypto
        default: assetClass = .stock
        }
        // Finnhub's /search returns no currency. It used to be hardcoded to USD,
        // which silently applied a USD→EUR rate to EUR-quoted European listings
        // and distorted their cost. Report it as unknown instead — the sheet
        // then asks rather than guesses.
        return AssetSearchResult(
            symbol: displaySymbol,
            name: description,
            exchange: extractExchange(from: symbol),
            assetClass: assetClass,
            currency: ""
        )
    }

    private func extractExchange(from symbol: String) -> String {
        if symbol.contains(":") {
            return String(symbol.split(separator: ":").first ?? "")
        }
        return ""
    }
}

nonisolated struct FinnhubCandleResponse: Decodable {
    let c: [Decimal]?  // close
    let h: [Decimal]?  // high
    let l: [Decimal]?  // low
    let o: [Decimal]?  // open
    let v: [Int]?      // volume
    let t: [TimeInterval]? // timestamps
    let s: String?     // status

    func toCandles() -> [Candle] {
        guard let closes = c, let highs = h, let lows = l,
              let opens = o, let volumes = v, let timestamps = t,
              s == "ok" else {
            return []
        }
        let count = min(closes.count, timestamps.count)
        return (0..<count).map { i in
            Candle(
                date: Date(timeIntervalSince1970: timestamps[i]),
                open: opens[i],
                high: highs[i],
                low: lows[i],
                close: closes[i],
                volume: volumes[i]
            )
        }
    }
}
