import Foundation
import SwiftData
import Observation
import os.log

@MainActor
@Observable
final class PriceStore {
    private static let log = Logger(subsystem: "pt.patrimonial", category: "polling")

    /// Keyed by `ListingID.storageKey`, not by ticker.
    ///
    /// The dictionary that was the bug. `quotes["NVD"]` had room for one price
    /// and two instruments wanted it, so whichever provider answered last owned
    /// the row — and both a XETRA position and a NASDAQ one read it.
    private(set) var quotes: [String: Quote] = [:]
    private(set) var revision: UInt64 = 0
    private(set) var isLoading = false
    private(set) var lastError: MarketDataError?

    private var stockProvider: any MarketDataProvider
    private var fallbackStockProvider: any MarketDataProvider
    private var cryptoProvider: any MarketDataProvider
    /// Third fallback, European listings only. Nil when no Alpha Vantage key is
    /// configured, in which case Euronext and XETRA positions keep showing a
    /// dash rather than a wrong number.
    private var europeanProvider: (any MarketDataProvider)?
    /// Fourth and last fallback, for the venues the other three do not reach at
    /// all. Undocumented and unsupported, so it is asked last and its failures
    /// are silent: if it breaks, only the exotic venues lose their price.
    private var lastResortProvider: (any MarketDataProvider)?
    /// The equity half of `search`. Injectable — not because the app ever
    /// swaps it, but because the combined list is what the user reads, and a
    /// test that cannot supply both halves can only check the ranking of rows
    /// it built by hand rather than the rows the screen actually shows.
    private var equitySearchProvider: any SymbolSearchProvider = TwelveDataSearchProvider()

    /// True when quotes are coming from a mock instead of a live provider. The
    /// UI must say so — looking at simulated prices without knowing is worse
    /// than seeing no prices at all.
    private(set) var isUsingMockData = true
    private let rateLimiter = RateLimiter(maxTokens: 60, refillInterval: 60)
    private var pollingTask: Task<Void, Never>?
    private var debounceTimers: [String: Date] = [:]
    private var modelContext: ModelContext?

    // CoinGecko ID mapping: ticker → coingecko ID
    private var coinIDMap: [String: String] = [:]
    private var coinIDMapLastRefresh: Date?

    /// The venue and currency of the listing the user actually bought, keyed by
    /// the symbol their position is held under.
    ///
    /// Held positions carry a bare ticker — `QDVE`, not `QDVE.DE` — because that
    /// is what the search returned and what the transaction stores. Routing them
    /// by symbol suffix, which is what `MarketCalendar.isEuropean` does, calls
    /// every one of them NYSE/USD: the Alpha Vantage fallback was never reached
    /// for a XETRA position, and the currency was assumed to be dollars. The MIC
    /// is recorded on the `Asset` at purchase, and this is it.
    struct Listing: Sendable {
        let id: ListingID
        let currency: String
        var mic: String? { id.mic }
    }
    private var listings: [String: Listing] = [:]
    private var assetClasses: [String: AssetClass] = [:]

    /// Records what a listing trades in. The venue is already in the key, so
    /// there is nothing here that can disagree with it.
    ///
    /// A currency is still required — a listing with no currency cannot be
    /// converted and would invite the rate of whatever the provider guessed —
    /// but a venue is **not**. A venueless listing registers under the bare
    /// symbol and keeps the routing it has always had.
    func register(_ id: ListingID, currency: String) {
        guard !currency.isEmpty else { return }
        listings[id.storageKey] = Listing(id: id, currency: currency)
    }

    func listing(for id: ListingID) -> Listing? { listings[id.storageKey] }

    /// The venue of a held listing: the recorded MIC first, the ticker suffix
    /// only as a fallback for positions bought before the MIC was stored.
    private func exchange(for id: ListingID) -> MarketCalendar.Exchange? {
        if let mic = id.mic, let resolved = MarketCalendar.exchangeForMIC(mic) {
            return resolved
        }
        // `exchangeForSymbol` treats an unsuffixed ticker as NYSE, which is a
        // guess, not a reading. Only trust it when there is a suffix to read.
        return id.symbol.contains(".") ? MarketCalendar.exchangeForSymbol(id.symbol) : nil
    }

    /// The session the *stored quote* belongs to, which for an end-of-day price
    /// is not the session running now.
    ///
    /// Held on this type because this is where the venue is known. `Holding`
    /// carries a bare ticker, and the header's day change has to know which
    /// session the price comes from — on a Saturday that is Friday's, not the
    /// calendar day's.
    ///
    /// This is the second half of the same lesson. Reading the boundary off the
    /// clock fixed the weekend case, where the price is Friday's close and the
    /// clock says Saturday. It does not fix the Alpha Vantage case, where the
    /// clock says Monday 15:00, XETRA is open, and the price on hand is still
    /// Friday's close because the free plan has nothing newer: a purchase made
    /// this morning falls inside Monday's session by the clock and gets measured
    /// against Thursday's close, which is two sessions it never lived through.
    ///
    /// So the anchor is the quote, not the clock. With a `.dailyClose` quote the
    /// window is the session that close came from, closed at both ends; with any
    /// live source it is the session in progress, open-ended.
    func sessionWindow(for id: ListingID, at date: Date = Date()) -> MarketCalendar.SessionWindow {
        if shouldRouteToCrypto(id) {
            return .open(from: MarketCalendar.currentSessionStart(.crypto, at: date))
        }
        guard let exchange = exchange(for: id) else {
            // An unrecorded venue falls back to the widest boundary rather than
            // to NYSE: guessing a venue here is the same guess `exchange(for:)`
            // already refuses to make, and the widest boundary can only
            // understate. Open-ended for the same reason — a closed window
            // silences lots, and silencing them on a guess is the larger error.
            return .open(from: MarketCalendar.widestSessionStart(at: date))
        }
        if let quote = quotes[id.storageKey],
           quote.source == .dailyClose,
           let closeDate = quote.closeDate {
            return MarketCalendar.sessionWindow(exchange, endingOn: closeDate)
        }
        return .open(from: MarketCalendar.currentSessionStart(exchange, at: date))
    }

