import SwiftUI
import Charts

/// Where the money actually sits — by class, by currency, or by account.
///
/// The ring is drawn only when every open position has a euro value. See
/// `PortfolioAllocation` for why a partial donut is not an option: the header
/// can carry a caveat next to one number, but a ring reads as the whole by
/// construction, and no label under it undoes that.
struct AllocationTabView: View {
    @Bindable var viewModel: PortfolioViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dimensionPicker

                switch viewModel.allocation {
                case .slices(let slices):
                    donut(slices)
                    sliceList(slices)
                case .unpriced(let symbols):
                    unpricedNotice(symbols)
                case .empty:
                    ContentUnavailableView(
                        "Sem posições",
                        systemImage: "chart.pie",
                        description: Text("A alocação aparece assim que houver uma posição aberta.")
                    )
                    .padding(.top, 40)
                }

                Spacer(minLength: 100)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Dimension

    private var dimensionPicker: some View {
        Picker("Dimensão", selection: $viewModel.allocationDimension) {
            ForEach(PortfolioAllocation.Dimension.allCases, id: \.self) { dim in
                Text(dim.rawValue).tag(dim)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    // MARK: - Donut

    private func donut(_ slices: [PortfolioAllocation.Slice]) -> some View {
        Chart(Array(slices.enumerated()), id: \.element.id) { index, slice in
            SectorMark(
                angle: .value("Valor", NSDecimalNumber(decimal: slice.value).doubleValue),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(color(index))
        }
        .chartLegend(.hidden)
        .frame(height: 220)
        .overlay {
            VStack(spacing: 2) {
                Text("Total")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if viewModel.privacyMode {
                    Text("••••").font(.system(size: 18, weight: .bold))
                } else {
                    Text(formatEUR(slices.reduce(Decimal(0)) { $0 + $1.value }))
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 16)
        .accessibilityLabel("Alocação por \(viewModel.allocationDimension.rawValue.lowercased())")
    }

    // MARK: - List

    private func sliceList(_ slices: [PortfolioAllocation.Slice]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                HStack(spacing: 10) {
                    Circle()
                        .fill(color(index))
                        .frame(width: 10, height: 10)
                    Text(slice.label)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if !viewModel.privacyMode {
                        Text(formatEUR(slice.value))
                            .font(.system(size: 14))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(formatPercent(slice.percent))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                if index < slices.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Unpriced

    /// Names what is missing instead of drawing a ring without it.
    ///
    /// Omitting the unpriced positions silently would produce a full circle that
    /// is quietly about a smaller portfolio — every slice inflated by whatever
    /// the missing ones are worth. Percentages resume the moment the quotes do.
    private func unpricedNotice(_ symbols: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                symbols.count == 1
                    ? "1 posição sem cotação"
                    : "\(symbols.count) posições sem cotação",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.orange)

            Text("Sem o valor de \(symbols.joined(separator: ", ")) não há um total sobre o qual calcular percentagens. Uma fatia de um todo incompleto seria um número errado, não um número parcial — por isso o gráfico não é desenhado.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }

    // MARK: - Helpers

    private func color(_ index: Int) -> Color {
        PB.cat[index % PB.cat.count]
    }

    private func formatEUR(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: value as NSDecimalNumber) ?? "—"
    }

    private func formatPercent(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return (f.string(from: value as NSDecimalNumber) ?? "0") + "%"
    }
}
