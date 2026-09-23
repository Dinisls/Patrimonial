import Foundation
import SwiftUI
import SwiftData
import Observation

@MainActor
@Observable
final class PortfolioViewModel {
    /// One line per asset. The position is a single pool — the account tracks
    /// cash flow, not ownership of units.
    private(set) var holdings: [Holding] = []
    /// Per-account breakdown for allocation by account. Derived from buy
    /// transactions only, scaled by the ratio of current to bought quantity.
    private(set) var perAccountHoldings: [Holding] = []
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var hasMissingQuotes = false
    /// A price arrived but its currency cannot be converted, so the position has
    /// no honest euro value to show.
    private(set) var hasMissingFXRates = false
    var privacyMode = false

    /// Native currency → the rate into EUR, direction included.
    ///
    /// The key says which currency the entry is *about*; the value says which
    /// direction it converts. Those two used to be the same claim made twice,
    /// once as a dictionary key and once as an unwritten convention, and only
    /// the key was ever checked.
    private(set) var currentFXRates: [String: FXRate] = [:]

    private var modelContext: ModelContext?
    private var priceStore: PriceStore?
    private var fxProvider: (any FXRateProvider)?

    enum SortMode: String, CaseIterable {
        case value = "Valor"
        case plPercent = "P/L %"
        case alphabetical = "A-Z"
    }

    var sortMode: SortMode = .value

    enum ValidationError: Error, LocalizedError {
        case futureDate

        var errorDescription: String? {
            switch self {
            case .futureDate: "Data não pode ser no futuro"
            }
        }
    }

    /// Two instruments claiming rows that can no longer be told apart.
    ///
    /// Much narrower than it was. The app now holds both listings happily — that
    /// is ponto F — so this fires only in the one case where accepting the
    /// purchase would destroy information: there are transactions for this
    /// ticker whose venue was never recorded, and they are currently
    /// attributable because exactly one venue exists for the ticker. Admit a
    /// second and those rows become unattributable for good, and the user's
    /// average price silently splits across two positions with no way back.
    enum AssetConflictError: Error, LocalizedError {
        case unattributedRows(symbol: String, recorded: String, incoming: String)

        var errorDescription: String? {
            switch self {
            case .unattributedRows(let symbol, let recorded, let incoming):
                "Há movimentos de \(symbol) gravados antes de a app guardar a praça, e neste momento só podem pertencer a \(recorded). Se registar também \(symbol) em \(incoming), deixa de haver forma de saber a que praça esses movimentos pertencem, e o preço médio partia-se em dois sem explicação. Nada foi gravado. Abre a posição de \(symbol) em \(recorded) e volta a gravar uma compra dela para os atribuir, e depois esta compra passa."
            }
        }
    }

    // Injectable save for testing rollback scenarios
    var saveHandler: ((ModelContext) throws -> Void)?

    /// Injectable clock.
    ///
    /// Here because the day change depends on *which day it is* in a way no
    /// other total does: the bug that put "Hoje +5,46 €" back on the header only
    /// reproduces when the app is read outside a session, and a test that calls
    /// `Date()` reproduces it on two days out of seven. See
    /// `MarketCalendar.currentSessionStart`.
    var now: () -> Date = { Date() }

    func bind(modelContext: ModelContext, priceStore: PriceStore, fxProvider: (any FXRateProvider)? = nil) {
        self.modelContext = modelContext
        self.priceStore = priceStore
        self.fxProvider = fxProvider ?? FrankfurterProvider()
    }

    // MARK: - Load