    /// Whether the US-only providers may be asked about this symbol at all.
    ///
    /// Twelve Data's free plan and Finnhub take a bare ticker and answer about
    /// the listing *they* consider canonical. For `NVD` that is a 2x inverse
    /// ETF on NASDAQ at 3,97 USD; the position was NVIDIA on XETRA at 194,22
    /// EUR. Neither provider was malfunctioning — they answered correctly to
    /// the wrong question, because the question could not carry a venue.
    ///
    /// So the venue has to be checked before asking, not after: a recorded MIC
    /// outside the US means these two are simply not sources for this symbol,
    /// and the request goes straight to the ones routed by venue. Asking anyway
    /// and filtering the reply would still work for Twelve Data, which reports
    /// its MIC, but not for Finnhub, which reports nothing at all — and Finnhub
    /// returns the same 3,97.
    ///
    /// No recorded MIC means no basis to refuse. Those symbols keep the old
    /// behaviour and rely on `answersAboutRecordedListing` instead, which is
    /// weaker but is all there is until the venue becomes part of the stored
    /// identity rather than only of the routing.
    private func mayAskUSProviders(_ id: ListingID) -> Bool {
        guard let mic = id.mic else { return true }
        return MarketCalendar.isUnitedStatesMIC(mic)
    }

    /// Whether a reply is about the listing that was asked about.
    ///
    /// The second line of defence, for providers that do report a venue. A
    /// quote whose MIC contradicts the recorded one is not a stale price or a
    /// bad price — it is a different instrument, and must not be published, not
    /// counted as coverage, and not allowed to stop the venue-routed providers
    /// from being tried.
    ///
    /// True when either side is unknown: this can only reject a contradiction
    /// it can actually see, and silence is not consent — `mayAskUSProviders` is
    /// what covers the silent providers.
    private func answersAboutRecordedListing(_ quote: Quote, heldAs id: ListingID) -> Bool {
        guard let reported = quote.venueMIC, !reported.isEmpty,
              let recorded = id.mic
        else { return true }
        return MarketCalendar.venuesAgree(reported, recorded)
    }

    /// Whether the reply may have the recorded currency imposed on it.
    ///
    /// Ponto E. The venue check above can only reject what it can see, and a
    /// listing with no recorded MIC gives it nothing to compare — every
    /// venueless position passes it. `rekeyed` then stamps the recorded currency
    /// onto whatever came back, which is the *amplifier* ordering: a dollar
    /// price relabelled as euros, converted at a rate of 1, arriving on screen
    /// with the composure of a checked number. It is how NVD's 3,97 USD became
    /// 3,97 EUR, and the MIC was the only thing that stopped it happening again.
    ///
    /// A disagreeing currency is the same evidence as a disagreeing MIC, only
    /// coarser: EUR and USD cannot both be right about one listing. So it is
    /// treated the same way — the reply is refused, the position keeps its dash,
    /// and the venue-routed providers are still allowed to answer. The one case
    /// where the recorded currency legitimately overrides the provider's is when
    /// the venue has been *confirmed*: there the currency label is the
    /// unreliable field (Finnhub used to stamp everything USD) and the venue is
    /// the fact.
    ///
    /// Silence is not a contradiction: a provider that reports no currency, or a
    /// listing recorded without one, leaves nothing to disagree about.
    private func currencyAgreesWithRecordedListing(
        _ quote: Quote, heldAs id: ListingID
    ) -> Bool {
        guard let recorded = listings[id.storageKey]?.currency, !recorded.isEmpty,
              !quote.currency.isEmpty,
              quote.currency.caseInsensitiveCompare(recorded) != .orderedSame
        else { return true }
        // Venue confirmed: keep the recorded currency over the provider's label.
        if let reported = quote.venueMIC, !reported.isEmpty, let mic = id.mic {
            return MarketCalendar.venuesAgree(reported, mic)
        }
        return false
    }

    /// Both checks, so no call site can remember one and forget the other.
    private func isAboutTheRecordedListing(_ quote: Quote, heldAs id: ListingID) -> Bool {
        answersAboutRecordedListing(quote, heldAs: id)
            && currencyAgreesWithRecordedListing(quote, heldAs: id)
    }

    /// The same quote filed under the symbol the position is held as, keeping
    /// the venue's currency rather than the provider's guess.
    ///
    /// Applied on **every** path now, not only the European and Yahoo ones. It
    /// used to be skipped on the primary and fallback paths, which is where the
    /// invented currencies actually come from — Finnhub used to stamp every
    /// quote USD — so the correction was absent from the two routes that needed
    /// it and present on the two that did not.
    ///
    /// The ordering matters and is easy to get backwards: the recorded currency
    /// may only be imposed on a price *after* that price has been confirmed to
    /// come from the recorded venue. Reversed, it is not a safeguard but an
    /// amplifier — that is precisely what turned NVD's 3,97 USD into 3,97 EUR,
    /// giving a foreign instrument's price the euro label of a listing it never
    /// came from, and with it an FX rate of 1 and a −97,96 % that read as fact.
    /// A wrong number that has passed through a validation step is worse than a
    /// wrong number, because it has stopped looking like one.
    private func rekeyed(_ quote: Quote, to id: ListingID) -> Quote {
        Quote(
            symbol: id.symbol,
            price: quote.price,
            previousClose: quote.previousClose,
            changeAbsolute: quote.changeAbsolute,
            changePercent: quote.changePercent,
            currency: listings[id.storageKey]?.currency ?? quote.currency,
            timestamp: quote.timestamp,
            source: quote.source,
            closeDate: quote.closeDate,
            // Kept, not dropped. It was being lost here, so the stored quote no
            // longer remembered which venue had answered and nothing downstream
            // could re-check the currency it had just been stamped with.
            venueMIC: quote.venueMIC
        )
    }

    // MARK: - Plausibility against the symbol's own history

    /// The most recent close known for a symbol from its own price history, in
    /// the listing's native currency. Injected rather than reached for: this
    /// type must not depend on `CandleStore`, and a store with no history wired
    /// in simply has no second opinion and publishes as before.
    var referenceClose: ((ListingID) -> Decimal?)?

    /// A published price and the history that contradicts it.
    struct Discrepancy: Equatable, Sendable {
        let refused: Decimal
        let reference: Decimal
    }
    private(set) var discrepancies: [String: Discrepancy] = [:]

    func discrepancy(for id: ListingID) -> Discrepancy? { discrepancies[id.storageKey] }

    /// More than one order of magnitude. A position does not fall 97 % between
    /// two sessions; a ticker resolving to a different instrument does exactly
    /// that.
    static let implausibleRatio: Decimal = 10

