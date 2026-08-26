import Foundation
import SwiftData

/// Attributes a venue to the rows written before venues were stored.
///
/// ## Why this can be done at all
///
/// Adopting a venue is a guess unless there is exactly one candidate — and here
/// there is, by construction rather than by luck. Since the NVD bug,
/// `upsertAsset` and `WatchlistViewModel.add` have **refused** to record a
/// second venue under a ticker that already had one. That interim guard is what
/// held this window open: every ticker in the store has at most one `Asset`
/// row, so its venue is not the most likely answer, it is the only one.
///
/// That is also why the window closes. The moment two venues can coexist under
/// one ticker — which is the whole point of ponto F — a row with no MIC becomes
/// permanently unattributable. `PortfolioViewModel` therefore refuses to create
/// the second venue while any unattributed row for that ticker survives.
///
/// ## What it will not do
///
/// No candidate, or more than one, means the row keeps `nil`. A venueless row
/// is not broken: it keys on the bare symbol and behaves exactly as it did
/// before this type existed. Guessing would be the failure, not abstaining.
///
/// ## Idempotence
///
/// Only rows with a nil MIC are ever touched, and a row that gets one is never
/// revisited. Running this on every launch is free after the first, and running
/// it twice cannot produce a different answer than running it once.
struct ListingBackfill {

    struct Report: Equatable {
        var transactions = 0
        var snapshots = 0
        var candles = 0
        /// Tickers left unattributed because the evidence was absent or
        /// contradictory. Not an error — a fact the caller may want to surface.
        var unresolved: Set<String> = []

        var didChangeAnything: Bool {
            transactions > 0 || snapshots > 0 || candles > 0
        }
    }

