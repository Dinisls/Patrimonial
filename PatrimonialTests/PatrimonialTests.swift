import Foundation
import Testing
import SwiftData
@testable import Patrimonial

struct PatrimonialTests {

    @Test func swiftDataContainerInitializes() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        #expect(container.schema.entities.count >= 4)
    }

    @Test func accountBalanceStartsAtZero() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let account = Account(name: "Test", type: .checking)
        context.insert(account)
        try context.save()
        #expect(account.balance == 0)
    }

    @Test func transactionAffectsAccountBalance() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let account = Account(name: "Corrente", type: .checking)
        context.insert(account)

        let income = FinancialTransaction(
            type: .income,
            amount: 1000,
            sourceAccount: account
        )
        context.insert(income)
        try context.save()

        #expect(account.balance == 1000)
    }

    @Test func currencyFormatterProducesOutput() {
        let result = CurrencyFormatter.format(99.99, currency: "EUR")
        #expect(!result.isEmpty)
    }
}
