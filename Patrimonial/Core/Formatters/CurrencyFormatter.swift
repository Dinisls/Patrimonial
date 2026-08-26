import Foundation

enum CurrencyFormatter {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale.current
        return f
    }()

    static func format(_ value: Decimal, currency: String = "EUR") -> String {
        let f = formatter
        f.currencyCode = currency
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func formatPercentage(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? "\(value)%"
    }
}
