import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @State private var showSettings = false
    @AppStorage("defaultCurrency") private var defaultCurrency = "EUR"
    @AppStorage("balanceTrendPeriod") private var balanceTrendPeriod: BalancePeriod = .thirtyDays
    @AppStorage("appTheme") private var appTheme = "system"

    private var totalBalance: Decimal { accounts.reduce(0) { $0 + $1.balance } }
    private var recentTransactions: [FinancialTransaction] { Array(transactions.prefix(6)) }

    private let accountColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var balanceMiniChart: [ChartDataPoint] {
        computeBalanceHistory(accounts: Array(accounts), days: balanceTrendPeriod.days)
    }

    private var balancePercentChange: Double? {
        guard balanceMiniChart.count >= 2,
              let first = balanceMiniChart.first,
              first.value != 0 else { return nil }
        let lastValue = balanceMiniChart[balanceMiniChart.count - 1].value
        return ((lastValue - first.value) / abs(first.value)) * 100
    }

    private var currentMonthCashFlow: (income: Decimal, expenses: Decimal) {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        let income = transactions.filter { $0.type == .income && $0.date >= start && $0.date < end }.reduce(Decimal.zero) { $0 + $1.amount }
        let expenses = transactions.filter { $0.type == .expense && $0.date >= start && $0.date < end }.reduce(Decimal.zero) { $0 + $1.amount }
        return (income, expenses)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "BOM DIA" }
        if hour < 19 { return "BOA TARDE" }
        return "BOA NOITE"
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    EmptyState(icon: "chart.pie", title: String(localized: "dashboard_empty_title"), message: String(localized: "dashboard_empty_message"))
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            headerSection
                            balanceTrendCard
                            accountsSection
                            cashFlowCard
                            if !recentTransactions.isEmpty { transactionsSection }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .background(Color.screenBackground)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            appTheme = appTheme == "dark" ? "light" : "dark"
                        } label: {
                            Image(systemName: appTheme == "dark" ? "sun.max" : "moon")
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Color.cardBackground, in: Circle())
                        }
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Color.cardBackground, in: Circle())
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.sectionHeader)
                .tracking(1.5)

            Text("Dashboard")
                .font(.system(.largeTitle, design: .default, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Balance Trend Card

    private var balanceTrendCard: some View {
        NavigationLink {
            BalanceTrendDetailView()
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "dashboard_balance_trend"))
                            .font(.cardBody)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let pct = balancePercentChange {
                            PercentBadge(value: pct)
                        }
                    }

                    Text(CurrencyFormatter.format(totalBalance, currency: defaultCurrency))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    if balanceMiniChart.count >= 2 {
                        let vals = balanceMiniChart.map(\.value)
                        let minV = (vals.min() ?? 0)
                        let maxV = (vals.max() ?? 1)
                        let pad = (maxV - minV) * 0.1
                        Chart {
                            ForEach(balanceMiniChart) { pt in
                                LineMark(x: .value("D", pt.date), y: .value("V", pt.value))
                                    .interpolationMethod(.catmullRom).foregroundStyle(Color.secondaryAccent)
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                                AreaMark(x: .value("D", pt.date), y: .value("V", pt.value))
                                    .interpolationMethod(.catmullRom)
                                    .foregroundStyle(LinearGradient(colors: [Color.secondaryAccent.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                            }
                        }
                        .chartYAxis(.hidden).chartXAxis(.hidden)
                        .chartYScale(domain: (minV - pad)...(maxV + pad))
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Accounts Section

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "dashboard_accounts"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.sectionHeader)
                    .tracking(1.5)
                Spacer()
                Text("\(accounts.count) CONTAS")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: accountColumns, spacing: 12) {
                ForEach(accounts) { account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        AccountCardTile(account: account)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Cash Flow Card

    private var cashFlowCard: some View {
        let (income, expenses) = currentMonthCashFlow
        let net = income - expenses
        let maxVal = max(income, expenses)

        return VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "dashboard_cash_flow"))
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.sectionHeader)
                .tracking(1.5)

            NavigationLink {
                CashFlowDetailView()
            } label: {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "dashboard_this_month"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(CurrencyFormatter.format(net, currency: defaultCurrency))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(net >= 0 ? Color.gainGreen : Color.lossRed)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }

                        cashFlowBar(label: String(localized: "dashboard_income"), value: income, maxValue: maxVal, color: .gainGreen)
                        cashFlowBar(label: String(localized: "dashboard_expenses_label"), value: expenses, maxValue: maxVal, color: .lossRed)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func cashFlowBar(label: String, value: Decimal, maxValue: Decimal, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    let proportion = maxValue > 0 ? Double(truncating: (value / maxValue) as NSDecimalNumber) : 0
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: geo.size.width * max(0, proportion), height: 8)
                }
            }
            .frame(height: 8)
            Text(CurrencyFormatter.format(value, currency: defaultCurrency))
                .font(.caption.weight(.medium)).frame(minWidth: 60, alignment: .trailing)
        }
    }

    // MARK: - Transactions Section

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "dashboard_recent"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.sectionHeader)
                    .tracking(1.5)
                Spacer()
                Text("Ver tudo")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.sectionHeader)
            }

            Card {
                VStack(spacing: 0) {
                    ForEach(Array(recentTransactions.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 { Divider().padding(.vertical, 6) }
                        TransactionRowView(transaction: transaction)
                    }
                }
            }
        }
    }
}

// MARK: - Percent Badge

struct PercentBadge: View {
    let value: Double

    var body: some View {
        let isPositive = value >= 0
        let sign = isPositive ? "+" : ""
        Text("\(sign)\(String(format: "%.2f", value))%")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isPositive ? Color.gainGreen : Color.lossRed)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isPositive ? Color.percentBadgeBackground : Color.percentBadgeBackgroundNegative,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [Account.self, FinancialTransaction.self], inMemory: true)
}
