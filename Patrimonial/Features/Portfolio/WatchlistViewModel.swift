import Foundation
import SwiftData
import Observation

/// Tickers the user follows without owning.
///
/// A watchlist entry is a full `Asset` row — symbol, MIC and currency — never a
/// bare ticker. The reason is the same one that made positions store the venue:
/// "IWDA" alone cannot be priced, because IWDA on XAMS quotes in EUR and IWDA on
/// XLON quotes in USD, and a bare ticker resolves to whichever the provider
/// happens to return first. An entry that cannot name its listing cannot be
/// honestly priced, so it is not stored.
@MainActor
@Observable
final class WatchlistViewModel {

    private(set) var entries: [Asset] = []

    private var modelContext: ModelContext?
    private var priceStore: PriceStore?

    /// The last filter applied, so a reload triggered from inside this type —
    /// after a removal, say — does not forget which tickers are held and
    /// resurface a position in the watchlist.
    private var lastOpenListings: Set<ListingID> = []

    func bind(modelContext: ModelContext, priceStore: PriceStore) {
        self.modelContext = modelContext
        self.priceStore = priceStore
        load()
    }

    /// Followed assets that are not also held.
    ///
    /// The flag survives a purchase — the entry is filtered out of the list
    /// rather than deleted, so selling out later restores it instead of
    /// silently losing something the user chose to follow.
    func load(openListings: Set<ListingID>? = nil) {
        guard let ctx = modelContext else { return }
        let filter = openListings ?? lastOpenListings
        lastOpenListings = filter

        let descriptor = FetchDescriptor<Asset>(sortBy: [SortDescriptor(\.symbol)])
        let all = (try? ctx.fetch(descriptor)) ?? []
        // Filtered by listing. Holding NVIDIA on XETRA used to hide a followed
        // namesake on NASDAQ from the watchlist, because both are "NVD".
        entries = all.filter { $0.isWatchlisted && !filter.contains($0.listing) }

        // Same routing the positions get: the listing has to be registered or
        // the price store falls back to guessing a venue from the ticker.
        for asset in entries where !asset.exchange.isEmpty && !asset.currency.isEmpty {
            priceStore?.register(asset.listing, currency: asset.currency)
            if asset.assetClass == .crypto, let cgID = asset.coingeckoID {
                priceStore?.registerCoinID(symbol: asset.symbol, coinID: cgID)
            }
        }
    }

    /// The listings to subscribe to, so watchlist rows are priced by exactly the
    /// same polling loop as the positions rather than a second, weaker path.
    var listings: [ListingID] { entries.map(\.listing) }

    // MARK: - Add

    enum AddError: Error, LocalizedError {
        case incompleteListing
        case venueConflict(symbol: String, recorded: String, incoming: String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .incompleteListing:
                "Este resultado não indica praça e moeda — não pode ser seguido."
            case .venueConflict(let symbol, let recorded, let incoming):
                "Há movimentos de \(symbol) gravados sem praça, e neste momento só podem pertencer a \(recorded). Seguir \(symbol) em \(incoming) tornava-os impossíveis de atribuir. Regista primeiro uma compra de \(symbol) em \(recorded)."
            case .saveFailed(let reason):
                reason
            }
        }
    }

    func add(_ result: AssetSearchResult, openListings: Set<ListingID>? = nil) throws {
        guard let ctx = modelContext else { return }

        let venue = result.mic ?? result.exchange
        guard !venue.isEmpty, !result.currency.isEmpty else {
            throw AddError.incompleteListing
        }

        let symbol = result.symbol
        let incoming = ListingID(symbol: symbol, mic: venue)
        let rows = (try? ctx.fetch(
            FetchDescriptor<Asset>(predicate: #Predicate { $0.symbol == symbol })
        )) ?? []
        // One row per listing, so following a namesake no longer competes with a
        // held position for the same row — it gets its own.
        let existing = rows.first { $0.listing == incoming }

        // The narrowed guard, same rule as a purchase. Following a namesake is
        // only refused when the ticker still has transactions with no venue: the
        // second listing would strand them. Everything else is now allowed.
        if ListingBackfill.hasUnattributedRows(forSymbol: symbol, in: ctx),
           let other = ListingBackfill.recordedVenues(forSymbol: symbol, in: ctx)
               .union(Set(rows.compactMap { $0.listing.mic }))
               .subtracting([incoming.mic ?? ""]).first {
            throw AddError.venueConflict(
                symbol: symbol, recorded: other, incoming: incoming.mic ?? venue
            )
        }

        priceStore?.register(incoming, currency: result.currency)
        if result.assetClass == .crypto, let cgID = result.coingeckoID {
            priceStore?.registerCoinID(symbol: result.symbol, coinID: cgID)
        }

        if let existing {
            existing.isWatchlisted = true
            existing.exchange = venue
            existing.currency = result.currency
            if existing.name.isEmpty { existing.name = result.name }
            if let cgID = result.coingeckoID { existing.coingeckoID = cgID }
        } else {
            ctx.insert(Asset(
                symbol: result.symbol,
                name: result.name,
                assetClass: result.assetClass,
                exchange: venue,
                currency: result.currency,
                coingeckoID: result.coingeckoID,
                isWatchlisted: true
            ))
        }

        do {
            try ctx.save()
        } catch {
            ctx.rollback()
            throw AddError.saveFailed(error.localizedDescription)
        }
        load(openListings: openListings)
    }

    func isWatchlisted(_ listing: ListingID) -> Bool {
        entries.contains { $0.listing == listing }
    }

    // MARK: - Remove

    /// Unfollows a ticker. The `Asset` row is only deleted when nothing else
    /// needs it — a symbol that has transactions behind it keeps its metadata,
    /// or the position it belongs to loses its venue and its currency.
    func remove(listing: ListingID) {
        guard let ctx = modelContext else { return }

        let all = (try? ctx.fetch(FetchDescriptor<Asset>())) ?? []
        let transactions = (try? ctx.fetch(FetchDescriptor<FinancialTransaction>())) ?? []
        let hasHistory = transactions.contains { tx in
            tx.assetSymbol.map { ListingID(symbol: $0, mic: tx.assetMIC) } == listing
        }

        for asset in all where asset.listing == listing {
            if hasHistory {
                asset.isWatchlisted = false
            } else {
                ctx.delete(asset)
            }
        }

        if !hasHistory {
            for snapshot in (try? ctx.fetch(FetchDescriptor<PriceSnapshot>())) ?? []
            where snapshot.listing == listing {
                ctx.delete(snapshot)
            }
            priceStore?.forget(listing: listing)
        }

        try? ctx.save()
        load()
    }

    // MARK: - Display

    func quote(for asset: Asset) -> Quote? { priceStore?.quote(for: asset.listing) }

    func freshness(for asset: Asset) -> QuoteFreshness? {
        guard quote(for: asset) != nil else { return nil }
        return priceStore?.freshness(for: asset.listing)
    }
}
