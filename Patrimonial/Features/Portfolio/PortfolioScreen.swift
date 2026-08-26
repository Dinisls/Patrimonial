import SwiftUI
import SwiftData

struct PortfolioScreen: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = PortfolioViewModel()
    @State private var watchlist = WatchlistViewModel()
    /// Shared with the rest of the app rather than owned here — see
    /// `PBRootView`. Settings needs to be able to clear it on a data reset.
    @Environment(PriceStore.self) private var priceStore
    @State private var candleStore = CandleStore()
    @State private var segment = "Portfolio"
    @State private var showAddPosition = false
    @State private var showAddWatchlist = false
    @State private var pendingDelete: Holding?
    @State private var deleteError: String?
    @Query(sort: \Account.name) private var allAccounts: [Account]

    private let segments = ["Portfolio", "Alocação", "Watchlist", "Evolução"]

    var body: some View {
        VStack(spacing: 0) {
            SegmentedControl(options: segments, value: $segment)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            switch segment {
            case "Portfolio":
                portfolioContent
            case "Alocação":
                AllocationTabView(viewModel: viewModel)
            case "Watchlist":
                WatchlistTabView(
                    watchlist: watchlist,
                    portfolio: viewModel,
                    showAdd: $showAddWatchlist
                )
            case "Evolução":
                EvolutionTabView()
            default:
                EmptyView()
            }
        }
        .background(PB.bg)
        .navigationDestination(for: String.self) { holdingID in
            if let holding = viewModel.holdings.first(where: { $0.id == holdingID }) {
                AssetDetailView(
                    listing: holding.listing,
                    accountID: holding.accountID,
                    holdingID: holding.id,
                    priceStore: priceStore,
                    candleStore: candleStore,
                    portfolio: viewModel
                )
            }
        }
        .navigationDestination(for: WatchlistRoute.self) { route in
            AssetDetailView(
                listing: route.listing,
                accountID: "",
                holdingID: route.listing.storageKey,
                priceStore: priceStore,
                candleStore: candleStore,
                portfolio: viewModel,
                isWatchlist: true
            )
        }
        .navigationTitle("Investimentos")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if segment == "Watchlist" {
                        showAddWatchlist = true
                    } else {
                        showAddPosition = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddPosition) {
            AddPositionSheet(viewModel: viewModel)
                .environment(\.modelContext, modelContext)
        }
        .sheet(isPresented: $showAddWatchlist) {
            AddWatchlistSheet(
                portfolio: viewModel,
                watchlist: watchlist,
                openListings: openListings
            )
            .environment(\.modelContext, modelContext)
        }
        .onChange(of: showAddWatchlist) { _, isShowing in
            // A ticker followed while the sheet was up has to be picked up by
            // the polling loop, or the new row shows a dash until the next
            // launch.
            if !isShowing { startQuotes() }
        }
        .onAppear {
            priceStore.configureLive(modelContext: modelContext)
            candleStore.bind(modelContext: modelContext)
            // The second opinion the plausibility check needs: the last close
            // this symbol's own history knows about. Wired before hydration so
            // a cached price is checked on the same terms as a fresh one.
            priceStore.referenceClose = { [candleStore] listing in
                candleStore.series(for: listing).last?.close
            }
            priceStore.hydrateFromCache()
            viewModel.bind(modelContext: modelContext, priceStore: priceStore)
            viewModel.referenceCloseLookup = { [candleStore] listing, cutoff in
                let target = CandleStore.sessionDate(cutoff)
                return candleStore.series(for: listing)
                    .last(where: { $0.date <= target })?.close
            }
            viewModel.loadHoldings()
            watchlist.bind(modelContext: modelContext, priceStore: priceStore)
            watchlist.load(openListings: openListings)
            startQuotes()
        }
        .onDisappear {
            priceStore.stopPolling()
        }
        .onChange(of: priceStore.revision) { _, _ in
            viewModel.loadHoldings()
            // A purchase made from the watchlist turns a followed ticker into a
            // position; the entry stays flagged but drops out of the list.
            watchlist.load(openListings: openListings)
            // Prices are what reveal which currencies are actually held, so the
            // rates can only be fetched once a quote has landed.
            Task {
                await viewModel.refreshCurrentFXRates()
                // Only once rates have landed can the portfolio be fully
                // valued, and only a fully valued portfolio is recorded — see
                // PortfolioSnapshotRecorder. Repeated calls in a day overwrite
                // rather than accumulate.
                PortfolioSnapshotRecorder.record(
                    holdings: viewModel.holdings, accounts: allAccounts, in: modelContext
                )
            }
        }
        .alert(
            "Apagar posição?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { holding in
            Button("Apagar", role: .destructive) { confirmDelete(holding) }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { holding in
            let count = viewModel.transactionCount(
                listing: holding.listing, accountID: holding.accountID
            )
            let noun = count == 1 ? "transação" : "transações"
            let scope = holding.isUnified
                ? "em todas as contas"
                : "em \(holding.accountName)"
            Text("Isto apaga \(count) \(noun) de \(holding.listing.description) \(scope), e o histórico correspondente. Não pode ser anulado.")
        }
        .alert("Erro ao apagar", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func confirmDelete(_ holding: Holding) {
        pendingDelete = nil
        do {
            try viewModel.deletePosition(
                listing: holding.listing, accountID: holding.accountID
            )
            // The deleted ticker must stop being polled and be dropped from the
            // in-memory quotes, or its price comes straight back into the cache
            // we just cleared.
            priceStore.stopPolling()
            watchlist.load(openListings: openListings)
            // Still followed, still priced. Only a ticker nothing refers to any
            // more loses its quote.
            if !viewModel.openHoldings.contains(where: { $0.listing == holding.listing }),
               !watchlist.isWatchlisted(holding.listing) {
                priceStore.forget(listing: holding.listing)
            }
            startQuotes()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Listings with an open position. Also what the watchlist filters itself
    /// against — a listing that is held is a position, not something followed.
    private var openListings: Set<ListingID> {
        Set(viewModel.holdings.filter(\.isOpen).map(\.listing))
    }

    /// Held listings whose latest quote was refused for contradicting their own
    /// history. Scoped to open positions so a stale entry for something no
    /// longer held cannot keep a warning on screen.
    private var discrepantSymbols: [String] {
        openListings
            .filter { priceStore.discrepancy(for: $0) != nil }
            .map(\.description)
            .sorted()
    }

    /// Nothing was ever asking for prices, so the quote dictionary stayed empty
    /// and every position showed a dash.
    ///
    /// Watchlist symbols ride the same loop rather than getting a second,
    /// weaker path: one subscription policy, one rate budget, one set of
    /// freshness rules. The cost is real — each followed ticker is another
    /// symbol against the daily budgets — and it is the price of the watchlist
    /// showing the same numbers the positions do.
    private func startQuotes() {
        let subscriptions = Array(openListings.union(watchlist.listings))
        guard !subscriptions.isEmpty else { return }
        priceStore.startPolling(listings: subscriptions)
    }

    // MARK: - Portfolio tab

    private var portfolioContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dataSourceBanner
                headerSection
                sortBar
                holdingsList
                Spacer(minLength: 100)
            }
        }
    }

    /// Simulated prices must never be mistaken for real ones, and a missing key
    /// must say so rather than look like an outage.
    @ViewBuilder
    private var dataSourceBanner: some View {
        if priceStore.isUsingMockData {
            let missingKeys = !AppConfig.hasTwelveDataKey && !AppConfig.hasFinnhubKey
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(missingKeys
                     ? "Sem chaves de API — cotações simuladas"
                     : "Dados simulados — cotações não são reais")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PB.accent, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if let error = viewModel.error {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundStyle(PB.neg)
                    .padding(16)
            } else {
                Text("Valor total")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if viewModel.privacyMode {
                    Text("••••")
                        .font(.system(size: 38, weight: .bold))
                } else if let total = viewModel.marketValueTotal {
                    Text(formatDecimalEUR(total.value))
                        .font(.system(size: 38, weight: .bold))
                        .monospacedDigit()
                    // A partial total must never appear as a plain one. The
                    // caveat is rendered in the same branch as the number, so
                    // there is no path that shows one without the other.
                    if total.isPartial {
                        Text(partialTotalCaveat(total.excludedCount))
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                } else if viewModel.openHoldings.isEmpty {
                    Text(formatDecimalEUR(0))
                        .font(.system(size: 38, weight: .bold))
                        .monospacedDigit()
                } else {
                    // Nothing at all could be priced, so there is no partial
                    // total to show either.
                    Text("—")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(partialTotalCaveat(viewModel.openHoldings.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }

                if !viewModel.privacyMode {
                    plChip
                        .padding(.top, 4)
                    periodPicker
                        .padding(.top, 10)
                    periodChangeLine
                        .padding(.top, 4)
                }

                HStack(spacing: 8) {
                    Button(viewModel.privacyMode ? "Mostrar" : "Ocultar") {
                        viewModel.privacyMode.toggle()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PB.accent)

                    // The exclusion is already spelled out under the total, so
                    // repeating it here would say the same thing twice.
                    if viewModel.hasMissingQuotes && viewModel.marketValueTotal == nil {
                        Text("· Posições sem cotação")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    if viewModel.hasMissingFXRates {
                        Text("· Câmbio indisponível")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    // A refused price must be visible as a refusal. Left
                    // unsaid, it is indistinguishable from a provider outage,
                    // and the whole point is that this one means something
                    // specific: the quote disagreed with the instrument's own
                    // history.
                    if discrepantSymbols.count == 1 {
                        Text("· Cotação de \(discrepantSymbols[0]) inconsistente com o histórico")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    } else if discrepantSymbols.count > 1 {
                        Text("· \(discrepantSymbols.count) cotações inconsistentes com o histórico")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var plChip: some View {
        if let pl = viewModel.totalUnrealizedPL, let pct = viewModel.totalUnrealizedPLPercent {
            let positive = pl >= 0
            HStack(spacing: 4) {
                Text(formatSignedDecimalEUR(pl))
                Text("(\(formatDecimalPct(pct)))")
            }
            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(positive ? PB.pos : PB.neg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill((positive ? PB.pos : PB.neg).opacity(0.15))
            )
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 6) {
            ForEach(PerformancePeriod.allCases, id: \.self) { period in
                Button {
                    viewModel.selectedPeriod = period
                } label: {
                    Text(period.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedPeriod == period
                                ? PB.accent.opacity(0.16)
                                : Color.clear,
                            in: Capsule()
                        )
                        .foregroundStyle(
                            viewModel.selectedPeriod == period
                                ? PB.accent
                                : Color.secondary
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var periodChangeLine: some View {
        if let dc = viewModel.periodChangeTotal {
            let positive = dc.value >= 0
            HStack(spacing: 4) {
                Text(formatSignedDecimalEUR(dc.value))
                if let pct = periodChangePct(dc) {
                    Text("(\(formatDecimalPct(pct)))")
                }
                if dc.isPartial {
                    Text("· parcial")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(positive ? PB.pos : PB.neg)
        } else if !viewModel.openHoldings.isEmpty {
            Text("sem dados suficientes")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func periodChangePct(_ total: PortfolioCalculator.DayChangeTotal) -> Decimal? {
        guard let mv = viewModel.marketValueTotal?.value, mv > 0 else { return nil }
        let base = mv - total.value
        guard base > 0 else { return nil }
        return (total.value / base) * 100
    }

    // MARK: - Sort

    private var sortBar: some View {
        HStack {
            Text("POSIÇÕES")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            // Beside the heading of the list whose rows carry the dots.
            FreshnessLegendButton()
            Spacer()
            Menu {
                ForEach(PortfolioViewModel.SortMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.sortMode = mode
                        viewModel.loadHoldings()
                    } label: {
                        if mode == viewModel.sortMode {
                            Label(mode.rawValue, systemImage: "checkmark")
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.sortMode.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(PB.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Holdings list

    private var holdingsList: some View {
        Group {
            if viewModel.openHoldings.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "Sem posições",
                    systemImage: "chart.bar",
                    description: Text("Toca em + para registar a primeira compra.")
                )
                .padding(.top, 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.openHoldings.enumerated()), id: \.element.id) { i, holding in
                        // Tap opens the detail, long-press still opens the
                        // delete menu. `NavigationLink` and `.contextMenu`
                        // resolve this between themselves — a tap activates the
                        // link, a press opens the menu — which is why the
                        // gesture is not hand-rolled.
                        NavigationLink(value: holding.id) {
                            PositionRowView(
                                holding: holding,
                                privacyMode: viewModel.privacyMode,
                                freshness: priceStore.quote(for: holding.listing) == nil
                                    ? nil
                                    : priceStore.freshness(for: holding.listing)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = holding
                            } label: {
                                Label("Apagar posição", systemImage: "trash")
                            }
                        }
                        if i < viewModel.openHoldings.count - 1 {
                            Divider().padding(.leading, 70)
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

    // MARK: - Formatters

    /// Says what is missing and how much, so the number above it is read as the
    /// part it is. "Exclui" rather than "sem cotação": the point is not that a
    /// price is missing but that the total in front of the user is incomplete.
    private func partialTotalCaveat(_ count: Int) -> String {
        count == 1
            ? "Exclui 1 posição sem cotação"
            : "Exclui \(count) posições sem cotação"
    }

    private func formatDecimalEUR(_ value: Decimal) -> String {
        let ns = value as NSDecimalNumber
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: ns) ?? "—"
    }

    private func formatSignedDecimalEUR(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value < 0 ? -value : value)
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let formatted = f.string(from: ns) ?? "0,00 €"
        return value >= 0 ? "+\(formatted)" : "−\(formatted)"
    }

    private func formatDecimalPct(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value < 0 ? -value : value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let formatted = f.string(from: ns) ?? "0"
        return (value >= 0 ? "+" : "−") + formatted + "%"
    }
}
