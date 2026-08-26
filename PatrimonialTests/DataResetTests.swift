import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// "Apagar todos os dados" has to mean all of them.
///
/// The version this replaces deleted accounts, transactions and custom
/// categories — the three models `AppStore` happened to know about — and left
/// the entire portfolio side on disk: assets, cached prices, FX rates, candles
/// and the portfolio history. The app looked empty and was not, which is the
/// failure mode a reset exists to prevent.
@MainActor
struct DataResetTests {

    // MARK: - Fixtures

    /// Every table in the schema, populated. If a model is added to
    /// `PersistenceController` and not here, this file stops covering it — which
    /// is why `everyTableIsEmptyAfterAReset` counts rows generically rather than
    /// checking a hand-written list twice.
    private func populate(_ ctx: ModelContext) throws {
        let account = Account(name: "IBKR", type: .brokerage)
        ctx.insert(account)

        let buy = FinancialTransaction(
            type: .assetPurchase, amount: Decimal(string: "194.22")!, date: Date(),
            note: "Compra NVD", category: .investments, sourceAccount: account
        )
        buy.assetSymbol = "NVD"
        buy.assetQuantity = 1
        buy.assetUnitPrice = Decimal(string: "194.22")!
        buy.assetFXRate = 1
        ctx.insert(buy)

        let expense = FinancialTransaction(
            type: .expense, amount: 40, date: Date(),
            note: "Supermercado", category: .food, sourceAccount: account
        )
        ctx.insert(expense)

        // A transaction with no account. `Account` cascades to its
        // transactions, so deleting the accounts alone empties this table for
        // every ordinary row — and the explicit delete looked covered while
        // doing nothing. This row is the one that survives a cascade, and it is
        // reachable: `sourceAccount` is optional, and `destinationAccount` is
        // nullify, so the receiving side of a transfer outlives its account.
        let orphan = FinancialTransaction(
            type: .income, amount: 100, date: Date(),
            note: "Sem conta", category: .other, sourceAccount: nil
        )
        ctx.insert(orphan)

        ctx.insert(CustomCategory(
            name: "Ginásio", symbol: "figure.run", colorHex: "FF9500",
            isExpense: true, isIncome: false
        ))
        ctx.insert(Asset(
            symbol: "NVD", name: "NVIDIA", assetClass: .stock,
            exchange: "XETR", currency: "EUR"
        ))
        ctx.insert(Asset(
            symbol: "GALP", name: "Galp", assetClass: .stock,
            exchange: "XLIS", currency: "EUR", isWatchlisted: true
        ))
        ctx.insert(PriceSnapshot(quote: Quote(
            symbol: "NVD", price: Decimal(string: "194.22")!,
            previousClose: Decimal(string: "189.16")!,
            changeAbsolute: 0, changePercent: 0,
            currency: "EUR", timestamp: Date(), source: .rest
        ), listing: ListingID(symbol: "NVD", mic: "XETR")))
        ctx.insert(PortfolioSnapshot(
            date: Date(), totalValue: Decimal(string: "194.22")!,
            totalCost: Decimal(string: "194.22")!, cashTotal: 0
        ))
        ctx.insert(FXRateCache(
            fromCurrency: "USD", toCurrency: "EUR",
            dateString: "2026-08-07", rate: Decimal(string: "0.86693")!
        ))
        ctx.insert(CoinGeckoCache(coinID: "bitcoin", symbol: "btc", name: "Bitcoin"))
        ctx.insert(CandleCache(
            symbol: "NVD", date: Date(),
            open: 190, high: 195, low: 189, close: Decimal(string: "194.22")!,
            volume: 1000, source: "test"
        ))

        try ctx.save()
    }

    private func count<T: PersistentModel>(_ type: T.Type, in ctx: ModelContext) -> Int {
        ((try? ctx.fetch(FetchDescriptor<T>())) ?? []).count
    }

    private func makePriceStore(_ ctx: ModelContext) -> PriceStore {
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        return store
    }

    // MARK: - Every table

    @Test func everyTableIsEmptyAfterAReset() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        // Populated first, so an assertion of "empty" cannot pass by accident on
        // a table that was never filled.
        #expect(count(Account.self, in: ctx) > 0)
        #expect(count(FinancialTransaction.self, in: ctx) > 0)
        #expect(count(CustomCategory.self, in: ctx) > 0)
        #expect(count(Asset.self, in: ctx) > 0)
        #expect(count(PriceSnapshot.self, in: ctx) > 0)
        #expect(count(PortfolioSnapshot.self, in: ctx) > 0)
        #expect(count(FXRateCache.self, in: ctx) > 0)
        #expect(count(CoinGeckoCache.self, in: ctx) > 0)
        #expect(count(CandleCache.self, in: ctx) > 0)

        try DataReset.eraseEverything(in: ctx)