    /// Whether a price is consistent with what this symbol has been trading at.
    ///
    /// The second layer of the identity defence, for the providers that cannot
    /// be checked by venue because they report none. Finnhub answers `3.97` for
    /// `NVD` with nothing at all to say which NVD it means; the cached history
    /// for that symbol is around 190, and the ratio settles it.
    ///
    /// **Splits.** A split moves the price and the series together, so the
    /// steady state is unaffected. The exposure is one narrow window: a split
    /// larger than 10:1 whose quote arrives before the candle refresh has caught
    /// up. There the price is refused and the position shows a dash until the
    /// history moves, which is the correct direction to fail — a dash that heals
    /// itself, not a wrong number that persists. A 10:1 split lands exactly on
    /// the ratio and passes, since the test is strictly greater.
    private func isPlausible(_ quote: Quote, as id: ListingID) -> Bool {
        guard let reference = referenceClose?(id), reference > 0,
              quote.price > 0
        else { return true }

        let implausible = quote.price > reference * Self.implausibleRatio
            || quote.price * Self.implausibleRatio < reference
        return !implausible
    }

    private let debounceInterval: TimeInterval = 1.0

    /// `provider` defaults to nil rather than to `MockMarketDataProvider()`:
    /// default arguments are evaluated in a nonisolated context, so building the
    /// mock there crossed the @MainActor boundary. Building it in the body keeps
    /// it on the actor.
    init(
        provider: (any MarketDataProvider)? = nil,
        fallbackProvider: (any MarketDataProvider)? = nil,
        cryptoProvider: (any MarketDataProvider)? = nil
    ) {
        let base = provider ?? MockMarketDataProvider()
        self.stockProvider = base
        self.fallbackStockProvider = fallbackProvider ?? base
        self.cryptoProvider = cryptoProvider ?? base
        self.isUsingMockData = provider == nil
    }

    func configure(
        provider: any MarketDataProvider,
        fallbackProvider: (any MarketDataProvider)? = nil,
        cryptoProvider: (any MarketDataProvider)? = nil,
        europeanProvider: (any MarketDataProvider)? = nil,
        lastResortProvider: (any MarketDataProvider)? = nil,
        equitySearchProvider: (any SymbolSearchProvider)? = nil,
        modelContext: ModelContext
    ) {
        self.stockProvider = provider
        self.fallbackStockProvider = fallbackProvider ?? provider
        self.cryptoProvider = cryptoProvider ?? CoinGeckoProvider()
        if let equitySearchProvider { self.equitySearchProvider = equitySearchProvider }
        self.europeanProvider = europeanProvider
        self.lastResortProvider = lastResortProvider
        self.modelContext = modelContext
        self.isUsingMockData = provider is MockMarketDataProvider
    }

    /// Wires the real providers, or leaves the mock in place when keys are
    /// missing — and reports which happened so the UI can say so.
    ///
    /// When a proxy URL is configured the proxy is the primary and fallback
    /// provider: API keys live server-side and the proxy caches popular symbols,
    /// so the client never needs TwelveData or Finnhub keys at all. CoinGecko
    /// stays local because the proxy does not cover crypto yet, and Yahoo stays
    /// as the last resort for venues the proxy cannot reach.
    func configureLive(modelContext: ModelContext) {
        if AppConfig.hasProxy {
            let proxy = ProxyMarketDataProvider(baseURL: AppConfig.proxyURL)
            configure(
                provider: proxy,
                fallbackProvider: proxy,
                cryptoProvider: CoinGeckoProvider(),
                europeanProvider: proxy,
                lastResortProvider: YahooChartProvider(),
                modelContext: modelContext
            )
            return
        }
        guard AppConfig.hasTwelveDataKey || AppConfig.hasFinnhubKey || AppConfig.hasAlphaVantageKey else {
            self.modelContext = modelContext
            self.isUsingMockData = true
            return
        }
        configure(
            provider: TwelveDataProvider(),
            fallbackProvider: FinnhubProvider(),
            cryptoProvider: CoinGeckoProvider(),
            europeanProvider: AppConfig.hasAlphaVantageKey ? AlphaVantageProvider() : nil,
            lastResortProvider: YahooChartProvider(),
            modelContext: modelContext
        )
    }

    // MARK: - Hydration from cache

    func hydrateFromCache() {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<PriceSnapshot>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let snapshots = try? ctx.fetch(descriptor) else { return }

        // Zero-priced snapshots are deleted, not merely skipped.
        //
        // Finnhub used to answer 200 with `{"c":0,…}` for symbols outside its
        // plan and that got persisted as a real price. The provider no longer
        // produces them, but the rows it already wrote outlive the fix: a
        // 0,00 USD snapshot for QDVE keeps hydrating on every launch, and
        // because nothing ever replaces it the position reads 0,00 € and
        // −100 % forever. Purging is the only thing that ends it, and no
        // information is lost — a zero was never a price.
        // Listings first, deliberately. The second purge below compares each
        // snapshot against the venue its position is recorded on, and this is
        // what loads those — running it afterwards, as it used to, left nothing
        // to compare against.
        hydrateListings(ctx)

        var poisoned: [PriceSnapshot] = []
        for snapshot in snapshots {
            guard snapshot.price > 0 else {
                poisoned.append(snapshot)
                continue
            }
            // A price in a currency the recorded venue does not trade in was
            // never a price for this position.
            //
            // The zero purge above catches a value that is obviously not a
            // price. This catches one that looks perfectly ordinary and belongs
            // to another instrument: NVD was cached at 3,97 **USD** from a
            // NASDAQ ETF while the position is XETRA, in EUR. There is no way to
            // tell that from the number — 3,97 is a plausible price — but the
            // currency contradiction is structural and unambiguous.
            //
            // This is cleanup of what an older build wrote, not a standing
            // defence: quotes are now rejected on venue before they are applied,
            // and `rekeyed` stamps the recorded currency before anything is
            // persisted, so a contradicting row can no longer be created. It
            // stays because the rows already on disk outlive the fix — the same
            // reason the zero purge had to exist at all.
            let listing = snapshot.listing
            if let recorded = listings[listing.storageKey]?.currency,
               !recorded.isEmpty, !snapshot.currency.isEmpty,
               snapshot.currency != recorded {
                poisoned.append(snapshot)
                continue
            }
            if quotes[listing.storageKey] == nil {
                quotes[listing.storageKey] = snapshot.toQuote()
            }
        }
        if !poisoned.isEmpty {
            for snapshot in poisoned { ctx.delete(snapshot) }
            try? ctx.save()
        }

        hydrateCoinIDMap()
    }

    /// `Asset.exchange` already holds the MIC of the listing that was picked —
    /// `upsertAsset` refuses to write the row without one — so the routing
    /// information has been on disk all along. Nothing was reading it.
    private func hydrateListings(_ ctx: ModelContext) {
        guard let assets = try? ctx.fetch(FetchDescriptor<Asset>()) else { return }
        for asset in assets {
            register(asset.listing, currency: asset.currency)
            assetClasses[asset.listing.storageKey] = asset.assetClass
        }
    }

