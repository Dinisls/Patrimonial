import Foundation
import SwiftData

@Observable
final class DashboardViewModel {
    var accounts: [Account] = []
    var recentTransactions: [FinancialTransaction] = []

    var totalNetWorth: Decimal {
        accounts.reduce(0) { $0 + $1.balance }
    }

    var topAccounts: [Account] {
        Array(accounts.sorted { $0.balance > $1.balance }.prefix(3))
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func refresh() {
        let accountDescriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)])
        accounts = (try? modelContext.fetch(accountDescriptor)) ?? []

        var txDescriptor = FetchDescriptor<FinancialTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        txDescriptor.fetchLimit = 5
        recentTransactions = (try? modelContext.fetch(txDescriptor)) ?? []
    }
}
