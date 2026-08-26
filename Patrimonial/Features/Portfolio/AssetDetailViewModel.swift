import Foundation
import SwiftData
import Observation

/// Everything the asset detail screen shows, for one position.
///
/// Cache first, network second. The screen is built from what is already on
/// disk and then refreshed underneath — there is no state in which it waits on
/// the network with nothing drawn, because the history it needs was fetched on
/// previous days and never thrown away.
@MainActor
@Observable
final class AssetDetailViewModel {

    let listing: ListingID
    var symbol: String { listing.symbol }
    let accountID: String
    /// Opened from the watchlist: there is no position behind this screen, so
    /// the position figures and the transaction list have nothing to show and
    /// the only sensible action is to buy. The price, the freshness and the
    /// chart are identical — they describe the listing, not the holding.
    let isWatchlist: Bool

    private(set) var holding: Holding?
    private(set) var transactions: [FinancialTransaction] = []
    private(set) var series: ChartSeries?
    /// True only while a network refresh is in flight *and* there is nothing
    /// cached to draw. A refresh over existing data must not blank the chart.
    private(set) var isLoadingHistory = false

    var selectedRange: ChartRange = .oneMonth {
        didSet { reloadSeries() }
    }

    private var modelContext: ModelContext?
    private var priceStore: PriceStore?
    private var candleStore: CandleStore?
    private var portfolio: PortfolioViewModel?

    var isUnified: Bool { accountID.isEmpty && !isWatchlist }

    init(listing: ListingID, accountID: String, isWatchlist: Bool = false) {
        self.listing = listing
        self.accountID = accountID
        self.isWatchlist = isWatchlist
    }

    func bind(
        modelContext: ModelContext,
        priceStore: PriceStore,
        candleStore: CandleStore,
        portfolio: PortfolioViewModel
    ) {
        self.modelContext = modelContext
        self.priceStore = priceStore
        self.candleStore = candleStore
        self.portfolio = portfolio
        load()
    }

    // MARK: - Loading

    func load() {
        holding = portfolio?.holdings.first {
            $0.listing == listing
            && (isUnified ? $0.isUnified || $0.accountID.isEmpty : $0.accountID == accountID)
        }
        loadTransactions()
        reloadSeries()
    }

    private func loadTransactions() {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<FinancialTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let listing = self.listing
        let accountID = self.accountID
        let unified = self.isUnified
        transactions = ((try? ctx.fetch(descriptor)) ?? []).filter { tx in
            tx.assetSymbol.map { ListingID(symbol: $0, mic: tx.assetMIC) } == listing
                && (unified || tx.sourceAccount?.id.uuidString == accountID)
        }
    }

    /// Reading is a filter over the cached series — never a fetch. Changing
    /// range must cost nothing, because all four ranges are views of one array.
    private func reloadSeries() {
        guard let candleStore else { return }
        series = candleStore.series(for: listing, range: selectedRange)
    }

    /// Fetches only what the cache lacks, then redraws. Safe to call on every
    /// appearance: a current cache makes it a no-op.
    func refreshHistory() async {
        guard let candleStore, let route else { return }

        let hadSomething = !(candleStore.series(for: listing).isEmpty)
        // The skeleton is only for a genuinely empty screen. With candles on
        // disk the chart stays up and is replaced when the new ones land.
        isLoadingHistory = !hadSomething
        await candleStore.refresh(listing: listing, route: route, range: .max)
        isLoadingHistory = false
        reloadSeries()
    }

    /// Which provider can serve this symbol's history, from the recorded MIC.
    ///
    /// Nil when the venue has no history provider — the German secondaries,
    /// Buenos Aires, Bogotá. Those get a quote from Yahoo but no chart, which
    /// is the agreed trade: Yahoo is not a history source.
    var route: CandleStore.Route? {
        guard let priceStore else { return nil }

        if let coinID = priceStore.coinGeckoID(for: symbol) {
            return .crypto(coinID: coinID)
        }
        guard let mic = listing.mic, let exchange = MarketCalendar.exchangeForMIC(mic)
        else { return nil }

        if exchange.isEuropean {
            guard let suffix = exchange.alphaVantageSuffix else { return nil }
            return .european(symbol: symbol.hasSuffix(suffix) ? symbol : symbol + suffix)
        }
        return .unitedStates(symbol: symbol)
    }

