import Foundation
import SwiftData
import Observation

/// Daily price history: cached first, fetched incrementally, never discarded.
///
/// The cache is the feature, not a speed-up. Alpha Vantage hands over 100
/// sessions at a time on a 25-call day, so a chart longer than that exists only
/// because previous days' candles were kept. Three rules follow, and every one
/// of them is load-bearing:
///
/// 1. **A closed session is immutable.** Fetched once, then never asked for
///    again — `earliestMissingDate` is what decides there is nothing to ask.
/// 2. **Refresh appends.** Merging never updates or deletes an existing row, so
///    a provider change or a short reply cannot shorten the user's history.
/// 3. **An exhausted budget is not an error.** It serves the cache silently;
///    charts degrade before quotes do.
///
/// All four ranges come off the same daily series — 1S, 1M, 1A and Máx are
/// filters over one array, not four fetches.
@MainActor
@Observable
final class CandleStore {

    /// Which provider can serve a symbol's history, and under what name.
    ///
    /// Resolved from the recorded MIC by the caller, never from a ticker
    /// suffix — the same rule the quote path learned the hard way. Yahoo is
    /// deliberately absent: it is a quote source only, so the venues only it
    /// reaches simply have no chart.
    enum Route: Equatable {
        case unitedStates(symbol: String)
        case european(symbol: String)
        case crypto(coinID: String)
    }

    private(set) var isLoading = false

    private var modelContext: ModelContext?
    private let usProvider: any MarketDataProvider
    private let europeanProvider: (any MarketDataProvider)?
    private let cryptoProvider: any MarketDataProvider
    private let now: @Sendable () -> Date

    /// One bucket per provider, because the ceilings are per provider and a
    /// shared limiter would let a crypto chart starve an equity one.
    private let usLimiter = RateLimiter(maxTokens: 8, refillInterval: 60)
    private let europeanLimiter = RateLimiter(maxTokens: 5, refillInterval: 60)
    private let cryptoLimiter = RateLimiter(maxTokens: 10, refillInterval: 60)

    /// Symbols with a refresh in flight, so a re-entrant view update cannot
    /// spend the budget twice on the same series.
    private var inFlight: Set<ListingID> = []

    init(
        usProvider: any MarketDataProvider = TwelveDataProvider(),
        europeanProvider: (any MarketDataProvider)? = AlphaVantageProvider(),
        cryptoProvider: any MarketDataProvider = CoinGeckoProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.usProvider = usProvider
        self.europeanProvider = europeanProvider
        self.cryptoProvider = cryptoProvider
        self.now = now
    }

