import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Step 8: allocation, watchlist, evolution

/// The four rules agreed for Step 8, each pinned at the level it can be broken:
/// percentages that add up, an allocation that refuses to draw over a hole, a
/// watchlist that stays out of the totals, and a chart that will not draw a
/// trend from a single point.
@MainActor
struct AllocationWatchlistEvolutionTests {

    // MARK: - Fixtures

    private func priced(
        _ symbol: String,
        account: String = "Corretora",
        quantity: Decimal,
        price: Decimal,
        fx: Decimal = 1,
        currency: String = "EUR",
        assetClass: AssetClass = .stock
    ) -> Holding {
        var h = Holding(
            assetSymbol: symbol,
            accountID: account,
            accountName: account,
            quantity: quantity,
            totalCostEUR: quantity * price * fx,
            averagePriceEUR: price * fx,
            commissions: 0,
            realizedPL: 0,
            dividendsReceived: 0
        )
        h.currentPriceNative = price
        h.currency = currency
        h.currentFXRate = FXRate(from: currency, to: "EUR", value: fx)
        h.assetClass = assetClass
        return h
    }

    private func unpriced(_ symbol: String, quantity: Decimal = 3) -> Holding {
        var h = Holding(
            assetSymbol: symbol,
            accountID: "Corretora",
            accountName: "Corretora",
            quantity: quantity,
            totalCostEUR: 300,
            averagePriceEUR: 100,
            commissions: 0,
            realizedPL: 0,
            dividendsReceived: 0
        )
        h.currency = "EUR"
        h.assetClass = .etf
        // No price at all — the case the ring must refuse to draw over.
        return h
    }

    // MARK: - Percentages sum to 100