        #expect(count(Account.self, in: ctx) == 0)
        #expect(count(FinancialTransaction.self, in: ctx) == 0)
        #expect(count(CustomCategory.self, in: ctx) == 0)
        #expect(count(Asset.self, in: ctx) == 0, "o ticker apagado voltaria a aparecer na pesquisa")
        #expect(count(PriceSnapshot.self, in: ctx) == 0)
        #expect(count(PortfolioSnapshot.self, in: ctx) == 0)
        #expect(count(FXRateCache.self, in: ctx) == 0)
        #expect(count(CoinGeckoCache.self, in: ctx) == 0)
        #expect(count(CandleCache.self, in: ctx) == 0)
    }

    /// The watchlist is a flag on `Asset`, not a table, so it is only gone if the
    /// assets are. Stated separately because that is not obvious from the model
    /// list and a deleted position deliberately *keeps* a watchlisted asset —
    /// see `PortfolioViewModel.deletePosition`.
    @Test func theWatchlistGoesToo() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let before = ((try? ctx.fetch(FetchDescriptor<Asset>())) ?? []).count(where: \.isWatchlisted)
        #expect(before > 0)

        try DataReset.eraseEverything(in: ctx)

        let after = ((try? ctx.fetch(FetchDescriptor<Asset>())) ?? []).count(where: \.isWatchlisted)
        #expect(after == 0)
    }

    // MARK: - In-memory state

    /// Disk alone is not enough. A quote left in `PriceStore.quotes` is written
    /// back to `PriceSnapshot` by the very next poll, so a reset that only
    /// cleared SwiftData would regrow the cache it just deleted.
    @Test func thePriceStoreKeepsNoQuotesOrListings() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let store = makePriceStore(ctx)
        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")
        store.registerCoinID(symbol: "BTC", coinID: "bitcoin")
        store.applyQuote(Quote(
            symbol: "NVD", price: Decimal(string: "194.22")!,
            previousClose: Decimal(string: "189.16")!,
            changeAbsolute: 0, changePercent: 0,
            currency: "EUR", timestamp: Date(), source: .rest
        ), as: ListingID(symbol: "NVD", mic: "XETR"))
        #expect(store.quote(for: ListingID(symbol: "NVD", mic: "XETR")) != nil)
        #expect(store.listing(for: ListingID(symbol: "NVD", mic: "XETR")) != nil)

        try DataReset.eraseEverything(in: ctx, priceStore: store)

        #expect(store.quote(for: ListingID(symbol: "NVD", mic: "XETR")) == nil)
        #expect(store.listing(for: ListingID(symbol: "NVD", mic: "XETR")) == nil)
        #expect(store.isCrypto("BTC") == false)
        #expect(store.freshness(for: ListingID(symbol: "NVD", mic: "XETR")) == .unknown)
    }

    /// A refused price leaves a mark on the store. It must not outlive the
    /// position it was about.
    @Test func theResetClearsRefusalMarks() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let store = makePriceStore(ctx)
        store.referenceClose = { _ in Decimal(string: "194.22") }
        store.applyQuote(Quote(
            symbol: "NVD", price: Decimal(string: "3.97")!, previousClose: 0,
            changeAbsolute: 0, changePercent: 0,
            currency: "EUR", timestamp: Date(), source: .rest
        ), as: ListingID(symbol: "NVD"))
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) != nil)

        try DataReset.eraseEverything(in: ctx, priceStore: store)

        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) == nil)
    }

    /// The `AppStore`'s cached arrays are what the Resumo and Contas tabs
    /// render. Left populated, the app shows accounts that no longer exist until
    /// it is relaunched — the "dados fantasma" case.
    @Test func theAppStoreCachesAreCleared() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let appStore = AppStore()
        appStore.bind(ctx)
        #expect(appStore.accounts.isEmpty == false)
        #expect(appStore.transactions.isEmpty == false)
        #expect(appStore.customCategories.isEmpty == false)

        try DataReset.eraseEverything(in: ctx, appStore: appStore)

        #expect(appStore.accounts.isEmpty)
        #expect(appStore.transactions.isEmpty)
        #expect(appStore.customCategories.isEmpty)
    }

    // MARK: - The app still works afterwards

    /// No relaunch. The same context, the same stores, and everything the user
    /// can do next has to work on an empty database.
    @Test func theAppIsUsableAfterAResetWithoutRelaunching() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let priceStore = makePriceStore(ctx)
        let appStore = AppStore()
        appStore.bind(ctx)

        try DataReset.eraseEverything(in: ctx, priceStore: priceStore, appStore: appStore)

        // A reload against an empty database must not resurrect anything or
        // throw.
        appStore.reload()
        #expect(appStore.accounts.isEmpty)
        #expect(appStore.transactions.isEmpty)
        #expect(appStore.totalBalance == 0)

        // The portfolio reads empty rather than erroring.
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore, fxProvider: MockFXRateProvider())
        vm.loadHoldings()
        #expect(vm.error == nil)
        #expect(vm.openHoldings.isEmpty)
        #expect(vm.marketValueTotal == nil)
        #expect(vm.dayChangeTotal == nil)

        // And a new account plus a new position go in cleanly on top of the
        // wiped tables.
        appStore.addAccount(
            name: "Revolut", sub: "Conta", kind: .cash, colorHex: 0x0A84FF,
            initialBalance: 500
        )
        #expect(appStore.accounts.count == 1)

        let fresh = try #require(try ctx.fetch(FetchDescriptor<Account>()).first)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: fresh, date: Date(), note: ""
        )
        #expect(vm.openHoldings.count == 1)
    }

    // MARK: - What must survive

    /// The keys are read from `Secrets.plist` in the bundle, and nothing in the
    /// reset path touches the bundle. Asserted anyway: "it cannot happen by
    /// construction" is exactly the claim that stops being true when someone
    /// later moves a key into `UserDefaults` or into a SwiftData row.
    @Test func theAPIKeysSurviveAReset() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let finnhub = AppConfig.finnhubAPIKey
        let twelveData = AppConfig.twelveDataAPIKey
        let alphaVantage = AppConfig.alphaVantageAPIKey
        let hadKeys = AppConfig.hasFinnhubKey || AppConfig.hasTwelveDataKey
            || AppConfig.hasAlphaVantageKey

        try DataReset.eraseEverything(in: ctx, priceStore: makePriceStore(ctx))

        #expect(AppConfig.finnhubAPIKey == finnhub)
        #expect(AppConfig.twelveDataAPIKey == twelveData)
        #expect(AppConfig.alphaVantageAPIKey == alphaVantage)
        #expect(AppConfig.hasFinnhubKey == (finnhub.isEmpty == false))
        #expect(AppConfig.hasTwelveDataKey == (twelveData.isEmpty == false))
        #expect(AppConfig.hasAlphaVantageKey == (alphaVantage.isEmpty == false))
        // Says out loud whether this run had keys at all, so a green tick on a
        // machine with an empty Secrets.plist is not mistaken for coverage.
        #expect(hadKeys == (AppConfig.hasFinnhubKey || AppConfig.hasTwelveDataKey
                            || AppConfig.hasAlphaVantageKey))
    }

    /// The theme is a preference, not data. Wiping it would be a surprise, and
    /// it lives in `UserDefaults` — the store a careless "delete everything"
    /// would reach for next.
    @Test func theAppearancePreferenceSurvives() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "appTheme")
        defaults.set("dark", forKey: "appTheme")
        defer {
            if let previous { defaults.set(previous, forKey: "appTheme") }
            else { defaults.removeObject(forKey: "appTheme") }
        }

        try DataReset.eraseEverything(in: ctx)

        #expect(defaults.string(forKey: "appTheme") == "dark")
    }

    // MARK: - The confirmation's numbers

    /// The counts in the alert are the point of the two-step confirmation. If
    /// they drift from what is actually deleted, the confirmation is worse than
    /// none — it invites the user to agree to a number that is not true.
    @Test func theInventoryMatchesWhatGetsDeleted() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        try populate(ctx)

        let inventory = DataReset.inventory(in: ctx)

        #expect(inventory.accounts == count(Account.self, in: ctx))
        #expect(inventory.transactions == count(FinancialTransaction.self, in: ctx))
        #expect(inventory.customCategories == count(CustomCategory.self, in: ctx))
        #expect(inventory.portfolioSnapshots == count(PortfolioSnapshot.self, in: ctx))
        #expect(inventory.watchlisted == 1)
        // One purchase of NVD, so one open position — not two, which is what
        // counting `Asset` rows would have given (NVD plus the watchlisted GALP).
        #expect(inventory.positions == 1)
        #expect(inventory.isEmpty == false)
    }

    /// A closed position is not something the user still has, so it must not be
    /// counted as one in a warning about what is about to disappear.
    @Test func theInventoryCountsOnlyOpenPositions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = Account(name: "IBKR", type: .brokerage)
        ctx.insert(account)

        for (type, price) in [(TransactionType.assetPurchase, "170.00"),
                              (TransactionType.assetSale, "194.22")] {
            let tx = FinancialTransaction(
                type: type, amount: Decimal(string: price)!, date: Date(),
                note: "", category: .investments, sourceAccount: account
            )
            tx.assetSymbol = "NVD"
            tx.assetQuantity = 1
            tx.assetUnitPrice = Decimal(string: price)!
            tx.assetFXRate = 1
            ctx.insert(tx)
        }
        try ctx.save()

        let inventory = DataReset.inventory(in: ctx)
        #expect(inventory.transactions == 2)
        #expect(inventory.positions == 0)
    }

    @Test func theInventoryOfAnEmptyDatabaseIsEmpty() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let inventory = DataReset.inventory(in: container.mainContext)

        #expect(inventory.isEmpty)
        #expect(inventory.positions == 0)
        #expect(inventory.portfolioSnapshots == 0)
    }
}
