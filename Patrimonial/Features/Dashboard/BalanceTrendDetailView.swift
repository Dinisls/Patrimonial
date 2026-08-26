import SwiftUI
import SwiftData
import Charts

struct ChartDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let value: Double
}

// MARK: - BalancePeriod

enum BalancePeriod: String, CaseIterable {
    case sevenDays
    case thirtyDays
    case threeMonths
    case sixMonths
    case oneYear

    var days: Int {
        switch self {
        case .sevenDays:    return 7
        case .thirtyDays:   return 30
        case .threeMonths:  return 90
        case .sixMonths:    return 180
        case .oneYear:      return 365
        }
    }

    var label: String {
        switch self {
        case .sevenDays:   return "7 dias"
        case .thirtyDays:  return "30 dias"
        case .threeMonths: return "3 meses"
        case .sixMonths:   return "6 meses"
        case .oneYear:     return "1 ano"
        }
    }

    var periodLabel: String {
        switch self {
        case .sevenDays:   return "ÚLTIMOS 7 DIAS"
        case .thirtyDays:  return "ÚLTIMOS 30 DIAS"
        case .threeMonths: return "ÚLTIMOS 3 MESES"
        case .sixMonths:   return "ÚLTIMOS 6 MESES"
        case .oneYear:     return "ÚLTIMO ANO"
        }
    }
}

// MARK: - computeBalanceHistory

func computeBalanceHistory(accounts: [Account], days: Int) -> [ChartDataPoint] {
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let allOutgoing: [FinancialTransaction] = accounts.flatMap { $0.outgoingTransactions }
    let currentBalanceDouble = accounts.reduce(0.0) { $0 + Double(truncating: $1.balance as NSDecimalNumber) }

    var points: [ChartDataPoint] = []

    for offset in (-days)...0 {
        guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
        let dayStart = calendar.startOfDay(for: date)

        var adjustment: Double = 0.0
        for tx in allOutgoing {
            let txDay = calendar.startOfDay(for: tx.date)
            guard txDay > dayStart else { continue }
            let amt = Double(truncating: tx.amount as NSDecimalNumber)
            switch tx.type {
            case .income, .assetSale, .dividend:
                adjustment -= amt
            case .expense, .assetPurchase:
                adjustment += amt
            case .transfer:
                break
            }
        }

        points.append(ChartDataPoint(date: dayStart, value: currentBalanceDouble + adjustment))
    }

    return points
}

// MARK: - computeSingleAccountHistory

func computeSingleAccountHistory(account: Account, days: Int) -> [ChartDataPoint] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    let outgoing = account.outgoingTransactions
    let incoming = account.incomingTransactions
    let currentBalance = Double(truncating: account.balance as NSDecimalNumber)

    var points: [ChartDataPoint] = []

    for offset in (-days)...0 {
        guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
        let dayStart = calendar.startOfDay(for: date)

        var adjustment: Double = 0.0

        for tx in outgoing {
            let txDay = calendar.startOfDay(for: tx.date)
            guard txDay > dayStart else { continue }
            let amt = Double(truncating: tx.amount as NSDecimalNumber)
            switch tx.type {
            case .income, .assetSale, .dividend:
                adjustment -= amt
            case .expense, .assetPurchase, .transfer:
                adjustment += amt
            }
        }

        for tx in incoming {
            let txDay = calendar.startOfDay(for: tx.date)
            guard txDay > dayStart else { continue }
            let amt = Double(truncating: tx.amount as NSDecimalNumber)
            adjustment -= amt
        }

        points.append(ChartDataPoint(date: dayStart, value: currentBalance + adjustment))
    }

    return points
}

// MARK: - BalanceTrendDetailView

