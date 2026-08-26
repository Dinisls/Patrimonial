import Foundation
import SwiftData

enum AccountType: String, Codable, CaseIterable, Identifiable {
    case checking = "checking"
    case savings = "savings"
    case creditCard = "creditCard"
    case brokerage = "brokerage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .checking: String(localized: "account_type_checking")
        case .savings: String(localized: "account_type_savings")
        case .creditCard: String(localized: "account_type_credit_card")
        case .brokerage: String(localized: "account_type_brokerage")
        }
    }

    var icon: String {
        switch self {
        case .checking: "banknote"
        case .savings: "building.columns"
        case .creditCard: "creditcard"
        case .brokerage: "chart.line.uptrend.xyaxis"
        }
    }
}

@Model
final class Account {
    var id: UUID
    var name: String
    var type: AccountType
    var currency: String
    var icon: String
    var colorHex: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \FinancialTransaction.sourceAccount)
    var outgoingTransactions: [FinancialTransaction] = []

    @Relationship(deleteRule: .nullify, inverse: \FinancialTransaction.destinationAccount)
    var incomingTransactions: [FinancialTransaction] = []

    var balance: Decimal {
        var total: Decimal = 0
        for transaction in outgoingTransactions {
            switch transaction.type {
            case .income, .assetSale, .dividend:
                total += transaction.amount
            case .expense, .assetPurchase:
                total -= transaction.amount
            case .transfer:
                total -= transaction.amount
            }
        }
        for transaction in incomingTransactions {
            if transaction.type == .transfer {
                total += transaction.amount
            }
        }
        return total
    }

    init(
        name: String,
        type: AccountType,
        currency: String = "EUR",
        icon: String? = nil,
        colorHex: String = "007AFF"
    ) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.currency = currency
        self.icon = icon ?? type.icon
        self.colorHex = colorHex
        self.createdAt = Date()
    }
}
