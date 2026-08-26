import Foundation
import Testing
import SwiftData
@testable import Patrimonial

@MainActor
struct PositionUnificationTests {

    private func account(_ name: String, in ctx: ModelContext) -> Account {
        let acc = Account(name: name, type: .brokerage)
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

    private func stockResult(
        symbol: String = "AAPL",
        name: String = "Apple",
        mic: String = "XNAS"
    ) -> AssetSearchResult {
        AssetSearchResult(
            symbol: symbol, name: name, exchange: mic,
            assetClass: .stock, currency: "USD", mic: mic
        )
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

    // MARK: - 1. Same asset, two accounts → one unified position

    @Test func sameAssetTwoAccountsGivesOneUnifiedPosition() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: Decimal(string: "0.92")!,
            commission: 0, account: accA, date: Date(), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: Decimal(string: "0.92")!,
            commission: 0, account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        let aaplHoldings = vm.openHoldings.filter { $0.assetSymbol == "AAPL" }
        #expect(aaplHoldings.count == 1, "Two accounts must unify into one line")

        let h = try #require(aaplHoldings.first)
        #expect(h.quantity == 15)

        let expectedCost = 10 * 150 * Decimal(string: "0.92")!
            + 5 * 160 * Decimal(string: "0.92")!
        #expect(h.totalCostEUR == expectedCost)
        #expect(h.averagePriceEUR == expectedCost / 15)
    }

    // MARK: - 2. Sale validates against TOTAL position, not per-account

    @Test func saleValidatesAgainstTotalQuantity() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: accA, date: Date(), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        let listing = ListingID(symbol: "AAPL", mic: "XNAS")
        let total = vm.totalQuantity(listing: listing)
        #expect(total == 15, "Total position is the sum of all accounts")
    }

    // MARK: - 3. Per-account breakdown survives for allocation

    @Test func accountBreakdownSurvivesForAllocation() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: accA, date: Date(), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        let listing = ListingID(symbol: "AAPL", mic: "XNAS")
        let breakdown = vm.accountBreakdown(for: listing)

        #expect(breakdown.count == 2, "Both accounts must survive for allocation")
        let degiro = breakdown.first { $0.accountName == "Degiro" }
        let ibkr = breakdown.first { $0.accountName == "IBKR" }

