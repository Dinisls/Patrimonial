import Foundation
import SwiftData

@Observable
final class TransactionsViewModel {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func addExpense(amount: Decimal, account: Account, category: TransactionCategory, note: String, date: Date) {
        let tx = FinancialTransaction(
            type: .expense,
            amount: amount,
            date: date,
            note: note,
            category: category,
            sourceAccount: account
        )
        modelContext.insert(tx)
        try? modelContext.save()
    }

    func addIncome(amount: Decimal, account: Account, category: TransactionCategory, note: String, date: Date) {
        let tx = FinancialTransaction(
            type: .income,
            amount: amount,
            date: date,
            note: note,
            category: category,
            sourceAccount: account
        )
        modelContext.insert(tx)
        try? modelContext.save()
    }

    func addTransfer(amount: Decimal, from source: Account, to destination: Account, note: String, date: Date) {
        let tx = FinancialTransaction(
            type: .transfer,
            amount: amount,
            date: date,
            note: note,
            sourceAccount: source,
            destinationAccount: destination
        )
        modelContext.insert(tx)
        try? modelContext.save()
    }

    func delete(_ transaction: FinancialTransaction) {
        modelContext.delete(transaction)
        try? modelContext.save()
    }
}
