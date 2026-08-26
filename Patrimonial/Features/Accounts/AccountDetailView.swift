import SwiftUI
import SwiftData
import Charts

struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let account: Account
    @State private var activeSheet: AccountDetailSheet?
    @State private var selectedPeriod: BalancePeriod = .thirtyDays
    @State private var selectedPoint: ChartDataPoint? = nil
    @AppStorage("defaultCurrency") private var defaultCurrency = "EUR"

    private var allTransactions: [FinancialTransaction] {
        (account.outgoingTransactions + account.incomingTransactions)
            .sorted { $0.date > $1.date }
    }

    private var chartData: [ChartDataPoint] {
        computeSingleAccountHistory(account: account, days: selectedPeriod.days)
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
                accountHeaderCard
                balanceTrendCard
                transactionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.screenBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    activeSheet = .editAccount
                } label: {
                    Label(String(localized: "account_form_title_edit"), systemImage: "pencil")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { activeSheet = .addExpense } label: {
                        Label(String(localized: "movements_add_expense"), systemImage: "minus.circle")
                    }
                    Button { activeSheet = .addIncome } label: {
                        Label(String(localized: "movements_add_income"), systemImage: "plus.circle")
                    }
                    Button { activeSheet = .addTransfer } label: {
                        Label(String(localized: "movements_add_transfer"), systemImage: "arrow.left.arrow.right")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .editAccount:
                AccountFormView(account: account)
            case .addExpense:
                TransactionFormView(preselectedAccount: account, initialType: .expense)
            case .addIncome:
                TransactionFormView(preselectedAccount: account, initialType: .income)
            case .addTransfer:
                TransferFormView(preselectedSource: account)
            case .editTransaction(let tx):
                switch tx.type {
                case .expense, .income, .assetPurchase, .assetSale, .dividend:
                    TransactionFormView(editing: tx)
                case .transfer:
                    TransferFormView(editing: tx)
                }
            }
        }
        .onChange(of: selectedPeriod) { _, _ in selectedPoint = nil }
    }

    // MARK: - Account Header Card

    private var accountHeaderCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: account.icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color(hex: account.colorHex), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(.sectionTitle)
                        Text(account.type.displayName)
                            .font(.cardBody)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let pct = percentChange {
                        PercentBadge(value: pct)
                    }
                }

                Text(CurrencyFormatter.format(account.balance, currency: account.currency))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Balance Trend Card

    private var balanceTrendCard: some View {
        Card {
            VStack(spacing: 8) {
                if chartData.count >= 2 {
                    let vals = chartData.map(\.value)
                    let minV = vals.min() ?? 0
                    let maxV = vals.max() ?? 1
                    let pad = (maxV - minV) * 0.1

                    Chart {
                        ForEach(chartData) { pt in
                            LineMark(
                                x: .value("D", pt.date),
                                y: .value("V", pt.value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.secondaryAccent)
                            .lineStyle(StrokeStyle(lineWidth: 2))

                            AreaMark(
                                x: .value("D", pt.date),
                                y: .value("V", pt.value)
                            )
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
                            PointMark(
                                x: .value("D", sel.date),
                                y: .value("V", sel.value)
                            )
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
                        AxisMarks(values: .stride(by: trendXAxisStride, count: 4)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(trendXAxisLabel(for: date))
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

    // MARK: - Transactions Section

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "account_detail_transactions"))
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.sectionHeader)
                .tracking(1.5)

            if allTransactions.isEmpty {
                Card {
                    Text(String(localized: "account_detail_no_transactions"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(allTransactions.enumerated()), id: \.element.id) { index, transaction in
                            if index > 0 { Divider().padding(.vertical, 6) }
                            TransactionRowView(transaction: transaction)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    activeSheet = .editTransaction(transaction)
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var trendXAxisStride: Calendar.Component {
        switch selectedPeriod {
        case .sevenDays, .thirtyDays: return .day
        case .threeMonths, .sixMonths, .oneYear: return .month
        }
    }

    private func trendXAxisLabel(for date: Date) -> String {
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

enum AccountDetailSheet: Identifiable {
    case editAccount
    case addExpense
    case addIncome
    case addTransfer
    case editTransaction(FinancialTransaction)

    var id: String {
        switch self {
        case .editAccount: return "editAccount"
        case .addExpense: return "addExpense"
        case .addIncome: return "addIncome"
        case .addTransfer: return "addTransfer"
        case .editTransaction(let tx): return "edit_\(tx.id)"
        }
    }
}
