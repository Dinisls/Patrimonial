import SwiftUI
import SwiftData
import Charts

// MARK: - CashFlowChartMode

enum CashFlowChartMode: String, CaseIterable {
    case tendency
    case cumulative

    var label: String {
        switch self {
        case .tendency:   return "Tendência"
        case .cumulative: return "Cumulativo"
        }
    }
}

// MARK: - DailyFlow

struct DailyFlow: Identifiable {
    let id = UUID()
    let date: Date
    let income: Double
    let expenses: Double

    var net: Double { income - expenses }
}

// MARK: - CashFlowDetailView

struct CashFlowDetailView: View {
    @Query(sort: \FinancialTransaction.date) private var transactions: [FinancialTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var selectedMonth: Date
    @State private var chartMode: CashFlowChartMode = .tendency
    @AppStorage("defaultCurrency") private var defaultCurrency = "EUR"

    init() {
        _selectedMonth = State(initialValue: Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())
        )!)
    }

    private var monthStart: Date { selectedMonth }
    private var monthEnd: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: selectedMonth) ?? selectedMonth
    }
    private var prevMonthStart: Date {
        Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
    }
    private var prevMonthEnd: Date { selectedMonth }

    private var income: Decimal {
        transactions.filter { $0.type == .income && $0.date >= monthStart && $0.date < monthEnd }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var expenses: Decimal {
        transactions.filter { $0.type == .expense && $0.date >= monthStart && $0.date < monthEnd }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var net: Decimal { income - expenses }

    private var previousIncome: Decimal {
        transactions.filter { $0.type == .income && $0.date >= prevMonthStart && $0.date < prevMonthEnd }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var previousExpenses: Decimal {
        transactions.filter { $0.type == .expense && $0.date >= prevMonthStart && $0.date < prevMonthEnd }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var vsPercent: Double? {
        let prevNet = previousIncome - previousExpenses
        guard prevNet != 0 else { return nil }
        let currentDouble = Double(truncating: net as NSDecimalNumber)
        let prevDouble = Double(truncating: prevNet as NSDecimalNumber)
        return ((currentDouble - prevDouble) / abs(prevDouble)) * 100
    }

    private var dailyFlows: [DailyFlow] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: selectedMonth) else { return [] }

        return range.compactMap { dayNum -> DailyFlow? in
            guard let day = calendar.date(bySetting: .day, value: dayNum, of: selectedMonth) else { return nil }
            let dayStart = calendar.startOfDay(for: day)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

            let dayIncome = transactions
                .filter { $0.type == .income && $0.date >= dayStart && $0.date < dayEnd }
                .reduce(0.0) { $0 + Double(truncating: $1.amount as NSDecimalNumber) }

            let dayExpenses = transactions
                .filter { $0.type == .expense && $0.date >= dayStart && $0.date < dayEnd }
                .reduce(0.0) { $0 + Double(truncating: $1.amount as NSDecimalNumber) }

            guard dayIncome > 0 || dayExpenses > 0 else { return nil }
            return DailyFlow(date: dayStart, income: dayIncome, expenses: dayExpenses)
        }
    }

    private var isCurrentOrFutureMonth: Bool {
        let calendar = Calendar.current
        let currentMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        return selectedMonth >= currentMonthStart
    }

    private var periodLabel: String {
        if isCurrentOrFutureMonth {
            return String(localized: "dashboard_this_month").uppercased()
        } else {
            return selectedMonth.formatted(.dateTime.month(.abbreviated).year()).uppercased()
        }
    }

    private var monthNavLabel: String {
        selectedMonth.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cashFlowCard
                trendCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.screenBackground)
        .navigationTitle(String(localized: "dashboard_cash_flow"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cash Flow Summary Card

    private var cashFlowCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "dashboard_cash_flow"))
                        .font(.cardTitle)
                    Text(String(localized: "dashboard_cash_flow_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(periodLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.sectionHeader)
                        Text(CurrencyFormatter.format(net, currency: defaultCurrency))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(net < 0 ? Color.lossRed : Color.primary)
                    }

                    Spacer()

                    if let pct = vsPercent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("VS PERÍODO ANTERIOR")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            PercentBadge(value: pct)
                        }
                    }
                }

                let maxVal = max(income, expenses)
                cashFlowBarRow(label: String(localized: "dashboard_income"), value: income, maxValue: maxVal, color: .gainGreen)
                cashFlowBarRow(label: String(localized: "dashboard_expenses_label"), value: expenses, maxValue: maxVal, color: .lossRed)
            }
        }
    }

    private func cashFlowBarRow(label: String, value: Decimal, maxValue: Decimal, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)

                    let proportion: Double = {
                        guard maxValue > 0 else { return 0 }
                        let ratio = value / maxValue
                        let d = Double(truncating: ratio as NSDecimalNumber)
                        return max(0, min(1, d))
                    }()

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * proportion, height: 8)
                }
            }
            .frame(height: 8)

            Text(CurrencyFormatter.format(value, currency: defaultCurrency))
                .font(.caption.weight(.medium))
                .frame(minWidth: 60, alignment: .trailing)
        }
    }

    // MARK: - Trend Card

    private var trendCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "cashflow_trend_title"))
                        .font(.cardTitle)
                    Text(String(localized: "cashflow_trend_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("", selection: $chartMode) {
                    ForEach(CashFlowChartMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if !dailyFlows.isEmpty {
                    chartView
                        .frame(height: 160)
                } else {
                    Text("Sem dados para este período.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 160)
                }

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.gainGreen).frame(width: 8, height: 8)
                        Text(String(localized: "dashboard_income")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.lossRed).frame(width: 8, height: 8)
                        Text(String(localized: "dashboard_expenses_label")).font(.caption).foregroundStyle(.secondary)
                    }
                }

                monthNavigationBar
            }
        }
    }

    @ViewBuilder
    private var chartView: some View {
        switch chartMode {
        case .tendency:
            Chart {
                ForEach(dailyFlows) { flow in
                    BarMark(
                        x: .value("Dia", flow.date, unit: .day),
                        y: .value("Valor", flow.income)
                    )
                    .foregroundStyle(by: .value("Tipo", "Receita"))

                    BarMark(
                        x: .value("Dia", flow.date, unit: .day),
                        y: .value("Valor", -flow.expenses)
                    )
                    .foregroundStyle(by: .value("Tipo", "Despesas"))
                }
            }
            .chartForegroundStyleScale([
                "Receita": Color.gainGreen,
                "Despesas": Color.lossRed
            ])
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day()))
                                .font(.caption2)
                        }
                    }
                }
            }

        case .cumulative:
            let cumulativeData: [(date: Date, cumulative: Double)] = {
                var running = 0.0
                return dailyFlows.map { flow in
                    running += flow.net
                    return (date: flow.date, cumulative: running)
                }
            }()

            Chart {
                ForEach(cumulativeData, id: \.date) { point in
                    LineMark(
                        x: .value("Dia", point.date, unit: .day),
                        y: .value("Acumulado", point.cumulative)
                    )
                    .foregroundStyle(Color.secondaryAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Dia", point.date, unit: .day),
                        y: .value("Acumulado", point.cumulative)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.secondaryAccent.opacity(0.25), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day()))
                                .font(.caption2)
                        }
                    }
                }
            }
        }
    }

    private var monthNavigationBar: some View {
        HStack {
            Button {
                if let prev = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth) {
                    selectedMonth = prev
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
            }

            Spacer()

            Text(monthNavLabel)
                .font(.caption.weight(.semibold))

            Spacer()

            Button {
                if let next = Calendar.current.date(byAdding: .month, value: 1, to: selectedMonth) {
                    selectedMonth = next
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .disabled(isCurrentOrFutureMonth)
        }
    }
}

#Preview {
    NavigationStack {
        CashFlowDetailView()
            .modelContainer(for: [Account.self, FinancialTransaction.self], inMemory: true)
    }
}
