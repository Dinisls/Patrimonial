import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - A. The FX chain, through the code the app actually runs

/// Rates without the network, so the chain is deterministic but genuine.
private struct StubFXProvider: FXRateProvider {
    let rate: Decimal
    /// Every call the view model made, so a test can prove the direction that
    /// was *asked for*, not only the number that came back.
    final class Calls: @unchecked Sendable {
        var pairs: [(from: String, to: String)] = []
    }
    let calls = Calls()

    func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
        calls.pairs.append((from, to))
        // Labelled with the direction it was *asked* for, exactly as a real
        // provider does. That is what lets the view model catch a request that
        // went out the wrong way round instead of accepting the number.
        guard let answer = FXRate(from: from, to: to, value: rate) else {
            throw FXError.currencyNotFound(to)
        }
        return answer
    }
}

/// The existing FX tests inject the rate straight into the view model with
/// `setCurrentFXRateForTesting`, so they assert `Holding.marketValueEUR` and
/// nothing else. They pass whether or not `refreshCurrentFXRates` works, which
/// is the half that talks to a provider, writes `FXRateCache` and re-runs
/// `loadHoldings`. These drive that half.
@MainActor
struct CurrentFXRefreshChainTests {

    private func setUp(_ ctx: ModelContext, fx: StubFXProvider) throws -> (PortfolioViewModel, PriceStore) {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: fx)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 2, unitPrice: 181,
            fxRate: Decimal(string: "0.86")!, commission: 0,
            account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
                assetClass: .stock, currency: "USD", mic: "XNGS"
            )
        )
        store.applyQuote(Quote(
            symbol: "NVDA", price: Decimal(string: "223.96")!,
            previousClose: Decimal(string: "218.99")!, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
        ), as: ListingID(symbol: "NVDA", mic: "XNGS"))
        vm.loadHoldings()
        return (vm, store)
    }

    /// The whole path in one assertion: a USD quote lands, the refresh asks the
    /// provider for USD→EUR, and the holding ends up in euros. 223,96 × 0,86693
    /// is 194,16 per share — below the dollar figure, which is what "converted"
    /// looks like when the euro is the stronger currency.
    @Test func refreshFetchesTheRateAndConvertsIntoEUR() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let fx = StubFXProvider(rate: Decimal(string: "0.86693")!)
        let (vm, _) = try setUp(ctx, fx: fx)

        // Before the refresh there is no rate, so there is no value — a dash,
        // never the dollar figure wearing a euro sign.
        #expect(vm.openHoldings.first?.marketValueEUR == nil)
        #expect(vm.hasMissingFXRates)

        await vm.refreshCurrentFXRates()

        // Direction, at the source: native → EUR, matching the rate stored on
        // the purchase. Inverting this is the failure mode that keeps coming
        // back, and it is invisible if you only assert the product.
        #expect(fx.calls.pairs.count == 1)
        #expect(fx.calls.pairs.first?.from == "USD")
        #expect(fx.calls.pairs.first?.to == "EUR")

        // The stored entry carries its direction, so this asserts the whole
        // claim — the value *and* which way it converts — instead of a number
        // that would look identical if it had been fetched backwards.
        #expect(vm.currentFXRates["USD"]
                == FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.86693")!))

        let holding = try #require(vm.openHoldings.first)
        let mv = try #require(holding.marketValueEUR)
        // 2 × 223,96 × 0,86693 = 388,32.
        #expect(mv > Decimal(string: "388.30")! && mv < Decimal(string: "388.34")!)
        // Strictly under the unconverted 447,92, which is what the bug produced.
        #expect(mv < Decimal(string: "447.92")!)
        #expect(!vm.hasMissingFXRates)
    }

    /// The rate is cached per day in `FXRateCache`, so a second refresh must not
    /// spend another request.
    @Test func rateIsFetchedOncePerDay() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let fx = StubFXProvider(rate: Decimal(string: "0.86693")!)
        let (vm, _) = try setUp(ctx, fx: fx)

        await vm.refreshCurrentFXRates()
        await vm.refreshCurrentFXRates()

        #expect(fx.calls.pairs.count == 1)
        let cached = try ctx.fetch(FetchDescriptor<FXRateCache>())
        #expect(cached.count == 1)
        #expect(cached.first?.fromCurrency == "USD")
        #expect(cached.first?.toCurrency == "EUR")
    }
}

// MARK: - C. One quote per listing, not per ticker

@MainActor
struct SearchListingPricingTests {

