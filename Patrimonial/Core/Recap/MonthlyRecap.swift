import Foundation
import SwiftData

/// Everything the end-of-month story shows, computed once when it opens.
///
/// Rules:
/// - **Cashflow** is the same `net` the Fluxo de caixa screen shows for that
///   month, so the two never disagree.
/// - **Account balances** are reconstructed from each account's own
///   transactions: the balance at a boundary is today's balance minus every
///   movement dated at or after it. Accounts created after the month ended are
///   left out — they did not exist in that month.
/// - **Portfolio** comes from `PortfolioSnapshot`, which cannot be backfilled.
///   The start is the last snapshot on or before the 1st; if there is none, the
///   first snapshot inside the month, and the slide names that day. The end is
///   the last snapshot inside the month. No snapshot in the month → `nil`, and
///   the slide says so instead of drawing a number.
struct MonthlyRecap: Equatable, Identifiable {
    var id: String { "\(year)-\(month)" }
    struct AccountLine: Equatable, Identifiable {
        let id: UUID
        let name: String
        let colorHex: String
        let start: Double
        let end: Double
        /// Created during the month: its start is 0 because it did not exist yet.
        let isNew: Bool
        var delta: Double { end - start }
    }

    struct PortfolioLine: Equatable {
        let start: Double
        let startDate: Date
        let end: Double
        let endDate: Date
        let invested: Double
        var delta: Double { end - start }
        var deltaFraction: Double? { start > 0 ? delta / start : nil }
    }

    let month: Int
    let year: Int
    let net: Double
    let income: Double
    let expenses: Double
    let tier: Tier
    let accounts: [AccountLine]
    let portfolio: PortfolioLine?

    var accountsStart: Double { accounts.reduce(0) { $0 + $1.start } }
    var accountsEnd: Double { accounts.reduce(0) { $0 + $1.end } }