    /// Symbol → its one recorded venue, for the symbols that have exactly one.
    ///
    /// Built from `Asset` rows, which is where the venue the user actually
    /// picked has been stored all along. A symbol whose rows disagree is
    /// deliberately absent: that is the ambiguity this whole design refuses to
    /// resolve by guessing.
    static func unambiguousVenues(in ctx: ModelContext) -> [String: String] {
        guard let assets = try? ctx.fetch(FetchDescriptor<Asset>()) else { return [:] }

        var candidates: [String: Set<String>] = [:]
        for asset in assets {
            let listing = asset.listing
            guard let mic = listing.mic else { continue }
            candidates[listing.symbol, default: []].insert(mic)
        }
        return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Runs the backfill. Saves once, at the end, and only if something changed.
    @discardableResult
    static func run(in ctx: ModelContext) -> Report {
        var report = Report()
        let venues = unambiguousVenues(in: ctx)

        if let transactions = try? ctx.fetch(FetchDescriptor<FinancialTransaction>()) {
            for tx in transactions {
                guard let symbol = tx.assetSymbol, tx.assetMIC == nil else { continue }
                let key = ListingID(symbol: symbol).symbol
                guard let mic = venues[key] else {
                    report.unresolved.insert(key)
                    continue
                }
                tx.assetMIC = mic
                report.transactions += 1
            }
        }

        // The cached price and the cached history follow the position. A
        // snapshot left venueless while its transactions adopt a venue is a
        // price the position can no longer find — the screen would go to a dash
        // on the first launch after the update, which is a regression dressed as
        // caution.
        if let snapshots = try? ctx.fetch(FetchDescriptor<PriceSnapshot>()) {
            for snapshot in snapshots where snapshot.mic == nil {
                guard let mic = venues[ListingID(symbol: snapshot.symbol).symbol] else { continue }
                snapshot.mic = mic
                report.snapshots += 1
            }
        }

        if let candles = try? ctx.fetch(FetchDescriptor<CandleCache>()) {
            for candle in candles where candle.mic == nil {
                guard let mic = venues[ListingID(symbol: candle.symbol).symbol] else { continue }
                candle.mic = mic
                report.candles += 1
            }
        }

        if report.didChangeAnything { try? ctx.save() }
        return report
    }

    /// Adopts a venue for a ticker at purchase time, for the rows the launch
    /// backfill could not resolve.
    ///
    /// The case this exists for: a position whose `Asset` row was deleted, or
    /// which predates `Asset` rows entirely, so there was no evidence at launch.
    /// The user then buys that same ticker and names a venue — which is evidence,
    /// and the same unambiguity test applies. If the ticker already carries a
    /// *different* venue somewhere, nothing is adopted and the caller's guard
    /// refuses the purchase instead.
    ///
    /// Returns how many rows adopted the venue. Does not save; the caller's
    /// transaction does, so a refused purchase takes the adoption back with it.
    @discardableResult
    static func adopt(
        venue mic: String, forSymbol symbol: String, in ctx: ModelContext
    ) -> Int {
        let listing = ListingID(symbol: symbol, mic: mic)
        guard let venue = listing.mic else { return 0 }

        var adopted = 0
        if let transactions = try? ctx.fetch(FetchDescriptor<FinancialTransaction>()) {
            for tx in transactions
            where tx.assetMIC == nil && tx.assetSymbol.map({ ListingID(symbol: $0).symbol }) == listing.symbol {
                tx.assetMIC = venue
                adopted += 1
            }
        }
        if let snapshots = try? ctx.fetch(FetchDescriptor<PriceSnapshot>()) {
            for snapshot in snapshots
            where snapshot.mic == nil && ListingID(symbol: snapshot.symbol).symbol == listing.symbol {
                snapshot.mic = venue
                adopted += 1
            }
        }
        if let candles = try? ctx.fetch(FetchDescriptor<CandleCache>()) {
            for candle in candles
            where candle.mic == nil && ListingID(symbol: candle.symbol).symbol == listing.symbol {
                candle.mic = venue
                adopted += 1
            }
        }
        return adopted
    }

    /// The venues already recorded against a ticker's transactions.
    ///
    /// What the narrowed guard asks. More than one is already-ambiguous; one
    /// that differs from an incoming purchase is the conflict the guard refuses
    /// while unattributed rows survive.
    static func recordedVenues(forSymbol symbol: String, in ctx: ModelContext) -> Set<String> {
        let wanted = ListingID(symbol: symbol).symbol
        guard let transactions = try? ctx.fetch(FetchDescriptor<FinancialTransaction>())
        else { return [] }
        var venues: Set<String> = []
        for tx in transactions {
            guard let txSymbol = tx.assetSymbol,
                  ListingID(symbol: txSymbol).symbol == wanted,
                  let mic = ListingID(symbol: txSymbol, mic: tx.assetMIC).mic
            else { continue }
            venues.insert(mic)
        }
        return venues
    }

    // MARK: - Crypto normalization

    /// Crypto has no venue. Any transaction for a crypto symbol that was stored
    /// with a non-nil MIC gets it cleared to nil, so all purchases of the same
    /// crypto aggregate into one position.
    ///
    /// Returns how many rows were fixed. Does not save — the caller decides.
    @discardableResult
    static func normalizeCryptoMICs(in ctx: ModelContext) -> Int {
        guard let assets = try? ctx.fetch(FetchDescriptor<Asset>()) else { return 0 }
        let cryptoSymbols = Set(
            assets.filter { $0.assetClass == .crypto }
                  .map { ListingID(symbol: $0.symbol).symbol }
        )
        guard !cryptoSymbols.isEmpty else { return 0 }

        var fixed = 0

        if let transactions = try? ctx.fetch(FetchDescriptor<FinancialTransaction>()) {
            for tx in transactions {
                guard let symbol = tx.assetSymbol,
                      cryptoSymbols.contains(ListingID(symbol: symbol).symbol),
                      tx.assetMIC != nil
                else { continue }
                tx.assetMIC = nil
                fixed += 1
            }
        }

        for asset in assets where asset.assetClass == .crypto && !asset.exchange.isEmpty {
            asset.exchange = ""
            fixed += 1
        }

        if let snapshots = try? ctx.fetch(FetchDescriptor<PriceSnapshot>()) {
            for snapshot in snapshots
            where cryptoSymbols.contains(ListingID(symbol: snapshot.symbol).symbol)
                  && snapshot.mic != nil {
                snapshot.mic = nil
                fixed += 1
            }
        }

        if let candles = try? ctx.fetch(FetchDescriptor<CandleCache>()) {
            for candle in candles
            where cryptoSymbols.contains(ListingID(symbol: candle.symbol).symbol)
                  && candle.mic != nil {
                candle.mic = nil
                fixed += 1
            }
        }

        if fixed > 0 { try? ctx.save() }
        return fixed
    }

    /// Whether any transaction for this ticker is still unattributed.
    static func hasUnattributedRows(forSymbol symbol: String, in ctx: ModelContext) -> Bool {
        let wanted = ListingID(symbol: symbol).symbol
        guard let transactions = try? ctx.fetch(FetchDescriptor<FinancialTransaction>())
        else { return false }
        return transactions.contains { tx in
            guard let txSymbol = tx.assetSymbol else { return false }
            return ListingID(symbol: txSymbol).symbol == wanted && tx.assetMIC == nil
        }
    }
}
