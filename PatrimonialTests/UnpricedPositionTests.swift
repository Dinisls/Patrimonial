import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - The rule: no quote means a dash, never 0,00 €

/// Agreed at Step 4 and broken by QDVE: a position with no usable price showed
/// 0,00 € and −100,00 %, counted as zero in the portfolio total, and did not
/// light the "sem cotação" warning — because as far as the code was concerned
/// it *had* a price. These pin the rule at every level it can be broken, so the
/// next provider that answers with a zero cannot resurrect it.
@MainActor
struct UnpricedPositionTests {

    private func setUp(_ ctx: ModelContext) throws -> (PortfolioViewModel, PriceStore) {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "QDVE", quantity: 5, unitPrice: 40,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "QDVE", name: "iShares S&P 500 IT UCITS ETF",
                exchange: "XETR", assetClass: .etf, currency: "EUR", mic: "XETR"
            )
        )
        return (vm, store)
    }

    private func zeroQuote(_ symbol: String, currency: String = "USD") -> Quote {
        Quote(
            symbol: symbol, price: 0, previousClose: 0, changeAbsolute: 0,
            changePercent: 0, currency: currency, timestamp: Date(), source: .rest
        )
    }

    /// The invariant, at the level that decides what the row renders.
    @Test func aZeroPriceIsNotAValuation() {
        var holding = Holding(
            assetSymbol: "QDVE", accountID: "a", accountName: "Corretora",
            quantity: 5, totalCostEUR: 200, averagePriceEUR: 40,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        holding.currentPriceNative = 0
        holding.currency = "EUR"
        holding.currentFXRate = FXRate.identity("EUR")

        #expect(holding.marketValueEUR == nil)
        #expect(holding.unrealizedPL == nil)
        // −100,00 % was the visible symptom. It has to be absent, not merely
        // different.
        #expect(holding.unrealizedPLPercent == nil)
    }

    /// The position stays out of the total rather than counting as zero. A
    /// portfolio that cannot be fully valued reports no total at all — a partial
    /// sum presented as the whole is the same lie in a quieter form.
    @Test func anUnpricedPositionKeepsItselfOutOfTheTotals() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, store) = try setUp(ctx)

        store.applyQuote(zeroQuote("QDVE"), as: ListingID(symbol: "QDVE"))
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first { $0.assetSymbol == "QDVE" })
        #expect(holding.marketValueEUR == nil)
        #expect(holding.unrealizedPLPercent == nil)
        #expect(vm.totalMarketValue == nil)
        #expect(vm.totalUnrealizedPL == nil)
        // And the user is told why the value is missing.
        #expect(vm.hasMissingQuotes)
    }

    /// `applyQuote` is the one door every provider comes through, so it is where
    /// a zero has to die — otherwise it reaches the SwiftData cache and comes
    /// back on the next launch.
    @Test func applyQuoteRefusesAZeroPrice() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: container.mainContext)

        store.applyQuote(zeroQuote("QDVE"), as: ListingID(symbol: "QDVE"))

        #expect(store.quote(for: ListingID(symbol: "QDVE")) == nil)
        let cached = try container.mainContext.fetch(FetchDescriptor<PriceSnapshot>())
        #expect(cached.isEmpty)
    }

    /// The residue. Zero-priced snapshots written by the old Finnhub path are
    /// still on disk on any device that ran it, and hydration used to load them
    /// back every launch — which is why the fix to the provider did not fix the
    /// position. They are purged, not merely skipped.
    @Test func hydrationPurgesZeroPricedSnapshots() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        ctx.insert(PriceSnapshot(quote: zeroQuote("QDVE"), listing: ListingID(symbol: "QDVE")))
        ctx.insert(PriceSnapshot(quote: Quote(
            symbol: "NVDA", price: Decimal(string: "223.96")!,
            previousClose: Decimal(string: "218.99")!, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
        ), listing: ListingID(symbol: "NVDA")))
        try ctx.save()

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        store.hydrateFromCache()

        #expect(store.quote(for: ListingID(symbol: "QDVE")) == nil)
        #expect(store.quote(for: ListingID(symbol: "NVDA"))?.price == Decimal(string: "223.96")!)

        let remaining = try ctx.fetch(FetchDescriptor<PriceSnapshot>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.symbol == "NVDA")
    }
}

