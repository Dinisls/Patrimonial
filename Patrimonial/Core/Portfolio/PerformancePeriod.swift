import Foundation

enum PerformancePeriod: String, CaseIterable, Codable, Sendable {
    case oneDay = "1D"
    case oneWeek = "1S"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1A"
    case ytd = "YTD"

    var label: String {
        switch self {
        case .oneDay: "1 Dia"
        case .oneWeek: "1 Semana"
        case .oneMonth: "1 Mês"
        case .threeMonths: "3 Meses"
        case .sixMonths: "6 Meses"
        case .oneYear: "1 Ano"
        case .ytd: "YTD"
        }
    }

    func cutoffDate(from reference: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .oneDay:
            return cal.date(byAdding: .day, value: -1, to: reference)!
        case .oneWeek:
            return cal.date(byAdding: .day, value: -7, to: reference)!
        case .oneMonth:
            return cal.date(byAdding: .month, value: -1, to: reference)!
        case .threeMonths:
            return cal.date(byAdding: .month, value: -3, to: reference)!
        case .sixMonths:
            return cal.date(byAdding: .month, value: -6, to: reference)!
        case .oneYear:
            return cal.date(byAdding: .year, value: -1, to: reference)!
        case .ytd:
            return cal.date(from: DateComponents(
                year: cal.component(.year, from: reference), month: 1, day: 1
            ))!
        }
    }
}
