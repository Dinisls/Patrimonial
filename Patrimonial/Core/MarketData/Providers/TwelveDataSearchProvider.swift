import Foundation

/// Symbol lookup backed by Twelve Data's `symbol_search`.
///
/// Used instead of Finnhub's search because it is the only free source that
/// returns the **currency** and **MIC** of each listing. Finnhub's search
/// returns neither, which meant every equity was tagged USD and a EUR-quoted
/// Amsterdam line silently had a USD→EUR rate applied to its cost.
///
/// `symbol_search` needs no API key and does not consume the daily credit
/// budget, so it is safe to call on every keystroke (debounced upstream).
struct TwelveDataSearchProvider: SymbolSearchProvider {
    private let session: URLSession
    private let baseURL = "https://api.twelvedata.com"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(_ query: String) async throws -> [AssetSearchResult] {
        guard var comps = URLComponents(string: "\(baseURL)/symbol_search") else {
            throw MarketDataError.invalidResponse
        }
        comps.queryItems = [
            URLQueryItem(name: "symbol", value: query),
            URLQueryItem(name: "outputsize", value: "20")
        ]
        guard let url = comps.url else { throw MarketDataError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketDataError.httpError(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(TwelveDataSearchResponse.self, from: data)
            return decoded.data.compactMap { $0.toSearchResult() }
        } catch {
            throw MarketDataError.decodingFailed(error)
        }
    }
}

nonisolated struct TwelveDataSearchResponse: Decodable {
    let data: [TwelveDataSearchItem]
}

nonisolated struct TwelveDataSearchItem: Decodable {
    let symbol: String
    let instrument_name: String
    let exchange: String
    let mic_code: String?
    let instrument_type: String?
    let country: String?
    let currency: String?

    func toSearchResult() -> AssetSearchResult? {
        guard let currency, !currency.isEmpty else { return nil }
        let norm = CurrencyNormalization.normalize(currency)

        let assetClass: AssetClass
        switch (instrument_type ?? "").uppercased() {
        case "ETF": assetClass = .etf
        case "BOND": assetClass = .bond
        default: assetClass = .stock
        }

        return AssetSearchResult(
            symbol: symbol,
            name: instrument_name,
            exchange: exchange,
            assetClass: assetClass,
            currency: norm.code,
            mic: mic_code,
            instrumentType: instrument_type
        )
    }
}