// MARK: - The portfolio routes by recorded MIC, not by ticker suffix

@MainActor
struct PortfolioVenueRoutingTests {

    /// The cause of the QDVE outage. `MarketCalendar.isEuropean` reads a suffix,
    /// and a held position carries the bare ticker the search returned — so
    /// `QDVE` resolved to NYSE, the Alpha Vantage fallback was never reached,
    /// and the only thing left was Finnhub's zero. Search had already been moved
    /// onto the MIC; the portfolio had not.
    @Test func aHeldEuropeanPositionReachesAlphaVantage() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
        refuses.mockQuotes = [:]
        let european = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: european, modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "QDVE", mic: "XETR"), currency: "EUR")

        await store.refresh([ListingID(symbol: "QDVE", mic: "XETR")])

        // The venue's suffix is appended for the provider, and only for it.
        #expect(european.received == ["QDVE.DE"])
    }

    /// The reply comes back as `QDVE.DE` but the position is held as `QDVE`.
    /// Filing it under the provider's symbol leaves the position looking
    /// unpriced next to a quote nothing reads, and the currency must be the
    /// venue's EUR, never the USD a US-only provider would have assumed.
    @Test func theQuoteIsFiledUnderTheHeldSymbolInTheVenueCurrency() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
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

        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: av, modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "QDVE", mic: "XETR"), currency: "EUR")

        await store.refresh([ListingID(symbol: "QDVE", mic: "XETR")])

        let quote = try #require(store.quote(for: ListingID(symbol: "QDVE", mic: "XETR")))
        #expect(quote.price == Decimal(string: "44.795")!)
        #expect(quote.currency == "EUR")
        #expect(store.quote(for: ListingID(symbol: "QDVE.DE")) == nil)
    }

    /// End to end: 5 QDVE at 40 € is 200 € of cost, and 5 × 44,795 is 223,98 €
    /// of value — a modest gain, not −100 %. No FX rate is fetched or needed:
    /// a euro asset converts by 1.
    @Test func theEuroETFIsValuedInEuros() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        var refuses = MockMarketDataProvider()
        refuses.answersOnlyKnownSymbols = true
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
        let store = PriceStore()
        store.configure(
            provider: refuses, fallbackProvider: refuses,
            europeanProvider: av, modelContext: ctx
        )

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "QDVE", quantity: 5, unitPrice: 40,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "QDVE", name: "iShares S&P 500 IT UCITS ETF",
                exchange: "XETR", assetClass: .etf, currency: "EUR", mic: "XETR"
            )
        )

        await store.refresh([ListingID(symbol: "QDVE", mic: "XETR")])
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first { $0.assetSymbol == "QDVE" })
        #expect(holding.currency == "EUR")
        #expect(holding.currentFXRate == FXRate.identity("EUR"))
        let mv = try #require(holding.marketValueEUR)
        #expect(mv == Decimal(string: "223.975")!)
        let pct = try #require(holding.unrealizedPLPercent)
        #expect(pct > 11 && pct < 13)
        #expect(!vm.hasMissingQuotes)
        #expect(!vm.hasMissingFXRates)
    }

    /// The MIC is recorded at purchase, from the listing the user picked — the
    /// routing has no other honest source.
    @Test func theChosenListingIsRecordedOnTheAsset() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "QDVE", quantity: 5, unitPrice: 40,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "QDVE", name: "iShares S&P 500 IT UCITS ETF",
                exchange: "XETR", assetClass: .etf, currency: "EUR", mic: "XETR"
            )
        )

        let asset = try #require(try ctx.fetch(FetchDescriptor<Asset>()).first)
        #expect(asset.exchange == "XETR")
        #expect(asset.currency == "EUR")

        // And it is live in the store immediately, not only after a relaunch.
        let listing = try #require(store.listing(for: ListingID(symbol: "QDVE", mic: "XETR")))
        #expect(listing.mic == "XETR")
        #expect(listing.currency == "EUR")
    }
}

