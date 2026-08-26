import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// Ponto F, camada 2: what happens to a store that already has data.
///
/// Every test here builds a **pre-F store by hand** — transactions with
/// `assetMIC` nil, snapshots and candles with `mic` nil, exactly the rows an
/// installed app is holding right now — and then asserts what the user sees
/// after the migration. Asserted through `PortfolioViewModel` and `CandleStore`,
/// not through the calculator: the calculator being right proves nothing about
/// the screen, and this is the seam where a migration would quietly lose a
/// price, a chart or an average cost.
@MainActor
struct ListingMigrationTests {

    // MARK: - Building a pre-F store

    /// A transaction as an old build wrote it: a ticker and nothing else.
    @discardableResult
    private func legacyBuy(
        _ ctx: ModelContext, symbol: String, account: Account,
        quantity: Decimal, price: Decimal, fx: Decimal = 1,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FinancialTransaction {
        let tx = FinancialTransaction(
            type: .assetPurchase, amount: quantity * price * fx, date: date,
            note: "", category: .investments, sourceAccount: account
        )
        tx.assetSymbol = symbol
        tx.assetQuantity = quantity
        tx.assetUnitPrice = price
        tx.assetFXRate = fx
        // Deliberately not set. This is the whole point.
        #expect(tx.assetMIC == nil)
        ctx.insert(tx)
        return tx
    }

    private func legacyAsset(
        _ ctx: ModelContext, symbol: String, venue: String, currency: String,
        name: String = "Instrumento", assetClass: AssetClass = .stock
    ) {
        ctx.insert(Asset(
            symbol: symbol, name: name, assetClass: assetClass,
            exchange: venue, currency: currency
        ))
    }

    private func legacySnapshot(
        _ ctx: ModelContext, symbol: String, price: Decimal, currency: String
    ) {
        let snapshot = PriceSnapshot(
            quote: Quote(
                symbol: symbol, price: price, previousClose: price,
                changeAbsolute: 0, changePercent: 0, currency: currency,
                timestamp: Date(), source: .rest
            ),
            listing: ListingID(symbol: symbol)
        )
        #expect(snapshot.mic == nil)
        ctx.insert(snapshot)
    }

    private func legacyCandles(_ ctx: ModelContext, symbol: String, count: Int) {
        for i in 0..<count {
            let row = CandleCache(
                symbol: symbol,
                date: CandleStore.sessionDate(Date().addingTimeInterval(Double(-i) * 86_400)),
                open: 100, high: 101, low: 99, close: Decimal(100 + i), volume: 1,
                source: "legacy"
            )
            #expect(row.mic == nil)
            ctx.insert(row)
        }
    }

    private func account(_ ctx: ModelContext, _ name: String = "Investimentos") -> Account {
        let acc = Account(name: name, type: .brokerage)
        ctx.insert(acc)
        return acc
    }

    private func makeVM(_ ctx: ModelContext, _ store: PriceStore) -> PortfolioViewModel {
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: MockFXRateProvider())
        return vm
    }

    private func makeStore(_ ctx: ModelContext) -> PriceStore {
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        return store
    }

    // MARK: - The whole migration, end to end

    /// The test that has to pass before this ships: an existing store with two
    /// positions, a cached price and a cached chart comes out the other side
    /// with the same positions, the same cost, the same price and the same
    /// chart — now attributed to their venues.
    @Test func anExistingStoreMigratesWithoutLosingAPositionAPriceOrAChart() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        legacyBuy(ctx, symbol: "NVD", account: acc, quantity: 2, price: Decimal(string: "194.22")!)
        legacyBuy(ctx, symbol: "GALP", account: acc, quantity: 100, price: Decimal(string: "19.75")!)
        legacyAsset(ctx, symbol: "NVD", venue: "XETR", currency: "EUR", name: "NVIDIA")
        legacyAsset(ctx, symbol: "GALP", venue: "XLIS", currency: "EUR", name: "Galp")
        legacySnapshot(ctx, symbol: "NVD", price: Decimal(string: "200.00")!, currency: "EUR")
        legacyCandles(ctx, symbol: "NVD", count: 5)
        try ctx.save()

        // What the user sees today, before anything migrates.
        let before = makeStore(ctx)
        before.hydrateFromCache()
        let vmBefore = makeVM(ctx, before)
        vmBefore.loadHoldings()
        #expect(vmBefore.openHoldings.count == 2)
        let nvdBefore = try #require(vmBefore.openHoldings.first { $0.assetSymbol == "NVD" })
        #expect(nvdBefore.totalCostEUR == Decimal(string: "388.44"))
        #expect(nvdBefore.marketValueEUR == 400)

        // The migration.
        let report = ListingBackfill.run(in: ctx)
        #expect(report.transactions == 2)
        #expect(report.snapshots == 1)
        #expect(report.candles == 5)
        #expect(report.unresolved.isEmpty)

