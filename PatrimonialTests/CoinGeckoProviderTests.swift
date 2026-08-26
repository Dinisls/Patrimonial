import Foundation
import Testing
import SwiftData
@testable import Patrimonial

struct CoinGeckoProviderTests {

    // MARK: - /simple/price decoding

    @Test func decodesSimplePrice() throws {
        let json = fixtureData("coingecko_simple_price")
        let decoded = try JSONDecoder().decode([String: CoinGeckoPriceEntry].self, from: json)

        #expect(decoded.count == 2)
        #expect(decoded["bitcoin"]?.eur == 62345.67)
        #expect(decoded["bitcoin"]?.eur_24h_change == 2.45)
        #expect(decoded["bitcoin"]?.last_updated_at == 1722700000)

        #expect(decoded["ethereum"]?.eur == 3456.78)
        #expect(decoded["ethereum"]?.eur_24h_change == -1.23)
    }

    @Test func quoteFromSimplePriceUsesDecimalPrecision() throws {
        let json = """
        {"bitcoin":{"eur":62345.67,"eur_24h_change":2.45,"last_updated_at":1722700000}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([String: CoinGeckoPriceEntry].self, from: json)
        let entry = decoded["bitcoin"]!

        let priceDecimal = Decimal(string: String(entry.eur!)) ?? Decimal(entry.eur!)
        #expect(priceDecimal == Decimal(string: "62345.67"))
    }

    @Test func previousCloseComputedFrom24hChange() throws {
        let json = """
        {"bitcoin":{"eur":102.0,"eur_24h_change":2.0,"last_updated_at":1722700000}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([String: CoinGeckoPriceEntry].self, from: json)
        let entry = decoded["bitcoin"]!

        let price = Decimal(string: String(entry.eur!))!
        let changePct = Decimal(string: String(entry.eur_24h_change!))!
        let prevClose = price / (1 + changePct / 100)

        #expect(prevClose == 100)
    }

    // MARK: - /coins/list decoding

    @Test func decodesCoinsList() throws {
        let json = fixtureData("coingecko_coins_list")
        let decoded = try JSONDecoder().decode([CoinGeckoListItem].self, from: json)

        #expect(decoded.count == 5)
        #expect(decoded[0].id == "bitcoin")
        #expect(decoded[0].symbol == "btc")
        #expect(decoded[0].market_cap_rank == 1)
    }

    // MARK: - Search decoding

    @Test func decodesSearchResponse() throws {
        let json = fixtureData("coingecko_search")
        let decoded = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: json)

        #expect(decoded.coins.count == 2)
        #expect(decoded.coins[0].id == "bitcoin")
        #expect(decoded.coins[0].symbol == "BTC")
        #expect(decoded.coins[1].id == "bitcoin-cash")
    }

    // MARK: - BTC → bitcoin mapping

    @Test func btcMapsToBitcoinByMarketCap() throws {
        let json = fixtureData("coingecko_coins_list")
        let coins = try JSONDecoder().decode([CoinGeckoListItem].self, from: json)

        var idMap: [String: String] = [:]
        var rankMap: [String: Int] = [:]

        for coin in coins {
            let sym = coin.symbol.lowercased()
            let rank = coin.market_cap_rank ?? Int.max
            if let existingRank = rankMap[sym] {
                if rank < existingRank {
                    idMap[sym] = coin.id
                    rankMap[sym] = rank
                }
            } else {
                idMap[sym] = coin.id
                rankMap[sym] = rank
            }
        }

        #expect(idMap["btc"] == "bitcoin")
        #expect(idMap["eth"] == "ethereum")
    }

    // MARK: - Ambiguous symbol resolved by market cap

    @Test func ambiguousSymbolResolvesToHigherMarketCap() throws {
        let json = fixtureData("coingecko_coins_list")
        let coins = try JSONDecoder().decode([CoinGeckoListItem].self, from: json)

        var idMap: [String: String] = [:]
        var rankMap: [String: Int] = [:]

        for coin in coins {
            let sym = coin.symbol.lowercased()
            let rank = coin.market_cap_rank ?? Int.max
            if let existingRank = rankMap[sym] {
                if rank < existingRank {
                    idMap[sym] = coin.id
                    rankMap[sym] = rank
                }
            } else {
                idMap[sym] = coin.id
                rankMap[sym] = rank
            }
        }

        // "sol" is shared by Solana (rank 5) and Solanium (rank 850)
        #expect(idMap["sol"] == "solana")
    }

