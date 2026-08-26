import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// London and Milan: the venues the search offered and nothing could price.
///
/// Every fixture here was captured live on 2026-08-14 through `URLSession`, the
/// same client the app uses, and is stored verbatim. The three payloads are the
/// argument of this file in one line:
///
/// - `3GOL.MI` → 136,81 **EUR** (Milan) — the position that was showing a dash;
/// - `3GOL.L`  → 158,47 **USD** (LSE);
/// - `VOD.L`   → 121,55 **GBp** (LSE).
///
/// The last two are the same venue in two different currencies. That is why no
/// table in this app may say "the LSE trades in pence".
struct LondonMilanRoutingTests {

    private let now = Date(timeIntervalSince1970: 1786727712)  // capture time

    private func decode(_ fixture: String, symbol: String) throws -> Quote {
        let bundle = Bundle(for: LondonBundleToken.self)
        guard let url = bundle.url(forResource: fixture, withExtension: "json") else {
            struct FixtureNotFound: Error { let name: String }
            throw FixtureNotFound(name: fixture)
        }
        let data = try Data(contentsOf: url)
        return try #require(YahooChartProvider.decodeQuote(data, symbol: symbol, now: now))
    }

    // MARK: - The payloads

    /// The user's position. Milan, euros, no sub-unit anywhere.
    @Test func milanAnswersInEuros() throws {
        let quote = try decode("yahoo_3gol_mi", symbol: "3GOL.MI")
        #expect(quote.price == Decimal(string: "136.81")!)
        #expect(quote.currency == "EUR")
        #expect(quote.source == .dailyClose)
    }

    /// The London line of the *same* ETP, in dollars — not pence, and not the
    /// Milan price either. 3GOL's pence line on the LSE is a different ticker
    /// (`3LGO`, around 10 950 GBp), which is exactly why the venue cannot be
    /// asked what the unit is.
    @Test func londonAnswersInDollarsForThisLine() throws {
        let quote = try decode("yahoo_3gol_l", symbol: "3GOL.L")
        #expect(quote.price == Decimal(string: "158.47")!)
        #expect(quote.currency == "USD")
    }

    /// And the pence line on the very same venue, divided by 100 at the
    /// boundary: 121,55 GBp is 1,2155 GBP.
    @Test func londonAnswersInPenceForThatLine() throws {
        let quote = try decode("yahoo_vod_l", symbol: "VOD.L")
        #expect(quote.price == Decimal(string: "1.2155")!)
        #expect(quote.currency == "GBP")
        // The previous close travels the same divisor, or the day change comes
        // out 100× and the position looks like it collapsed. It is the bar
        // before in the series — 120,15 — not meta's `chartPreviousClose` of
        // 120,50, which at `range=5d` is the close before the window. 120,15 is
        // also exactly what Alpha Vantage answered for `VOD.LON` on the same
        // session, which is the two providers agreeing on the scale.
        // Verbatim from the wire, float precision and all — the series carries
        // 120,1500015258789 — because the assertion is about the *scale*, and
        // rounding it here would hide a divisor that had gone missing.
        #expect(quote.previousClose == Decimal(string: "1.201500015258789")!)
    }

    /// The property, stated over the pair rather than as two examples: one
    /// venue, two lines, two currencies, and the app must take each line's word
    /// for it. A table keyed on the venue gets exactly one of these right.
    @Test func theSameVenueQuotesInTwoCurrencies() throws {
        let dollars = try decode("yahoo_3gol_l", symbol: "3GOL.L")
        let pence = try decode("yahoo_vod_l", symbol: "VOD.L")
        #expect(dollars.currency != pence.currency)
        // And nothing in the routing tables claims a currency for the LSE.
        #expect(MarketCalendar.yahooVenue(for: "XLON")?.currency == nil)
        #expect(MarketCalendar.yahooCurrency(forSuffixOf: "3GOL.L") == nil)
    }

