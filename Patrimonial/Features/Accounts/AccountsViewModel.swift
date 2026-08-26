import Foundation
import SwiftData

@Observable
final class AccountsViewModel {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func add(name: String, type: AccountType, currency: String = "EUR", colorHex: String = "007AFF") {
        let account = Account(name: name, type: type, currency: currency, colorHex: colorHex)
        modelContext.insert(account)
        try? modelContext.save()
    }

    func delete(_ account: Account) {
        modelContext.delete(account)
        try? modelContext.save()
    }

    func update(_ account: Account, name: String, type: AccountType, colorHex: String) {
        account.name = name
        account.type = type
        account.icon = type.icon
        account.colorHex = colorHex
        try? modelContext.save()
    }
}