    /// True when this asset has no history source at all, so the screen can say
    /// why rather than showing an empty frame.
    var hasNoHistoryProvider: Bool { route == nil }

    // MARK: - Price

    var quote: Quote? { priceStore?.quote(for: listing) }

    var freshness: QuoteFreshness? {
        guard quote != nil else { return nil }
        return priceStore?.freshness(for: listing)
    }

    /// The listing's own currency — the chart is drawn in it, unconverted.
    var nativeCurrency: String {
        priceStore?.listing(for: listing)?.currency
            ?? quote?.currency
            ?? holding?.currency
            ?? ""
    }

    // MARK: - Chart availability

    /// Ranges longer than the stored history are offered but disabled, so it is
    /// visible that they exist and that the data does not reach them yet.
    func isRangeAvailable(_ range: ChartRange) -> Bool {
        guard let candleStore else { return false }
        return candleStore.series(for: listing, range: range).candles.count >= 2
    }

    /// Fewer than two points is not a line: the chart hides and the rest of the
    /// screen carries on.
    var showsChart: Bool {
        guard let series else { return false }
        return !series.isEmpty
    }

    /// Set when the series starts after the range does — shown as text, never
    /// as a padded window drawn down to zero.
    var shortfallDescription: String? {
        guard let series, !series.isEmpty, !series.coversFullRange,
              let first = series.firstDate
        else { return nil }
        return "Histórico desde \(Self.dayLabel(first))"
    }

    // MARK: - Position figures

    var quantity: Decimal { holding?.quantity ?? 0 }
    var averagePriceEUR: Decimal { holding?.averagePriceEUR ?? 0 }
    var totalCostEUR: Decimal { holding?.totalCostEUR ?? 0 }
    var marketValueEUR: Decimal? { holding?.marketValueEUR }
    var unrealizedPL: Decimal? { holding?.unrealizedPL }
    var unrealizedPLPercent: Decimal? { holding?.unrealizedPLPercent }
    var realizedPL: Decimal { holding?.realizedPL ?? 0 }
    var dividendsReceived: Decimal { holding?.dividendsReceived ?? 0 }

    /// Share of the portfolio, against the same partial total the header shows —
    /// so the number is consistent with what the user just came from. Nil when
    /// this position is one of the unpriced ones.
    var portfolioWeightPercent: Decimal? {
        guard let value = marketValueEUR,
              let total = portfolio?.marketValueTotal,
              total.value > 0
        else { return nil }
        return (value / total.value) * 100
    }

    // MARK: - Quick actions

    var isCrypto: Bool {
        if let cls = holding?.assetClass { return cls == .crypto }
        if case .crypto = route { return true }
        return false
    }

    /// The listing this position was bought on, rebuilt from what was stored at
    /// purchase, so a quick action carries the same venue, MIC and currency the
    /// original transaction did.
    ///
    /// Nil when there is no `Asset` row — a position from before the venue was
    /// recorded. The buttons hide rather than opening a sheet that would write
    /// a second, venue-less asset over a good one.
    var prefillAsset: AssetSearchResult? {
        guard let ctx = modelContext else { return nil }
        let symbol = self.symbol
        let listing = self.listing
        let descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.symbol == symbol })
        guard let asset = ((try? ctx.fetch(descriptor)) ?? []).first(where: { $0.listing == listing }),
              !asset.currency.isEmpty,
              asset.assetClass == .crypto || !asset.exchange.isEmpty
        else { return nil }

        return AssetSearchResult(
            symbol: asset.symbol,
            name: asset.name,
            exchange: asset.exchange,
            assetClass: asset.assetClass,
            currency: asset.currency,
            mic: asset.assetClass == .crypto ? nil : asset.exchange,
            coingeckoID: asset.coingeckoID
        )
    }

    var canUseQuickActions: Bool {
        prefillAsset != nil && (isWatchlist || isUnified || accountUUID != nil)
    }

    var accountUUID: UUID? { UUID(uuidString: accountID) }

    var availableToSell: Decimal {
        portfolio?.totalQuantity(listing: listing) ?? 0
    }

    func prefill(for type: TransactionType) -> AddPositionSheet.Prefill? {
        guard let asset = prefillAsset else { return nil }
        return AddPositionSheet.Prefill(asset: asset, accountID: nil, type: type)
    }

    static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f.string(from: date)
    }
}
