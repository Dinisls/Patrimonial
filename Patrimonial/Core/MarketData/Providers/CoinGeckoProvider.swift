import Foundation
import SwiftData

struct CoinGeckoProvider: MarketDataProvider {
    let supportsStreaming = false

    private let session: URLSession
    private let baseURL = "https://api.coingecko.com/api/v3"

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Quote via /simple/price

    func quote(for symbol: String) async throws -> Quote {
        let quotes = try await quotes(for: [symbol])
        guard let q = quotes.first else { throw MarketDataError.noData }
        return q
    }

    func quotes(for symbols: [String]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }

        let ids = symbols.joined(separator: ",")
        guard let url = URL(string: "\(baseURL)/simple/price?ids=\(ids)&vs_currencies=eur&include_24hr_change=true&include_last_updated_at=true") else {
            throw MarketDataError.invalidResponse
        }

        let data = try await fetchData(url)
        let decoded = try JSONDecoder().decode([String: CoinGeckoPriceEntry].self, from: data)

        return decoded.compactMap { id, entry in
            guard let price = entry.eur else { return nil }
            let priceDecimal = Decimal(string: String(price)) ?? Decimal(price)
            // Ponto N, the same shape as I: an absent 24 h change used to become
            // 0 %, which then derived a previous close identical to the price.
            // Absent stays absent, and the row shows no day change.
            let changePct = entry.eur_24h_change.map { Decimal(string: String($0)) ?? Decimal($0) }
            let prevClose = changePct.flatMap { pct -> Decimal? in
                let divisor = 1 + pct / 100
                // A 24 h move of −100 % would divide by zero; it also cannot
                // have happened to something still quoting a price.
                return divisor > 0 ? priceDecimal / divisor : nil
            }
            let changeAbs = prevClose.map { priceDecimal - $0 }

            return Quote(
                symbol: id,
                price: priceDecimal,
                previousClose: prevClose,
                changeAbsolute: changeAbs,
                changePercent: changePct,
                currency: "EUR",
                timestamp: entry.last_updated_at.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                source: .rest
            )
        }
    }

    // MARK: - Search (returns crypto results from /coins/list)

    func search(_ query: String) async throws -> [AssetSearchResult] {
        guard let url = URL(string: "\(baseURL)/search?query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)") else {
            return []
        }
        let data = try await fetchData(url)
        let decoded = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: data)
        return decoded.coins.prefix(10).map { coin in
            AssetSearchResult(
                symbol: coin.symbol.uppercased(),
                name: coin.name,
                exchange: "",
                assetClass: .crypto,
                currency: "EUR",
                coingeckoID: coin.id
            )
        }
    }

    // MARK: - Candles

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        try await dailyCandles(coinID: symbol, since: range.fromDate)
    }

    /// Daily points in EUR, straight from `market_chart`.
    ///
    /// The free tier gives closing prices, not OHLC, so open/high/low are all
    /// set to the close rather than invented. A candlestick drawn from a
    /// fabricated range would be a picture of data that does not exist; the
    /// chart draws a line for crypto, which is what this actually is.
    ///
    /// Crypto is quoted in EUR at source, so no FX conversion is involved here
    /// or anywhere downstream.
    func dailyCandles(coinID: String, since: Date) async throws -> [Candle] {
        let days = max(1, Int(Date().timeIntervalSince(since) / 86_400) + 1)
        guard let url = URL(string:
            "\(baseURL)/coins/\(coinID)/market_chart?vs_currency=eur&days=\(days)&interval=daily"
        ) else { throw MarketDataError.invalidResponse }

        let data = try await fetchData(url)
        return Self.decodeCandles(data)
    }

    static func decodeCandles(_ data: Data) -> [Candle] {
        guard let response = try? JSONDecoder().decode(CoinGeckoMarketChart.self, from: data) else {
            return []
        }
        return response.prices.compactMap { point -> Candle? in
            guard point.count >= 2, point[1] > 0 else { return nil }
            let price = Decimal(string: String(point[1])) ?? Decimal(point[1])
            // Milliseconds since the epoch.
            let date = Date(timeIntervalSince1970: point[0] / 1000)
            return Candle(
                date: date, open: price, high: price, low: price, close: price, volume: 0
            )
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: - Coins list for ID mapping

    func fetchCoinsList() async throws -> [CoinGeckoListItem] {
        guard let url = URL(string: "\(baseURL)/coins/markets?vs_currency=eur&order=market_cap_desc&per_page=250&page=1") else {
            throw MarketDataError.invalidResponse
        }
        let data = try await fetchData(url)
        return try JSONDecoder().decode([CoinGeckoListItem].self, from: data)
    }

    // MARK: - Network

    private func fetchData(_ url: URL) async throws -> Data {
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
        return data
    }
}

// MARK: - Response types

nonisolated struct CoinGeckoPriceEntry: Decodable, Sendable {
    let eur: Double?
    let eur_24h_change: Double?
    let last_updated_at: TimeInterval?
}

nonisolated struct CoinGeckoSearchResponse: Decodable, Sendable {
    let coins: [CoinGeckoSearchCoin]
}

nonisolated struct CoinGeckoSearchCoin: Decodable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let market_cap_rank: Int?
}

nonisolated struct CoinGeckoListItem: Decodable, Sendable {
    let id: String
    let symbol: String
    let name: String
    let market_cap_rank: Int?
}

// MARK: - Market chart wire format

/// `[[millisecondsSinceEpoch, price], …]` — CoinGecko returns bare pairs, not
/// objects, so the array shape is the schema.
nonisolated struct CoinGeckoMarketChart: Decodable {
    let prices: [[Double]]
}