    func loadHoldings() {
        guard let ctx = modelContext else { return }
        isLoading = true
        error = nil

        let descriptor = FetchDescriptor<FinancialTransaction>(
            sortBy: [SortDescriptor(\.date)]
        )
        guard let allTx = try? ctx.fetch(descriptor) else {
            error = "Erro ao carregar transações"
            isLoading = false
            return
        }

        let investmentTx = PortfolioCalculator.investmentTransactions(from: allTx)

        // One instant for the whole load, so two holdings priced in the same
        // pass can never land either side of a session boundary.
        let asOf = now()

        do {
            var computed = try PortfolioCalculator.computeHoldings(
                from: investmentTx
            )
            hasMissingQuotes = false
            hasMissingFXRates = false

            let classes = assetClassByListing(in: ctx)

            for i in computed.indices {
                let listing = computed[i].listing

                let window = priceStore?.sessionWindow(for: listing, at: asOf)
                    ?? .open(from: MarketCalendar.widestSessionStart(at: asOf))
                computed[i].sessionStart = window.start
                computed[i].sessionEnd = window.end

                computed[i].currency = nativeCurrency(for: listing)
                computed[i].assetClass = classes[listing]

                if let quote = priceStore?.quote(for: listing), quote.price > 0 {
                    computed[i].currentPriceNative = quote.price
                    let fx = lookupCurrentFX(for: listing)
                    computed[i].currentFXRate = fx
                    computed[i].previousCloseNative = quote.previousClose
                    if fx == nil && computed[i].isOpen { hasMissingFXRates = true }
                } else if computed[i].isOpen {
                    hasMissingQuotes = true
                }
            }

            holdings = sortHoldings(computed)
            perAccountHoldings = PortfolioCalculator.perAccountHoldings(
                from: investmentTx, unified: computed
            )
            publishToWidget()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func publishToWidget() {
        let open = openHoldings
        let totalVal = open.reduce(Decimal.zero) { $0 + ($1.marketValueEUR ?? 0) }
        let totalCst = PortfolioCalculator.totalCost(open)
        let dayChange = PortfolioCalculator.dayChangeTotal(open)

        let top = open
            .filter { $0.marketValueEUR != nil }
            .sorted { ($0.marketValueEUR ?? 0) > ($1.marketValueEUR ?? 0) }
            .prefix(5)
            .map { h in
                let mv = h.marketValueEUR ?? 0
                let dayPct: Decimal? = if let dc = h.dayChangeEUR, mv > 0 {
                    (dc / mv) * 100
                } else {
                    nil
                }
                return WidgetDataBridge.Position(
                    symbol: h.assetSymbol,
                    name: h.assetSymbol,
                    value: mv,
                    dayChangePercent: dayPct,
                    weight: totalVal > 0 ? (mv / totalVal) * 100 : 0
                )
            }

        let dcValue = dayChange?.value ?? 0
        let dcPercent: Decimal = totalVal > 0 ? (dcValue / totalVal) * 100 : 0
        WidgetDataBridge.write(WidgetDataBridge.PortfolioSummary(
            totalValue: totalVal,
            totalCost: totalCst,
            dayChangeAbsolute: dcValue,
            dayChangePercent: dcPercent,
            positionCount: open.count,
            topPositions: top,
            updatedAt: Date()
        ))
    }

    /// Listing → class, from the stored `Asset` rows. Missing entries stay
    /// missing: a position with no `Asset` row is unclassified, and allocation
    /// labels it as such rather than defaulting it into "Ações".
    ///
    /// Keyed by listing, so NVIDIA does not lend its "Ações" to the inverse ETF
    /// that shares its ticker — the allocation chart would have shown the ETF's
    /// value in the equities slice.
    private func assetClassByListing(in ctx: ModelContext) -> [ListingID: AssetClass] {
        guard let assets = try? ctx.fetch(FetchDescriptor<Asset>()) else { return [:] }
        return Dictionary(assets.map { ($0.listing, $0.assetClass) }) { a, _ in a }
    }

    // MARK: - Derived totals

    var openHoldings: [Holding] { holdings.filter(\.isOpen) }

    // MARK: - Allocation

    var allocationDimension: PortfolioAllocation.Dimension = .assetClass

    var allocation: PortfolioAllocation.Result {
        let source = allocationDimension == .account
            ? perAccountHoldings.filter(\.isOpen)
            : openHoldings
        return PortfolioAllocation.allocation(allocationDimension, holdings: source)
    }

    /// The value shown in the header, with its own account of what it leaves
    /// out. Nil only when nothing could be priced.
    var marketValueTotal: PortfolioCalculator.MarketValueTotal? {
        PortfolioCalculator.marketValueTotal(openHoldings)
    }

    /// How many open positions the header total excludes, for the label that
    /// has to accompany it.
    var unpricedPositionCount: Int {
        marketValueTotal?.excludedCount ?? openHoldings.count
    }

    var totalMarketValue: Decimal? {
        PortfolioCalculator.totalMarketValue(openHoldings)
    }

    var totalCost: Decimal {
        PortfolioCalculator.totalCost(openHoldings)
    }

    /// Over the priced positions only, matching the header total. Reporting P/L
    /// against the full cost while the value covers a subset would understate
    /// the return by whatever the unpriced positions cost.
    var totalUnrealizedPL: Decimal? {
        marketValueTotal?.unrealizedPL
    }

    var totalUnrealizedPLPercent: Decimal? {
        marketValueTotal?.unrealizedPLPercent
    }

    /// Partial in the same way the value total is, and carrying the same
    /// exclusion count, so the two figures in the header never disagree about
    /// which positions they describe.
    var dayChangeTotal: PortfolioCalculator.DayChangeTotal? {
        PortfolioCalculator.dayChangeTotal(openHoldings)
    }

    // MARK: - Period change

    var selectedPeriod: PerformancePeriod = {
        guard let raw = UserDefaults.standard.string(forKey: "selectedPerformancePeriod"),
              let p = PerformancePeriod(rawValue: raw)
        else { return .oneDay }
        return p
    }() {
        didSet {
            UserDefaults.standard.set(selectedPeriod.rawValue, forKey: "selectedPerformancePeriod")
        }
    }

    var referenceCloseLookup: ((ListingID, Date) -> Decimal?)?

    var periodChangeTotal: PortfolioCalculator.DayChangeTotal? {
        let period = selectedPeriod
        if period == .oneDay {
            return PortfolioCalculator.dayChangeTotal(openHoldings)
        }

        let cutoff = period.cutoffDate(from: now())
        return PortfolioCalculator.changeTotal(openHoldings) { [referenceCloseLookup] h in
            guard let lookup = referenceCloseLookup,
                  let refClose = lookup(h.listing, cutoff)
            else { return nil }
            return h.periodChangeEUR(
                referenceClose: refClose,
                periodStart: cutoff,
                clampToReference: false,
                sessionEnd: nil
            )
        }
    }

    /// The selected period's change for one position, in euros and in percent.
    ///
    /// The per-row figure and the header total are the **same** computation with
    /// the same inputs — `periodChangeTotal` sums exactly what this returns.
    /// Two independent derivations would be two chances to disagree, and a row
    /// that contradicts the total above it is worse than no row at all.
    ///
    /// Nil whenever the position has no reference close inside the period: a
    /// ticker whose history the cache has not reached, or one bought after the
    /// cutoff with no candle behind it. The row shows a dash for those. It does
    /// **not** fall back to the lifetime P/L — a number under a "1M" label has
    /// to be a month's move or nothing.
    struct PeriodChange: Equatable {
        let eur: Decimal
        let percent: Decimal
    }

    func periodChange(for holding: Holding) -> PeriodChange? {
        let changeEUR: Decimal?
        if selectedPeriod == .oneDay {
            changeEUR = holding.dayChangeEUR
        } else {
            let cutoff = selectedPeriod.cutoffDate(from: now())
            guard let lookup = referenceCloseLookup,
                  let refClose = lookup(holding.listing, cutoff)
            else { return nil }
            changeEUR = holding.periodChangeEUR(
                referenceClose: refClose,
                periodStart: cutoff,
                clampToReference: false,
                sessionEnd: nil
            )
        }

        guard let eur = changeEUR, let marketValue = holding.marketValueEUR else { return nil }
        // The base is what the position was worth at the start of the period —
        // today's value less the move. Dividing by today's value instead would
        // understate every gain and overstate every loss.
        let base = marketValue - eur
        guard base > 0 else { return nil }
        return PeriodChange(eur: eur, percent: (eur / base) * 100)
    }

    // MARK: - Add investment transaction

    func addInvestment(
        type: TransactionType,
        symbol: String,
        quantity: Decimal,
        unitPrice: Decimal,
        fxRate: Decimal,
        commission: Decimal,
        account: Account,
        date: Date,
        note: String,
        asset: AssetSearchResult? = nil
    ) throws {
        guard let ctx = modelContext else { return }

        if date > now() { throw ValidationError.futureDate }

        let totalNative = quantity * unitPrice
        let totalEUR: Decimal
        switch type {
        case .assetPurchase:
            totalEUR = totalNative * fxRate + commission
        case .assetSale:
            totalEUR = totalNative * fxRate - commission
        case .dividend:
            totalEUR = totalNative * fxRate - commission
        default:
            return
        }

        if type == .assetSale {
            let listing = resolvedListing(
                symbol: symbol, asset: asset
            )
            let available = totalQuantity(listing: listing)
            if quantity > available {
                throw PortfolioCalculator.CalculationError.insufficientQuantity(
                    symbol: symbol, requested: quantity, available: available
                )
            }
        }

        // "Compra" alone said nothing about what was bought. The symbol belongs
        // in the title because that is all the movements list shows.
        let tx = FinancialTransaction(
            type: type,
            amount: totalEUR,
            date: date,
            note: note.isEmpty ? "\(type.displayName) \(symbol)" : note,
            category: .investments,
            sourceAccount: account
        )
        tx.assetSymbol = symbol
        tx.assetMIC = resolvedListing(symbol: symbol, asset: asset).mic
        tx.assetQuantity = quantity
        tx.assetUnitPrice = unitPrice
        tx.assetFXRate = fxRate
        tx.assetFXRateFrom = asset?.currency ?? "EUR"
        tx.assetFXRateTo = "EUR"
        tx.commission = commission

        ctx.insert(tx)

        do {
            if let asset { try upsertAsset(asset, in: ctx) }
        } catch {
            // The transaction is already inserted; a venue conflict must take it
            // back out rather than leave a position whose metadata was refused.
            ctx.rollback()
            throw error
        }

        do {
            if let handler = saveHandler {
                try handler(ctx)
            } else {
                try ctx.save()
            }
        } catch {
            ctx.rollback()
            throw error
        }

        loadHoldings()
    }

    /// Which listing this transaction is about.
    ///
    /// The picked listing when there is one. When there is not — a sale or a
    /// dividend entered without a search result behind it — the venue is
    /// inherited from what is already held, but **only** when that is
    /// unambiguous (exactly one venue exists for this ticker across all
    /// accounts).
    private func resolvedListing(
        symbol: String, asset: AssetSearchResult?
    ) -> ListingID {
        if let asset {
            return ListingID(symbol: symbol, mic: asset.mic ?? asset.exchange)
        }
        let wanted = ListingID(symbol: symbol)
        let candidates = Set(
            holdings
                .filter { $0.listing.symbol == wanted.symbol }
                .map(\.listing)
        )
        return candidates.count == 1 ? candidates.first! : wanted
    }

    /// Persists the venue and currency of the listing the user actually picked.
    /// Without this the app cannot tell IWDA on XAMS (EUR) from IWDA on XLON
    /// (USD), and the wrong FX rate gets applied to the cost.
    private func upsertAsset(_ result: AssetSearchResult, in ctx: ModelContext) throws {
        let symbol = result.symbol
        let venue = result.mic ?? result.exchange
        let isCrypto = result.assetClass == .crypto

        // Crypto has no exchange venue — its identity is the symbol alone, with
        // mic always nil. For everything else, a venue is required so the app
        // can tell two listings of the same ticker apart.
        guard isCrypto || !venue.isEmpty else { return }
        guard !result.currency.isEmpty else { return }

        let incoming = isCrypto
            ? ListingID(symbol: symbol)
            : ListingID(symbol: symbol, mic: venue)

        // Venue conflict checks apply only to exchange-traded assets. Crypto
        // has no venue to conflict on.
        if !isCrypto {
            let unattributed = ListingBackfill.hasUnattributedRows(forSymbol: symbol, in: ctx)
            let recorded = ListingBackfill.recordedVenues(forSymbol: symbol, in: ctx)
                .union(assetVenues(symbol, in: ctx))

            if unattributed, let other = recorded.subtracting([incoming.mic ?? ""]).first {
                throw AssetConflictError.unattributedRows(
                    symbol: symbol, recorded: other, incoming: incoming.mic ?? venue
                )
            }

            if unattributed, let mic = incoming.mic {
                ListingBackfill.adopt(venue: mic, forSymbol: symbol, in: ctx)
            }
        }

        priceStore?.register(incoming, currency: result.currency)
        priceStore?.registerAssetClass(incoming, result.assetClass)

        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        let existing = ((try? ctx.fetch(descriptor)) ?? []).first { $0.listing == incoming }

        if let existing {
            if !isCrypto && !venue.isEmpty { existing.exchange = venue }
            if !result.currency.isEmpty { existing.currency = result.currency }
            if existing.name.isEmpty { existing.name = result.name }
            if let cgID = result.coingeckoID { existing.coingeckoID = cgID }
        } else {
            ctx.insert(Asset(
                symbol: symbol,
                name: result.name,
                assetClass: result.assetClass,
                exchange: isCrypto ? "" : venue,
                currency: result.currency,
                coingeckoID: result.coingeckoID
            ))
        }
    }

    /// Venues recorded on `Asset` rows for a ticker. A watchlisted namesake has
    /// no transactions but still stakes a claim on the ticker.
    private func assetVenues(_ symbol: String, in ctx: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.symbol == symbol })
        return Set(((try? ctx.fetch(descriptor)) ?? []).compactMap { $0.listing.mic })
    }