    // MARK: - Single quote

    func quote(for id: ListingID) -> Quote? {
        quotes[id.storageKey]
    }

    // MARK: - Routing: crypto vs stock

    func isCrypto(_ symbol: String) -> Bool {
        coinIDMap[symbol.lowercased()] != nil
    }

    func coinGeckoID(for symbol: String) -> String? {
        coinIDMap[symbol.lowercased()]
    }

    func registerCoinID(symbol: String, coinID: String) {
        coinIDMap[symbol.lowercased()] = coinID
        persistCoinID(symbol: symbol.lowercased(), coinID: coinID, name: symbol)
    }

    func registerAssetClass(_ id: ListingID, _ assetClass: AssetClass) {
        assetClasses[id.storageKey] = assetClass
    }

    /// Whether the routing should send this listing to CoinGecko.
    ///
    /// Two barriers, either sufficient alone:
    /// 1. A MIC that `exchangeForMIC` recognises is a stock exchange — never crypto.
    /// 2. An `AssetClass` from the `Asset` table that is not `.crypto` — the user
    ///    bought it as a stock/ETF/bond, so it stays on the stock providers.
    ///
    /// Only when neither barrier fires AND the symbol is in `coinIDMap` does the
    /// listing go to CoinGecko. This stops SOL-on-NYSE from being priced as
    /// Solana while leaving genuine crypto unaffected.
    func shouldRouteToCrypto(_ listing: ListingID) -> Bool {
        if let mic = listing.mic, MarketCalendar.exchangeForMIC(mic) != nil {
            return false
        }
        if let cls = assetClasses[listing.storageKey], cls != .crypto {
            return false
        }
        return coinIDMap[listing.symbol.lowercased()] != nil
    }

    // MARK: - Fetch with routing

    func refresh(_ requested: [ListingID]) async {
        guard !requested.isEmpty else { return }
        isLoading = true
        lastError = nil

        await ensureCoinIDMap()

        var stockListings: [ListingID] = []
        var cryptoIDs: [String] = []
        var cryptoIDToListing: [String: ListingID] = [:]

        for listing in requested {
            if shouldRouteToCrypto(listing),
               let coinID = coinIDMap[listing.symbol.lowercased()] {
                cryptoIDs.append(coinID)
                cryptoIDToListing[coinID] = listing
            } else {
                let exch = exchange(for: listing)
                if let exch, !MarketCalendar.isOpen(exch),
                   quotes[listing.storageKey] != nil {
                    Self.log.info("skip \(listing.symbol, privacy: .public): \(exch.rawValue, privacy: .public) closed, cached")
                    continue
                }
                stockListings.append(listing)
            }
        }

        // Equities: Twelve Data first, Finnhub for whatever it could not serve.
        // Twelve Data's free plan covers US listings only, so European symbols
        // come back refused while US ones succeed in the same batch — the
        // fallback is per symbol, not all-or-nothing.
        if !stockListings.isEmpty {
            var covered: Set<ListingID> = []
            var primaryError: Error?

            // Only the symbols these two can honestly answer about. A XETRA
            // position is not "missing" from them — it was never theirs, and
            // asking is what produced a NASDAQ price wearing a XETRA position's
            // name.
            //
            // The ticker is what goes on the wire — these two take nothing else
            // — but a reply now has to be *placed*, because two listings can
            // share one ticker and one request. `deliverUS` is where that
            // placement happens, and it is the only thing standing between a
            // NASDAQ reply and a NYSE position.
            var usTargets: [String: [ListingID]] = [:]
            var usOrder: [String] = []
            for listing in stockListings where mayAskUSProviders(listing) {
                if usTargets[listing.symbol] == nil { usOrder.append(listing.symbol) }
                usTargets[listing.symbol, default: []].append(listing)
            }

            /// Files a reply under every listing it can honestly be about, and
            /// reports whether it was about any of them at all. A reply nobody
            /// claims must not count as coverage, or it silences the providers
            /// that would have answered correctly.
            func deliverUS(_ q: Quote) -> Bool {
                var placed = false
                for target in usTargets[q.symbol] ?? [] {
                    guard isAboutTheRecordedListing(q, heldAs: target) else { continue }
                    applyQuote(rekeyed(q, to: target), as: target)
                    covered.insert(target)
                    placed = true
                }
                return placed
            }

            if !usOrder.isEmpty {
                do {
                    let fetched = try await stockProvider.quotes(for: usOrder)
                    for q in fetched { _ = deliverUS(q) }
                } catch {
                    primaryError = error
                }

                let missing = usOrder.filter { ticker in
                    (usTargets[ticker] ?? []).contains { !covered.contains($0) }
                }
                if !missing.isEmpty {
                    do {
                        let fetched = try await fallbackStockProvider.quotes(for: missing)
                        for q in fetched { _ = deliverUS(q) }
                    } catch {
                        if primaryError == nil { primaryError = error }
                    }
                }
            }

            // Third fallback: Alpha Vantage, European listings only. Neither of
            // the two above covers Euronext or XETRA on a free plan, so without
            // this every Lisbon and Amsterdam position stays blank.
            //
            // It is end-of-day data on a 25-a-day budget shared with Step 7's
            // charts, so the provider itself rations it to one call per symbol
            // per day and simply omits what it will not spend on. A refusal is
            // the expected steady state, not a failure.
            //
            // The symbol sent is the provider's, the symbol stored is the
            // user's: Alpha Vantage answers about `QDVE.DE`, the position is
            // held as `QDVE`, and filing the reply under the wrong one leaves
            // the position looking unpriced next to a quote nothing reads.
            // Ordered, not a dictionary's arbitrary order: the request list is
            // sent to a provider on a 25-a-day budget, and which symbols get
            // served when it runs out must follow the caller's order rather
            // than change run to run.
            var europeanOrder: [String] = []
            var europeanTargets: [String: [ListingID]] = [:]  // AV symbol → listings
            for listing in stockListings where !covered.contains(listing) {
                guard let exchange = self.exchange(for: listing), exchange.isEuropean,
                      let suffix = exchange.alphaVantageSuffix
                else { continue }
                let avSymbol = listing.symbol.hasSuffix(suffix)
                    ? listing.symbol : listing.symbol + suffix
                if europeanTargets[avSymbol] == nil { europeanOrder.append(avSymbol) }
                europeanTargets[avSymbol, default: []].append(listing)
            }
            if !europeanOrder.isEmpty, let europeanProvider {
                if let fetched = try? await europeanProvider.quotes(for: europeanOrder) {
                    for q in fetched {
                        for target in europeanTargets[q.symbol] ?? [] {
                            applyQuote(rekeyed(q, to: target), as: target)
                            covered.insert(target)
                        }
                    }
                }
            }

            // Fourth and last: Yahoo, for whatever the three above left behind.
            // Frankfurt, Munich, Düsseldorf, Hamburg, Buenos Aires, Mexico City
            // and Toronto reach nothing else, and Alpha Vantage's daily budget
            // can leave a XETRA position unserved too.
            //
            // Reached only through the MIC table, so a position with no
            // recorded venue is never guessed at, and every failure is silent —
            // `lastError` is not touched on this path.
            var lastResortOrder: [String] = []
            var lastResortTargets: [String: [ListingID]] = [:]
            for listing in stockListings where !covered.contains(listing) {
                guard let mic = listing.mic,
                      let yahooSymbol = MarketCalendar.yahooSymbol(listing.symbol, mic: mic)
                else { continue }
                if lastResortTargets[yahooSymbol] == nil { lastResortOrder.append(yahooSymbol) }
                lastResortTargets[yahooSymbol, default: []].append(listing)
            }
            if !lastResortOrder.isEmpty, let lastResortProvider {
                if let fetched = try? await lastResortProvider.quotes(for: lastResortOrder) {
                    for q in fetched {
                        for target in lastResortTargets[q.symbol] ?? [] {
                            applyQuote(rekeyed(q, to: target), as: target)
                            covered.insert(target)
                        }
                    }
                }
            }

            // A symbol we could not refresh but which still has a price on
            // screen is not an error. The budget running out, or a symbol
            // already fetched today, must serve the cached close quietly rather
            // than paint the screen red.
            let stillMissing = stockListings.filter {
                !covered.contains($0) && quotes[$0.storageKey] == nil
            }
            if stillMissing.isEmpty {
                lastError = nil
            } else if let primaryError {
                lastError = (primaryError as? MarketDataError) ?? .noData
            } else {
                lastError = .noData
            }
        }

        // Fetch crypto via CoinGecko — unless a search is waiting on it.
        if !cryptoIDs.isEmpty, !cryptoSearchInFlight {
            do {
                let fetched = try await cryptoProvider.quotes(for: cryptoIDs)
                for q in fetched {
                    // Map coinID back to the listing that asked for it
                    if let target = cryptoIDToListing[q.symbol] {
                        let mapped = Quote(
                            symbol: target.symbol,
                            price: q.price,
                            previousClose: q.previousClose,
                            changeAbsolute: q.changeAbsolute,
                            changePercent: q.changePercent,
                            currency: q.currency,
                            timestamp: q.timestamp,
                            source: q.source
                        )
                        applyQuote(mapped, as: target)
                    } else {
                        applyQuote(q, as: ListingID(symbol: q.symbol))
                    }
                }
            } catch let error as MarketDataError {
                lastError = error
            } catch {}
        }

        isLoading = false
    }

