import Foundation
import SwiftData

@Model
final class CustomCategory {
    var id: UUID
    var name: String
    var symbol: String    // SF Symbol name
    var colorHex: String  // 6-char hex sem #
    var isExpense: Bool
    var isIncome: Bool
    var createdAt: Date

    init(name: String, symbol: String, colorHex: String, isExpense: Bool, isIncome: Bool) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.isExpense = isExpense
        self.isIncome = isIncome
        self.createdAt = Date()
    }
}
