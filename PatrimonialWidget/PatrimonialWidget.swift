import WidgetKit
import SwiftUI

// MARK: - Timeline Entries

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let summary: WidgetDataBridge.PortfolioSummary?
}

struct CashEntry: TimelineEntry {
    let date: Date
    let cash: WidgetDataBridge.CashSummary?
    let portfolio: WidgetDataBridge.PortfolioSummary?
}

// MARK: - Timeline Providers

struct PortfolioTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: .now, summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        completion(PortfolioEntry(date: .now, summary: WidgetDataBridge.readPortfolio() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let entry = PortfolioEntry(date: .now, summary: WidgetDataBridge.readPortfolio())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CashTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CashEntry {
        CashEntry(date: .now, cash: .placeholder, portfolio: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CashEntry) -> Void) {
        completion(CashEntry(date: .now, cash: WidgetDataBridge.readCash() ?? .placeholder, portfolio: WidgetDataBridge.readPortfolio() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CashEntry>) -> Void) {
        let entry = CashEntry(date: .now, cash: WidgetDataBridge.readCash(), portfolio: WidgetDataBridge.readPortfolio())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Portfolio Widget Views

struct PortfolioWidgetSmall: View {
    let summary: WidgetDataBridge.PortfolioSummary?

    var body: some View {
        if let s = summary {
            VStack(alignment: .leading, spacing: 6) {
                Text("Investimentos")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(fmtCurrency(s.totalValue))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: s.dayChangeAbsolute >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(fmtChange(s.dayChangeAbsolute))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(fmtPercent(s.dayChangePercent))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(s.dayChangeAbsolute >= 0 ? .green : .red)

                Spacer()

                Text("\(s.positionCount) posições")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        } else {
            emptyState
        }
    }
}

struct PortfolioWidgetMedium: View {
    let summary: WidgetDataBridge.PortfolioSummary?

    var body: some View {
        if let s = summary {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Investimentos")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(fmtCurrency(s.totalValue))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 3) {
                            Image(systemName: s.dayChangeAbsolute >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                            Text(fmtChange(s.dayChangeAbsolute))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(s.dayChangeAbsolute >= 0 ? .green : .red)

                        Text("P/L \(fmtChange(s.totalPL))")
                            .font(.system(size: 11))
                            .foregroundStyle(s.totalPL >= 0 ? .green : .red)
                    }
                }

                if !s.topPositions.isEmpty {
                    Divider()
                    HStack(spacing: 12) {
                        ForEach(s.topPositions.prefix(4), id: \.symbol) { pos in
                            VStack(spacing: 2) {
                                Text(pos.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Text(fmtCurrency(pos.value))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(2)
        } else {
            emptyState
        }
    }
}

// MARK: - Cash / Balance Widget Views

struct CashWidgetSmall: View {
    let cash: WidgetDataBridge.CashSummary?

    var body: some View {
        if let c = cash {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saldo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(fmtCurrency(c.totalBalance))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.left")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                        Text(fmtCurrency(c.monthIncome))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.green)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.red)
                        Text(fmtCurrency(c.monthExpenses))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        } else {
            emptyState
        }
    }
}

struct CashWidgetMedium: View {
    let cash: WidgetDataBridge.CashSummary?

    var body: some View {
        if let c = cash {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Saldo")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(fmtCurrency(c.totalBalance))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        Link(destination: URL(string: "patrimonial://expense")!) {
                            VStack(spacing: 4) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.red)
                                Text("Despesa")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Link(destination: URL(string: "patrimonial://income")!) {
                            VStack(spacing: 4) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.green)
                                Text("Receita")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !c.accounts.isEmpty {
                    Divider()
                    HStack(spacing: 12) {
                        ForEach(c.accounts.prefix(4), id: \.name) { acc in
                            VStack(spacing: 2) {
                                Image(systemName: acc.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(acc.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                Text(fmtCurrency(acc.balance))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(2)
        } else {
            emptyState
        }
    }
}

// MARK: - Net Worth Widget Views

struct NetWorthWidgetSmall: View {
    let cash: WidgetDataBridge.CashSummary?
    let portfolio: WidgetDataBridge.PortfolioSummary?

    var body: some View {
        let cashVal = cash?.totalBalance ?? 0
        let investVal = portfolio?.totalValue ?? 0
        let total = cashVal + investVal

        if cash != nil || portfolio != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Património")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(fmtCurrency(total))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Spacer()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                        Text("Contas")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(fmtCurrency(cashVal))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("Investido")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(fmtCurrency(investVal))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        } else {
            emptyState
        }
    }
}

struct NetWorthWidgetMedium: View {
    let cash: WidgetDataBridge.CashSummary?
    let portfolio: WidgetDataBridge.PortfolioSummary?

    var body: some View {
        let cashVal = cash?.totalBalance ?? 0
        let investVal = portfolio?.totalValue ?? 0
        let total = cashVal + investVal

        if cash != nil || portfolio != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Património Total")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(fmtCurrency(total))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let p = portfolio, p.dayChangeAbsolute != 0 {
                        HStack(spacing: 3) {
                            Image(systemName: p.dayChangeAbsolute >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                            Text(fmtChange(p.dayChangeAbsolute))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(p.dayChangeAbsolute >= 0 ? .green : .red)
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(.blue).frame(width: 8, height: 8)
                            Text("Contas")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(fmtCurrency(cashVal))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        if let c = cash {
                            HStack(spacing: 8) {
                                Label(fmtCompact(c.monthIncome), systemImage: "arrow.down.left")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green)
                                Label(fmtCompact(c.monthExpenses), systemImage: "arrow.up.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                            Text("Investido")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(fmtCurrency(investVal))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        if let p = portfolio {
                            Text("P/L \(fmtChange(p.totalPL))")
                                .font(.system(size: 9))
                                .foregroundStyle(p.totalPL >= 0 ? .green : .red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(2)
        } else {
            emptyState
        }
    }
}

// MARK: - Cashflow Widget

struct CashflowWidgetMedium: View {
    let cash: WidgetDataBridge.CashSummary?

    var body: some View {
        if let c = cash {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cashflow Mensal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Receitas", systemImage: "arrow.down.left")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                        Text(fmtCurrency(c.monthIncome))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Label("Despesas", systemImage: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red)
                        Text(fmtCurrency(c.monthExpenses))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.red)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                HStack {
                    Text("Balanço")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fmtChange(c.monthNet))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(c.monthNet >= 0 ? .green : .red)
                }

                cashflowBar(income: c.monthIncome, expenses: c.monthExpenses)
            }
            .padding(2)
        } else {
            emptyState
        }
    }

    private func cashflowBar(income: Decimal, expenses: Decimal) -> some View {
        let total = income + expenses
        let ratio = total > 0 ? Double(truncating: (income / total) as NSDecimalNumber) : 0.5
        return HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.green.opacity(0.7))
                .frame(maxWidth: .infinity)
                .scaleEffect(x: ratio, anchor: .leading)
            RoundedRectangle(cornerRadius: 3)
                .fill(.red.opacity(0.7))
                .frame(maxWidth: .infinity)
                .scaleEffect(x: 1 - ratio, anchor: .trailing)
        }
        .frame(height: 6)
    }
}

// MARK: - Empty State

private var emptyState: some View {
    VStack(spacing: 8) {
        Image(systemName: "chart.line.uptrend.xyaxis")
            .font(.title2)
            .foregroundStyle(.secondary)
        Text("Abre a app para\nver os dados")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Formatting

private func fmtCurrency(_ value: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "EUR"
    f.maximumFractionDigits = 0
    return f.string(from: value as NSDecimalNumber) ?? "€0"
}

private func fmtChange(_ value: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "EUR"
    f.maximumFractionDigits = 0
    f.positivePrefix = "+"
    return f.string(from: value as NSDecimalNumber) ?? "€0"
}

private func fmtPercent(_ value: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.maximumFractionDigits = 1
    f.multiplier = 0.01
    f.positivePrefix = "+"
    return f.string(from: value as NSDecimalNumber) ?? "0%"
}

private func fmtCompact(_ value: Decimal) -> String {
    let d = Double(truncating: value as NSDecimalNumber)
    if d >= 1000 {
        return String(format: "€%.0fk", d / 1000)
    }
    return fmtCurrency(value)
}

// MARK: - Widget Definitions

struct PatrimonialWidget: Widget {
    let kind = "PatrimonialPortfolio"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PortfolioTimelineProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, *) {
                    PortfolioWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    PortfolioWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Investimentos")
        .description("Valor do portfólio e variação diária.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CashWidget: Widget {
    let kind = "PatrimonialCash"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CashTimelineProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, *) {
                    CashWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    CashWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Saldo")
        .description("Saldo das contas com ações rápidas.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NetWorthWidget: Widget {
    let kind = "PatrimonialNetWorth"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CashTimelineProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, *) {
                    NetWorthWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    NetWorthWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Património")
        .description("Contas e investimentos combinados.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CashflowWidget: Widget {
    let kind = "PatrimonialCashflow"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CashTimelineProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, *) {
                    CashflowWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    CashflowWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Cashflow")
        .description("Receitas e despesas do mês.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Entry Views

struct PortfolioWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: PortfolioEntry

    var body: some View {
        switch family {
        case .systemMedium:
            PortfolioWidgetMedium(summary: entry.summary)
        default:
            PortfolioWidgetSmall(summary: entry.summary)
        }
    }
}

struct CashWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: CashEntry

    var body: some View {
        switch family {
        case .systemMedium:
            CashWidgetMedium(cash: entry.cash)
        default:
            CashWidgetSmall(cash: entry.cash)
        }
    }
}

struct NetWorthWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: CashEntry

    var body: some View {
        switch family {
        case .systemMedium:
            NetWorthWidgetMedium(cash: entry.cash, portfolio: entry.portfolio)
        default:
            NetWorthWidgetSmall(cash: entry.cash, portfolio: entry.portfolio)
        }
    }
}

struct CashflowWidgetEntryView: View {
    let entry: CashEntry

    var body: some View {
        Link(destination: URL(string: "patrimonial://cashflow")!) {
            CashflowWidgetMedium(cash: entry.cash)
        }
    }
}

// MARK: - Placeholder Data

extension WidgetDataBridge.PortfolioSummary {
    static let placeholder = WidgetDataBridge.PortfolioSummary(
        totalValue: 12450,
        totalCost: 10200,
        dayChangeAbsolute: 85,
        dayChangePercent: 0.69,
        positionCount: 6,
        topPositions: [
            .init(symbol: "AAPL", name: "Apple", value: 3200, dayChangePercent: 1.2, weight: 25.7),
            .init(symbol: "MSFT", name: "Microsoft", value: 2800, dayChangePercent: -0.3, weight: 22.5),
            .init(symbol: "IWDA", name: "iShares MSCI", value: 2100, dayChangePercent: 0.5, weight: 16.9),
        ],
        updatedAt: Date()
    )
}

extension WidgetDataBridge.CashSummary {
    static let placeholder = WidgetDataBridge.CashSummary(
        totalBalance: 5320,
        monthIncome: 2100,
        monthExpenses: 1450,
        accounts: [
            .init(name: "Corrente", icon: "banknote", balance: 3200, colorHex: "007AFF"),
            .init(name: "Poupança", icon: "building.columns", balance: 2120, colorHex: "34C759"),
        ],
        updatedAt: Date()
    )
}