    // MARK: - Delete position

    /// How many transactions a delete would take with it, for the confirmation.
    /// An empty accountID counts across all accounts (unified position).
    func transactionCount(listing: ListingID, accountID: String) -> Int {
        guard let ctx = modelContext,
              let all = try? ctx.fetch(FetchDescriptor<FinancialTransaction>())
        else { return 0 }
        return all.count {
            listingKey(for: $0) == listing
            && (accountID.isEmpty || accountKey(for: $0) == accountID)
        }
    }

    /// A position is not a stored object — it is the sum of its transactions. So
    /// removing one means removing those, and then the `Asset` row and the
    /// cached price, which would otherwise keep a deleted ticker alive.
    ///
    /// An empty accountID deletes across all accounts (unified position).
    func deletePosition(listing: ListingID, accountID: String) throws {
        guard let ctx = modelContext else { return }

        guard let all = try? ctx.fetch(FetchDescriptor<FinancialTransaction>()) else {
            throw DeletionError.fetchFailed
        }

        let isUnified = accountID.isEmpty
        var doomed: [FinancialTransaction] = []
        var survivingElsewhere = 0
        for tx in all where listingKey(for: tx) == listing {
            if isUnified || accountKey(for: tx) == accountID {
                doomed.append(tx)
            } else {
                survivingElsewhere += 1
            }
        }

        // One by one, not a batch predicate delete: that leaves rows behind here.
        for tx in doomed { ctx.delete(tx) }

        if survivingElsewhere == 0 {
            for asset in (try? ctx.fetch(assetDescriptor(listing.symbol))) ?? []
            where asset.listing == listing {
                // A watchlisted ticker is followed on its own account. Deleting
                // the position must not silently unfollow it — the row stays,
                // now carrying only the watchlist flag.
                if asset.isWatchlisted { continue }
                ctx.delete(asset)
            }
            for snapshot in (try? ctx.fetch(snapshotDescriptor(listing.symbol))) ?? []
            where snapshot.listing == listing {
                ctx.delete(snapshot)
            }
            for candle in (try? ctx.fetch(FetchDescriptor<CandleCache>())) ?? []
            where candle.listing == listing {
                // The chart cache too. It used to survive the position and get
                // re-adopted by whatever was bought under that ticker next,
                // handing a new position someone else's history.
                ctx.delete(candle)
            }
        }

        do {
            if let handler = saveHandler {
                try handler(ctx)
            } else {
                try ctx.save()
            }
        } catch {
            ctx.rollback()
            throw error
        }

        loadHoldings()
    }