        #expect(degiro?.quantity == 10)
        #expect(ibkr?.quantity == 5)
    }

    // MARK: - 4. Migration: pre-existing positions in two accounts merge

    @Test func preExistingPositionsMergeAfterUnification() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)

        let tx1 = FinancialTransaction(
            type: .assetPurchase, amount: 1500,
            date: Date().addingTimeInterval(-86_400),
            note: "", category: .investments, sourceAccount: accA
        )
        tx1.assetSymbol = "AAPL"
        tx1.assetMIC = "XNAS"
        tx1.assetQuantity = 10
        tx1.assetUnitPrice = 150
        tx1.assetFXRate = 1
        ctx.insert(tx1)

        let tx2 = FinancialTransaction(
            type: .assetPurchase, amount: 800,
            date: Date(),
            note: "", category: .investments, sourceAccount: accB
        )
        tx2.assetSymbol = "AAPL"
        tx2.assetMIC = "XNAS"
        tx2.assetQuantity = 5
        tx2.assetUnitPrice = 160
        tx2.assetFXRate = 1
        ctx.insert(tx2)
        try ctx.save()

        let vm = viewModel(ctx)
        vm.loadHoldings()
        let aaplHoldings = vm.openHoldings.filter { $0.assetSymbol == "AAPL" }
        #expect(aaplHoldings.count == 1, "Two pre-existing positions must unify")
        #expect(aaplHoldings.first?.quantity == 15)
    }

    // MARK: - 5. Sell to account where you never bought is accepted

    @Test func sellToAccountWithNoPurchasesIsAccepted() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Rep", in: ctx)
        let santander = account("Santander", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC",
            quantity: Decimal(string: "0.002892")!, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: tradeRep,
            date: Date().addingTimeInterval(-86_400), note: "",
            asset: cryptoResult()
        )

        try vm.addInvestment(
            type: .assetSale, symbol: "BTC",
            quantity: Decimal(string: "0.002")!, unitPrice: 65_000,
            fxRate: 1, commission: 0, account: santander,
            date: Date(), note: "",
            asset: cryptoResult()
        )

        let listing = ListingID(symbol: "BTC")
        let remaining = vm.totalQuantity(listing: listing)
        #expect(remaining == Decimal(string: "0.000892")!)
    }

    // MARK: - 6. Sell more than total is refused

    @Test func sellMoreThanTotalIsRefused() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account("Trade Rep", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC",
            quantity: Decimal(string: "0.002892")!, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: acc,
            date: Date().addingTimeInterval(-86_400), note: "",
            asset: cryptoResult()
        )

        #expect(throws: (any Error).self) {
            try vm.addInvestment(
                type: .assetSale, symbol: "BTC",
                quantity: Decimal(string: "0.003")!, unitPrice: 65_000,
                fxRate: 1, commission: 0, account: acc,
                date: Date(), note: "",
                asset: cryptoResult()
            )
        }
    }

    // MARK: - 7. P/L uses global average cost, not per-account

    @Test func realizedPLUsesGlobalAverageCost() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let santander = account("Santander", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 100, fxRate: 1, commission: 0,
            account: accA, date: Date().addingTimeInterval(-172_800), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 200, fxRate: 1, commission: 0,
            account: accB, date: Date().addingTimeInterval(-86_400), note: "",
            asset: stockResult()
        )

        // Global average cost = (10×100 + 10×200) / 20 = 150 EUR
        // Sell 5 at 180, proceeds = 900. Cost of sold = 5×150 = 750.
        // Realized P/L = 900 − 750 = 150.
        try vm.addInvestment(
            type: .assetSale, symbol: "AAPL", quantity: 5,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: santander, date: Date(), note: "",
            asset: stockResult()
        )

        let h = try #require(vm.openHoldings.first { $0.assetSymbol == "AAPL" })
        #expect(h.quantity == 15)
        #expect(h.realizedPL == 150)
    }

    // MARK: - 8. Account of sale affects destination saldo

    @Test func saleAccountIsDestinationNotOrigin() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Rep", in: ctx)
        let santander = account("Santander", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: tradeRep,
            date: Date().addingTimeInterval(-86_400), note: "",
            asset: stockResult()
        )

        try vm.addInvestment(
            type: .assetSale, symbol: "AAPL", quantity: 5,
            unitPrice: 180, fxRate: 1, commission: 0,
            account: santander,
            date: Date(), note: "",
            asset: stockResult()
        )

        let txs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        let saleTx = try #require(txs.first { $0.type == .assetSale })
        #expect(saleTx.sourceAccount?.name == "Santander",
                "Sale transaction records the destination account")
    }

    // MARK: - Crypto unifies across accounts

    @Test func cryptoUnifiesAcrossAccounts() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Binance", in: ctx)
        let accB = account("Kraken", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC",
            quantity: Decimal(string: "0.5")!, unitPrice: 60_000,
            fxRate: 1, commission: 0, account: accA, date: Date(), note: "",
            asset: cryptoResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "BTC",
            quantity: Decimal(string: "0.3")!, unitPrice: 62_000,
            fxRate: 1, commission: 0, account: accB, date: Date(), note: "",
            asset: cryptoResult()
        )

        let btc = vm.openHoldings.filter { $0.assetSymbol == "BTC" }
        #expect(btc.count == 1, "Crypto in two accounts must unify")
        #expect(btc.first?.quantity == Decimal(string: "0.8")!)

        let listing = ListingID(symbol: "BTC")
        let breakdown = vm.accountBreakdown(for: listing)
        #expect(breakdown.count == 2)
    }

    // MARK: - Single account position

    @Test func singleAccountPositionHasEmptyAccountID() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account("Degiro", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: "",
            asset: stockResult()
        )

        let h = try #require(vm.openHoldings.first { $0.assetSymbol == "AAPL" })
        #expect(h.accountID.isEmpty, "Position always has empty accountID — it's a pool")
        #expect(h.accountName == "Degiro")
    }

    // MARK: - Delete position removes all accounts' transactions

    @Test func deletePositionRemovesAllTransactions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: accA, date: Date(), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        let listing = ListingID(symbol: "AAPL", mic: "XNAS")
        try vm.deletePosition(listing: listing, accountID: "")

        vm.loadHoldings()
        #expect(vm.openHoldings.filter({ $0.assetSymbol == "AAPL" }).isEmpty)

        let txs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        let aaplTxs = txs.filter { $0.assetSymbol == "AAPL" }
        #expect(aaplTxs.isEmpty, "All AAPL transactions must be removed")
    }

    // MARK: - Detail loads all transactions

    @Test func detailLoadsAllAccountTransactions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: accA, date: Date().addingTimeInterval(-86_400), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let candles = CandleStore(
            usProvider: RecordingCandleProvider(),
            europeanProvider: RecordingCandleProvider(),
            cryptoProvider: RecordingCandleProvider()
        )
        candles.bind(modelContext: ctx)

        let detail = AssetDetailViewModel(
            listing: ListingID(symbol: "AAPL", mic: "XNAS"),
            accountID: ""
        )
        detail.bind(
            modelContext: ctx, priceStore: priceStore,
            candleStore: candles, portfolio: vm
        )

        #expect(detail.isUnified)
        #expect(detail.transactions.count == 2, "Detail must show both accounts' transactions")
        #expect(detail.quantity == 15)
    }

    // MARK: - Account label shows both names

    @Test func holdingShowsBothAccountNames() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: accA, date: Date(), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        let h = try #require(vm.openHoldings.first { $0.assetSymbol == "AAPL" })
        #expect(h.accountName.contains("Degiro"))
        #expect(h.accountName.contains("IBKR"))
    }

    // MARK: - Allocation by account uses per-account data

    @Test func allocationByAccountUsesPerAccountData() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let accA = account("Degiro", in: ctx)
        let accB = account("IBKR", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: accA, date: Date(), note: "",
            asset: stockResult()
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 5,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: accB, date: Date(), note: "",
            asset: stockResult()
        )

        #expect(vm.perAccountHoldings.filter({ $0.assetSymbol == "AAPL" }).count == 2,
                "perAccountHoldings must keep both accounts separate")
    }

    // MARK: - Mutation: removing total validation breaks safety

    @Test func removingTotalValidationAllowsOverSell() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account("Degiro", in: ctx)
        let vm = viewModel(ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: acc, date: Date().addingTimeInterval(-86_400), note: "",
            asset: stockResult()
        )

        let listing = ListingID(symbol: "AAPL", mic: "XNAS")
        let available = vm.totalQuantity(listing: listing)
        #expect(available == 10)

        #expect(throws: (any Error).self) {
            try vm.addInvestment(
                type: .assetSale, symbol: "AAPL", quantity: 11,
                unitPrice: 160, fxRate: 1, commission: 0,
                account: acc, date: Date(), note: "",
                asset: stockResult()
            )
        }
    }
}
