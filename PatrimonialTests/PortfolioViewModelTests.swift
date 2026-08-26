import Foundation
import Testing
import SwiftData
@testable import Patrimonial

struct PortfolioViewModelTests {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        try PersistenceController.makeContainer(inMemory: true)
    }

    private func makeBrokerageAccount(in ctx: ModelContext, name: String = "IBKR") -> Account {
        let acc = Account(name: name, type: .brokerage)
        ctx.insert(acc)
        try! ctx.save()
        return acc
    }

    @MainActor
    private func makeVM(ctx: ModelContext, fxProvider: (any FXRateProvider)? = nil) -> PortfolioViewModel {
        let vm = PortfolioViewModel()
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: fxProvider ?? MockFXRateProvider())
        return vm
    }

    // MARK: - addInvestment saves transaction and updates holdings

    @MainActor
    @Test func addInvestmentSavesTransactionAndUpdatesHoldings() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        try vm.addInvestment(
            type: .assetPurchase,
            symbol: "AAPL",
            quantity: 10,
            unitPrice: 150,
            fxRate: Decimal(string: "0.92")!,
            commission: 5,
            account: acc,
            date: Date(),
            note: "Test buy"
        )

        let descriptor = FetchDescriptor<FinancialTransaction>()
        let txs = try ctx.fetch(descriptor)
        let investTx = txs.filter { $0.type == .assetPurchase }
        #expect(investTx.count == 1)
        #expect(investTx[0].assetSymbol == "AAPL")
        #expect(investTx[0].assetQuantity == 10)
        #expect(investTx[0].assetUnitPrice == 150)

        #expect(vm.openHoldings.count == 1)
        #expect(vm.openHoldings[0].assetSymbol == "AAPL")
        #expect(vm.openHoldings[0].quantity == 10)
    }

    // MARK: - Save failure triggers rollback — transaction is not persisted

    @MainActor
    @Test func saveFailureRollsBackTransaction() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        struct ForcedSaveError: Error {}

        vm.saveHandler = { _ in throw ForcedSaveError() }

        #expect(throws: ForcedSaveError.self) {
            try vm.addInvestment(
                type: .assetPurchase, symbol: "AAPL", quantity: 10,
                unitPrice: 150, fxRate: 1, commission: 0,
                account: acc, date: Date(), note: ""
            )
        }

        let descriptor = FetchDescriptor<FinancialTransaction>()
        let txs = try ctx.fetch(descriptor)
        #expect(txs.isEmpty)
    }

    // MARK: - Sale above available quantity is blocked

    @MainActor
    @Test func saleAboveAvailableQuantityIsBlocked() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "MSFT", quantity: 5,
            unitPrice: 400, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: ""
        )

        #expect(throws: PortfolioCalculator.CalculationError.self) {
            try vm.addInvestment(
                type: .assetSale, symbol: "MSFT", quantity: 8,
                unitPrice: 420, fxRate: 1, commission: 0,
                account: acc, date: Date(), note: ""
            )
        }

        #expect(vm.openHoldings.count == 1)
        #expect(vm.openHoldings[0].quantity == 5)
    }

    // MARK: - Future date is blocked

    @MainActor
    @Test func futureDateIsBlocked() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        #expect(throws: PortfolioViewModel.ValidationError.self) {
            try vm.addInvestment(
                type: .assetPurchase, symbol: "AAPL", quantity: 10,
                unitPrice: 150, fxRate: 1, commission: 0,
                account: acc, date: tomorrow, note: ""
            )
        }

        let descriptor = FetchDescriptor<FinancialTransaction>()
        let txs = try ctx.fetch(descriptor)
        #expect(txs.isEmpty)
    }

    // MARK: - Totals ignore missing quotes and show warning

    @MainActor
    @Test func totalsIgnoreMissingQuotesAndShowWarning() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: ""
        )

        vm.loadHoldings()

        #expect(vm.hasMissingQuotes == true)
        #expect(vm.totalMarketValue == nil)
        #expect(vm.totalUnrealizedPL == nil)
        // Nothing priced at all, so there is no partial day change either —
        // the same rule the value total follows.
        #expect(vm.dayChangeTotal == nil)
        #expect(vm.totalCost == 1500)
    }

    // MARK: - Available quantity tracking

    @MainActor
    @Test func totalQuantityReturnsCorrectAmount() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        #expect(vm.totalQuantity(listing: ListingID(symbol: "AAPL")) == 0)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: ""
        )

        #expect(vm.totalQuantity(listing: ListingID(symbol: "AAPL")) == 10)

        try vm.addInvestment(
            type: .assetSale, symbol: "AAPL", quantity: 3,
            unitPrice: 160, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: ""
        )

        #expect(vm.totalQuantity(listing: ListingID(symbol: "AAPL")) == 7)
    }

    // MARK: - Multiple assets tracked separately

    @MainActor
    @Test func multipleAssetsTrackedSeparately() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acc = makeBrokerageAccount(in: ctx)
        let vm = makeVM(ctx: ctx)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10,
            unitPrice: 150, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: ""
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "MSFT", quantity: 5,
            unitPrice: 400, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: ""
        )

        #expect(vm.openHoldings.count == 2)
        let symbols = Set(vm.openHoldings.map(\.assetSymbol))
        #expect(symbols == ["AAPL", "MSFT"])
    }

    // MARK: - FX cache hit does not call provider again

    @MainActor
    @Test func fxCacheHitDoesNotCallProvider() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let tracker = TrackingFXRateProvider()
        let vm = makeVM(ctx: ctx, fxProvider: tracker)

        let rate1 = await vm.lookupFXRate(currency: "USD", on: Date())
        #expect(rate1 != nil)
        #expect(tracker.callCount == 1)

        let rate2 = await vm.lookupFXRate(currency: "USD", on: Date())
        #expect(rate2 == rate1)
        #expect(tracker.callCount == 1)
    }

    // MARK: - EUR always returns 1 without provider call

    @MainActor
    @Test func eurReturnsOneWithoutProviderCall() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let tracker = TrackingFXRateProvider()
        let vm = makeVM(ctx: ctx, fxProvider: tracker)

        let rate = await vm.lookupFXRate(currency: "EUR", on: Date())
        #expect(rate == FXRate.identity("EUR"))
        #expect(tracker.callCount == 0)
    }

    // MARK: - FX failure returns nil (does not block form)

    @MainActor
    @Test func fxNetworkFailureReturnsNil() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        var failing = MockFXRateProvider()
        failing.shouldFail = true
        let vm = makeVM(ctx: ctx, fxProvider: failing)

        let rate = await vm.lookupFXRate(currency: "USD", on: Date())
        #expect(rate == nil)
    }
}