    private func makeStore(_ ctx: ModelContext, european: MockMarketDataProvider? = nil) -> PriceStore {
        let store = PriceStore()
        var us = MockMarketDataProvider()
        us.answersOnlyKnownSymbols = true
        us.mockQuotes = [
            "AAPL": Quote(
                symbol: "AAPL", price: Decimal(string: "313.33")!,
                previousClose: Decimal(string: "312.41")!, changeAbsolute: 0,
                changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
            )
        ]
        var fallback = MockMarketDataProvider()
        fallback.answersOnlyKnownSymbols = true
        store.configure(
            provider: us,
            fallbackProvider: fallback,
            cryptoProvider: fallback,
            europeanProvider: european,
            modelContext: ctx
        )
        return store
    }

    private let appleListings = [
        AssetSearchResult(symbol: "AAPL", name: "Apple Inc.", exchange: "NASDAQ",
                          assetClass: .stock, currency: "USD", mic: "XNGS"),
        AssetSearchResult(symbol: "AAPL", name: "Apple Inc. CEDEAR", exchange: "BCBA",
                          assetClass: .stock, currency: "ARS", mic: "XBUE"),
        AssetSearchResult(symbol: "AAPL", name: "Apple Inc.", exchange: "BVC",
                          assetClass: .stock, currency: "COP", mic: "XBOG"),
    ]

    /// The bug, pinned. All three rows showed 313,33 — the NASDAQ close — even
    /// though the second is a CEDEAR in Argentine pesos and the third trades in
    /// Colombian pesos. Same ticker, three different instruments. Only the
    /// listing we can actually price gets a number.
    @Test func onlyTheQuotedVenueIsPriced() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = makeStore(container.mainContext)

        let priced = await store.quotesForSearch(appleListings)

        let nasdaq = try #require(priced[appleListings[0].id])
        #expect(nasdaq.price == Decimal(string: "313.33")!)
        #expect(nasdaq.currency == "USD")

        // No provider here reaches Buenos Aires or Bogotá, so those rows have
        // no price rather than someone else's.
        #expect(priced[appleListings[1].id] == nil)
        #expect(priced[appleListings[2].id] == nil)
    }

    /// A European ETF is routed to Alpha Vantage with the venue's suffix. The
    /// search path used to decide "European" from the symbol suffix, which a
    /// search result does not carry — `QDVE` read as NYSE, this branch never
    /// ran, and the row fell through to Finnhub's zero.
    @Test func europeanListingsReachTheAlphaVantageFallback() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var av = MockMarketDataProvider()
        av.answersOnlyKnownSymbols = true
        av.mockQuotes = [
            "QDVE.DE": Quote(
                symbol: "QDVE.DE", price: Decimal(string: "44.795")!,
                previousClose: Decimal(string: "44.49")!, changeAbsolute: 0,
                changePercent: 0, currency: "EUR", timestamp: Date(),
                source: .dailyClose, closeDate: Date()
            )
        ]
        let store = makeStore(container.mainContext, european: av)

        let xetr = AssetSearchResult(
            symbol: "QDVE", name: "iShares S&P 500 IT UCITS ETF", exchange: "XETR",
            assetClass: .etf, currency: "EUR", mic: "XETR"
        )
        // Frankfurt is a separate venue with its own price; Alpha Vantage's
        // `.DE` is the XETRA listing, so this row stays unpriced rather than
        // borrowing it.
        let xfra = AssetSearchResult(
            symbol: "QDVE", name: "iShares S&P 500 IT UCITS ETF", exchange: "FSX",
            assetClass: .etf, currency: "EUR", mic: "XFRA"
        )

        let priced = await store.quotesForSearch([xetr, xfra])

        let quote = try #require(priced[xetr.id])
        #expect(quote.price == Decimal(string: "44.795")!)
        #expect(quote.currency == "EUR")
        #expect(priced[xfra.id] == nil)
    }

    /// Never 0,00. Finnhub answers 200 with an all-zero body for the European
    /// listings its free plan does not cover, and that zero used to be published
    /// as a price *and* mark the symbol covered, so Alpha Vantage was skipped.
    @Test func aZeroPriceIsNoPrice() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var us = MockMarketDataProvider()
        us.answersOnlyKnownSymbols = true
        us.mockQuotes = [
            "AAPL": Quote(
                symbol: "AAPL", price: 0, previousClose: 0, changeAbsolute: 0,
                changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
            )
        ]
        var empty = MockMarketDataProvider()
        empty.answersOnlyKnownSymbols = true
        let store = PriceStore()
        store.configure(provider: us, fallbackProvider: empty,
                        cryptoProvider: empty, modelContext: container.mainContext)

        let priced = await store.quotesForSearch([appleListings[0]])

        #expect(priced[appleListings[0].id] == nil)
        #expect(store.quote(for: ListingID(symbol: "AAPL")) == nil)
    }
}
