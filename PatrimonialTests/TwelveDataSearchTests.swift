import Testing
import Foundation
@testable import Patrimonial

struct TwelveDataSearchTests {

    /// Real shape of a `symbol_search` response for IWDA — the same ticker on
    /// two venues in two currencies.
    private let iwdaJSON = """
    {"data":[
      {"symbol":"IWDA","instrument_name":"iShares Core MSCI World UCITS ETF USD (Acc)","exchange":"LSE","mic_code":"XLON","exchange_timezone":"Europe/London","instrument_type":"ETF","country":"United Kingdom","currency":"USD"},
      {"symbol":"IWDA","instrument_name":"iShares Core MSCI World UCITS ETF USD (Acc)","exchange":"Euronext","mic_code":"XAMS","exchange_timezone":"Europe/Amsterdam","instrument_type":"ETF","country":"Netherlands","currency":"EUR"}
    ]}
    """

    private func decode(_ json: String) throws -> [AssetSearchResult] {
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(TwelveDataSearchResponse.self, from: data)
        return response.data.compactMap { $0.toSearchResult() }
    }

    @Test func decodesCurrencyAndMIC() throws {
        let results = try decode(iwdaJSON)
        #expect(results.count == 2)

        let amsterdam = try #require(results.first { $0.mic == "XAMS" })
        #expect(amsterdam.currency == "EUR")
        #expect(amsterdam.assetClass == .etf)

        let london = try #require(results.first { $0.mic == "XLON" })
        #expect(london.currency == "USD")
    }

    /// The two IWDA lines must be separately selectable. When `id` was just the
    /// symbol, SwiftUI collapsed them and the user could not pick the venue.
    @Test func sameTickerOnTwoVenuesHasDistinctIDs() throws {
        let results = try decode(iwdaJSON)
        let ids = Set(results.map(\.id))
        #expect(ids.count == results.count)
    }

    /// A listing with no currency cannot be converted to EUR safely, so it is
    /// dropped rather than defaulted.
    @Test func listingWithoutCurrencyIsDropped() throws {
        let json = """
        {"data":[
          {"symbol":"XXXX","instrument_name":"No Currency Ltd","exchange":"Euronext","mic_code":"XAMS","instrument_type":"Common Stock","country":"Netherlands","currency":null}
        ]}
        """
        #expect(try decode(json).isEmpty)
    }

    @Test func emptyResponseDecodes() throws {
        #expect(try decode(#"{"data":[]}"#).isEmpty)
    }

    /// London penny stocks report GBp (pence); the search result must show GBP
    /// so downstream FX and portfolio math use the right unit.
    @Test func penceIsNormalisedToPounds() throws {
        let json = """
        {"data":[
          {"symbol":"BTC","instrument_name":"Vinanz Ltd.","exchange":"LSE","mic_code":"XLON","instrument_type":"Common Stock","country":"United Kingdom","currency":"GBp"}
        ]}
        """
        let result = try #require(try decode(json).first)
        #expect(result.currency == "GBP")
    }

    @Test func currencyNormalizationDividesPrice() {
        let norm = CurrencyNormalization.normalize("GBp")
        #expect(norm.code == "GBP")
        #expect(norm.divisor == 100)
        let price: Decimal = 160
        #expect(price / norm.divisor == Decimal(string: "1.6"))
    }

    @Test func ordinaryCurrencyIsUntouched() {
        let norm = CurrencyNormalization.normalize("USD")
        #expect(norm.code == "USD")
        #expect(norm.divisor == 1)
    }

    /// Finnhub's search reports no currency at all; it must not claim USD.
    @Test func finnhubSearchDoesNotClaimUSD() throws {
        let item = FinnhubSearchItem(
            description: "iShares Core MSCI World",
            displaySymbol: "IWDA.AS",
            symbol: "IWDA.AS",
            type: "ETF"
        )
        let result = try #require(item.toSearchResult())
        #expect(result.currency.isEmpty)
    }
}