struct BalanceTrendDetailView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage("balanceTrendPeriod") private var selectedPeriod: BalancePeriod = .thirtyDays
    @State private var selectedPoint: ChartDataPoint? = nil
    @AppStorage("defaultCurrency") private var defaultCurrency = "EUR"

    private var totalBalance: Decimal {
        accounts.reduce(0) { $0 + $1.balance }
    }

    private var chartData: [ChartDataPoint] {
        computeBalanceHistory(accounts: Array(accounts), days: selectedPeriod.days)
    }

    private var percentChange: Double? {
        guard chartData.count >= 2,
              let first = chartData.first,
              first.value != 0 else { return nil }
        let endValue = selectedPoint?.value ?? chartData[chartData.count - 1].value
        return ((endValue - first.value) / abs(first.value)) * 100
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                trendCard
                accountsCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.screenBackground)
        .navigationTitle(String(localized: "balance_detail_title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedPeriod) { _, _ in selectedPoint = nil }
    }

    // MARK: - Trend Card

    private var trendCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "dashboard_balance_trend"))
                        .font(.cardTitle)
                    Text(String(localized: "dashboard_balance_trend_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let sel = selectedPoint {
                            Text(sel.date.formatted(.dateTime.day().month(.wide).year()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                            Text(CurrencyFormatter.format(Decimal(sel.value), currency: defaultCurrency))
                                .font(.title3.weight(.bold))
                                .transition(.opacity)
                        } else {
                            Text(String(localized: "dashboard_today").uppercased())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(CurrencyFormatter.format(totalBalance, currency: defaultCurrency))
                                .font(.title3.weight(.bold))
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: selectedPoint?.id)

                    Spacer()

                    if let pct = percentChange {
                        PercentBadge(value: pct)
                    }
                }

                if chartData.count >= 2 {
                    let vals = chartData.map(\.value)
                    let minV = vals.min() ?? 0
                    let maxV = vals.max() ?? 1
                    let pad = (maxV - minV) * 0.1

                    Chart {
                        ForEach(chartData) { pt in
                            LineMark(x: .value("D", pt.date), y: .value("V", pt.value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(Color.secondaryAccent)
                                .lineStyle(StrokeStyle(lineWidth: 2))

                            AreaMark(x: .value("D", pt.date), y: .value("V", pt.value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color.secondaryAccent.opacity(0.3), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }

                        if let sel = selectedPoint {
                            RuleMark(x: .value("Selected", sel.date))
                                .foregroundStyle(Color.subtleText.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            PointMark(x: .value("D", sel.date), y: .value("V", sel.value))
                                .symbolSize(50)
                                .foregroundStyle(Color.secondaryAccent)
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Color.clear.contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                        .onChanged { value in
                                            let plotOriginX = proxy.plotFrame.map { geo[$0].origin.x } ?? 0
                                            let x = value.location.x - plotOriginX
                                            guard x >= 0 else { return }
                                            if let date: Date = proxy.value(atX: x) {
                                                selectedPoint = chartData.min(by: {
                                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                                })
                                            }
                                        }
                                        .onEnded { _ in
                                            withAnimation(.easeOut(duration: 0.2)) { selectedPoint = nil }
                                        }
                                )
                        }
                    }
                    .chartYAxis {
                        AxisMarks(preset: .automatic, position: .trailing) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                                .foregroundStyle(Color.separatorLine)
                            AxisValueLabel {
                                if let dbl = value.as(Double.self) {
                                    Text(compactNumber(dbl))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: xAxisStride, count: 4)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(xAxisLabel(for: date))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: (minV - pad)...(maxV + pad))
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BalancePeriod.allCases, id: \.self) { period in
                            Button {
                                selectedPeriod = period
                            } label: {
                                Text(period.label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(selectedPeriod == period ? Color.primaryAction : .secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        selectedPeriod == period
                                            ? Color.primaryAction.opacity(0.15)
                                            : Color.clear,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().stroke(
                                            selectedPeriod == period ? Color.primaryAction.opacity(0.3) : Color.clear,
                                            lineWidth: 1
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Accounts Card

    private var accountsCard: some View {
        let sortedAccounts = accounts.sorted { $0.balance > $1.balance }
        let totalBalanceVal = accounts.reduce(Decimal.zero) { $0 + $1.balance }

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "dashboard_accounts"))
                        .font(.cardTitle)
                    Text(String(localized: "dashboard_accounts_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    ForEach(sortedAccounts) { account in
                        VStack(spacing: 4) {
                            HStack {
                                Text(account.name)
                                    .font(.cardBody)
                                Spacer()
                                Text(CurrencyFormatter.format(account.balance, currency: account.currency))
                                    .font(.monoValue)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.15))
                                        .frame(height: 6)

                                    let proportion: Double = {
                                        guard totalBalanceVal > 0 else { return 0 }
                                        let ratio = account.balance / totalBalanceVal
                                        let d = Double(truncating: ratio as NSDecimalNumber)
                                        return max(0, min(1, d))
                                    }()

                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(hex: account.colorHex))
                                        .frame(width: geo.size.width * proportion, height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var xAxisStride: Calendar.Component {
        switch selectedPeriod {
        case .sevenDays:   return .day
        case .thirtyDays:  return .day
        case .threeMonths: return .month
        case .sixMonths:   return .month
        case .oneYear:     return .month
        }
    }

    private func xAxisLabel(for date: Date) -> String {
        switch selectedPeriod {
        case .sevenDays:
            return date.formatted(.dateTime.weekday(.abbreviated))
        case .thirtyDays:
            return date.formatted(.dateTime.day().month(.abbreviated))
        default:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func compactNumber(_ value: Double) -> String {
        let absVal = abs(value)
        let sign = value < 0 ? "-" : ""
        if absVal >= 1_000_000 {
            return "\(sign)\(String(format: "%.1f", absVal / 1_000_000))M"
        } else if absVal >= 1_000 {
            return "\(sign)\(String(format: "%.1f", absVal / 1_000))K"
        } else {
            return "\(sign)\(String(format: "%.0f", absVal))"
        }
    }
}

#Preview {
    NavigationStack {
        BalanceTrendDetailView()
            .modelContainer(for: [Account.self, FinancialTransaction.self], inMemory: true)
    }
}
