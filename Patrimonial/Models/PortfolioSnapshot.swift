import Foundation
import SwiftData

@Model
final class PortfolioSnapshot {
    var date: Date
    var totalValue: Decimal
    var totalCost: Decimal
    var cashTotal: Decimal
    var createdAt: Date

    var totalPL: Decimal { totalValue - totalCost }

    init(date: Date, totalValue: Decimal, totalCost: Decimal, cashTotal: Decimal) {
        self.date = date
        self.totalValue = totalValue
        self.totalCost = totalCost
        self.cashTotal = cashTotal
        self.createdAt = Date()
    }
}