// MARK: - The header total is partial, and says so

/// The dash was correct but unhelpful: one unpriced ETF hid 388 € of NVDA. The
/// total now covers the priced positions and declares what it leaves out — a
/// partial figure is fine, an unlabelled one is not.
@MainActor
struct PartialTotalTests {

    private func holding(_ symbol: String, cost: Decimal, price: Decimal?) -> Holding {
        var h = Holding(
            assetSymbol: symbol, accountID: "a", accountName: "Corretora",
            quantity: 2, totalCostEUR: cost, averagePriceEUR: cost / 2,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        h.currentPriceNative = price
        h.currency = "EUR"
        h.currentFXRate = price == nil ? nil : FXRate.identity("EUR")
        return h
    }

    @Test func theTotalCoversThePricedPositionsAndCountsTheRest() {
        let total = PortfolioCalculator.marketValueTotal([
            holding("NVDA", cost: 311, price: 194.16),
            holding("QDVE", cost: 200, price: nil),
        ])

        let t = try! #require(total)
        #expect(t.value == Decimal(string: "388.32")!)
        #expect(t.isPartial)
        #expect(t.pricedCount == 1)
        #expect(t.excludedCount == 1)
    }

    /// P/L is measured against the cost of the *same* positions. Dividing a
    /// partial value by the full cost would report −24 % on a portfolio that is
    /// up 25 %.
    @Test func profitIsMeasuredAgainstTheCostOfThePricedPositionsOnly() {
        let t = try! #require(PortfolioCalculator.marketValueTotal([
            holding("NVDA", cost: 311, price: 194.16),
            holding("QDVE", cost: 200, price: nil),
        ]))

        #expect(t.costOfPriced == 311)
        #expect(t.unrealizedPL == Decimal(string: "77.32")!)
        let pct = try! #require(t.unrealizedPLPercent)
        #expect(pct > 24 && pct < 25)
    }

    /// Nothing priced at all: no partial total exists, so the header falls back
    /// to the dash.
    @Test func nothingPricedMeansNoTotal() {
        #expect(PortfolioCalculator.marketValueTotal([
            holding("QDVE", cost: 200, price: nil)
        ]) == nil)
    }

    /// Fully priced: not partial, and identical to the strict total.
    @Test func aFullyPricedPortfolioIsNotPartial() {
        let holdings = [
            holding("NVDA", cost: 311, price: 194.16),
            holding("GALP", cost: 200, price: 110),
        ]
        let t = try! #require(PortfolioCalculator.marketValueTotal(holdings))
        #expect(!t.isPartial)
        #expect(t.excludedCount == 0)
        #expect(t.value == PortfolioCalculator.totalMarketValue(holdings))
    }

    /// End to end through the view model, which is what the header reads.
    @Test func theViewModelReportsThePartialTotalAndTheExclusion() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 2, unitPrice: 181,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: acc,
            date: Date(), note: "",
            asset: AssetSearchResult(symbol: "NVDA", name: "NVIDIA", exchange: "XNGS",
                                     assetClass: .stock, currency: "USD", mic: "XNGS")
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "QDVE", quantity: 5, unitPrice: 40,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(symbol: "QDVE", name: "iShares", exchange: "XETR",
                                     assetClass: .etf, currency: "EUR", mic: "XETR")
        )

        store.applyQuote(Quote(
            symbol: "NVDA", price: Decimal(string: "223.96")!,
            previousClose: Decimal(string: "218.99")!, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
        ), as: ListingID(symbol: "NVDA", mic: "XNGS"))
        vm.setCurrentFXRateForTesting(
            FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.86693")!)!
        )

        let total = try #require(vm.marketValueTotal)
        // The NVDA position is visible instead of being hidden by QDVE.
        #expect(total.value > Decimal(string: "388.30")! && total.value < Decimal(string: "388.34")!)
        #expect(total.isPartial)
        #expect(vm.unpricedPositionCount == 1)
        #expect(vm.hasMissingQuotes)
    }
}
