import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Item 1: manual entry

/// The rule that free text can no longer produce a half-formed asset. This is
/// the path that once saved a position in "NVD" instead of NVDA, with no venue
/// and no currency attached.
struct ManualAssetEntryTests {

    private func draft(
        symbol: String = "GALP.LS",
        name: String = "Galp Energia",
        venue: String = "XLIS",
        currency: String = "EUR",
        assetClass: AssetClass = .stock
    ) -> ManualAssetSheet.Draft {
        ManualAssetSheet.Draft(
            symbol: symbol, name: name, venue: venue,
            currency: currency, assetClass: assetClass
        )
    }

    @Test func completeDraftIsAccepted() throws {
        let result = try #require(draft().result())
        #expect(result.symbol == "GALP.LS")
        #expect(result.name == "Galp Energia")
        #expect(result.mic == "XLIS")
        #expect(result.currency == "EUR")
        #expect(result.assetClass == .stock)
    }

    @Test func everyFieldIsRequired() {
        #expect(!draft(symbol: "").isComplete)
        #expect(!draft(name: "").isComplete)
        #expect(!draft(venue: "").isComplete)
        #expect(!draft(currency: "").isComplete)
    }

    @Test func whitespaceOnlyIsNotAValue() {
        #expect(!draft(symbol: "   ").isComplete)
        #expect(!draft(name: "  ").isComplete)
        #expect(!draft(venue: " ").isComplete)
    }

    /// A currency that is not a three-letter code will never match a rate, so it
    /// is refused rather than stored to fail later.
    @Test func currencyMustBeAThreeLetterCode() {
        #expect(!draft(currency: "EU").isComplete)
        #expect(!draft(currency: "EUROS").isComplete)
        #expect(!draft(currency: "E1R").isComplete)
        #expect(draft(currency: "eur").isComplete)
    }

    @Test func symbolAndCurrencyAreNormalisedToUppercase() throws {
        let result = try #require(draft(symbol: "galp.ls", currency: "eur").result())
        #expect(result.symbol == "GALP.LS")
        #expect(result.currency == "EUR")
    }

    /// There is no path from an incomplete draft to an asset.
    @Test func incompleteDraftYieldsNothing() {
        #expect(draft(venue: "").result() == nil)
        #expect(draft(currency: "").result() == nil)
    }

    /// Typing a crypto ticker cannot conjure a CoinGecko id, so the manual asset
    /// carries none — no price beats a wrong price.
    @Test func manualCryptoGetsNoCoinGeckoID() throws {
        let result = try #require(draft(symbol: "XYZ", assetClass: .crypto).result())
        #expect(result.coingeckoID == nil)
    }
}

// MARK: - Item 1: the Asset row itself

@MainActor
struct AssetPersistenceTests {

    private func account(in ctx: ModelContext) -> Account {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        return acc
    }

    private func viewModel(_ ctx: ModelContext) -> PortfolioViewModel {
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        return vm
    }

    private func searchResult(
        symbol: String = "GALP.LS",
        exchange: String = "XLIS",
        currency: String = "EUR",
        mic: String? = "XLIS"
    ) -> AssetSearchResult {
        AssetSearchResult(
            symbol: symbol, name: "Galp Energia", exchange: exchange,
            assetClass: .stock, currency: currency, mic: mic
        )
    }

    @Test func assetIsStoredWithVenueAndCurrency() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP.LS", quantity: 10, unitPrice: 19.75,
            fxRate: 1, commission: 0, account: account(in: ctx), date: Date(),
            note: "", asset: searchResult()
        )

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        let galp = try #require(assets.first { $0.symbol == "GALP.LS" })
        #expect(galp.exchange == "XLIS")
        #expect(galp.currency == "EUR")
    }

    /// An Asset with no venue and no currency is worse than none: it cannot tell
    /// two listings of one ticker apart and it invites the wrong FX rate. The
    /// transaction still saves — the position is derived from transactions — but
    /// the metadata row is not written half-formed.
    @Test func assetWithoutCurrencyIsNotStored() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP.LS", quantity: 10, unitPrice: 19.75,
            fxRate: 1, commission: 0, account: account(in: ctx), date: Date(),
            note: "", asset: searchResult(currency: "")
        )

        #expect(try ctx.fetch(FetchDescriptor<Asset>()).isEmpty)
        // The position itself is unaffected.
        #expect(vm.openHoldings.contains { $0.assetSymbol == "GALP.LS" })
    }

    @Test func assetWithoutVenueIsNotStored() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP.LS", quantity: 10, unitPrice: 19.75,
            fxRate: 1, commission: 0, account: account(in: ctx), date: Date(),
            note: "", asset: searchResult(exchange: "", mic: nil)
        )

        #expect(try ctx.fetch(FetchDescriptor<Asset>()).isEmpty)
    }
}

// MARK: - Deleting a position

@MainActor
struct PositionDeletionTests {

    private func viewModel(_ ctx: ModelContext) -> PortfolioViewModel {
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        return vm
    }