    // MARK: - Routing

    @Test func londonAndMilanHaveASymbol() {
        #expect(MarketCalendar.yahooSymbol("3GOL", mic: "XMIL") == "3GOL.MI")
        #expect(MarketCalendar.yahooSymbol("3GOL", mic: "MTAA") == "3GOL.MI")
        #expect(MarketCalendar.yahooSymbol("3GOL", mic: "XLON") == "3GOL.L")
        #expect(MarketCalendar.yahooSymbol("QQQ3", mic: "XLON") == "QQQ3.L")
        // Already-suffixed symbols are not suffixed twice.
        #expect(MarketCalendar.yahooSymbol("3GOL.MI", mic: "XMIL") == "3GOL.MI")
    }

    /// The invite and the capability, as one function.
    @Test func onlyVenuesWithARouteAreOfferedAsPriceable() {
        for mic in ["XMIL", "MTAA", "XLON", "XNGS", "XETR", "XLIS", "XBUE", "XFRA"] {
            #expect(MarketCalendar.hasQuoteRoute(mic: mic), "\(mic) is routable")
        }
        // Lima is deliberately unmapped (a dead Yahoo endpoint), Sydney was
        // never mapped at all, and a row with no venue cannot be placed.
        for mic in ["XLIM", "XASX", "", nil] {
            #expect(!MarketCalendar.hasQuoteRoute(mic: mic), "\(mic ?? "nil") has no route")
        }
    }

    /// The row the user sees before buying says so.
    @MainActor
    @Test func aSearchRowWithoutARouteSaysSoBeforeThePurchase() {
        let milan = AssetSearchResult(symbol: "3GOL", name: "WisdomTree Gold 3x Daily Leveraged",
                                      exchange: "MTA", assetClass: .etf, currency: "EUR", mic: "XMIL")
        let lima = AssetSearchResult(symbol: "CVERDEC1", name: "Cerro Verde",
                                     exchange: "BVL", assetClass: .stock, currency: "PEN", mic: "XLIM")
        let bitcoin = AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "",
                                        assetClass: .crypto, currency: "EUR", coingeckoID: "bitcoin")

        func row(_ r: AssetSearchResult) -> AssetSearchResultRow {
            AssetSearchResultRow(result: r, quote: nil, freshness: nil, isPricing: false)
        }
        #expect(!row(milan).hasNoQuoteRoute, "Milan is priceable now")
        #expect(row(lima).hasNoQuoteRoute, "Lima has no provider and must say so")
        // Crypto is routed by coin id, not by venue, and has no MIC at all.
        #expect(!row(bitcoin).hasNoQuoteRoute)
    }

    // MARK: - Through the store, which is what the portfolio reads

    /// Not the decoder: `PriceStore.refresh`, the path a held position takes.
    /// The 3GOL dash was never a decoding problem — the request was never made,
    /// because no table could build the symbol.
    /// Returns the container alongside the store on purpose: a helper that lets
    /// the `ModelContainer` go out of scope leaves the context dangling and
    /// takes the whole test host down at 0,000 s, in every suite at once.
    @MainActor
    private func storeServing(_ quotes: [String: Quote]) throws -> (PriceStore, ModelContainer) {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PriceStore()
        var us = MockMarketDataProvider()
        us.answersOnlyKnownSymbols = true
        var lastResort = MockMarketDataProvider()
        lastResort.answersOnlyKnownSymbols = true
        lastResort.mockQuotes = quotes
        store.configure(
            provider: us,
            fallbackProvider: us,
            cryptoProvider: us,
            lastResortProvider: lastResort,
            modelContext: container.mainContext
        )
        return (store, container)
    }

    @MainActor
    @Test func aMilanPositionGetsAPriceThroughTheStore() async throws {
        let listing = ListingID(symbol: "3GOL", mic: "XMIL")
        let (store, container) = try storeServing([
            "3GOL.MI": Quote(symbol: "3GOL.MI", price: Decimal(string: "136.81")!,
                             previousClose: Decimal(string: "133.97")!, changeAbsolute: nil,
                             changePercent: nil, currency: "EUR", timestamp: Date(),
                             source: .dailyClose, closeDate: Date())
        ])
        store.register(listing, currency: "EUR")

        await store.refresh([listing])

        let quote = try #require(store.quote(for: listing))
        #expect(quote.price == Decimal(string: "136.81")!)
        #expect(quote.currency == "EUR")
        _ = container
    }

    /// London through the same path, with the sub-unit already divided — the
    /// store must file 1,2155 GBP, not 121,55 of anything.
    @MainActor
    @Test func aLondonPenceListingIsStoredInPounds() async throws {
        let listing = ListingID(symbol: "VOD", mic: "XLON")
        let (store, container) = try storeServing([
            // What `YahooChartProvider` hands over after normalization.
            "VOD.L": Quote(symbol: "VOD.L", price: Decimal(string: "1.2155")!,
                           previousClose: Decimal(string: "1.205")!, changeAbsolute: nil,
                           changePercent: nil, currency: "GBP", timestamp: Date(),
                           source: .dailyClose, closeDate: Date())
        ])
        store.register(listing, currency: "GBP")

        await store.refresh([listing])

        let quote = try #require(store.quote(for: listing))
        #expect(quote.price == Decimal(string: "1.2155")!)
        #expect(quote.currency == "GBP")
        _ = container
    }
}