    func refreshSingle(_ id: ListingID) async {
        let symbol = id.symbol
        if let coinID = coinIDMap[symbol.lowercased()] {
            do {
                let q = try await cryptoProvider.quote(for: coinID)
                let mapped = Quote(
                    symbol: symbol,
                    price: q.price,
                    previousClose: q.previousClose,
                    changeAbsolute: q.changeAbsolute,
                    changePercent: q.changePercent,
                    currency: q.currency,
                    timestamp: q.timestamp,
                    source: q.source
                )
                applyQuote(mapped, as: id)
            } catch {}
        } else {
            // Same venue rules as the batch path. This path used to ask the US
            // providers unconditionally, so a XETRA symbol refreshed on its own
            // took the wrong instrument's price even after the batch path was
            // fixed.
            var served = false
            if mayAskUSProviders(id) {
                if let q = try? await stockProvider.quote(for: symbol),
                   isAboutTheRecordedListing(q, heldAs: id) {
                    applyQuote(rekeyed(q, to: id), as: id)
                    served = true
                } else if let q = try? await fallbackStockProvider.quote(for: symbol),
                          isAboutTheRecordedListing(q, heldAs: id) {
                    applyQuote(rekeyed(q, to: id), as: id)
                    served = true
                }
            }
            if !served, let exchange = self.exchange(for: id), exchange.isEuropean,
               let suffix = exchange.alphaVantageSuffix, let europeanProvider {
                let avSymbol = symbol.hasSuffix(suffix) ? symbol : symbol + suffix
                if let q = try? await europeanProvider.quote(for: avSymbol) {
                    applyQuote(rekeyed(q, to: id), as: id)
                    served = true
                }
            }
            if !served, let mic = id.mic,
               let yahooSymbol = MarketCalendar.yahooSymbol(symbol, mic: mic),
               let lastResortProvider {
                if let q = try? await lastResortProvider.quote(for: yahooSymbol) {
                    applyQuote(rekeyed(q, to: id), as: id)
                }
            }
        }
    }

    // MARK: - Polling