    func bind(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Reading

    /// The full cached daily series, oldest first.
    ///
    /// Narrowed by ticker in the predicate, settled by listing in Swift. Two
    /// instruments sharing a ticker used to share one series, and since a closed
    /// session is never re-fetched, whichever venue reached a given day first
    /// owned it permanently — a chart that is a price history of nothing.
    func series(for listing: ListingID) -> [Candle] {
        guard let ctx = modelContext else { return [] }
        let interval = CandleInterval.daily.rawValue
        let symbol = listing.symbol
        let descriptor = FetchDescriptor<CandleCache>(
            predicate: #Predicate { $0.symbol == symbol && $0.interval == interval },
            sortBy: [SortDescriptor(\.date)]
        )
        return ((try? ctx.fetch(descriptor)) ?? [])
            .filter { $0.listing == listing }
            .map(\.candle)
    }

    /// The series clipped to a range.
    ///
    /// Clipping, not padding. When the cache starts inside the window — a
    /// position added last week asked for 1A — the result is simply shorter,
    /// and `ChartSeries.firstDate` tells the UI what to say about it. Filling
    /// the gap with zeros would draw a crash that never happened.
    func series(for listing: ListingID, range: ChartRange) -> ChartSeries {
        let all = series(for: listing)
        let cutoff = range.cutoffDate(from: now())
        let clipped = all.filter { $0.date >= cutoff }
        // Fewer than two points is not a line. Better no chart than a dot the
        // user reads as a trend.
        guard clipped.count >= 2 else {
            return ChartSeries(candles: [], range: range, coversFullRange: false, firstDate: all.first?.date)
        }
        return ChartSeries(
            candles: clipped,
            range: range,
            // Tolerates a few days: a series starting on the Monday of a range
            // that opens on a Saturday is complete, not truncated.
            coversFullRange: clipped.first.map { $0.date <= cutoff.addingTimeInterval(5 * 86_400) } ?? false,
            firstDate: clipped.first?.date
        )
    }

    // MARK: - Refreshing

    /// Fetches only what the cache is missing, and only if anything is.
    ///
    /// Silent throughout: no error is published. A chart that cannot be
    /// extended shows what it has.
    func refresh(listing: ListingID, route: Route, range: ChartRange = .max) async {
        guard modelContext != nil, !inFlight.contains(listing) else { return }

        // Nothing to ask for. This is the clause that makes closed sessions
        // free: once today's (or the last session's) candle is in the cache,
        // the whole refresh costs zero requests.
        guard let since = earliestMissingDate(for: listing, range: range) else { return }

        inFlight.insert(listing)
        isLoading = true
        defer {
            inFlight.remove(listing)
            isLoading = false
        }

        let fetched: [Candle]
        switch route {
        case .unitedStates(let providerSymbol):
            guard await usLimiter.tryAcquire() else { return }
            fetched = (try? await usProvider.candles(
                symbol: providerSymbol, range: rangeCovering(since)
            )) ?? []

        case .european(let providerSymbol):
            guard let europeanProvider, await europeanLimiter.tryAcquire() else { return }
            // The budget refuses inside the provider once the quote reserve is
            // all that is left, and a refusal arrives here as an empty result.
            fetched = (try? await europeanProvider.candles(
                symbol: providerSymbol, range: rangeCovering(since)
            )) ?? []

        case .crypto(let coinID):
            guard await cryptoLimiter.tryAcquire() else { return }
            fetched = (try? await cryptoProvider.candles(
                symbol: coinID, range: rangeCovering(since)
            )) ?? []
        }

        guard !fetched.isEmpty else { return }
        merge(fetched, listing: listing, source: sourceName(route))
    }

    // MARK: - Cache mechanics

    /// The first session not already cached, or nil when the cache is current.
    ///
    /// "Current" means the latest cached candle is today's or later. Weekends
    /// and holidays are handled by the market calendar rather than guessed at:
    /// asking again on a Sunday for a Friday close would spend a request to
    /// learn nothing.
    func earliestMissingDate(for listing: ListingID, range: ChartRange) -> Date? {
        let cached = series(for: listing)
        guard let latest = cached.last?.date else {
            return range.cutoffDate(from: now())
        }

        let today = Self.sessionDate(now())
        guard latest < today else { return nil }

        // The day after the last one held. Providers are inclusive of the start
        // date, so this re-reads nothing.
        return latest.addingTimeInterval(86_400)
    }

    /// Inserts what is new and leaves everything else alone.
    ///
    /// Deliberately never updates an existing row. A provider that revises a
    /// close, or returns a shorter window than last time, must not be able to
    /// rewrite or shorten history the user has already accumulated.
    func merge(_ candles: [Candle], listing: ListingID, source: String) {
        guard let ctx = modelContext else { return }
        let interval = CandleInterval.daily.rawValue
        let symbol = listing.symbol
        let existing = Set(
            ((try? ctx.fetch(FetchDescriptor<CandleCache>(
                predicate: #Predicate { $0.symbol == symbol && $0.interval == interval }
            ))) ?? []).filter { $0.listing == listing }.map(\.date)
        )

        var inserted = 0
        for candle in candles {
            let date = Self.sessionDate(candle.date)
            guard !existing.contains(date), candle.close > 0 else { continue }
            ctx.insert(CandleCache(
                symbol: symbol,
                mic: listing.mic,
                interval: interval,
                date: date,
                open: candle.open,
                high: candle.high,
                low: candle.low,
                close: candle.close,
                volume: candle.volume,
                source: source
            ))
            inserted += 1
        }
        if inserted > 0 { try? ctx.save() }
    }

    /// Midnight UTC of the session a timestamp belongs to.
    ///
    /// Every write and every comparison goes through this, because the
    /// uniqueness of a cached candle depends on two providers agreeing on what
    /// "that day" means: Twelve Data sends `2026-08-07`, CoinGecko sends
    /// milliseconds mid-afternoon. Without normalising, the same session would
    /// be cached twice and drawn twice.
    static func sessionDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 86_400) * 86_400)
    }

    /// The smallest standard range that reaches back to `since`, so a provider
    /// taking a range rather than a date is not asked for more than needed.
    private func rangeCovering(_ since: Date) -> ChartRange {
        let days = now().timeIntervalSince(since) / 86_400
        switch days {
        case ..<8: return .oneWeek
        case ..<32: return .oneMonth
        case ..<370: return .oneYear
        default: return .max
        }
    }

    private func sourceName(_ route: Route) -> String {
        switch route {
        case .unitedStates: "twelvedata"
        case .european: "alphavantage"
        case .crypto: "coingecko"
        }
    }
}

// MARK: - Series

/// A clipped series plus what the UI needs to describe it honestly.
struct ChartSeries: Equatable {
    let candles: [Candle]
    let range: ChartRange
    /// False when the data starts after the range does — the chart shows less
    /// than it was asked for, and must say since when.
    let coversFullRange: Bool
    let firstDate: Date?

    var isEmpty: Bool { candles.count < 2 }

    var closes: [Decimal] { candles.map(\.close) }

    /// Chart bounds from the data, never from zero.
    ///
    /// A y-axis anchored at zero turns every equity into a flat line near the
    /// top; worse, padding a short series down to zero would draw a collapse
    /// that never happened.
    var valueBounds: (low: Decimal, high: Decimal)? {
        guard let low = candles.map(\.low).min(), let high = candles.map(\.high).max(),
              high > low
        else {
            guard let close = candles.first?.close else { return nil }
            return (close * Decimal(string: "0.99")!, close * Decimal(string: "1.01")!)
        }
        let padding = (high - low) * Decimal(string: "0.06")!
        return (low - padding, high + padding)
    }

    var change: (absolute: Decimal, percent: Decimal)? {
        guard let first = candles.first?.close, let last = candles.last?.close, first != 0
        else { return nil }
        let absolute = last - first
        return (absolute, (absolute / first) * 100)
    }
}

extension ChartRange {
    /// The ranges the detail screen offers. 1D is absent: every range is
    /// derived from the same daily series, and a single day of daily candles is
    /// one point.
    static var chartSelectable: [ChartRange] { [.oneWeek, .oneMonth, .oneYear, .max] }
}
