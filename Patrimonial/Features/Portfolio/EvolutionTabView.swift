import SwiftUI
import SwiftData
import Charts

/// The portfolio's value over time, from the snapshots actually recorded.
///
/// Nothing here is reconstructed. A snapshot is what the portfolio was worth on
/// a day at the prices and rates of that day, and none of those are recoverable
/// after the fact — so the series starts on the first day the app recorded one
/// and grows from there. The empty state says exactly that rather than filling
/// the frame with a shape.
struct EvolutionTabView: View {
    @Query(sort: \PortfolioSnapshot.date) private var snapshots: [PortfolioSnapshot]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if PortfolioSnapshotRecorder.drawsChart(snapshots) {
                    chart
                    figures
                } else {
                    emptyState
                }
                Spacer(minLength: 100)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let points = snapshots
        let values = points.map { NSDecimalNumber(decimal: $0.totalValue).doubleValue }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.08, 1)

        return VStack(alignment: .leading, spacing: 8) {
            Text("VALOR DA CARTEIRA")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            Chart(points, id: \.date) { snapshot in
                let value = NSDecimalNumber(decimal: snapshot.totalValue).doubleValue
                AreaMark(
                    x: .value("Data", snapshot.date),
                    yStart: .value("Base", low - pad),
                    yEnd: .value("Valor", value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [PB.accent.opacity(0.22), PB.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Data", snapshot.date),
                    y: .value("Valor", value)
                )
                .foregroundStyle(PB.accent)
                .interpolationMethod(.monotone)
            }
            // The axis stops at the first snapshot. Letting Charts round the
            // domain outwards would draw the line starting somewhere before
            // any data exists, which reads as a flat history that was never
            // recorded — the same reason the accounts chart is bounded.
            .chartXScale(domain: (snapshots.first?.date ?? Date())...(snapshots.last?.date ?? Date()))
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(compact(raw))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(preset: .aligned) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: 9))
                }
            }
            .frame(height: 220)
            .padding(.horizontal, 16)

            Text("Histórico desde \(AssetDetailViewModel.dayLabel(snapshots.first?.date ?? Date())) · \(snapshots.count) registos")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Figures

    @ViewBuilder
    private var figures: some View {
        if let first = snapshots.first, let last = snapshots.last {
            let change = last.totalValue - first.totalValue
            VStack(spacing: 0) {
                row("Primeiro registo", formatEUR(first.totalValue))
                Divider().padding(.leading, 16)
                row("Valor atual", formatEUR(last.totalValue))
                Divider().padding(.leading, 16)
                row(
                    "Variação no período",
                    (change >= 0 ? "+" : "−") + formatEUR(change < 0 ? -change : change),
                    tint: change >= 0 ? PB.pos : PB.neg
                )
                Divider().padding(.leading, 16)
                row("P/L não realizado", formatSigned(last.totalPL),
                    tint: last.totalPL >= 0 ? PB.pos : PB.neg)
            }
            .background(
                Color(UIColor.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .padding(.horizontal, 16)
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Empty state

    /// Explains that the series has to be lived through, not loaded.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text(snapshots.isEmpty ? "O histórico começa hoje" : "Ainda só há um registo")
                .font(.system(size: 18, weight: .semibold))

            Text("A carteira é registada uma vez por dia, sempre que abrires a app com todas as posições cotadas. Não há forma honesta de reconstruir dias anteriores — os preços e os câmbios desses dias já passaram — por isso o gráfico cresce a partir de agora.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let only = snapshots.first {
                Text("Registo de \(AssetDetailViewModel.dayLabel(only.date)): \(formatEUR(only.totalValue))")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(PB.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(PB.accent)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

    private func formatEUR(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: value as NSDecimalNumber) ?? "—"
    }

    private func formatSigned(_ value: Decimal) -> String {
        (value >= 0 ? "+" : "−") + formatEUR(value < 0 ? -value : value)
    }

    private func compact(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.maximumFractionDigits = abs(value) < 100 ? 1 : 0
        return f.string(from: NSNumber(value: value)) ?? ""
    }
}
