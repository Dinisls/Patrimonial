import SwiftUI
import SwiftData
import Charts

/// One position, in full: what it is worth now, how it got there, and every
/// transaction behind it.
struct AssetDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let holdingID: String
    let listing: ListingID
    var symbol: String { listing.symbol }
    let accountID: String

    var priceStore: PriceStore
    var candleStore: CandleStore
    var portfolio: PortfolioViewModel

    @State private var viewModel: AssetDetailViewModel

    /// Identified so `.sheet(item:)` gets a fresh presentation each time —
    /// reusing one across actions is how a sheet ends up showing the previous
    /// operation's type.
    private struct QuickAction: Identifiable {
        let prefill: AddPositionSheet.Prefill
        var id: String {
            "\(prefill.asset.id)|\(prefill.accountID?.uuidString ?? "sem-conta")|\(prefill.type.rawValue)"
        }
    }
    @State private var pendingAction: QuickAction?

    init(
        listing: ListingID,
        accountID: String,
        holdingID: String,
        priceStore: PriceStore,
        candleStore: CandleStore,
        portfolio: PortfolioViewModel,
        isWatchlist: Bool = false
    ) {
        self.listing = listing
        self.accountID = accountID
        self.holdingID = holdingID
        self.priceStore = priceStore
        self.candleStore = candleStore
        self.portfolio = portfolio
        _viewModel = State(initialValue: AssetDetailViewModel(
            listing: listing, accountID: accountID, isWatchlist: isWatchlist
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                priceHeader
                quickActions
                chartSection
                // No position, nothing to report about one. Rendering the
                // figures with zeros would describe a holding that does not
                // exist.
                if !viewModel.isWatchlist {
                    figuresSection
                    transactionsSection
                } else {
                    watchlistNotice
                }
                Spacer(minLength: 60)
            }
            .padding(.top, 8)
        }
        .background(PB.bg)
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.bind(
                modelContext: modelContext,
                priceStore: priceStore,
                candleStore: candleStore,
                portfolio: portfolio
            )
        }
        .task {
            // Cache is already on screen by now; this fills the gap behind it.
            await viewModel.refreshHistory()
        }
    }

    // MARK: - Price

    private var priceHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let quote = viewModel.quote {
                    Text(formatNative(quote.price))
                        .font(.system(size: 32, weight: .bold))
                        .monospacedDigit()
                    Text(viewModel.nativeCurrency)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if let freshness = viewModel.freshness {
                    FreshnessIndicator(freshness: freshness)
                    FreshnessLegendButton()
                }
            }

            // The session a close belongs to, always spelled out — a price three
            // days old on a daily-trading venue is not a holiday, it is a dead
            // line, and the date is how that becomes visible.
            if case .dailyClose(let date) = viewModel.freshness {
                Text("Fecho de \(FreshnessIndicator.closeDateLabel(date))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            // The dash above says the price is unknown; this says why, and the
            // two numbers are what make it checkable rather than a shrug.
            if let discrepancy = priceStore.discrepancy(for: listing) {
                Text("Cotação recusada: \(formatNative(discrepancy.refused)) contra um histórico de \(formatNative(discrepancy.reference)) \(viewModel.nativeCurrency). Uma diferença desta ordem não é uma queda — é outro instrumento com o mesmo símbolo.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Quick actions

    /// Sell, buy more, record a dividend — without going back through search.
    ///
    /// Each opens the same `AddPositionSheet` with the asset fixed and this
    /// screen's account preselected, so a ticker held in two brokerages acts on
    /// the position actually being looked at.
    @ViewBuilder
    private var quickActions: some View {
        if viewModel.canUseQuickActions {
            HStack(spacing: 10) {
                if viewModel.isWatchlist {
                    // Nothing is held, so there is nothing to sell and no
                    // dividend to record against it. One action, and it turns
                    // the followed ticker into a position.
                    quickActionButton("Comprar", "plus", .assetPurchase)
                } else {
                    quickActionButton("Vender", "arrow.up.right", .assetSale)
                        .disabled(viewModel.availableToSell <= 0)
                    quickActionButton("Comprar mais", "plus", .assetPurchase)
                    if !viewModel.isCrypto {
                        quickActionButton("Dividendo", "eurosign.circle", .dividend)
                    }
                }
            }
            .padding(.horizontal, 16)
            .sheet(item: $pendingAction) { action in
                AddPositionSheet(viewModel: portfolio, prefill: action.prefill)
                    .environment(\.modelContext, modelContext)
                    .id(action.id)
            }
        }
    }

    private func quickActionButton(
        _ title: String, _ icon: String, _ type: TransactionType
    ) -> some View {
        Button {
            if let prefill = viewModel.prefill(for: type) {
                pendingAction = QuickAction(prefill: prefill)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(PB.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(PB.accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            rangePicker

            if viewModel.isLoadingHistory {
                chartSkeleton
            } else if viewModel.showsChart, let series = viewModel.series {
                chart(series)
                if let shortfall = viewModel.shortfallDescription {
                    Text(shortfall)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                }
            } else {
                // No chart at all, and the rest of the screen carries on
                // regardless.
                Text(viewModel.hasNoHistoryProvider
                     ? "Sem histórico disponível para esta praça."
                     : "Ainda sem histórico suficiente para desenhar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
            }
        }
    }

    private func chart(_ series: ChartSeries) -> some View {
        let bounds = series.valueBounds
        return Chart(series.candles, id: \.date) { candle in
            AreaMark(
                x: .value("Data", candle.date),
                yStart: .value("Base", NSDecimalNumber(decimal: bounds?.low ?? 0).doubleValue),
                yEnd: .value("Fecho", NSDecimalNumber(decimal: candle.close).doubleValue)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [lineColor(series).opacity(0.22), lineColor(series).opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Data", candle.date),
                y: .value("Fecho", NSDecimalNumber(decimal: candle.close).doubleValue)
            )
            .foregroundStyle(lineColor(series))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: yDomain(bounds))
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        // Native currency, unconverted: the chart is the
                        // listing's own price series, and running it through an
                        // FX rate would make it a different number every day for
                        // reasons that have nothing to do with the asset. The
                        // EUR figures below come from PortfolioCalculator.
                        Text("\(formatAxis(raw)) \(viewModel.nativeCurrency)")
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
        .frame(height: 200)
        .padding(.horizontal, 16)
    }

    private func yDomain(_ bounds: (low: Decimal, high: Decimal)?) -> ClosedRange<Double> {
        guard let bounds else { return 0...1 }
        let low = NSDecimalNumber(decimal: bounds.low).doubleValue
        let high = NSDecimalNumber(decimal: bounds.high).doubleValue
        return low < high ? low...high : (low - 1)...(high + 1)
    }

    private func lineColor(_ series: ChartSeries) -> Color {
        (series.change?.absolute ?? 0) >= 0 ? PB.pos : PB.neg
    }

    /// A skeleton, not a bare spinner: the shape of the chart that is coming,
    /// so the screen does not visibly empty out while the network is asked.
    private var chartSkeleton: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 200)
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<12, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.16))
                            .frame(width: 10, height: 30 + CGFloat((i * 37) % 90))
                    }
                }
                .padding(12)
            }
            .padding(.horizontal, 16)
            .redacted(reason: .placeholder)
            .accessibilityLabel("A carregar histórico")
    }

    /// Ranges the history cannot fill are disabled, not hidden — so it is
    /// visible that they exist and that the data will reach them.
    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(ChartRange.chartSelectable, id: \.self) { range in
                let available = viewModel.isRangeAvailable(range)
                Button {
                    viewModel.selectedRange = range
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedRange == range
                                ? PB.accent.opacity(0.16)
                                : Color.clear,
                            in: Capsule()
                        )
                        .foregroundStyle(
                            !available ? Color.secondary.opacity(0.4)
                                : viewModel.selectedRange == range ? PB.accent : Color.secondary
                        )
                }
                .disabled(!available)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Watchlist

    private var watchlistNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text("Ativo seguido, sem posição. Não entra no valor nem na alocação da carteira.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Figures

    private var figuresSection: some View {
        VStack(spacing: 0) {
            figureRow("Quantidade", formatQuantity(viewModel.quantity))
            Divider().padding(.leading, 16)
            figureRow("Preço médio", formatEUR(viewModel.averagePriceEUR))
            Divider().padding(.leading, 16)
            figureRow("Custo total", formatEUR(viewModel.totalCostEUR))
            Divider().padding(.leading, 16)
            figureRow("Valor de mercado", viewModel.marketValueEUR.map(formatEUR) ?? "—")
            Divider().padding(.leading, 16)
            figureRow(
                "P/L não realizado",
                viewModel.unrealizedPL.map(formatSignedEUR) ?? "—",
                tint: (viewModel.unrealizedPL ?? 0) >= 0 ? PB.pos : PB.neg,
                tinted: viewModel.unrealizedPL != nil,
                detail: viewModel.unrealizedPLPercent.map(formatPercent)
            )
            Divider().padding(.leading, 16)
            figureRow(
                "P/L realizado",
                formatSignedEUR(viewModel.realizedPL),
                tint: viewModel.realizedPL >= 0 ? PB.pos : PB.neg,
                tinted: viewModel.realizedPL != 0
            )
            if viewModel.dividendsReceived != 0 {
                Divider().padding(.leading, 16)
                figureRow("Dividendos", formatEUR(viewModel.dividendsReceived))
            }
            Divider().padding(.leading, 16)
            figureRow("Peso na carteira", viewModel.portfolioWeightPercent.map {
                formatPercent($0, signed: false)
            } ?? "—")
        }
        .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .padding(.horizontal, 16)
    }

    private func figureRow(
        _ label: String,
        _ value: String,
        tint: Color = .primary,
        tinted: Bool = false,
        detail: String? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tinted ? tint : .secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tinted ? tint : .primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Transactions

    @ViewBuilder
    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRANSAÇÕES")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            if viewModel.transactions.isEmpty {
                Text("Sem transações registadas.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.transactions.enumerated()), id: \.element.id) { i, tx in
                        transactionRow(tx)
                        if i < viewModel.transactions.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(
                    Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .padding(.horizontal, 16)
            }
        }
    }

    private func transactionRow(_ tx: FinancialTransaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.type.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if let qty = tx.assetQuantity, let price = tx.assetUnitPrice {
                    Text("\(formatQuantity(qty)) un × \(formatNative(price)) \(viewModel.nativeCurrency)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatEUR(tx.amount))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Text(AssetDetailViewModel.dayLabel(tx.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Formatting

    private func formatNative(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = value < 1 ? 8 : 2
        return f.string(from: value as NSDecimalNumber) ?? "—"
    }

    private func formatAxis(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.maximumFractionDigits = value < 10 ? 2 : 0
        return f.string(from: NSNumber(value: value)) ?? ""
    }

    private func formatEUR(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        return f.string(from: value as NSDecimalNumber) ?? "—"
    }

    private func formatSignedEUR(_ value: Decimal) -> String {
        (value >= 0 ? "+" : "") + formatEUR(value)
    }

    private func formatPercent(_ value: Decimal) -> String {
        formatPercent(value, signed: true)
    }

    private func formatPercent(_ value: Decimal, signed: Bool) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let sign = signed && value >= 0 ? "+" : ""
        return sign + (f.string(from: value as NSDecimalNumber) ?? "0") + "%"
    }

    private func formatQuantity(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 8
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}
