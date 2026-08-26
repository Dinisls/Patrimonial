import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Ponto E: the recorded currency may only be imposed on a confirmed venue

/// The recorded currency exists to protect: a provider's currency field is a
/// report and some of them are simply wrong, so the listing the user actually
/// picked wins. That is right *after* the price has been confirmed to come from
/// that listing, and an amplifier before it — the ordering that turned NVD's
/// 3,97 USD into 3,97 EUR at a rate of 1.
///
/// Ponto F closed that for listings with a recorded MIC. These cover the ones
/// without: the venue check has nothing to compare, so a disagreeing currency is
/// the only evidence left that the reply is about something else.
@MainActor
struct RecordedCurrencyTests {

    private func quote(
        _ symbol: String, price: Decimal, currency: String, mic: String? = nil
    ) -> Quote {
        var q = Quote(
            symbol: symbol, price: price, previousClose: price,
            changeAbsolute: 0, changePercent: 0, currency: currency,
            timestamp: Date(), source: .rest
        )
        q.venueMIC = mic
        return q
    }

    private func makeStore(
        _ ctx: ModelContext, primary: MockMarketDataProvider
    ) -> PriceStore {
        let store = PriceStore()
        var fallback = MockMarketDataProvider()
        fallback.answersOnlyKnownSymbols = true
        store.configure(provider: primary, fallbackProvider: fallback, modelContext: ctx)
        return store
    }

    /// The hole ponto F left open. A venueless listing recorded as EUR, and a US
    /// provider answering in dollars about whatever it thinks the ticker is.
    ///
    /// The reply is refused. The position keeps its dash, which is a visible
    /// absence the user can act on, instead of a dollar figure wearing a euro
    /// sign — which is not.
    @Test func aDollarReplyIsRefusedForAListingRecordedInEuros() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.mockQuotes = ["NVD": quote("NVD", price: Decimal(string: "3.97")!, currency: "USD")]
        let store = makeStore(container.mainContext, primary: primary)

        let listing = ListingID(symbol: "NVD")
        store.register(listing, currency: "EUR")
        await store.refresh([listing])

        #expect(
            store.quote(for: listing) == nil,
            "publicou um preço em dólares como se fosse a listagem em euros"
        )
    }

    /// The same reply, with the venue confirmed. Here the recorded currency is
    /// the fact and the provider's label is the doubtful field — Finnhub used to
    /// stamp everything USD — so the price is kept and relabelled.
    @Test func aConfirmedVenueLetsTheRecordedCurrencyWin() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.mockQuotes = [
            "QDVE": quote("QDVE", price: Decimal(string: "38.42")!, currency: "USD", mic: "XNGS")
        ]
        let store = makeStore(container.mainContext, primary: primary)

        // Recorded on a US venue, in euros — unusual but not contradictory, and
        // the point is that the venue is what settles it.
        let listing = ListingID(symbol: "QDVE", mic: "XNGS")
        store.register(listing, currency: "EUR")
        await store.refresh([listing])

        let published = try #require(store.quote(for: listing))
        #expect(published.price == Decimal(string: "38.42")!)
        #expect(published.currency == "EUR")
    }

    /// Silence is not a contradiction. Finnhub reports no currency at all, and
    /// refusing those would leave every position it serves without a price.
    @Test func aReplyWithNoCurrencyIsNotARefusal() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.mockQuotes = ["AAPL": quote("AAPL", price: 224, currency: "")]
        let store = makeStore(container.mainContext, primary: primary)

        let listing = ListingID(symbol: "AAPL")
        store.register(listing, currency: "USD")
        await store.refresh([listing])

        #expect(store.quote(for: listing)?.price == 224)
    }

    /// And agreement passes untouched, so the guard is not simply refusing
    /// everything it is shown.
    @Test func anAgreeingCurrencyPasses() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.mockQuotes = ["AAPL": quote("AAPL", price: 224, currency: "USD")]
        let store = makeStore(container.mainContext, primary: primary)

        let listing = ListingID(symbol: "AAPL")
        store.register(listing, currency: "USD")
        await store.refresh([listing])

        #expect(store.quote(for: listing)?.price == 224)
    }

    /// The consequence at the layer the user reads.
    ///
    /// Built the way the case actually arises: a position from before the venue
    /// was stored, so the `Asset` has a currency and no MIC, and the routing
    /// table is loaded by `hydrateFromCache` at launch rather than by a purchase.
    /// A refused quote must leave the position unpriced and the screen must say
    /// a position is missing a price, not quietly total up the rest as though it
    /// were everything.
    @Test func theScreenShowsADashAndSaysThePositionIsUnpriced() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Investimentos", type: .brokerage)
        ctx.insert(acc)

        // No exchange: this is what a position bought before the venue was
        // stored looks like, and it is the whole point — with a MIC the venue
        // check already covers it.
        let asset = Asset(
            symbol: "NVD", name: "NVIDIA", assetClass: .stock,
            exchange: "", currency: "EUR"
        )
        ctx.insert(asset)

        let buy = FinancialTransaction(
            type: .assetPurchase, amount: 194, date: Date(),
            note: "Compra NVD", category: .investments, sourceAccount: acc
        )
        buy.assetSymbol = "NVD"
        buy.assetQuantity = 1
        buy.assetUnitPrice = 194
        buy.assetFXRate = 1
        ctx.insert(buy)
        try ctx.save()

        var primary = MockMarketDataProvider()
        primary.mockQuotes = ["NVD": quote("NVD", price: Decimal(string: "3.97")!, currency: "USD")]
        let store = makeStore(ctx, primary: primary)
        store.hydrateFromCache()

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: MockFXRateProvider())
        await store.refresh([ListingID(symbol: "NVD")])
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first)
        #expect(holding.marketValueEUR == nil)
        #expect(vm.hasMissingQuotes)
    }
}