private class LondonBundleToken {}

// MARK: - The sub-unit through the currency conversion

/// The user's second requirement, spelled out: pence divided in the price *and*
/// in the euro conversion. The division happens once, at the parsing boundary,
/// and everything downstream multiplies by a GBP rate — so the test is that the
/// euro value is built from 1,2155 and never from 121,55.
private struct PenceFXStub: FXRateProvider {
    func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
        // Deliberately far from 1 and far from its own inverse: at 1 the
        // division and the multiplication are indistinguishable.
        guard from == "GBP", to == "EUR",
              let rate = FXRate(from: from, to: to, value: Decimal(string: "1.15")!)
        else { throw FXError.currencyNotFound(to) }
        return rate
    }
}

@MainActor
struct LondonSubUnitConversionTests {

    @Test func penceIsDividedInThePriceAndInTheEuroValue() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = Account(name: "Corretora", type: .brokerage)
        ctx.insert(account)

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: PenceFXStub())

        try vm.addInvestment(
            type: .assetPurchase, symbol: "VOD", quantity: 100,
            unitPrice: Decimal(string: "1.10")!,
            fxRate: Decimal(string: "1.15")!, commission: 0,
            account: account, date: Date(), note: "",
            asset: AssetSearchResult(symbol: "VOD", name: "Vodafone Group",
                                     exchange: "LSE", assetClass: .stock,
                                     currency: "GBP", mic: "XLON")
        )
        // The quote as it leaves the provider: already in pounds.
        store.applyQuote(
            Quote(symbol: "VOD", price: Decimal(string: "1.2155")!,
                  previousClose: Decimal(string: "1.205")!, changeAbsolute: nil,
                  changePercent: nil, currency: "GBP", timestamp: Date(),
                  source: .dailyClose, closeDate: Date()),
            as: ListingID(symbol: "VOD", mic: "XLON")
        )
        vm.loadHoldings()
        await vm.refreshCurrentFXRates()

        let holding = try #require(vm.openHoldings.first)
        // 100 × 1,2155 × 1,15 = 139,7825 €. In pence it would have been
        // 13 978,25 € — a hundredfold position, and the kind of number that
        // looks plausible on its own.
        let value = try #require(holding.marketValueEUR)
        #expect(value == Decimal(string: "139.7825")!)
        #expect(value < 1000, "a pence-scaled value would be 13 978,25 €")
    }
}
