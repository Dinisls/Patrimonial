import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Crypto identity and aggregation

@MainActor
struct CryptoIdentityTests {

    private func account(in ctx: ModelContext) -> Account {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        return acc
    }

    private func viewModel(_ ctx: ModelContext) -> PortfolioViewModel {
        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)
        return vm
    }

    private func cryptoResult(
        symbol: String = "BTC",
        coingeckoID: String = "bitcoin"
    ) -> AssetSearchResult {
        AssetSearchResult(
            symbol: symbol, name: "Bitcoin", exchange: "",
            assetClass: .crypto, currency: "EUR",
            coingeckoID: coingeckoID
        )
    }

    private func detail(
        _ ctx: ModelContext, _ vm: PortfolioViewModel,
        symbol: String = "BTC", account: Account
    ) -> AssetDetailViewModel {
        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        priceStore.registerCoinID(symbol: symbol, coinID: "bitcoin")
        let candles = CandleStore(
            usProvider: RecordingCandleProvider(),
            europeanProvider: RecordingCandleProvider(),
            cryptoProvider: RecordingCandleProvider()
        )
        candles.bind(modelContext: ctx)
        let detail = AssetDetailViewModel(
            listing: ListingID(symbol: symbol),
            accountID: account.id.uuidString
        )
        detail.bind(
            modelContext: ctx, priceStore: priceStore,
            candleStore: candles, portfolio: vm
        )
        return detail
    }

    // MARK: - Bug 1: two purchases aggregate into one position

    /// Buying the same crypto twice — once through search, once through "buy
    /// more" — must result in a single position with summed quantity and
    /// weighted average price, never in two separate lines.
    @Test func twoCryptoPurchasesAggregateIntoOnePosition() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        // First purchase through search
        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: Decimal(string: "0.5")!,
            unitPrice: 60_000, fxRate: 1, commission: 0, account: acc,
            date: Date().addingTimeInterval(-86_400), note: "",
            asset: cryptoResult()
        )

        // Second purchase — same crypto, same account
        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: Decimal(string: "0.3")!,
            unitPrice: 62_000, fxRate: 1, commission: 0, account: acc,
            date: Date(), note: "",
            asset: cryptoResult()
        )

        let btcHoldings = vm.openHoldings.filter { $0.assetSymbol == "BTC" }
        #expect(btcHoldings.count == 1, "Expected one BTC position, got \(btcHoldings.count)")

        let holding = try #require(btcHoldings.first)
        #expect(holding.quantity == Decimal(string: "0.8")!)

        // Weighted average: (0.5 × 60000 + 0.3 × 62000) / 0.8 = 48600 / 0.8 = 60750
        let expectedCost = Decimal(string: "0.5")! * 60_000 + Decimal(string: "0.3")! * 62_000
        #expect(holding.totalCostEUR == expectedCost)
        #expect(holding.averagePriceEUR == expectedCost / Decimal(string: "0.8")!)
    }

    /// The crypto ListingID has no MIC — it is the bare symbol.
    @Test func cryptoListingIDHasNilMIC() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: 1, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: cryptoResult()
        )

        let holding = try #require(vm.openHoldings.first { $0.assetSymbol == "BTC" })
        #expect(holding.listing.mic == nil)
        #expect(holding.listing.symbol == "BTC")
        #expect(holding.listing.storageKey == "BTC")
    }

    /// The Asset row is created for crypto even though exchange is empty.
    @Test func assetRowIsCreatedForCrypto() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "ETH", quantity: 2, unitPrice: 3_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "ETH", name: "Ethereum", exchange: "",
                assetClass: .crypto, currency: "EUR", coingeckoID: "ethereum"
            )
        )

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        let eth = try #require(assets.first { $0.symbol == "ETH" })
        #expect(eth.assetClass == .crypto)
        #expect(eth.exchange == "")
        #expect(eth.currency == "EUR")
        #expect(eth.coingeckoID == "ethereum")
        #expect(eth.listing == ListingID(symbol: "ETH"))
    }

    /// A second purchase of the same crypto updates the existing Asset row
    /// rather than creating a duplicate.
    @Test func secondPurchaseDoesNotDuplicateAssetRow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: 1, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: cryptoResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: 1, unitPrice: 62_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: cryptoResult()
        )

        let btcAssets = try ctx.fetch(FetchDescriptor<Asset>()).filter { $0.symbol == "BTC" }
        #expect(btcAssets.count == 1)
    }

    // MARK: - Bug 2: quick actions for crypto

    /// The crypto detail screen must show Vender and Comprar mais.
    @Test func cryptoDetailHasQuickActions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: 1, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: cryptoResult()
        )

        let det = detail(ctx, vm, account: acc)
        #expect(det.prefillAsset != nil, "prefillAsset should resolve for crypto")
        #expect(det.canUseQuickActions)

        let buyMore = try #require(det.prefill(for: .assetPurchase))
        #expect(buyMore.asset.symbol == "BTC")
        #expect(buyMore.asset.assetClass == .crypto)
        #expect(buyMore.asset.coingeckoID == "bitcoin")

        let sell = try #require(det.prefill(for: .assetSale))
        #expect(sell.asset.symbol == "BTC")
        #expect(sell.type == .assetSale)
    }

    /// The prefill for crypto carries mic: nil, matching the position's identity.
    @Test func cryptoPrefillHasNilMIC() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: 1, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: cryptoResult()
        )

        let det = detail(ctx, vm, account: acc)
        let asset = try #require(det.prefillAsset)
        #expect(asset.mic == nil)

        let listing = ListingID(symbol: asset.symbol, mic: asset.mic ?? asset.exchange)
        #expect(listing == ListingID(symbol: "BTC"))
    }

    /// "Buy more" from detail and original search both produce the same
    /// ListingID, so the position aggregates.
    @Test func buyMoreFromDetailAggregatesWithOriginal() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        // First purchase through search
        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: Decimal(string: "0.5")!,
            unitPrice: 60_000, fxRate: 1, commission: 0, account: acc,
            date: Date().addingTimeInterval(-86_400), note: "",
            asset: cryptoResult()
        )

        // Second purchase using the prefill from "Comprar mais"
        let det = detail(ctx, vm, account: acc)
        let prefillAsset = try #require(det.prefillAsset)

        try vm.addInvestment(
            type: .assetPurchase, symbol: prefillAsset.symbol,
            quantity: Decimal(string: "0.3")!, unitPrice: 62_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: prefillAsset
        )

        let btcHoldings = vm.openHoldings.filter { $0.assetSymbol == "BTC" }
        #expect(btcHoldings.count == 1, "Buy-more must not create a second position")
        #expect(btcHoldings.first?.quantity == Decimal(string: "0.8")!)
    }

    /// isCrypto is true for a crypto position.
    @Test func isCryptoIsTrueForCryptoPosition() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC", quantity: 1, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: cryptoResult()
        )

        let det = detail(ctx, vm, account: acc)
        #expect(det.isCrypto)
    }

    // MARK: - Migration: normalization merges split positions

    /// If a crypto transaction somehow got a non-nil MIC, normalization clears
    /// it so the position merges on next load.
    @Test func normalizationClearsSpuriousCryptoMIC() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)

        // Insert an Asset so normalization knows this symbol is crypto
        ctx.insert(Asset(
            symbol: "BTC", name: "Bitcoin", assetClass: .crypto,
            exchange: "", currency: "EUR", coingeckoID: "bitcoin"
        ))

        // Simulate a transaction with a spurious MIC
        let tx = FinancialTransaction(
            type: .assetPurchase, amount: 30_000, date: Date(),
            note: "", category: .investments, sourceAccount: acc
        )
        tx.assetSymbol = "BTC"
        tx.assetMIC = "XNAS"  // wrong — crypto has no MIC
        tx.assetQuantity = Decimal(string: "0.5")!
        tx.assetUnitPrice = 60_000
        tx.assetFXRate = 1
        ctx.insert(tx)
        try ctx.save()

        let fixed = ListingBackfill.normalizeCryptoMICs(in: ctx)
        #expect(fixed >= 1)
        #expect(tx.assetMIC == nil)
    }

    /// After normalization, two crypto transactions that were split by MIC
    /// collapse into one position.
    @Test func splitCryptoPositionsMergeAfterNormalization() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)

        ctx.insert(Asset(
            symbol: "BTC", name: "Bitcoin", assetClass: .crypto,
            exchange: "", currency: "EUR", coingeckoID: "bitcoin"
        ))

        // Two transactions: one with nil MIC, one with "XNAS"
        let tx1 = FinancialTransaction(
            type: .assetPurchase, amount: 30_000,
            date: Date().addingTimeInterval(-86_400),
            note: "", category: .investments, sourceAccount: acc
        )
        tx1.assetSymbol = "BTC"
        tx1.assetMIC = nil
        tx1.assetQuantity = Decimal(string: "0.5")!
        tx1.assetUnitPrice = 60_000
        tx1.assetFXRate = 1
        ctx.insert(tx1)

        let tx2 = FinancialTransaction(
            type: .assetPurchase, amount: 18_600,
            date: Date(),
            note: "", category: .investments, sourceAccount: acc
        )
        tx2.assetSymbol = "BTC"
        tx2.assetMIC = "XNAS"
        tx2.assetQuantity = Decimal(string: "0.3")!
        tx2.assetUnitPrice = 62_000
        tx2.assetFXRate = 1
        ctx.insert(tx2)
        try ctx.save()

        // Before normalization: two different ListingIDs
        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)
        vm.loadHoldings()
        let beforeCount = vm.openHoldings.filter { $0.assetSymbol == "BTC" }.count
        #expect(beforeCount == 2, "Before normalization, BTC is split into \(beforeCount) positions")

        // Normalize
        ListingBackfill.normalizeCryptoMICs(in: ctx)

        // After: one position
        vm.loadHoldings()
        let afterHoldings = vm.openHoldings.filter { $0.assetSymbol == "BTC" }
        #expect(afterHoldings.count == 1, "After normalization, BTC should be one position")

        let merged = try #require(afterHoldings.first)
        #expect(merged.quantity == Decimal(string: "0.8")!)
        let expectedCost = Decimal(30_000) + Decimal(18_600)
        #expect(merged.totalCostEUR == expectedCost)
        #expect(merged.averagePriceEUR == expectedCost / Decimal(string: "0.8")!)
    }

    // MARK: - Mutation: identity normalization is load-bearing

    /// Removing the crypto identity normalization from upsertAsset (setting a
    /// non-nil MIC for crypto) must break aggregation.
    @Test func aNonNilMICForCryptoBreaksAggregation() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(in: ctx)

        // Simulate what would happen if crypto got a MIC: two transactions
        // with different MICs for the same symbol.
        let tx1 = FinancialTransaction(
            type: .assetPurchase, amount: 30_000,
            date: Date().addingTimeInterval(-86_400),
            note: "", category: .investments, sourceAccount: acc
        )
        tx1.assetSymbol = "BTC"
        tx1.assetMIC = nil
        tx1.assetQuantity = Decimal(string: "0.5")!
        tx1.assetUnitPrice = 60_000
        tx1.assetFXRate = 1
        ctx.insert(tx1)

        let tx2 = FinancialTransaction(
            type: .assetPurchase, amount: 18_600,
            date: Date(),
            note: "", category: .investments, sourceAccount: acc
        )
        tx2.assetSymbol = "BTC"
        tx2.assetMIC = "CRYPTO"  // any non-nil value splits the identity
        tx2.assetQuantity = Decimal(string: "0.3")!
        tx2.assetUnitPrice = 62_000
        tx2.assetFXRate = 1
        ctx.insert(tx2)
        try ctx.save()

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)
        vm.loadHoldings()

        let btcHoldings = vm.openHoldings.filter { $0.assetSymbol == "BTC" }
        #expect(btcHoldings.count == 2,
                "A non-nil MIC on one transaction must split the position")
    }

    // MARK: - Non-crypto is unaffected

    /// A stock without a venue still does not get an Asset row.
    @Test func stockWithoutVenueStillRefused() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP", quantity: 10, unitPrice: 20,
            fxRate: 1, commission: 0, account: account(in: ctx), date: Date(),
            note: "", asset: AssetSearchResult(
                symbol: "GALP", name: "Galp", exchange: "",
                assetClass: .stock, currency: "EUR", mic: nil
            )
        )

        #expect(try ctx.fetch(FetchDescriptor<Asset>()).isEmpty)
    }
}
