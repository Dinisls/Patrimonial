import Foundation
import SwiftData

enum TransactionType: String, Codable, CaseIterable, Identifiable {
    case expense = "expense"
    case income = "income"
    case transfer = "transfer"
    case assetPurchase = "assetPurchase"
    case assetSale = "assetSale"
    case dividend = "dividend"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expense: String(localized: "transaction_type_expense")
        case .income: String(localized: "transaction_type_income")
        case .transfer: String(localized: "transaction_type_transfer")
        case .assetPurchase: "Compra"
        case .assetSale: "Venda"
        case .dividend: "Dividendo"
        }
    }
}

enum TransactionCategory: String, Codable, CaseIterable, Identifiable {
    case food = "food"
    case transport = "transport"
    case rent = "rent"
    case salary = "salary"
    case leisure = "leisure"
    case health = "health"
    case subscriptions = "subscriptions"
    case investments = "investments"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .food: String(localized: "category_food")
        case .transport: String(localized: "category_transport")
        case .rent: String(localized: "category_rent")
        case .salary: String(localized: "category_salary")
        case .leisure: String(localized: "category_leisure")
        case .health: String(localized: "category_health")
        case .subscriptions: String(localized: "category_subscriptions")
        case .investments: String(localized: "category_investments")
        case .other: String(localized: "category_other")
        }
    }

    var icon: String {
        switch self {
        case .food: "fork.knife"
        case .transport: "car"
        case .rent: "house"
        case .salary: "briefcase"
        case .leisure: "theatermasks"
        case .health: "heart"
        case .subscriptions: "repeat"
        case .investments: "chart.bar"
        case .other: "ellipsis.circle"
        }
    }
}

enum Recurrence: String, Codable {
    case none
    case weekly
    case bimonthly
    case monthly
}

@Model
final class FinancialTransaction {
    var id: UUID
    var type: TransactionType
    var amount: Decimal
    var date: Date
    var note: String
    var category: TransactionCategory?
    var customCategoryID: String? = nil
    var recurrence: Recurrence
    var recurrenceDay: Int? = nil
    var recurrenceDay2: Int? = nil
    var recurrenceSourceID: String? = nil

    // Investment fields (nil for non-investment transactions).
    // amount = total EUR deducted/credited to the account, commissions included.
    // assetQuantity × assetUnitPrice × assetFXRate + commission ≈ amount.
    var assetSymbol: String? = nil
    /// The venue the listing was bought on, canonicalised.
    ///
    /// Optional with a default, and with no `@Attribute(.unique)` anywhere near
    /// it: that is what lets an existing store open without a schema version
    /// bump. Uniqueness of a listing is enforced in code — `ListingID` — because
    /// a failed migration on a unique attribute is unrecoverable on a phone,
    /// and that outweighs what the schema would have guaranteed.
    ///
    /// Nil means the venue was never recorded, not that the instrument has
    /// none. Such a transaction keys on the bare symbol and behaves exactly as
    /// it did before this field existed.
    var assetMIC: String? = nil
    var assetQuantity: Decimal? = nil
    var assetUnitPrice: Decimal? = nil
    var assetFXRate: Decimal? = nil
    var commission: Decimal? = nil

    var sourceAccount: Account?
    var destinationAccount: Account?

    init(
        type: TransactionType,
        amount: Decimal,
        date: Date = Date(),
        note: String = "",
        category: TransactionCategory? = nil,
        recurrence: Recurrence = .none,
        sourceAccount: Account? = nil,
        destinationAccount: Account? = nil
    ) {
        self.id = UUID()
        self.type = type
        self.amount = amount
        self.date = date
        self.note = note
        self.category = category
        self.recurrence = recurrence
        self.sourceAccount = sourceAccount
        self.destinationAccount = destinationAccount
    }
}