    // MARK: - Routing: crypto does not call Finnhub, stock does not call CoinGecko

    @MainActor
    @Test func cryptoRoutesToCoinGeckoNotFinnhub() async throws {
        let stockProvider = TrackingMarketDataProvider(name: "stock")
        let cryptoProvider = TrackingMarketDataProvider(name: "crypto")

        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = ModelContext(container)

        let store = PriceStore(provider: stockProvider, cryptoProvider: cryptoProvider)
        store.configure(provider: stockProvider, cryptoProvider: cryptoProvider, modelContext: ctx)
        store.registerCoinID(symbol: "BTC", coinID: "bitcoin")

        await store.refresh([ListingID(symbol: "BTC")])

        #expect(cryptoProvider.quoteCallCount > 0)
        #expect(stockProvider.quoteCallCount == 0)
    }

    @MainActor
    @Test func stockRoutesToFinnhubNotCoinGecko() async throws {
        let stockProvider = TrackingMarketDataProvider(name: "stock")
        let cryptoProvider = TrackingMarketDataProvider(name: "crypto")

        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = ModelContext(container)

        let store = PriceStore(provider: stockProvider, cryptoProvider: cryptoProvider)
        store.configure(provider: stockProvider, cryptoProvider: cryptoProvider, modelContext: ctx)

        await store.refresh([ListingID(symbol: "AAPL")])

        #expect(stockProvider.quoteCallCount > 0)
        #expect(cryptoProvider.quoteCallCount == 0)
    }

    // MARK: - Precision: 0.00374 BTC retains 8 decimal places

    @Test func fractionalCryptoPrecision() {
        let qty = Decimal(string: "0.00374000")!
        let price = Decimal(string: "62345.67")!
        let total = qty * price
        let expected = Decimal(string: "233.17280580")!

        #expect(total == expected)

        // Verify the quantity survives round-trip through NSDecimalNumber
        let ns = qty as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        let formatted = formatter.string(from: ns)!

        #expect(formatted == "0,00374")
    }

    @Test func eightDecimalPlacesPreserved() {
        let qty = Decimal(string: "0.00000001")!
        let ns = qty as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        let formatted = formatter.string(from: ns)!

        #expect(formatted == "0,00000001")
    }

    // MARK: - Crypto always open: polling not gated by time

    @Test func cryptoAlwaysOpen() {
        #expect(MarketCalendar.isOpen(.crypto) == true)

        // Even at midnight UTC
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 4 // Sunday
        comps.hour = 3
        comps.minute = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let sundayNight = cal.date(from: comps)!
        #expect(MarketCalendar.isOpen(.crypto, at: sundayNight) == true)
    }

    @Test func cryptoPollingInterval15s() {
        #expect(MarketCalendar.pollingInterval(for: .crypto) == 15)
    }

    // MARK: - Search returns AssetClass for crypto

    @Test func searchResultsShowCryptoClass() throws {
        let json = fixtureData("coingecko_search")
        let decoded = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: json)

        let results = decoded.coins.map { coin in
            AssetSearchResult(
                symbol: coin.symbol.uppercased(),
                name: coin.name,
                exchange: "",
                assetClass: .crypto,
                currency: "EUR",
                coingeckoID: coin.id
            )
        }

        #expect(results[0].assetClass == .crypto)
        #expect(results[0].coingeckoID == "bitcoin")
        #expect(results[0].currency == "EUR")
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }
}

// Used to locate the test bundle
private class BundleMarker {}

// Tracking provider for routing tests
final class TrackingMarketDataProvider: MarketDataProvider, @unchecked Sendable {
    let supportsStreaming = false
    let name: String
    private(set) var quoteCallCount = 0
    private(set) var searchCallCount = 0

    init(name: String = "tracking") {
        self.name = name
    }

    func quote(for symbol: String) async throws -> Quote {
        quoteCallCount += 1
        return MockMarketDataProvider.defaultQuote(symbol: symbol)
    }

    func quotes(for symbols: [String]) async throws -> [Quote] {
        quoteCallCount += 1
        return symbols.map { MockMarketDataProvider.defaultQuote(symbol: $0) }
    }

    func search(_ query: String) async throws -> [AssetSearchResult] {
        searchCallCount += 1
        return []
    }

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] { [] }
}