    private func buy(
        _ vm: PortfolioViewModel,
        symbol: String,
        account: Account,
        quantity: Decimal = 10,
        price: Decimal = 100
    ) throws {
        try vm.addInvestment(
            type: .assetPurchase, symbol: symbol, quantity: quantity, unitPrice: price,
            fxRate: 1, commission: 0, account: account, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: symbol, name: symbol, exchange: "XNAS",
                assetClass: .stock, currency: "USD", mic: "XNAS"
            )
        )
    }

    /// The whole point: a position is the sum of its transactions, so deleting
    /// one has to take those with it or the position simply reappears.
    @Test func deletingAPositionRemovesItsTransactions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = viewModel(ctx)
        try buy(vm, symbol: "NVD", account: acc)
        try buy(vm, symbol: "NVD", account: acc, quantity: 5)
        try buy(vm, symbol: "AAPL", account: acc)

        #expect(vm.transactionCount(listing: ListingID(symbol: "NVD", mic: "XNAS"), accountID: acc.id.uuidString) == 2)

        try vm.deletePosition(listing: ListingID(symbol: "NVD", mic: "XNAS"), accountID: acc.id.uuidString)

        let remaining = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        #expect(!remaining.contains { $0.assetSymbol == "NVD" })
        // The untouched position is still there.
        #expect(remaining.contains { $0.assetSymbol == "AAPL" })
        #expect(!vm.openHoldings.contains { $0.assetSymbol == "NVD" })
    }

    /// The ghost has to go completely. An Asset left behind keeps a deleted
    /// ticker in every future search; a PriceSnapshot left behind keeps quoting
    /// a position that no longer exists.
    @Test func deletingAlsoRemovesTheAssetAndTheCachedPrice() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = viewModel(ctx)
        try buy(vm, symbol: "NVD", account: acc)

        ctx.insert(PriceSnapshot(quote: Quote(
            symbol: "NVD", price: 100, previousClose: 100, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
        ), listing: ListingID(symbol: "NVD", mic: "XNAS")))
        try ctx.save()

        #expect(try !ctx.fetch(FetchDescriptor<Asset>()).isEmpty)

        try vm.deletePosition(listing: ListingID(symbol: "NVD", mic: "XNAS"), accountID: acc.id.uuidString)

        #expect(try ctx.fetch(FetchDescriptor<Asset>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PriceSnapshot>()).isEmpty)
    }

    /// The same ticker in a second account is a separate position. Deleting one
    /// must not strip the metadata the other still depends on.
    @Test func holdingTheSameTickerElsewhereKeepsItsAssetAndTransactions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let first = Account(name: "Corretora A", type: .brokerage)
        let second = Account(name: "Corretora B", type: .brokerage)
        ctx.insert(first)
        ctx.insert(second)

        let vm = viewModel(ctx)
        try buy(vm, symbol: "AAPL", account: first)
        try buy(vm, symbol: "AAPL", account: second)

        try vm.deletePosition(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: first.id.uuidString)

        let remaining = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        #expect(remaining.count { $0.assetSymbol == "AAPL" } == 1)
        // The surviving account still needs the venue and currency.
        #expect(try !ctx.fetch(FetchDescriptor<Asset>()).isEmpty)
        #expect(vm.openHoldings.contains { $0.assetSymbol == "AAPL" })
    }

    /// Sales and dividends belong to the position too, not just the purchases.
    @Test func deletingRemovesSalesAndDividendsAsWell() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = viewModel(ctx)
        try buy(vm, symbol: "AAPL", account: acc, quantity: 10)
        try vm.addInvestment(
            type: .assetSale, symbol: "AAPL", quantity: 4, unitPrice: 120,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )
        try vm.addInvestment(
            type: .dividend, symbol: "AAPL", quantity: 6, unitPrice: 1,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )

        #expect(vm.transactionCount(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: acc.id.uuidString) == 3)

        try vm.deletePosition(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: acc.id.uuidString)

        let remaining = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        #expect(!remaining.contains { $0.assetSymbol == "AAPL" })
    }

    /// The count shown in the confirmation has to be the count actually deleted,
    /// or the dialog is lying about what it is about to do.
    @Test func transactionCountIsScopedToTheAccount() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let first = Account(name: "Corretora A", type: .brokerage)
        let second = Account(name: "Corretora B", type: .brokerage)
        ctx.insert(first)
        ctx.insert(second)

        let vm = viewModel(ctx)
        try buy(vm, symbol: "AAPL", account: first)
        try buy(vm, symbol: "AAPL", account: first)
        try buy(vm, symbol: "AAPL", account: second)

        #expect(vm.transactionCount(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: first.id.uuidString) == 2)
        #expect(vm.transactionCount(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: second.id.uuidString) == 1)
    }

    /// A failed save must leave the position exactly as it was, not half gone.
    @Test func failedSaveRollsBackTheWholeDelete() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = viewModel(ctx)
        try buy(vm, symbol: "AAPL", account: acc)
        try ctx.save()

        struct SaveFailure: Error {}
        vm.saveHandler = { _ in throw SaveFailure() }

        #expect(throws: SaveFailure.self) {
            try vm.deletePosition(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: acc.id.uuidString)
        }

        vm.saveHandler = nil
        let remaining = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        #expect(remaining.contains { $0.assetSymbol == "AAPL" })
    }
}
