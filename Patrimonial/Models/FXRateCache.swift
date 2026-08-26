import Foundation
import SwiftData

@Model
final class FXRateCache {
    var fromCurrency: String
    var toCurrency: String
    var dateString: String
    var rate: Decimal
    var createdAt: Date

    init(fromCurrency: String, toCurrency: String, dateString: String, rate: Decimal) {
        self.fromCurrency = fromCurrency
        self.toCurrency = toCurrency
        self.dateString = dateString
        self.rate = rate
        self.createdAt = Date()
    }
}