    /// "setembro", in pt-PT.
    var monthName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        return f.standaloneMonthSymbols[month - 1]
    }

    // MARK: - Tier

    /// Message band for the month's net cashflow. Lower bounds are inclusive.
    enum Tier: Equatable, CaseIterable {
        case negative      //  < 0
        case slow          //  0 ..< 100
        case good          //  100 ..< 200
        case great         //  200 ..< 500
        case amazing       //  500 ..< 1000
        case legendary     //  ≥ 1000

        static func forNet(_ net: Double) -> Tier {
            switch net {
            case ..<0:       .negative
            case ..<100:     .slow
            case ..<200:     .good
            case ..<500:     .great
            case ..<1000:    .amazing
            default:         .legendary
            }
        }

        var title: String {
            switch self {
            case .negative:  "Houve derrapagem"
            case .slow:      "No verde, por pouco"
            case .good:      "Bom mês"
            case .great:     "Muito bom mês"
            case .amazing:   "Mês incrível"
            case .legendary: "Mês lendário"
            }
        }

        var message: String {
            switch self {
            case .negative:
                "Gastaste mais do que ganhaste. Para a próxima tens de fazer melhor as contas à vida."
            case .slow:
                "Foi bom, mas a este ritmo vais demorar a lá chegar."
            case .good:
                "Estás no bom caminho. Continua assim e o mealheiro agradece."
            case .great:
                "Grande mês! Poupar assim já começa a fazer diferença."
            case .amazing:
                "Incrível! Este é o tipo de mês que muda o jogo."
            case .legendary:
                "Lendário. Mais de mil euros poupados num mês — estás noutro campeonato."
            }
        }

        var emoji: String {
            switch self {
            case .negative:  "😬"
            case .slow:      "🐢"
            case .good:      "👍"
            case .great:     "💪"
            case .amazing:   "🚀"
            case .legendary: "👑"
            }
        }
    }

    // MARK: - Build

    @MainActor
    static func build(month: Int, year: Int, store: AppStore, context ctx: ModelContext) -> MonthlyRecap? {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let nextMonthStart = cal.date(byAdding: .month, value: 1, to: monthStart)
        else { return nil }

        let cf = store.cashflowFor(month: month, year: year)

        let accounts = (try? ctx.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let lines: [AccountLine] = accounts.compactMap { acc in
            let deltas = movements(of: acc)
            let hasMovementBefore = deltas.contains { $0.date < nextMonthStart }
            // Did not exist during the month at all.
            guard acc.createdAt < nextMonthStart || hasMovementBefore else { return nil }

            let current = acc.balance
            let afterStart = deltas.filter { $0.date >= monthStart }.reduce(Decimal(0)) { $0 + $1.amount }
            let afterEnd = deltas.filter { $0.date >= nextMonthStart }.reduce(Decimal(0)) { $0 + $1.amount }
            let existedAtStart = acc.createdAt < monthStart || deltas.contains { $0.date < monthStart }
            return AccountLine(
                id: acc.id,
                name: acc.name,
                colorHex: acc.colorHex,
                start: Double(truncating: (current - afterStart) as NSNumber),
                end: Double(truncating: (current - afterEnd) as NSNumber),
                isNew: !existedAtStart
            )
        }

        let snapshots = PortfolioSnapshotRecorder.series(in: ctx)
        let allTx = (try? ctx.fetch(FetchDescriptor<FinancialTransaction>())) ?? []
        let invested = allTx
            .filter { $0.type == .assetPurchase && $0.date >= monthStart && $0.date < nextMonthStart }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let sold = allTx
            .filter { $0.type == .assetSale && $0.date >= monthStart && $0.date < nextMonthStart }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let netInvested = Double(truncating: (invested - sold) as NSNumber)
        let portfolio = portfolioLine(snapshots: snapshots.map { ($0.date, $0.totalValue) },
                                      monthStart: monthStart, nextMonthStart: nextMonthStart,
                                      invested: netInvested)

        return MonthlyRecap(
            month: month, year: year,
            net: cf.net, income: cf.receita, expenses: cf.despesas,
            tier: .forNet(cf.net),
            accounts: lines,
            portfolio: portfolio
        )
    }

    /// Pure so the boundary rules can be tested without a store.
    /// `snapshots` must be sorted oldest first.
    static func portfolioLine(snapshots: [(date: Date, value: Decimal)],
                              monthStart: Date, nextMonthStart: Date,
                              invested: Double = 0) -> PortfolioLine? {
        let inMonth = snapshots.filter { $0.date >= monthStart && $0.date < nextMonthStart }
        guard let last = inMonth.last else { return nil }
        let start = snapshots.last { $0.date <= monthStart } ?? inMonth.first!
        return PortfolioLine(
            start: Double(truncating: start.value as NSNumber), startDate: start.date,
            end: Double(truncating: last.value as NSNumber), endDate: last.date,
            invested: invested
        )
    }

    /// Signed movements from the account's point of view — the same rule as
    /// `Account.balance`.
    private static func movements(of acc: Account) -> [(date: Date, amount: Decimal)] {
        var out: [(date: Date, amount: Decimal)] = []
        for tx in acc.outgoingTransactions {
            switch tx.type {
            case .income, .assetSale, .dividend: out.append((tx.date, tx.amount))
            case .expense, .assetPurchase, .transfer: out.append((tx.date, -tx.amount))
            }
        }
        for tx in acc.incomingTransactions where tx.type == .transfer {
            out.append((tx.date, tx.amount))
        }
        return out
    }
}

// MARK: - When to show it

/// Shows last month's recap on the first launch of a new month, once.
///
/// Rules:
/// - The key stores the month that was **shown** ("2026-08"). The recap for the
///   previous month appears when the key is anything else.
/// - Months skipped while the app was closed are not replayed: only the month
///   that just ended matters.
/// - A month with no transactions at all is marked as seen without showing —
///   a fresh install should not open on a story of zeros.
enum MonthlyRecapSchedule {
    static let defaultsKey = "monthlyRecap.lastShown"

    static func key(month: Int, year: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    static func previousMonth(of now: Date, calendar cal: Calendar = .current) -> (month: Int, year: Int) {
        let prev = cal.date(byAdding: .month, value: -1, to: now)!
        return (cal.component(.month, from: prev), cal.component(.year, from: prev))
    }

    /// Which month to show now, or nil. Marks a month with no activity as seen.
    @MainActor
    static func due(now: Date = Date(), store: AppStore, defaults: UserDefaults = .standard) -> (month: Int, year: Int)? {
        let prev = previousMonth(of: now)
        let k = key(month: prev.month, year: prev.year)
        guard defaults.string(forKey: defaultsKey) != k else { return nil }

        let cal = Calendar.current
        let hadActivity = store.transactions.contains { tx in
            guard let d = AppStore.parseDate(tx.date) else { return false }
            return cal.component(.month, from: d) == prev.month && cal.component(.year, from: d) == prev.year
        }
        guard hadActivity else {
            defaults.set(k, forKey: defaultsKey)
            return nil
        }
        return prev
    }

    static func markShown(month: Int, year: Int, defaults: UserDefaults = .standard) {
        defaults.set(key(month: month, year: year), forKey: defaultsKey)
    }
}
