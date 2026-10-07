import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// The list and the balance must agree on direction for every transaction type:
/// a dividend that raises the balance cannot be listed as an expense.
@MainActor
struct TransactionSignTests {

    @Test(arguments: [
        TransactionType.income, .expense, .assetPurchase, .assetSale, .dividend,
    ])
    func listedSignMatchesTheBalanceEffect(type: TransactionType) throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Conta", type: .brokerage)
        ctx.insert(acc)

        let tx = FinancialTransaction(
            type: type, amount: Decimal(string: "0.50")!, date: Date(),
            note: "x", category: .investments, sourceAccount: acc
        )
        if type == .assetPurchase || type == .assetSale || type == .dividend {
            tx.assetSymbol = "NVD"
            tx.assetQuantity = 1
            tx.assetUnitPrice = Decimal(string: "0.50")!
            tx.assetFXRate = 1
        }
        ctx.insert(tx)
        try ctx.save()

        let store = AppStore()
        store.bind(ctx)
        store.reload()

        let row = try #require(store.transactions.first { $0.txID == tx.id })
        #expect((row.amount > 0) == (acc.balance > 0))
    }

    @Test func aDividendIsListedAsMoneyIn() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Conta", type: .brokerage)
        ctx.insert(acc)
        let tx = FinancialTransaction(
            type: .dividend, amount: Decimal(string: "0.50")!, date: Date(),
            note: "Dividendo NVD", category: .investments, sourceAccount: acc
        )
        tx.assetSymbol = "NVD"
        ctx.insert(tx)
        try ctx.save()

        let store = AppStore()
        store.bind(ctx)
        store.reload()

        let row = try #require(store.transactions.first { $0.txID == tx.id })
        #expect(row.amount == 0.5)
    }
}
