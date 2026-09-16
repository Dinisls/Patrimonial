import Foundation

/// Fetches quotes through the Cloudflare Worker proxy instead of hitting
/// providers directly. API keys live server-side; the app carries only the
/// proxy URL and a shared secret.
struct ProxyMarketDataProvider: MarketDataProvider {
    let supportsStreaming = false

    private let baseURL: String
    private let appSecret: String
    private let session: URLSession

    init(
        baseURL: String,
        appSecret: String = AppConfig.proxySecret,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.appSecret = appSecret
        self.session = session
    }

    // MARK: - Quotes

    func quote(for symbol: String) async throws -> Quote {
        let quotes = try await quotes(for: [symbol])
        guard let q = quotes.first else { throw MarketDataError.noData }
        return q
    }

    func quotes(for symbols: [String]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        let url = "\(baseURL)?action=quotes&symbols=\(symbols.joined(separator: ","))"
        let data = try await request(url)
        let response = try JSONDecoder().decode(ProxyQuotesResponse.self, from: data)
        return response.quotes.compactMap { $0.toQuote() }
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [AssetSearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let url = "\(baseURL)?action=search&q=\(encoded)"
        let data = try await request(url)
        let response = try JSONDecoder().decode(ProxySearchResponse.self, from: data)
        return response.results.map { $0.toSearchResult() }
    }

    // MARK: - Candles (not proxied — stays local)

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        throw MarketDataError.noData
    }

    // MARK: - HTTP

    private func request(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw MarketDataError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !appSecret.isEmpty {
            req.setValue(appSecret, forHTTPHeaderField: "X-App-Secret")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        if http.statusCode == 429 { throw MarketDataError.rateLimited }
        guard (200...299).contains(http.statusCode) else {
            throw MarketDataError.httpError(http.statusCode)
        }
        return data
    }
}

// MARK: - Response types

private struct ProxyQuotesResponse: Decodable {
    let quotes: [ProxyQuote]
}

private struct ProxyQuote: Decodable {
    let symbol: String
    let price: Double
    let previousClose: Double?
    let changeAbsolute: Double?
    let changePercent: Double?
    let currency: String
    let timestamp: String
    let source: String
    let venueMIC: String?

    func toQuote() -> Quote? {
        guard price > 0 else { return nil }
        let ts = ISO8601DateFormatter().date(from: timestamp) ?? Date()
        let src: QuoteSource = source == "dailyClose" ? .dailyClose : .rest
        return Quote(
            symbol: symbol,
            price: Decimal(price),
            previousClose: previousClose.map { Decimal($0) },
            changeAbsolute: changeAbsolute.map { Decimal($0) },
            changePercent: changePercent.map { Decimal($0) },
            currency: currency,
            timestamp: ts,
            source: src,
            venueMIC: venueMIC
        )
    }
}

private struct ProxySearchResponse: Decodable {
    let results: [ProxySearchResult]
}

private struct ProxySearchResult: Decodable {
    let symbol: String
    let name: String
    let exchange: String?
    let mic: String?
    let currency: String?
    let type: String?

    func toSearchResult() -> AssetSearchResult {
        let assetClass: AssetClass = switch type?.lowercased() {
        case "etf": .etf
        case "bond": .bond
        default: .stock
        }
        return AssetSearchResult(
            symbol: symbol,
            name: name,
            exchange: exchange ?? "",
            assetClass: assetClass,
            currency: currency ?? "USD",
            mic: mic,
            instrumentType: type
        )
    }
}