    /// The whole point of using the strict total: every slice is a share of one
    /// number, so the shares add up. Checked on all three dimensions, because
    /// each buckets by a different key and each could drop a holding.
    @Test func percentagesSumTo100InEveryDimension() {
        let holdings = [
            priced("NVDA", account: "IBKR", quantity: 2, price: 100, fx: Decimal(string: "0.86")!,
                   currency: "USD", assetClass: .stock),
            priced("IWDA", account: "DEGIRO", quantity: 10, price: 90, currency: "EUR", assetClass: .etf),
            priced("BTC", account: "IBKR", quantity: 1, price: 50000, currency: "EUR", assetClass: .crypto),
        ]

        for dimension in PortfolioAllocation.Dimension.allCases {
            guard case .slices(let slices) = PortfolioAllocation.allocation(dimension, holdings: holdings)
            else {
                Issue.record("\(dimension.rawValue) devia produzir fatias")
                continue
            }
            let total = slices.reduce(Decimal(0)) { $0 + $1.percent }
            // Within Decimal's precision, not bit-exact: a third of a whole is
            // not representable, and the fix for that would be to hand the
            // rounding remainder to one arbitrary slice — making that slice
            // wrong so the column would add up. The invariant that actually
            // matters is that nothing is dropped, which
            // `slicesCoverTheWholeMarketValue` pins exactly.
            let drift = total > 100 ? total - 100 : 100 - total
            #expect(drift < Decimal(string: "0.0000001")!,
                    "\(dimension.rawValue) somou \(total)%")
        }
    }

    /// Slices are also a partition of the value, not just of the percentages —
    /// a holding silently dropped from a bucket would still let the remaining
    /// percentages sum to 100 if the total were computed from the buckets.
    @Test func slicesCoverTheWholeMarketValue() {
        let holdings = [
            priced("NVDA", quantity: 2, price: 100),
            priced("IWDA", quantity: 10, price: 90),
        ]
        guard case .slices(let slices) =
                PortfolioAllocation.allocation(.account, holdings: holdings) else {
            Issue.record("esperava fatias")
            return
        }
        let summed = slices.reduce(Decimal(0)) { $0 + $1.value }
        #expect(summed == PortfolioCalculator.totalMarketValue(holdings))
        #expect(summed == 1100)
    }

    /// Two currencies, two accounts, two classes — each dimension has to split
    /// the same money differently rather than always returning one slice.
    @Test func dimensionsBucketByTheirOwnKey() {
        let holdings = [
            priced("NVDA", account: "IBKR", quantity: 1, price: 100, currency: "USD", assetClass: .stock),
            priced("IWDA", account: "DEGIRO", quantity: 1, price: 100, currency: "EUR", assetClass: .etf),
        ]

        guard case .slices(let byClass) =
                PortfolioAllocation.allocation(.assetClass, holdings: holdings),
              case .slices(let byCurrency) =
                PortfolioAllocation.allocation(.currency, holdings: holdings),
              case .slices(let byAccount) =
                PortfolioAllocation.allocation(.account, holdings: holdings)
        else {
            Issue.record("esperava fatias em todas as dimensões")
            return
        }

        #expect(Set(byClass.map(\.label)) == ["Ações", "ETF"])
        #expect(Set(byCurrency.map(\.label)) == ["USD", "EUR"])
        #expect(Set(byAccount.map(\.label)) == ["IBKR", "DEGIRO"])
        #expect(byClass.allSatisfy { $0.percent == 50 })
    }

    // MARK: - An unpriced position blocks the ring

    /// The rule that separates allocation from the header: the header may show
    /// a partial total with a caveat, allocation may not show partial slices at
    /// all. A ring reads as the whole, so a hole in it is a wrong number rather
    /// than an incomplete one.
    @Test func unpricedPositionBlocksAllocationAndIsNamed() {
        let holdings = [
            priced("NVDA", quantity: 2, price: 100),
            unpriced("QDVE"),
        ]

        for dimension in PortfolioAllocation.Dimension.allCases {
            let result = PortfolioAllocation.allocation(dimension, holdings: holdings)
            guard case .unpriced(let symbols) = result else {
                Issue.record("\(dimension.rawValue) desenhou fatias com uma posição sem cotação")
                continue
            }
            // Named, not counted: the screen says which ticker is missing.
            #expect(symbols == ["QDVE"])
        }
    }

    /// The header still shows its partial total in the same situation. The two
    /// rules are deliberately different, and this is what keeps someone from
    /// "fixing" the inconsistency by loosening the stricter one.
    @Test func headerStaysPartialWhileAllocationRefuses() {
        let holdings = [priced("NVDA", quantity: 2, price: 100), unpriced("QDVE")]

        let header = PortfolioCalculator.marketValueTotal(holdings)
        #expect(header?.value == 200)
        #expect(header?.isPartial == true)
        #expect(header?.excludedCount == 1)

        guard case .unpriced = PortfolioAllocation.allocation(.assetClass, holdings: holdings) else {
            Issue.record("a alocação não devia desenhar")
            return
        }
    }

    /// A holding from before the venue was recorded has no class. It is labelled
    /// as unclassified rather than folded into "Ações", which would be a guess
    /// dressed as a fact.
    @Test func holdingWithoutClassIsLabelledNotGuessed() {
        var mystery = priced("OLD", quantity: 1, price: 100)
        mystery.assetClass = nil

        guard case .slices(let slices) =
                PortfolioAllocation.allocation(.assetClass, holdings: [mystery]) else {
            Issue.record("esperava fatias")
            return
        }
        #expect(slices.map(\.label) == [PortfolioAllocation.unknownLabel])
    }

    /// Closed positions are not allocation. Zero quantity means the money is no
    /// longer there, whatever the price says.
    @Test func closedPositionsAreExcluded() {
        var closed = priced("SOLD", quantity: 0, price: 100)
        closed.currentPriceNative = 100
        let holdings = [priced("NVDA", quantity: 2, price: 100), closed]

        guard case .slices(let slices) =
                PortfolioAllocation.allocation(.assetClass, holdings: holdings) else {
            Issue.record("esperava fatias")
            return
        }
        #expect(slices.count == 1)
        #expect(slices[0].value == 200)
    }

    @Test func noHoldingsIsEmptyNotZero() {
        #expect(PortfolioAllocation.allocation(.assetClass, holdings: []) == .empty)
    }

    // MARK: - Watchlist stays out of the totals

    /// A followed ticker is something the user is looking at, not something
    /// they own. It must not reach the portfolio value, the cost, or the
    /// allocation — otherwise adding one invents a holding.
    @Test func watchlistEntryDoesNotEnterPortfolioTotals() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let portfolio = PortfolioViewModel()
        portfolio.bind(modelContext: ctx, priceStore: store)
        try portfolio.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 2, unitPrice: 100,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
                assetClass: .stock, currency: "EUR", mic: "XNAS"
            )
        )

        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)
        try watchlist.add(AssetSearchResult(
            symbol: "TSLA", name: "Tesla", exchange: "XNAS",
            assetClass: .stock, currency: "EUR", mic: "XNAS"
        ))

        // Both priced, deliberately. A watchlist symbol that cannot be valued
        // would stay out of the totals by accident; this proves it stays out
        // even when the app knows exactly what it is worth.
        for symbol in ["NVDA", "TSLA"] {
            store.applyQuote(Quote(
                symbol: symbol, price: 120, previousClose: 118, changeAbsolute: 2,
                changePercent: Decimal(string: "1.69")!, currency: "EUR",
                timestamp: Date(), source: .rest
            ), as: ListingID(symbol: symbol, mic: "XNAS"))
        }
        portfolio.loadHoldings()

        // The watchlist row exists…
        #expect(watchlist.listings.map(\.symbol) == ["TSLA"])
        // …and the portfolio has never heard of it.
        #expect(portfolio.openHoldings.map(\.assetSymbol) == ["NVDA"])
        #expect(portfolio.totalCost == 200)
        // 2 × 120, and not a cent of Tesla.
        #expect(portfolio.marketValueTotal?.value == 240)

        guard case .slices(let slices) = portfolio.allocation else {
            Issue.record("esperava fatias")
            return
        }
        #expect(slices.count == 1)
        #expect(slices[0].value == 240)
        #expect(slices[0].percent == 100)
    }

    /// A watchlist entry always carries its venue and its currency. "TSLA"
    /// alone cannot be routed to a provider, and a row that can never be priced
    /// is a permanent dash pretending to be a feature.
    @Test func watchlistRefusesAListingWithoutVenueOrCurrency() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)

        #expect(throws: WatchlistViewModel.AddError.self) {
            try watchlist.add(AssetSearchResult(
                symbol: "TSLA", name: "Tesla", exchange: "",
                assetClass: .stock, currency: "USD", mic: nil
            ))
        }
        #expect(throws: WatchlistViewModel.AddError.self) {
            try watchlist.add(AssetSearchResult(
                symbol: "TSLA", name: "Tesla", exchange: "XNAS",
                assetClass: .stock, currency: "", mic: "XNAS"
            ))
        }
        #expect(watchlist.entries.isEmpty)
    }

    /// Stored the way a position is: MIC and currency, so the same quote
    /// routing applies to both.
    @Test func watchlistStoresMICAndCurrency() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)
        try watchlist.add(AssetSearchResult(
            symbol: "IWDA", name: "iShares Core MSCI World", exchange: "Euronext",
            assetClass: .etf, currency: "EUR", mic: "XAMS"
        ))

        let entry = try #require(watchlist.entries.first)
        #expect(entry.exchange == "XAMS")
        #expect(entry.currency == "EUR")
        #expect(entry.isWatchlisted)
        // Registered with the price store too, so it is routed by listing and
        // not by a ticker guess.
        #expect(store.listing(for: ListingID(symbol: "IWDA", mic: "XAMS"))?.mic == "XAMS")
        #expect(store.listing(for: ListingID(symbol: "IWDA", mic: "XAMS"))?.currency == "EUR")
    }

    /// Buying a followed ticker does not unfollow it; the entry drops out of
    /// the list because it is now a position, and comes back if it stops being
    /// one.
    @Test func buyingAFollowedTickerFiltersItRatherThanDeletingIt() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)
        try watchlist.add(AssetSearchResult(
            symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
            assetClass: .stock, currency: "EUR", mic: "XNAS"
        ))
        #expect(watchlist.entries.count == 1)

        watchlist.load(openListings: [ListingID(symbol: "NVDA", mic: "XNAS")])
        #expect(watchlist.entries.isEmpty)

        // The flag survived — the entry was filtered, not deleted.
        watchlist.load(openListings: [])
        #expect(watchlist.entries.map(\.symbol) == ["NVDA"])
    }

    /// Unfollowing a ticker that has transactions behind it must not take the
    /// `Asset` row with it: the position would lose its venue and its currency,
    /// and with them the right FX rate.
    @Test func unfollowingKeepsMetadataWhenTransactionsExist() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let portfolio = PortfolioViewModel()
        portfolio.bind(modelContext: ctx, priceStore: store)
        try portfolio.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 2, unitPrice: 100,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
                assetClass: .stock, currency: "USD", mic: "XNAS"
            )
        )

        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)
        try watchlist.add(AssetSearchResult(
            symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
            assetClass: .stock, currency: "USD", mic: "XNAS"
        ))

        watchlist.remove(listing: ListingID(symbol: "NVDA", mic: "XNAS"))

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        let nvda = try #require(assets.first { $0.symbol == "NVDA" })
        #expect(nvda.isWatchlisted == false)
        #expect(nvda.exchange == "XNAS")
        #expect(nvda.currency == "USD")
    }

    /// Unfollowing something never held removes the row entirely — nothing else
    /// refers to it, and leaving it would keep a dead ticker in future searches.
    @Test func unfollowingDeletesTheRowWhenNothingElseNeedsIt() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)
        try watchlist.add(AssetSearchResult(
            symbol: "TSLA", name: "Tesla", exchange: "XNAS",
            assetClass: .stock, currency: "USD", mic: "XNAS"
        ))

        watchlist.remove(listing: ListingID(symbol: "TSLA", mic: "XNAS"))

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        #expect(!assets.contains { $0.symbol == "TSLA" })
        #expect(watchlist.entries.isEmpty)
    }

    // MARK: - One snapshot is not a chart

    /// Two points or no line. One snapshot can only become a chart by
    /// duplicating it or extending it to today, and both claim a flat stretch
    /// that was never measured.
    @Test func aSingleSnapshotDoesNotDrawAChart() {
        let one = [PortfolioSnapshot(date: Date(), totalValue: 1000, totalCost: 900, cashTotal: 0)]
        #expect(PortfolioSnapshotRecorder.drawsChart([]) == false)
        #expect(PortfolioSnapshotRecorder.drawsChart(one) == false)

        let two = one + [PortfolioSnapshot(
            date: Date().addingTimeInterval(86_400),
            totalValue: 1100, totalCost: 900, cashTotal: 0
        )]
        #expect(PortfolioSnapshotRecorder.drawsChart(two))
    }

    /// Repeated recording on the same day overwrites rather than accumulating,
    /// so opening the app twice does not fake a second point and turn a single
    /// snapshot into a "trend".
    @Test func sameDayRecordingStaysOnePointAndDoesNotUnlockTheChart() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        var holding = Holding(
            assetSymbol: "NVDA", accountID: "a", accountName: "Corretora",
            quantity: 2, totalCostEUR: 200, averagePriceEUR: 100,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        holding.currentPriceNative = 110
        holding.currency = "EUR"
        holding.currentFXRate = FXRate.identity("EUR")

        #expect(PortfolioSnapshotRecorder.record(holdings: [holding], accounts: [], in: ctx))
        #expect(PortfolioSnapshotRecorder.record(holdings: [holding], accounts: [], in: ctx))

        let series = PortfolioSnapshotRecorder.series(in: ctx)
        #expect(series.count == 1)
        #expect(PortfolioSnapshotRecorder.drawsChart(series) == false)
    }

    /// A partially priced portfolio is still never recorded — a stored point
    /// has no caveat beside it, so a provider outage would read as a real dip a
    /// year from now.
    @Test func partiallyPricedPortfolioIsNotRecorded() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let holdings = [priced("NVDA", quantity: 2, price: 100), unpriced("QDVE")]
        #expect(PortfolioSnapshotRecorder.record(holdings: holdings, accounts: [], in: ctx) == false)
        #expect(PortfolioSnapshotRecorder.series(in: ctx).isEmpty)
    }
}
