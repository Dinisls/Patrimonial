import Foundation
import Testing
import SwiftData
@testable import Patrimonial

struct TwelveDataProviderTests {

    // MARK: - Decoding

    /// A single symbol comes back as a flat object.
    @Test func decodesSingleQuote() throws {
        let json = """
        {"symbol":"NVDA","name":"NVIDIA Corporation","exchange":"NASDAQ","mic_code":"XNGS",
         "currency":"USD","timestamp":1785850200,"close":"211.84000","previous_close":"206.64000",
         "change":"5.20000","percent_change":"2.51645"}
        """
        let quotes = try TwelveDataProvider.decodeQuotes(Data(json.utf8), requested: ["NVDA"])
        let q = try #require(quotes.first)
        #expect(q.symbol == "NVDA")
        #expect(q.price == Decimal(string: "211.84000"))
        #expect(q.previousClose == Decimal(string: "206.64000"))
        #expect(q.currency == "USD")
    }

    /// Several symbols come back keyed by symbol — a different shape entirely.
    @Test func decodesBatchQuotesKeyedBySymbol() throws {
        let json = """
        {"AAPL":{"symbol":"AAPL","currency":"USD","timestamp":1785850200,"close":"309.39001","previous_close":"303.42001"},
         "GALP.LS":{"symbol":"GALP.LS","currency":"EUR","timestamp":1785850200,"close":"19.75","previous_close":"19.60"}}
        """
        let quotes = try TwelveDataProvider.decodeQuotes(Data(json.utf8), requested: ["AAPL", "GALP.LS"])
        #expect(quotes.count == 2)

        let galp = try #require(quotes.first { $0.symbol == "GALP.LS" })
        #expect(galp.currency == "EUR")
        #expect(galp.price == Decimal(string: "19.75"))
    }

    /// The whole point of moving off Finnhub: the listing's own currency, not a
    /// hardcoded USD.
    @Test func reportsNonUSDCurrency() throws {
        let json = """
        {"symbol":"IWDA.AS","currency":"EUR","timestamp":1785850200,"close":"105.42","previous_close":"105.00"}
        """
        let quotes = try TwelveDataProvider.decodeQuotes(Data(json.utf8), requested: ["IWDA.AS"])
        #expect(try #require(quotes.first).currency == "EUR")
    }

    /// A quote with no price must be dropped, not turned into 0,00 €.
    @Test func quoteWithoutPriceIsDropped() throws {
        let json = """
        {"symbol":"XXXX","currency":"EUR","timestamp":1785850200,"close":null,"previous_close":null}
        """
        let quotes = try TwelveDataProvider.decodeQuotes(Data(json.utf8), requested: ["XXXX"])
        #expect(quotes.isEmpty)
    }

    /// Symbols outside the free plan come back as per-symbol error objects in
    /// the same batch as the ones that worked. Losing the whole batch to one
    /// refusal is how NVDA silently disappeared alongside GALP.LS.
    @Test func partialBatchKeepsTheSymbolsThatWorked() throws {
        let json = """
        {"NVDA":{"symbol":"NVDA","currency":"USD","timestamp":1785850200,"close":"211.84","previous_close":"206.64"},
         "GALP.LS":{"code":404,"message":"**symbol** not found: GALP.LS.","status":"error"},
         "IWDA.AS":{"code":404,"message":"**symbol** not found: IWDA.AS.","status":"error"}}
        """
        let quotes = try TwelveDataProvider.decodeQuotes(
            Data(json.utf8), requested: ["NVDA", "GALP.LS", "IWDA.AS"]
        )
        #expect(quotes.count == 1)
        #expect(quotes.first?.symbol == "NVDA")
    }

    @Test func batchOfOnlyErrorsYieldsNoQuotes() throws {
        let json = """
        {"GALP.LS":{"code":404,"status":"error"},"IWDA.AS":{"code":404,"status":"error"}}
        """
        let quotes = try TwelveDataProvider.decodeQuotes(
            Data(json.utf8), requested: ["GALP.LS", "IWDA.AS"]
        )
        #expect(quotes.isEmpty)
    }

    @Test func malformedPayloadThrows() {
        let json = #"{"nonsense":true}"#
        #expect(throws: MarketDataError.self) {
            try TwelveDataProvider.decodeQuotes(Data(json.utf8), requested: ["NVDA"])
        }
    }

    // MARK: - Budget

    @Test func budgetRefusesBeyondPerMinuteLimit() async {
        let budget = TwelveDataBudget(requestsPerMinute: 2, creditsPerDay: 800)
        #expect(await budget.reserve(credits: 1) == true)
        #expect(await budget.reserve(credits: 1) == true)
        // Third request in the same minute.
        #expect(await budget.reserve(credits: 1) == false)
    }

    @Test func budgetRefusesBeyondDailyCredits() async {
        let budget = TwelveDataBudget(requestsPerMinute: 8, creditsPerDay: 5)
        #expect(await budget.reserve(credits: 4) == true)
        // Only one credit left, but two symbols asked for.
        #expect(await budget.reserve(credits: 2) == false)
    }

    /// A batch charges one credit per symbol, not one per request.
    @Test func batchChargesPerSymbol() async {
        let budget = TwelveDataBudget(requestsPerMinute: 8, creditsPerDay: 10)
        #expect(await budget.reserve(credits: 10) == true)
        #expect(await budget.reserve(credits: 1) == false)
    }

    @Test func missingKeyThrowsRatherThanCallingOut() async {
        let provider = TwelveDataProvider(apiKey: "", budget: TwelveDataBudget())
        await #expect(throws: MarketDataError.self) {
            try await provider.quotes(for: ["NVDA"])
        }
    }
}
