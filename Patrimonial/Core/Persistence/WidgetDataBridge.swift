import Foundation
import SwiftData

enum WidgetDataBridge {
    static let appGroup = "group.pt.patrimonial.shared"
    private static let portfolioKey = "portfolioSummary"
    private static let cashKey = "cashSummary"

    // MARK: - Portfolio

    struct PortfolioSummary: Codable {
        var totalValue: Decimal
        var totalCost: Decimal
        var dayChangeAbsolute: Decimal
        var dayChangePercent: Decimal
        var positionCount: Int
        var topPositions: [Position]
        var updatedAt: Date

        var totalPL: Decimal { totalValue - totalCost }
        var totalPLPercent: Decimal {
            totalCost > 0 ? (totalPL / totalCost) * 100 : 0
        }
    }

    struct Position: Codable {
        var symbol: String
        var name: String
        var value: Decimal
        var dayChangePercent: Decimal?
        var weight: Decimal
    }

    @MainActor
    static func write(_ summary: PortfolioSummary) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(summary) else { return }
        defaults.set(data, forKey: portfolioKey)
    }

    static func readPortfolio() -> PortfolioSummary? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: portfolioKey)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PortfolioSummary.self, from: data)
    }

    static func read() -> PortfolioSummary? { readPortfolio() }

    // MARK: - Cash / Accounts

    struct CashSummary: Codable {
        var totalBalance: Decimal
        var monthIncome: Decimal
        var monthExpenses: Decimal
        var accounts: [AccountEntry]
        var updatedAt: Date

        var monthNet: Decimal { monthIncome - monthExpenses }
    }

    struct AccountEntry: Codable {
        var name: String
        var icon: String
        var balance: Decimal
        var colorHex: String
    }

    @MainActor
    static func writeCash(_ summary: CashSummary) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(summary) else { return }
        defaults.set(data, forKey: cashKey)
    }

    static func readCash() -> CashSummary? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: cashKey)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CashSummary.self, from: data)
    }

    @MainActor
    static func clearAll() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.removeObject(forKey: portfolioKey)
        defaults.removeObject(forKey: cashKey)
    }

    // MARK: - Publish from ModelContext (app target only)

    #if !WIDGET_EXTENSION
    @MainActor
    static func publishCash(from ctx: ModelContext) {
        let accounts = (try? ctx.fetch(FetchDescriptor<Account>())) ?? []

        let cal = Calendar.current
        let now = Date()
        let currentMonth = cal.component(.month, from: now)
        let currentYear = cal.component(.year, from: now)

        let allTx = (try? ctx.fetch(FetchDescriptor<FinancialTransaction>())) ?? []

        var receita = 0.0
        var despesas = 0.0
        for tx in allTx {
            guard cal.component(.month, from: tx.date) == currentMonth,
                  cal.component(.year, from: tx.date) == currentYear else { continue }
            let amount = Double(truncating: tx.amount as NSNumber)
            switch tx.type {
            case .income:
                receita += amount
            case .transfer:
                receita += amount
                despesas += amount
            default:
                despesas += amount
            }
        }

        let entries: [AccountEntry] = accounts
            .sorted { $0.balance > $1.balance }
            .prefix(5)
            .map { AccountEntry(name: $0.name, icon: $0.icon, balance: $0.balance, colorHex: $0.colorHex) }

        writeCash(CashSummary(
            totalBalance: accounts.reduce(0) { $0 + $1.balance },
            monthIncome: Decimal(receita), monthExpenses: Decimal(despesas),
            accounts: entries, updatedAt: Date()
        ))
    }
    #endif
}