        // And what the user sees afterwards. A fresh store, as on the next
        // launch — the price has to come back off disk, not out of memory.
        let after = makeStore(ctx)
        after.hydrateFromCache()
        let vmAfter = makeVM(ctx, after)
        vmAfter.loadHoldings()

        #expect(vmAfter.openHoldings.count == 2, "a migração não pode partir nem fundir posições")

        let nvd = try #require(vmAfter.openHoldings.first { $0.assetSymbol == "NVD" })
        #expect(nvd.assetMIC == "XETR")
        #expect(nvd.quantity == 2)
        #expect(nvd.totalCostEUR == Decimal(string: "388.44"))
        #expect(nvd.averagePriceEUR == Decimal(string: "194.22"))
        // The cached price survived and still reaches the position. This is the
        // assertion that fails if the snapshot is left behind by the backfill:
        // the transaction moves to `NVD|XETR` and the price stays at `NVD`.
        #expect(nvd.marketValueEUR == 400, "a cotação em cache tem de continuar a chegar à posição")

        let galp = try #require(vmAfter.openHoldings.first { $0.assetSymbol == "GALP" })
        #expect(galp.assetMIC == "XLIS")
        #expect(galp.totalCostEUR == 1975)

        // The chart too.
        let candles = CandleStore()
        candles.bind(modelContext: ctx)
        #expect(candles.series(for: ListingID(symbol: "NVD", mic: "XETR")).count == 5)
    }

    /// Runs on every launch, so it has to be free and harmless after the first.
    @Test func theBackfillIsIdempotent() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        legacyBuy(ctx, symbol: "NVD", account: acc, quantity: 2, price: 194)
        legacyAsset(ctx, symbol: "NVD", venue: "XETR", currency: "EUR")
        legacySnapshot(ctx, symbol: "NVD", price: 200, currency: "EUR")
        try ctx.save()

        let first = ListingBackfill.run(in: ctx)
        #expect(first.didChangeAnything)

        let second = ListingBackfill.run(in: ctx)
        #expect(!second.didChangeAnything)
        #expect(second.transactions == 0)
        #expect(second.snapshots == 0)

        let vm = makeVM(ctx, makeStore(ctx))
        vm.loadHoldings()
        #expect(vm.openHoldings.count == 1)
        #expect(vm.openHoldings[0].assetMIC == "XETR")
    }

    /// No evidence, no venue. A ticker whose `Asset` row is gone keeps `nil` and
    /// keeps working exactly as before — a dash would be a regression, and a
    /// guessed venue would be the original bug.
    @Test func aTickerWithNoEvidenceStaysUnattributedAndKeepsWorking() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        legacyBuy(ctx, symbol: "MYST", account: acc, quantity: 3, price: 50)
        legacySnapshot(ctx, symbol: "MYST", price: 60, currency: "EUR")
        try ctx.save()

        let report = ListingBackfill.run(in: ctx)
        #expect(report.transactions == 0)
        #expect(report.unresolved == ["MYST"])

        let store = makeStore(ctx)
        store.hydrateFromCache()
        let vm = makeVM(ctx, store)
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first)
        #expect(holding.assetMIC == nil)
        #expect(holding.quantity == 3)
        #expect(holding.totalCostEUR == 150)
        // Still priced off its bare-ticker snapshot, exactly as before.
        #expect(holding.marketValueEUR == 180)
    }

    /// Two `Asset` rows disagreeing about a ticker cannot happen through the
    /// app — the old guard saw to that — but a row written by hand, or a future
    /// store, must not be resolved by picking one.
    @Test func aContradictedTickerIsNotResolvedByGuessing() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        legacyBuy(ctx, symbol: "NVD", account: acc, quantity: 1, price: 100)
        legacyAsset(ctx, symbol: "NVD", venue: "XETR", currency: "EUR")
        legacyAsset(ctx, symbol: "NVD", venue: "XNMS", currency: "USD")
        try ctx.save()

        let report = ListingBackfill.run(in: ctx)
        #expect(report.transactions == 0)
        #expect(report.unresolved == ["NVD"])
        #expect(ListingBackfill.unambiguousVenues(in: ctx)["NVD"] == nil)
    }

    /// The same legacy ticker in two accounts is two positions, and both adopt.
    @Test func everyAccountsCopyOfALegacyTickerAdopts() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let a = account(ctx, "Corretora A")
        let b = account(ctx, "Corretora B")
        legacyBuy(ctx, symbol: "GALP", account: a, quantity: 10, price: 20)
        legacyBuy(ctx, symbol: "GALP", account: b, quantity: 5, price: 20)
        legacyAsset(ctx, symbol: "GALP", venue: "XLIS", currency: "EUR")
        try ctx.save()

        ListingBackfill.run(in: ctx)

        let vm = makeVM(ctx, makeStore(ctx))
        vm.loadHoldings()
        #expect(vm.openHoldings.count == 1, "Unified: one line per listing")
        #expect(vm.openHoldings.first?.quantity == 15)
        #expect(vm.perAccountHoldings.count == 2)
        #expect(vm.perAccountHoldings.allSatisfy { $0.assetMIC == "XLIS" })
        #expect(Set(vm.perAccountHoldings.map(\.quantity)) == [10, 5])
    }

    /// Groceries have no venue. The backfill must not go near them.
    @Test func nonInvestmentTransactionsAreUntouched() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        let expense = FinancialTransaction(
            type: .expense, amount: 12, date: Date(), note: "Café",
            category: .food, sourceAccount: acc
        )
        ctx.insert(expense)
        legacyAsset(ctx, symbol: "NVD", venue: "XETR", currency: "EUR")
        try ctx.save()

        let report = ListingBackfill.run(in: ctx)
        #expect(report.transactions == 0)
        #expect(expense.assetMIC == nil)
        #expect(expense.amount == 12)
    }

    // MARK: - The average price must not split (the user's question)

    /// The fear, answered. A purchase made before venues were stored and a
    /// purchase made after are **one** position with one blended average — not
    /// two positions that appeared out of nowhere.
    @Test func aLegacyBuyAndANewBuyOfTheSameListingStayOnePosition() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        legacyBuy(ctx, symbol: "GALP", account: acc, quantity: 100, price: 20)
        legacyAsset(ctx, symbol: "GALP", venue: "XLIS", currency: "EUR")
        try ctx.save()

        ListingBackfill.run(in: ctx)

        let vm = makeVM(ctx, makeStore(ctx))
        vm.loadHoldings()
        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP", quantity: 100, unitPrice: 22,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "GALP", name: "Galp Energia", exchange: "XLIS",
                assetClass: .stock, currency: "EUR", mic: "XLIS"
            )
        )

        #expect(vm.openHoldings.count == 1, "o preço médio não se pode partir em dois")
        let holding = try #require(vm.openHoldings.first)
        #expect(holding.quantity == 200)
        #expect(holding.totalCostEUR == 4200)
        #expect(holding.averagePriceEUR == 21)
    }

    /// The harder half: the backfill had nothing to work with, because the
    /// `Asset` row was gone. The purchase itself is then the evidence, and it
    /// adopts the orphaned rows rather than opening a second position beside
    /// them. Same unambiguity test, applied later.
    @Test func aNewBuyAdoptsOrphanedRowsTheBackfillCouldNotResolve() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        // No `Asset` row at all — nothing for the launch backfill to read.
        legacyBuy(ctx, symbol: "GALP", account: acc, quantity: 100, price: 20)
        try ctx.save()
        let report = ListingBackfill.run(in: ctx)
        #expect(report.transactions == 0)
        #expect(report.unresolved == ["GALP"])

        let vm = makeVM(ctx, makeStore(ctx))
        vm.loadHoldings()
        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP", quantity: 100, unitPrice: 22,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "GALP", name: "Galp Energia", exchange: "XLIS",
                assetClass: .stock, currency: "EUR", mic: "XLIS"
            )
        )

        #expect(vm.openHoldings.count == 1)
        let holding = try #require(vm.openHoldings.first)
        #expect(holding.assetMIC == "XLIS")
        #expect(holding.quantity == 200)
        #expect(holding.averagePriceEUR == 21)

        // The old rows really were rewritten, not merely displayed together.
        let txs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        #expect(txs.allSatisfy { $0.assetMIC == "XLIS" })
    }

    /// A sale entered without picking a listing still comes out of the position
    /// that is actually held. Otherwise it opens a second, negative one and the
    /// portfolio grows a holding of −10 units.
    @Test func aSaleWithNoPickedListingLandsOnTheHeldOne() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        legacyBuy(ctx, symbol: "GALP", account: acc, quantity: 100, price: 20)
        legacyAsset(ctx, symbol: "GALP", venue: "XLIS", currency: "EUR")
        try ctx.save()
        ListingBackfill.run(in: ctx)

        let vm = makeVM(ctx, makeStore(ctx))
        vm.loadHoldings()
        try vm.addInvestment(
            type: .assetSale, symbol: "GALP", quantity: 40, unitPrice: 25,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: ""
        )

        #expect(vm.openHoldings.count == 1)
        #expect(vm.openHoldings[0].quantity == 60)
        #expect(vm.openHoldings[0].assetMIC == "XLIS")
    }

    // MARK: - The two NVDs, through the ViewModel

    /// The question this whole point exists to answer: two instruments sharing
    /// a ticker, each with its own price, in one account.
    ///
    /// The two providers answer about different venues, and the routing has to
    /// send each listing to the one that can honestly speak for it — the US pair
    /// must never even be asked about the XETRA listing.
    @Test func theTwoNVDsAreTwoPositionsWithTheirOwnPrices() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        func quote(_ symbol: String, _ price: Decimal, _ currency: String, mic: String?) -> Quote {
            Quote(
                symbol: symbol, price: price, previousClose: price, changeAbsolute: 0,
                changePercent: 0, currency: currency, timestamp: Date(), source: .rest,
                venueMIC: mic
            )
        }

        let us = RecordingProvider(returns: [
            quote("NVD", Decimal(string: "3.97")!, "USD", mic: "XNMS")
        ])
        let av = RecordingProvider(returns: [
            quote("NVD.DE", Decimal(string: "194.22")!, "EUR", mic: nil)
        ])

        let store = PriceStore()
        store.configure(
            provider: us, fallbackProvider: us,
            europeanProvider: av, lastResortProvider: RecordingProvider(),
            modelContext: ctx
        )

        let vm = makeVM(ctx, store)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 2,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "NVIDIA Corporation", exchange: "XETR",
                assetClass: .stock, currency: "EUR", mic: "XETR"
            )
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 10,
            unitPrice: Decimal(string: "3.97")!, fxRate: Decimal(string: "0.86693")!,
            commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
                exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
            )
        )

        await store.refresh([
            ListingID(symbol: "NVD", mic: "XETR"),
            ListingID(symbol: "NVD", mic: "XNMS"),
        ])
        vm.setCurrentFXRateForTesting(
            FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.86693")!)!
        )

        // The US providers were asked about the NASDAQ listing and only that one.
        #expect(us.received == ["NVD"])
        #expect(av.received == ["NVD.DE"])

        #expect(vm.openHoldings.count == 2)

        let nvidia = try #require(vm.openHoldings.first { $0.assetMIC == "XETR" })
        #expect(nvidia.currentPriceNative == Decimal(string: "194.22"))
        #expect(nvidia.currency == "EUR")
        #expect(nvidia.marketValueEUR == Decimal(string: "388.44"))
        // The symptom, as the thing that must not happen.
        #expect(nvidia.marketValueEUR != Decimal(string: "7.94"))

        let etf = try #require(vm.openHoldings.first { $0.assetMIC == "XNAS" })
        #expect(etf.currentPriceNative == Decimal(string: "3.97"))
        #expect(etf.currency == "USD")

        // Neither borrowed the other's number, and the header adds them up.
        #expect(vm.marketValueTotal?.pricedCount == 2)
        #expect(vm.marketValueTotal?.excludedCount == 0)
    }

    /// And their histories stay apart. A shared series is the worst of the
    /// collisions, because a closed session is never re-fetched: whichever venue
    /// reaches a day first owns it permanently.
    @Test func theTwoNVDsKeepSeparateCharts() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let candles = CandleStore()
        candles.bind(modelContext: ctx)

        let xetra = ListingID(symbol: "NVD", mic: "XETR")
        let nasdaq = ListingID(symbol: "NVD", mic: "XNMS")
        let day = CandleStore.sessionDate(Date())

        candles.merge(
            [Candle(date: day, open: 194, high: 195, low: 193, close: Decimal(string: "194.22")!, volume: 1)],
            listing: xetra, source: "test"
        )
        candles.merge(
            [Candle(date: day, open: 4, high: 4, low: 3, close: Decimal(string: "3.97")!, volume: 1)],
            listing: nasdaq, source: "test"
        )

        #expect(candles.series(for: xetra).map(\.close) == [Decimal(string: "194.22")!])
        #expect(candles.series(for: nasdaq).map(\.close) == [Decimal(string: "3.97")!])
    }

    /// Deleting one takes nothing of the other with it — not its transactions,
    /// not its metadata, not its cached price.
    @Test func deletingOneOfTheTwoNVDsLeavesTheOtherIntact() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        let store = makeStore(ctx)
        let vm = makeVM(ctx, store)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 2,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "NVIDIA Corporation", exchange: "XETR",
                assetClass: .stock, currency: "EUR", mic: "XETR"
            )
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 10,
            unitPrice: Decimal(string: "3.97")!, fxRate: Decimal(string: "0.86693")!,
            commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
                exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
            )
        )

        try vm.deletePosition(
            listing: ListingID(symbol: "NVD", mic: "XNMS"), accountID: acc.id.uuidString
        )

        #expect(vm.openHoldings.count == 1)
        let survivor = try #require(vm.openHoldings.first)
        #expect(survivor.assetMIC == "XETR")
        #expect(survivor.quantity == 2)

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        #expect(assets.count == 1)
        #expect(assets[0].listing.mic == "XETR")
        #expect(assets[0].currency == "EUR")
    }
}
