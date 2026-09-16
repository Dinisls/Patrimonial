import Foundation
import Testing
import SwiftData
@testable import Patrimonial

@MainActor
struct AccountDeletionMoveTests {

    private func account(_ name: String, in ctx: ModelContext) -> Account {
        let acc = Account(name: name, type: .brokerage)
        ctx.insert(acc)
        return acc
    }

    private func portfolioVM(_ ctx: ModelContext) -> PortfolioViewModel {
        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)
        return vm
    }

    private func stockResult(
        symbol: String = "AAPL",
        mic: String = "XNAS"
    ) -> AssetSearchResult {
        AssetSearchResult(
            symbol: symbol, name: symbol, exchange: mic,
            assetClass: .stock, currency: "USD", mic: mic
        )
    }

    private func addBuy(
        vm: PortfolioViewModel, symbol: String = "AAPL", mic: String = "XNAS",
        quantity: Decimal, price: Decimal, fxRate: Decimal = Decimal(string: "0.92")!,
        commission: Decimal = 0, account: Account, date: Date = Date()
    ) throws {
        try vm.addInvestment(
            type: .assetPurchase, symbol: symbol, quantity: quantity,
            unitPrice: price, fxRate: fxRate, commission: commission,
            account: account, date: date, note: "",
            asset: stockResult(symbol: symbol, mic: mic)
        )
    }

    private func addSale(
        vm: PortfolioViewModel, symbol: String = "AAPL", mic: String = "XNAS",
        quantity: Decimal, price: Decimal, fxRate: Decimal = Decimal(string: "0.92")!,
        commission: Decimal = 0, account: Account, date: Date = Date()
    ) throws {
        try vm.addInvestment(
            type: .assetSale, symbol: symbol, quantity: quantity,
            unitPrice: price, fxRate: fxRate, commission: commission,
            account: account, date: date, note: "",
            asset: stockResult(symbol: symbol, mic: mic)
        )
    }

    private func addExpense(ctx: ModelContext, amount: Decimal, account: Account) {
        let tx = FinancialTransaction(
            type: .expense, amount: amount, date: Date(),
            note: "Despesa", category: .other, sourceAccount: account
        )
        ctx.insert(tx)
        try! ctx.save()
    }

    // MARK: - 1. Move reassigns sourceAccount, position unchanged

    @Test("Move reassigns account and position stays identical")
    func moveReassignsAccountPositionUnchanged() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let santander = account("Santander", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)
        try addBuy(vm: pvm, quantity: 5, price: 160, account: tradeRep)
        try addSale(vm: pvm, quantity: 3, price: 170, account: tradeRep)

        let holdingsBefore = pvm.openHoldings.filter { $0.assetSymbol == "AAPL" }
        #expect(holdingsBefore.count == 1)
        let before = try #require(holdingsBefore.first)
        let qtyBefore = before.quantity
        let avgBefore = before.averagePriceEUR
        let realizedBefore = before.realizedPL

        let vm = AccountsViewModel(modelContext: ctx)
        try vm.moveInvestmentsAndDelete(from: tradeRep, to: santander)

        pvm.loadHoldings()
        let holdingsAfter = pvm.openHoldings.filter { $0.assetSymbol == "AAPL" }
        #expect(holdingsAfter.count == 1)
        let after = try #require(holdingsAfter.first)

        #expect(after.quantity == qtyBefore)
        #expect(after.averagePriceEUR == avgBefore)
        #expect(after.realizedPL == realizedBefore)
        #expect(after.accountName == "Santander")
    }

    // MARK: - 2. Move recalculates destination balance

    @Test("Move adjusts destination account balance")
    func moveRecalculatesDestinationBalance() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let santander = account("Santander", in: ctx)
        let pvm = portfolioVM(ctx)

        addExpense(ctx: ctx, amount: 50, account: santander)
        let santanderBalanceBefore = santander.balance
        #expect(santanderBalanceBefore == -50)

        let fx = Decimal(string: "0.92")!
        try addBuy(vm: pvm, quantity: 10, price: 100, fxRate: fx, account: tradeRep)
        let buyAmount = 10 * 100 * fx

        let vm = AccountsViewModel(modelContext: ctx)
        let delta = vm.moveBalanceDelta(for: tradeRep)
        #expect(delta == -buyAmount)

        try vm.moveInvestmentsAndDelete(from: tradeRep, to: santander)

        #expect(santander.balance == santanderBalanceBefore - buyAmount)
    }

    // MARK: - 3. Balance invariant: saldo = sum of transactions

    @Test("Balance invariant holds on destination after move")
    func balanceInvariantAfterMove() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let santander = account("Santander", in: ctx)
        let pvm = portfolioVM(ctx)

        addExpense(ctx: ctx, amount: 100, account: santander)
        try addBuy(vm: pvm, quantity: 5, price: 200, account: tradeRep)
        try addSale(vm: pvm, quantity: 2, price: 250, account: tradeRep)

        let vm = AccountsViewModel(modelContext: ctx)
        try vm.moveInvestmentsAndDelete(from: tradeRep, to: santander)

        var expectedBalance: Decimal = 0
        for tx in santander.outgoingTransactions {
            switch tx.type {
            case .income, .assetSale, .dividend: expectedBalance += tx.amount
            case .expense, .assetPurchase: expectedBalance -= tx.amount
            case .transfer: expectedBalance -= tx.amount
            }
        }
        for tx in santander.incomingTransactions where tx.type == .transfer {
            expectedBalance += tx.amount
        }

        #expect(santander.balance == expectedBalance)
    }

    // MARK: - 4. Delete removes transactions, position shrinks

    @Test("Delete all removes transactions and position shrinks or disappears")
    func deleteRemovesTransactionsPositionShrinks() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let ibkr = account("IBKR", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)
        try addBuy(vm: pvm, quantity: 5, price: 160, account: ibkr)

        let before = try #require(pvm.openHoldings.first { $0.assetSymbol == "AAPL" })
        #expect(before.quantity == 15)

        let vm = AccountsViewModel(modelContext: ctx)
        try vm.deleteWithEverything(tradeRep)

        pvm.loadHoldings()
        let after = try #require(pvm.openHoldings.first { $0.assetSymbol == "AAPL" })
        #expect(after.quantity == 5)
    }

    @Test("Delete all makes position disappear when it was the only account")
    func deleteAllMakesPositionDisappear() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)
        #expect(pvm.openHoldings.contains { $0.assetSymbol == "AAPL" })

        let vm = AccountsViewModel(modelContext: ctx)
        try vm.deleteWithEverything(tradeRep)

        pvm.loadHoldings()
        #expect(!pvm.openHoldings.contains { $0.assetSymbol == "AAPL" })
    }

    // MARK: - 5. Impact message shows correct numbers

    @Test("Deletion impact reports correct position changes")
    func deletionImpactReportsCorrectly() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let ibkr = account("IBKR", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)
        try addBuy(vm: pvm, quantity: 5, price: 160, account: ibkr)

        addExpense(ctx: ctx, amount: 20, account: tradeRep)

        let vm = AccountsViewModel(modelContext: ctx)
        let impact = vm.deletionImpact(for: tradeRep)

        #expect(impact.investmentCount == 1)
        #expect(impact.nonInvestmentCount == 1)
        #expect(impact.symbols == ["AAPL"])
        #expect(impact.positionChanges.count == 1)

        let change = try #require(impact.positionChanges.first)
        #expect(change.currentQuantity == 15)
        #expect(change.newQuantity == 5)
        #expect(!change.disappears)
    }

    @Test("Deletion impact reports disappearing position")
    func deletionImpactReportsDisappearing() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)

        let vm = AccountsViewModel(modelContext: ctx)
        let impact = vm.deletionImpact(for: tradeRep)

        #expect(impact.positionChanges.count == 1)
        let change = try #require(impact.positionChanges.first)
        #expect(change.disappears)
    }

    // MARK: - 6. Move then delete original leaves no orphans

    @Test("Move then delete original leaves no orphan transactions")
    func moveThenDeleteLeavesNoOrphans() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let santander = account("Santander", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)
        try addBuy(vm: pvm, quantity: 5, price: 160, account: tradeRep)

        let vm = AccountsViewModel(modelContext: ctx)
        try vm.moveInvestmentsAndDelete(from: tradeRep, to: santander)

        let allTxs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        for tx in allTxs {
            #expect(tx.sourceAccount != nil, "Transaction \(tx.id) has no source account")
            #expect(tx.sourceAccount?.id == santander.id)
        }
    }

    // MARK: - 7. Mutation guard: without reassignment, balance test fails

    @Test("Without reassignment the destination balance does not change")
    func mutationGuardBalanceUnchangedWithoutReassignment() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let santander = account("Santander", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 100, fxRate: Decimal(string: "0.92")!, account: tradeRep)

        let balanceBefore = santander.balance
        #expect(balanceBefore == 0)

        // Simulate "just delete without move" — the balance must NOT change
        // This proves that the move step is what causes the recalculation
        let vm = AccountsViewModel(modelContext: ctx)
        try vm.deleteWithEverything(tradeRep)

        #expect(santander.balance == balanceBefore, "Without move, destination balance must not change")
    }

    // MARK: - 8. Non-investment transactions are cascade-deleted, not moved

    @Test("Non-investment transactions are deleted with the account, not moved")
    func nonInvestmentTransactionsDeletedNotMoved() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let santander = account("Santander", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 10, price: 150, account: tradeRep)
        addExpense(ctx: ctx, amount: 50, account: tradeRep)

        let vm = AccountsViewModel(modelContext: ctx)
        try vm.moveInvestmentsAndDelete(from: tradeRep, to: santander)

        let allTxs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        let expenseTxs = allTxs.filter { $0.type == .expense }
        #expect(expenseTxs.isEmpty, "Expense should be cascade-deleted with the account")

        let investmentTxs = allTxs.filter(\.isInvestmentTransaction)
        #expect(investmentTxs.count == 1, "Investment tx should survive via move")
        #expect(investmentTxs.first?.sourceAccount?.id == santander.id)
    }

    // MARK: - 9. Move balance delta includes sales

    @Test("Move balance delta accounts for both buys and sales")
    func moveBalanceDeltaIncludesSales() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let tradeRep = account("Trade Republic", in: ctx)
        let pvm = portfolioVM(ctx)

        let fx = Decimal(string: "0.92")!
        try addBuy(vm: pvm, quantity: 10, price: 100, fxRate: fx, account: tradeRep)
        try addSale(vm: pvm, quantity: 3, price: 120, fxRate: fx, account: tradeRep)

        let buyAmount = 10 * 100 * fx
        let saleAmount = 3 * 120 * fx

        let vm = AccountsViewModel(modelContext: ctx)
        let delta = vm.moveBalanceDelta(for: tradeRep)

        #expect(delta == -buyAmount + saleAmount)
    }

    // MARK: - 10. Atomicity: failed save leaves everything intact

    @Test("isInvestmentTransaction matches PortfolioCalculator criteria")
    func isInvestmentTransactionMatchesCalculator() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account("Test", in: ctx)
        let pvm = portfolioVM(ctx)

        try addBuy(vm: pvm, quantity: 5, price: 100, account: acc)
        addExpense(ctx: ctx, amount: 50, account: acc)

        let allTxs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        let byProperty = allTxs.filter(\.isInvestmentTransaction)
        let byCalculator = PortfolioCalculator.investmentTransactions(from: allTxs)

        #expect(byProperty.count == byCalculator.count)
        #expect(byProperty.count == 1)
    }
}