    enum DeletionError: Error, LocalizedError {
        case fetchFailed

        var errorDescription: String? {
            switch self {
            case .fetchFailed: "Não foi possível ler as transações"
            }
        }
    }

    /// Matches how `loadHoldings` keys a holding's account, so a position and
    /// its delete always agree on which transactions belong to it.
    private func accountKey(for tx: FinancialTransaction) -> String {
        tx.sourceAccount?.id.uuidString ?? ""
    }

    /// Matches how `loadHoldings` keys a holding's listing, for the same reason.
    private func listingKey(for tx: FinancialTransaction) -> ListingID? {
        tx.assetSymbol.map { ListingID(symbol: $0, mic: tx.assetMIC) }
    }

    private func assetDescriptor(_ symbol: String) -> FetchDescriptor<Asset> {
        FetchDescriptor<Asset>(predicate: #Predicate { $0.symbol == symbol })
    }

    private func snapshotDescriptor(_ symbol: String) -> FetchDescriptor<PriceSnapshot> {
        FetchDescriptor<PriceSnapshot>(predicate: #Predicate { $0.symbol == symbol })
    }

    func registerCryptoAsset(symbol: String, coinGeckoID: String) {
        priceStore?.registerCoinID(symbol: symbol, coinID: coinGeckoID)
    }

    func totalQuantity(listing: ListingID) -> Decimal {
        holdings.first { $0.listing == listing }?.quantity ?? 0
    }

    /// Which accounts hold this listing and how much each has.
    func accountBreakdown(for listing: ListingID) -> [(accountID: String, accountName: String, quantity: Decimal)] {
        perAccountHoldings
            .filter { $0.listing == listing && $0.isOpen }
            .map { (accountID: $0.accountID, accountName: $0.accountName, quantity: $0.quantity) }
    }

    // MARK: - Ticker search

    private(set) var searchResults: [AssetSearchResult] = []
    /// Whether the list is expanded past the first few. Reset on every new
    /// search, so a query never opens already scrolled.
    var showAllSearchResults = false
    private(set) var isSearching = false

    /// The rows to render: the most relevant few until the user asks for the
    /// rest. The full list stays available — the deep venues are reachable,
    /// just not in the way.
    var visibleSearchResults: [AssetSearchResult] {
        showAllSearchResults
            ? searchResults
            : Array(searchResults.prefix(SearchRanking.initialDisplayCount))
    }

    var hiddenSearchResultCount: Int {
        max(0, searchResults.count - SearchRanking.initialDisplayCount)
    }
    private(set) var searchQuotes: [String: Quote] = [:]
    private(set) var isPricingSearch = false
    private var searchTask: Task<Void, Never>?

    /// How many result rows get a price. Every extra row is another symbol
    /// charged against the daily budgets.
    ///
    /// Matched to `SearchRanking.initialDisplayCount`, so every row visible
    /// before "ver mais" carries a price instead of a dash. Raising it was
    /// affordable only once ranking landed: the eight most relevant listings
    /// are worth pricing, the eight the provider happened to list first were
    /// not.
    static let pricedSearchResultLimit = SearchRanking.initialDisplayCount

    func searchTicker(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else {
            searchResults = []
            showAllSearchResults = false
            searchQuotes = [:]
            isSearching = false
            isPricingSearch = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let store = self.priceStore else { return }
            do {
                let results = try await store.search(trimmed)
                guard !Task.isCancelled else { return }
                // Ordered before the pricing cut below, so the five symbols
                // that cost a request are the five most relevant rather than
                // the five the provider happened to list first. The count and
                // the routing are unchanged.
                self.searchResults = SearchRanking.rank(results, query: trimmed)
                self.showAllSearchResults = false
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.showAllSearchResults = false
            }
            self.isSearching = false

            // Prices only once typing has settled — this runs after the debounce
            // and after the search itself, never per keystroke.
            guard !Task.isCancelled else { return }
            await self.loadSearchPrices()
        }
    }

    private func loadSearchPrices() async {
        guard let store = priceStore else { return }
        let top = Array(searchResults.prefix(Self.pricedSearchResultLimit))
        guard !top.isEmpty else { return }

        isPricingSearch = true
        let fetched = await store.quotesForSearch(top)
        guard !Task.isCancelled else { isPricingSearch = false; return }
        searchQuotes.merge(fetched) { _, new in new }
        isPricingSearch = false
    }

    /// Nil when there is no price — the caller shows a dash. Never zero.
    /// Scoped to the listing, never to the bare ticker.
    ///
    /// The old signature took a symbol, so all six AAPL rows resolved to one
    /// quote and the Buenos Aires CEDEAR displayed the NASDAQ close as if it
    /// were its own. There is deliberately no fall-back to
    /// `priceStore.quote(for:)` here: that store is keyed by ticker, and
    /// reaching into it is exactly how a foreign venue borrows a US price. A
    /// listing we did not price shows a dash.
    func searchQuote(for result: AssetSearchResult) -> Quote? {
        searchQuotes[result.id]
    }

    func searchFreshness(for result: AssetSearchResult) -> QuoteFreshness? {
        guard searchQuote(for: result) != nil else { return nil }
        return priceStore?.freshness(for: ListingID(symbol: result.symbol, mic: result.mic))
    }

    func clearSearch() {
        searchTask?.cancel()
        searchResults = []
        showAllSearchResults = false
        searchQuotes = [:]
        isSearching = false
        isPricingSearch = false
    }

    // MARK: - FX rate lookup (Frankfurter + SwiftData cache)

    func lookupFXRate(currency: String, on date: Date) async -> FXRate? {
        guard currency != "EUR" else { return FXRate.identity("EUR") }
        guard let ctx = modelContext, let provider = fxProvider else { return nil }

        let adjusted = FrankfurterProvider.adjustToBusinessDay(date)
        let dateStr = FrankfurterProvider.formatDate(adjusted)
        let from = currency
        let to = "EUR"

        // Check cache — historical rates never change
        let descriptor = FetchDescriptor<FXRateCache>(
            predicate: #Predicate { $0.fromCurrency == from && $0.toCurrency == to && $0.dateString == dateStr }
        )
        if let cached = try? ctx.fetch(descriptor).first {
            // Rebuilt from the row's own two currency columns, not from the two
            // local constants: if a row was ever written the wrong way round, it
            // has to come back out the wrong way round and be refused, rather
            // than be relabelled correct on the way past.
            return FXRate(
                from: cached.fromCurrency, to: cached.toCurrency, value: cached.rate
            )
        }

        // Fetch from provider
        do {
            let rate = try await provider.rate(from: currency, to: "EUR", on: adjusted)
            // What came back is checked against what was asked. A provider that
            // answers about another pair is not answering this question.
            guard rate.converts(currency, into: "EUR") else { return nil }
            let entry = FXRateCache(
                fromCurrency: rate.from, toCurrency: rate.to,
                dateString: dateStr, rate: rate.value
            )
            ctx.insert(entry)
            try? ctx.save()
            return rate
        } catch {
            return nil
        }
    }

    // MARK: - Private

    /// The rate that converts this asset's native currency into EUR, or nil when
    /// it is not known.
    ///
    /// Returning 1 as a fallback — which is what this did — silently published a
    /// USD price as if it were euros: a NVDA quote of 223,98 USD became a market
    /// value of 223,98 € against a cost of 137,73 €, and invented a +62 % gain
    /// on a position bought the same day. Nil instead, so the value shows a dash
    /// and stays out of the totals, exactly as a missing price does.
    ///
    /// Direction is deliberately the same as the rate stored on the purchase:
    /// native → EUR, so USD→EUR ≈ 0,86 and the cost and the market value are
    /// converted the same way round.
    private func lookupCurrentFX(for listing: ListingID) -> FXRate? {
        guard let currency = nativeCurrency(for: listing) else { return nil }
        if currency == "EUR" { return FXRate.identity("EUR") }
        // Checked, not trusted, even though this dictionary is filled in by code
        // three lines away: a rate stored under "USD" that converts *out of*
        // euros is not a USD rate, and the whole point of the type is that the
        // last reader is still able to notice.
        guard let rate = currentFXRates[currency] else {
            return nil
        }
        return rate
    }

    /// The currency to convert from: the listing the user chose, ahead of
    /// whatever the provider claims.
    ///
    /// The recorded MIC and currency come from the row the user actually
    /// picked, so they are the fact. A provider's currency field is a report,
    /// and some of them are simply wrong — Finnhub labels everything USD. When a
    /// EUR-quoted ETF gets reported as dollars, a USD→EUR rate is applied to a
    /// euro price and the position loses 13 % that never happened.
    private func nativeCurrency(for listing: ListingID) -> String? {
        if let recorded = priceStore?.listing(for: listing)?.currency, !recorded.isEmpty {
            return recorded
        }
        guard let quote = priceStore?.quote(for: listing), !quote.currency.isEmpty else {
            return nil
        }
        return quote.currency
    }

    /// Latest native→EUR rates for the currencies actually held, fetched once
    /// and cached in `FXRateCache` by day. Frankfurter publishes ECB daily
    /// reference rates, so one per day is the real resolution, not a shortcut.
    func refreshCurrentFXRates() async {
        let currencies = Set(
            holdings.filter(\.isOpen).compactMap { nativeCurrency(for: $0.listing) }
        ).filter { !$0.isEmpty && $0 != "EUR" }

        var changed = false
        for currency in currencies where currentFXRates[currency] == nil {
            guard let rate = await lookupFXRate(currency: currency, on: Date()),
                  // Filed under the currency the rate itself says it converts
                  // out of, not under the one that was asked for. If those ever
                  // disagree the entry does not get written, instead of getting
                  // written under a key that makes it look right.
                  rate.converts(currency, into: "EUR")
            else { continue }
            currentFXRates[currency] = rate
            changed = true
        }
        if changed { loadHoldings() }
    }

    /// Injects a rate without going to the network.
    ///
    /// Takes an `FXRate` rather than a currency and a number, so a test has to
    /// say which way round its rate converts. That is the difference between a
    /// suite where 463 tests are indifferent to the direction and one where
    /// every test that values a foreign position states it.
    func setCurrentFXRateForTesting(_ rate: FXRate) {
        currentFXRates[rate.from] = rate
        loadHoldings()
    }

    private func sortHoldings(_ h: [Holding]) -> [Holding] {
        switch sortMode {
        case .value:
            h.sorted { ($0.marketValueEUR ?? 0) > ($1.marketValueEUR ?? 0) }
        case .plPercent:
            h.sorted { ($0.unrealizedPLPercent ?? 0) > ($1.unrealizedPLPercent ?? 0) }
        case .alphabetical:
            h.sorted { $0.listing < $1.listing }
        }
    }
}