    func startPolling(listings pollFor: [ListingID]) {
        stopPolling()
        guard !pollFor.isEmpty else { return }

        let symbols = pollFor.map(\.symbol).joined(separator: ", ")
        Self.log.info("polling start: \(symbols, privacy: .public)")

        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(pollFor)

            while !Task.isCancelled {
                let interval = self.pollingInterval(for: pollFor)
                Self.log.info("polling sleep \(Int(interval))s — \(symbols, privacy: .public)")
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                Self.log.info("polling tick")
                await self.refresh(pollFor)
            }
            Self.log.info("polling loop ended")
        }
    }

    func stopPolling() {
        if pollingTask != nil { Self.log.info("polling stop") }
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Apply quote with "most recent wins" + debounce

    func applyQuote(_ quote: Quote, as id: ListingID) {
        let age = Int(-quote.timestamp.timeIntervalSinceNow)
        Self.log.info("quote \(id.symbol, privacy: .public) \(quote.price) age=\(age)s src=\(String(describing: quote.source), privacy: .public)")
        guard quote.price > 0 else { return }

        // The same chokepoint, for the same reason: what does not enter never
        // has to be purged. A price two orders of magnitude away from what this
        // symbol has been trading at is not a crash, it is another instrument,
        // and letting it through would write it to the SwiftData cache where it
        // would outlive the session exactly as NVD's 3,97 did.
        guard isPlausible(quote, as: id) else {
            if let reference = referenceClose?(id), reference > 0 {
                discrepancies[id.storageKey] = Discrepancy(
                    refused: quote.price, reference: reference
                )
                // Bumped so the screen can put the dash and the reason up
                // together — a refusal that nothing observes is a silent
                // failure, which is the thing this whole line of work exists to
                // stop.
                revision &+= 1
            }
            return
        }
        discrepancies.removeValue(forKey: id.storageKey)

        if quote.source == .websocket && shouldDebounce(id.storageKey) { return }

        if let existing = quotes[id.storageKey] {
            if quote.timestamp <= existing.timestamp && existing.source != .cache {
                return
            }
        }

        quotes[id.storageKey] = quote
        // Bumped so views can reload derived values when prices land. Observing
        // `quotes` alone is not enough: replacing a value leaves the count
        // unchanged.
        revision &+= 1
        if quote.source == .websocket {
            debounceTimers[id.storageKey] = Date()
        }
        persistToCache(quote, as: id)
    }

    /// Freshness for a symbol, routed through the market calendar.
    ///
    /// `Quote.freshness` on its own knows nothing about opening hours, so a
    /// price fetched more than a minute ago read as "desatualizado" (red) at
    /// midnight with the NYSE long shut — when the honest label is "mercado
    /// fechado" (grey). The calendar is what knows the difference, and crypto is
    /// routed to its own always-open exchange rather than defaulting to NYSE.
    func freshness(for id: ListingID) -> QuoteFreshness {
        guard let quote = quotes[id.storageKey] else { return .unknown }
        // The recorded venue first. `exchangeForSymbol` answers NYSE for any
        // ticker without a suffix, which is every held position, so a XETRA
        // holding was being timed against New York's opening hours.
        let exchange: MarketCalendar.Exchange = shouldRouteToCrypto(id)
            ? .crypto
            : (self.exchange(for: id) ?? MarketCalendar.exchangeForSymbol(id.symbol))
        return MarketCalendar.freshness(
            for: exchange,
            quoteTimestamp: quote.timestamp,
            source: quote.source,
            closeDate: quote.closeDate
        )
    }

    /// Forgets every symbol at once, for a full data reset.
    ///
    /// The counterpart to wiping the stored rows: quotes, listings and refusal
    /// marks live only here, and a reset that clears SwiftData while leaving
    /// this dictionary populated puts the old prices straight back into the
    /// cache on the next poll — the ghost data a reset is supposed to remove.
    ///
    /// Configuration is deliberately kept: the providers, the model context and
    /// `isUsingMockData` describe how the app is wired, not what the user
    /// entered, and re-deriving them would leave the store unable to fetch
    /// anything until the next launch.
    func reset() {
        stopPolling()
        quotes.removeAll()
        listings.removeAll()
        discrepancies.removeAll()
        debounceTimers.removeAll()
        // Downloaded, not entered — but it is keyed by ticker and a reset should
        // leave nothing keyed by a ticker the user no longer holds. It refetches
        // on demand.
        coinIDMap.removeAll()
        assetClasses.removeAll()
        coinIDMapLastRefresh = nil
        lastError = nil
        revision &+= 1
    }

    /// Drops a symbol's price after its position is deleted. Without this the
    /// quote survives in memory until the app is killed, and the next poll or
    /// re-add would find a price for a ticker that no longer exists.
    func forget(listing id: ListingID) {
        quotes.removeValue(forKey: id.storageKey)
        debounceTimers.removeValue(forKey: id.storageKey)
        discrepancies.removeValue(forKey: id.storageKey)
        revision &+= 1
    }

    // MARK: - Search (combined: stocks + crypto)

    /// Equities come from Twelve Data because it is the only free search that
    /// reports each listing's currency and MIC. Finnhub's search is kept as a
    /// fallback for when that call fails, even though its results are
    /// currency-blind.
    /// True while a crypto search is waiting on CoinGecko.
    ///
    /// CoinGecko's free tier is rate-limited per IP, and search and polling
    /// spend the same allowance: `/search` competes with the `/simple/price`
    /// call the 15-second crypto cadence makes, plus `market_chart` for any
    /// open chart. When the allowance runs out CoinGecko answers 429, and the
    /// search — the one thing a user is sitting there waiting for — comes back
    /// empty while the polling that nobody is watching keeps its slot.
    ///
    /// So the refresh yields. A quote that is fifteen seconds late is
    /// invisible; a search that returns nothing looks like the coin does not
    /// exist. The flag is only ever set around the search call, so the crypto
    /// cadence resumes on the very next tick.
    private(set) var cryptoSearchInFlight = false

    func search(_ query: String) async throws -> [AssetSearchResult] {
        async let equityResults = equitySearchProvider.search(query)
        cryptoSearchInFlight = true
        defer { cryptoSearchInFlight = false }
        async let cryptoResults = cryptoProvider.search(query)

        var combined: [AssetSearchResult] = []
        do {
            let equities = try await equityResults
            Self.log.info("search equity: \(equities.count) results")
            combined.append(contentsOf: equities)
        } catch {
            Self.log.error("search equity failed: \(error.localizedDescription, privacy: .public)")
            if let fallback = try? await stockProvider.search(query) {
                combined.append(contentsOf: fallback)
            }
        }
        do {
            let crypto = try await cryptoResults
            Self.log.info("search crypto: \(crypto.count) results")
            combined.append(contentsOf: crypto)
        } catch let error as MarketDataError {
            // Named, not just described. `localizedDescription` on a 429 and on
            // a decoding failure read much alike in the console, and those are
            // opposite diagnoses: one is the budget, the other is the payload.
            switch error {
            case .rateLimited:
                Self.log.error("search crypto failed: CoinGecko rate-limited (429)")
            case .httpError(let code):
                Self.log.error("search crypto failed: HTTP \(code, privacy: .public)")
            case .decodingFailed(let underlying):
                Self.log.error("search crypto failed: decoding — \(String(describing: underlying), privacy: .public)")
            default:
                Self.log.error("search crypto failed: \(String(describing: error), privacy: .public)")
            }
        } catch {
            Self.log.error("search crypto failed: \(error.localizedDescription, privacy: .public)")
        }

        return combined
    }

    // MARK: - Search prices

    /// Prices for a handful of search results, so the user can see what they are
    /// picking before they commit to it.
    ///
    /// Deliberately does **not** go through `refresh`: a failure here is a blank
    /// price on a search row, not a portfolio error, and it must never set
    /// `lastError` or the loading flag that the portfolio header reads.
    ///
    /// Budget discipline is unchanged — the same providers, the same limits. A
    /// European symbol still costs one Alpha Vantage call per day shared with
    /// everything else, and when that is spent the symbol is simply absent and
    /// the row shows a dash.
    /// Keyed by `AssetSearchResult.id` — symbol *plus* venue and currency — not
    /// by ticker.
    ///
    /// Keying by ticker was what put the NASDAQ close on all six AAPL rows,
    /// including the Buenos Aires CEDEAR quoted in pesos. The ticker is not the
    /// instrument; the listing is. Every row now gets the price of its own
    /// venue or nothing at all, and "nothing" reaches the UI as an absent key,
    /// which renders as a dash.
    func quotesForSearch(_ results: [AssetSearchResult]) async -> [String: Quote] {
        var found: [String: Quote] = [:]
        // Ticker → the listing ids waiting on it. US venues share one request
        // per ticker even when both NASDAQ and NYSE rows are present.
        var pendingUS: [String: [String]] = [:]
        var pendingEuropean: [String: [String]] = [:]   // AV symbol → listing ids
        var pendingLastResort: [String: [String]] = [:]  // Yahoo symbol → listing ids
        // Request order follows the result order, not a dictionary's.
        var usOrder: [String] = []
        var europeanOrder: [String] = []
        var lastResortOrder: [String] = []
        var pendingCryptoIDs: [String] = []
        var cryptoIDToListings: [String: [String]] = [:]

        for result in results {
            if result.assetClass == .crypto, let coinID = result.coingeckoID {
                pendingCryptoIDs.append(coinID)
                cryptoIDToListings[coinID, default: []].append(result.id)
                continue
            }

            // A row with no MIC cannot be placed on a venue, so it stays
            // unpriced rather than borrowing someone else's number.
            guard let mic = result.mic else { continue }

            // A venue none of the first three providers covers — Frankfurt,
            // Munich, Buenos Aires — is not unpriceable any more: it goes
            // straight to the last resort, which is the only one that reaches
            // it. `exchangeForMIC` staying nil is exactly that signal.
            guard let exchange = MarketCalendar.exchangeForMIC(mic) else {
                if let yahooSymbol = MarketCalendar.yahooSymbol(result.symbol, mic: mic) {
                    if pendingLastResort[yahooSymbol] == nil { lastResortOrder.append(yahooSymbol) }
                    pendingLastResort[yahooSymbol, default: []].append(result.id)
                }
                continue
            }

            let providerSymbol = exchange.isEuropean
                ? exchange.alphaVantageSuffix.map { result.symbol + $0 }
                : result.symbol
            guard let providerSymbol else { continue }

            // Already priced: reuse rather than spend a request — but only when
            // the cached quote is in this listing's own currency. The reuse used
            // to be by ticker alone, which is how the NASDAQ close ended up on
            // the Buenos Aires row.
            if let existing = quotes[ListingID(symbol: result.symbol, mic: mic).storageKey],
               existing.price > 0,
               existing.currency == result.currency {
                found[result.id] = existing
                continue
            }

            if exchange.isEuropean {
                if pendingEuropean[providerSymbol] == nil { europeanOrder.append(providerSymbol) }
                pendingEuropean[providerSymbol, default: []].append(result.id)
            } else {
                if pendingUS[providerSymbol] == nil { usOrder.append(providerSymbol) }
                pendingUS[providerSymbol, default: []].append(result.id)
            }
        }

        // US listings: Twelve Data, then Finnhub. Both answer in the listing's
        // own currency, which the quote carries.
        if !pendingUS.isEmpty {
            let symbols = usOrder
            var covered: Set<String> = []

            /// A reply is only for the rows whose venue it actually matches.
            /// Two US rows can share a ticker — NASDAQ and NYSE — and only one
            /// of them is what came back.
            func deliver(_ q: Quote) -> Bool {
                let ids = (pendingUS[q.symbol] ?? []).filter { id in
                    guard let mic = results.first(where: { $0.id == id })?.mic,
                          let reported = q.venueMIC, !reported.isEmpty
                    else { return true }
                    return MarketCalendar.venuesAgree(reported, mic)
                }
                guard !ids.isEmpty else { return false }
                for id in ids { found[id] = q }
                for listing in listingsFor(ids, in: results) { applyQuote(q, as: listing) }
                return true
            }

            if let fetched = try? await stockProvider.quotes(for: symbols) {
                for q in fetched where q.price > 0 {
                    if deliver(q) { covered.insert(q.symbol) }
                }
            }
            let missing = symbols.filter { !covered.contains($0) }
            if !missing.isEmpty, let fetched = try? await fallbackStockProvider.quotes(for: missing) {
                for q in fetched where q.price > 0 {
                    _ = deliver(q)
                }
            }
        }

        // European listings: straight to Alpha Vantage. They used to be routed
        // by symbol suffix, which a search result does not have, so this branch
        // never ran for a search — the row fell through to Finnhub's zero.
        if !pendingEuropean.isEmpty, let europeanProvider {
            var covered: Set<String> = []
            if let fetched = try? await europeanProvider.quotes(for: europeanOrder) {
                for q in fetched where q.price > 0 {
                    let ids = pendingEuropean[q.symbol] ?? []
                    for id in ids { found[id] = q }
                    for listing in listingsFor(ids, in: results) { applyQuote(q, as: listing) }
                    covered.insert(q.symbol)
                }
            }
            // Alpha Vantage's 25-a-day budget runs out, and a XETRA row it
            // could not serve can still be served by the last resort.
            for (avSymbol, ids) in pendingEuropean where !covered.contains(avSymbol) {
                guard let id = ids.first,
                      let result = results.first(where: { $0.id == id }),
                      let mic = result.mic,
                      let yahooSymbol = MarketCalendar.yahooSymbol(result.symbol, mic: mic),
                      pendingLastResort[yahooSymbol] == nil
                else { continue }
                pendingLastResort[yahooSymbol] = ids
                lastResortOrder.append(yahooSymbol)
            }
        }

        // Last resort, once everything above has had its turn.
        if !pendingLastResort.isEmpty, let lastResortProvider {
            if let fetched = try? await lastResortProvider.quotes(for: lastResortOrder) {
                for q in fetched where q.price > 0 {
                    let ids = pendingLastResort[q.symbol] ?? []
                    for id in ids { found[id] = q }
                    for listing in listingsFor(ids, in: results) { applyQuote(q, as: listing) }
                }
            }
        }

        if !pendingCryptoIDs.isEmpty,
           let fetched = try? await cryptoProvider.quotes(for: pendingCryptoIDs) {
            for q in fetched {
                guard let listings = cryptoIDToListings[q.symbol], let first = listings.first,
                      let symbol = results.first(where: { $0.id == first })?.symbol
                else { continue }
                let mapped = Quote(
                    symbol: symbol, price: q.price, previousClose: q.previousClose,
                    changeAbsolute: q.changeAbsolute, changePercent: q.changePercent,
                    currency: q.currency, timestamp: q.timestamp, source: q.source,
                    closeDate: q.closeDate
                )
                for id in listings { found[id] = mapped }
                for listing in listingsFor(listings, in: results) { applyQuote(mapped, as: listing) }
            }
        }

        return found
    }

    /// The listings behind a set of `AssetSearchResult.id`s, so a search price
    /// is cached under the venue it actually came from.
    ///
    /// This is what makes a search prime the portfolio's cache correctly: the
    /// row the user is about to buy is priced, and the price lands on that
    /// listing's key rather than on the bare ticker where any namesake would
    /// have read it.
    private func listingsFor(_ ids: [String], in results: [AssetSearchResult]) -> [ListingID] {
        ids.compactMap { id in
            guard let result = results.first(where: { $0.id == id }) else { return nil }
            return ListingID(symbol: result.symbol, mic: result.mic)
        }
    }

    // MARK: - Candles

    func candles(symbol: String, range: ChartRange) async throws -> [Candle] {
        if coinIDMap[symbol.lowercased()] != nil {
            return try await cryptoProvider.candles(symbol: symbol, range: range)
        }
        return try await stockProvider.candles(symbol: symbol, range: range)
    }

    // MARK: - CoinGecko ID map management

    func refreshCoinIDMap() async {
        guard let cgProvider = cryptoProvider as? CoinGeckoProvider else { return }
        do {
            let coins = try await cgProvider.fetchCoinsList()
            for coin in coins {
                let sym = coin.symbol.lowercased()
                let rank = coin.market_cap_rank ?? Int.max
                if let existing = coinIDMap[sym] {
                    // Keep higher market cap (lower rank number)
                    if let cachedRank = coinRank(for: existing), rank < cachedRank {
                        coinIDMap[sym] = coin.id
                    }
                } else {
                    coinIDMap[sym] = coin.id
                }
                persistCoinID(symbol: sym, coinID: coin.id, name: coin.name, rank: rank)
            }
            coinIDMapLastRefresh = Date()
        } catch {}
    }

    func ensureCoinIDMap() async {
        if let last = coinIDMapLastRefresh,
           Date().timeIntervalSince(last) < 7 * 24 * 3600 {
            return
        }
        if !coinIDMap.isEmpty && coinIDMapLastRefresh == nil {
            // Loaded from cache, check age
            if let ctx = modelContext {
                let descriptor = FetchDescriptor<CoinGeckoCache>(
                    sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
                )
                if let newest = try? ctx.fetch(descriptor).first,
                   Date().timeIntervalSince(newest.updatedAt) < 7 * 24 * 3600 {
                    coinIDMapLastRefresh = newest.updatedAt
                    return
                }
            }
        }
        await refreshCoinIDMap()
    }

    // MARK: - Private

    private func shouldDebounce(_ symbol: String) -> Bool {
        guard let lastUpdate = debounceTimers[symbol] else { return false }
        return Date().timeIntervalSince(lastUpdate) < debounceInterval
    }

    /// The tightest interval any of these listings needs.
    ///
    /// The venue now comes from the MIC where there is one. It used to come from
    /// `exchangeForSymbol`, which reads a suffix a held position does not have
    /// and answers NYSE for everything — so a XETRA-only portfolio polled on
    /// New York's clock, staying on the 15-second cadence for two hours after
    /// Frankfurt had shut.
    private func pollingInterval(for pollFor: [ListingID]) -> TimeInterval {
        var minInterval: TimeInterval = 600
        for listing in pollFor {
            if coinIDMap[listing.symbol.lowercased()] != nil {
                minInterval = min(minInterval, 15)
                continue
            }
            let exchange = self.exchange(for: listing) ?? .nyse
            let interval = MarketCalendar.pollingInterval(for: exchange)
            Self.log.info("interval \(listing.symbol, privacy: .public) → \(exchange.rawValue, privacy: .public) \(Int(interval))s")
            minInterval = min(minInterval, interval)
        }
        return minInterval
    }

    private func persistToCache(_ quote: Quote, as id: ListingID) {
        guard let ctx = modelContext else { return }
        let symbol = id.symbol
        let descriptor = FetchDescriptor<PriceSnapshot>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        // Narrowed by ticker in the predicate and settled by listing in Swift.
        // Comparing an optional MIC inside a `#Predicate` is exactly the kind of
        // thing that compiles and then matches nothing at runtime, and the rows
        // for one ticker are a handful.
        let rows = (try? ctx.fetch(descriptor)) ?? []
        if let existing = rows.first(where: { $0.listing == id }) {
            existing.update(from: quote)
        } else {
            ctx.insert(PriceSnapshot(quote: quote, listing: id))
        }
        try? ctx.save()
    }

    private func hydrateCoinIDMap() {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<CoinGeckoCache>(
            sortBy: [SortDescriptor(\.marketCapRank)]
        )
        guard let entries = try? ctx.fetch(descriptor) else { return }
        for entry in entries {
            let sym = entry.symbol.lowercased()
            if coinIDMap[sym] == nil || entry.marketCapRank < (coinRank(for: coinIDMap[sym]!) ?? Int.max) {
                coinIDMap[sym] = entry.coinID
            }
        }
    }

    private func coinRank(for coinID: String) -> Int? {
        guard let ctx = modelContext else { return nil }
        let descriptor = FetchDescriptor<CoinGeckoCache>(
            predicate: #Predicate { $0.coinID == coinID }
        )
        return try? ctx.fetch(descriptor).first?.marketCapRank
    }

    private func persistCoinID(symbol: String, coinID: String, name: String, rank: Int = Int.max) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<CoinGeckoCache>(
            predicate: #Predicate { $0.coinID == coinID }
        )
        if let existing = try? ctx.fetch(descriptor).first {
            existing.symbol = symbol.lowercased()
            existing.name = name
            existing.marketCapRank = rank
            existing.updatedAt = Date()
        } else {
            ctx.insert(CoinGeckoCache(coinID: coinID, symbol: symbol.lowercased(), name: name, marketCapRank: rank))
        }
        try? ctx.save()
    }
}
