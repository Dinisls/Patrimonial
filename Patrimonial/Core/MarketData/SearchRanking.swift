import Foundation

/// Orders search results for a Portuguese investor, and drops the instruments
/// that are not the thing being searched for.
///
/// Twelve Data answers `AAPL` with dozens of rows — Thai depositary receipts,
/// Argentine CEDEARs, tokenized "Apple xStock", and structured notes like
/// "Barclays Bank PLC Capped Point to Point" that are not Apple at all — in no
/// useful order. The listing the user actually wants was buried.
///
/// Presentation only. Nothing here changes which provider is asked, how a
/// symbol is built, or how many quotes are fetched: `PriceStore` still routes
/// by MIC and still prices the top five. Reordering happens before that cut, so
/// the five that get priced are the five most relevant rather than the five
/// that arrived first — same cost, better spent.
enum SearchRanking {

    /// How many rows to show before "ver mais".
    static let initialDisplayCount = 8

    // MARK: - Venue groups

    /// Ordered by how often this user actually buys there. Lower sorts first.
    enum VenueGroup: Int, Comparable {
        case europe = 0
        case unitedStates = 1
        case canada = 2
        case asia = 3
        /// Latin America, Thailand, secondary German venues. Kept, not hidden —
        /// just last.
        case other = 4

        static func < (a: VenueGroup, b: VenueGroup) -> Bool { a.rawValue < b.rawValue }
    }

    /// MIC → group, and the rank of the venue within it.
    ///
    /// The second number orders venues inside a group so the primary listing
    /// leads: XETR ahead of Frankfurt, Munich, Düsseldorf and Hamburg, and the
    /// NASDAQ Global Select tier ahead of the rest of the US.
    static func venue(for mic: String) -> (group: VenueGroup, rank: Int) {
        switch mic.uppercased() {
        // Europe — Euronext first, being the home market.
        case "XLIS": (.europe, 0)
        case "XAMS": (.europe, 1)
        case "XPAR": (.europe, 2)
        case "XBRU": (.europe, 3)
        case "XETR": (.europe, 4)
        case "XLON": (.europe, 5)
        case "XMIL", "MTAA": (.europe, 6)
        case "XMAD", "BMEX": (.europe, 7)
        case "XSWX", "XVTX": (.europe, 8)
        case "XWBO": (.europe, 9)
        case "XWAR": (.europe, 10)
        // Secondary German venues: real listings with their own prices, but not
        // where anyone buys on purpose.
        case "XFRA": (.other, 10)
        case "XMUN": (.other, 11)
        case "XDUS": (.other, 12)
        case "XHAM": (.other, 13)

        case "XNGS": (.unitedStates, 0)
        case "XNMS": (.unitedStates, 1)
        case "XNCM": (.unitedStates, 2)
        case "XNAS": (.unitedStates, 3)
        case "XNYS": (.unitedStates, 4)
        case "ARCX": (.unitedStates, 5)
        case "BATS": (.unitedStates, 6)
        case "XASE": (.unitedStates, 7)

        case "XTSE": (.canada, 0)
        case "NEOE": (.canada, 1)

        case "XTKS": (.asia, 0)
        case "XHKG": (.asia, 1)

        default: (.other, 50)
        }
    }

    // MARK: - Primary listing

    /// The venue where an instrument's price is actually made — its home
    /// listing, as opposed to the cross-listings and receipts that follow it.
    ///
    /// This outranks the geographic order, which exists to sort *secondary*
    /// venues against each other. Without it, "Europa antes de EUA" put Apple's
    /// Swiss line above NASDAQ, which is not what a search for AAPL means.
    ///
    /// Derived per instrument, not tabulated: a hand-kept list of primary venues
    /// per ticker would be wrong the moment an instrument is missing from it,
    /// and would have to grow forever.
    ///
    /// Instead, among the rows that share a ticker, the primary listing is the
    /// one on the highest-standing venue by `globalPrecedence` — a worldwide
    /// ordering of where price discovery actually happens, independent of this
    /// user's regional preference. Apple is listed on XNGS and XSWX, and XNGS
    /// outranks XSWX globally; QDVE on XETR and four secondary German venues,
    /// and XETR outranks them; Galp only on XLIS, which is therefore its own
    /// primary. Exactly the three answers asked for, with no ticker table.
    ///
    /// Global standing of a venue. Lower is more principal. Deliberately not
    /// the same axis as `venue(for:)`: that one encodes where *this user*
    /// prefers to buy, this one where an instrument's price is made.
    static func globalPrecedence(for mic: String) -> Int {
        switch mic.uppercased() {
        case "XNGS": 0
        case "XNMS": 1
        case "XNCM": 2
        case "XNYS": 3
        case "ARCX": 4
        case "XNAS": 5
        case "BATS", "XASE": 6
        case "XETR": 10
        case "XLON": 11
        case "XPAR": 12
        case "XAMS": 13
        case "XBRU": 14
        case "XLIS": 15
        case "XMIL", "MTAA": 16
        case "XMAD", "BMEX": 17
        case "XSWX", "XVTX": 18
        case "XWBO": 19
        case "XWAR": 20
        case "XTKS": 30
        case "XHKG": 31
        case "XTSE": 40
        case "NEOE": 41
        // Secondary German venues, and everything that is a cross-listing or a
        // receipt rather than a home listing.
        case "XFRA": 60
        case "XMUN": 61
        case "XDUS": 62
        case "XHAM": 63
        default: 90
        }
    }

    /// The ids of the rows that are the primary listing of their ticker.
    static func primaryListingIDs(_ results: [AssetSearchResult]) -> Set<String> {
        var best: [String: (precedence: Int, id: String)] = [:]
        for result in results {
            let symbol = result.symbol.uppercased()
            let precedence = globalPrecedence(for: result.mic ?? result.exchange)
            if let current = best[symbol], current.precedence <= precedence { continue }
            best[symbol] = (precedence, result.id)
        }
        return Set(best.values.map(\.id))
    }

    // MARK: - Exclusions

    /// Name fragments that mark a row as not the searched instrument.
    ///
    /// Matched case-insensitively against the instrument name. These are
    /// wrappers and bets *referencing* a stock, not the stock: a tokenized
    /// "Apple xStock" tracks Apple without being it, and a capped
    /// point-to-point note is a structured product whose payoff has almost
    /// nothing to do with holding the share.
    /// Only what is *not the asset*.
    ///
    /// Depositary receipts are deliberately **not** here. A CEDEAR or a BDR is
    /// the asset bought another way — it tracks the share one for one (or one
    /// for twenty, in AAPL.BA's case) and can be held as a real position, which
    /// is why the portfolio prices it. It belongs at the bottom of the list,
    /// not in the bin. A structured note does not: its payoff is a bet
    /// referencing the share, and a tokenized wrapper is a claim on a custodian.
    static let excludedNameFragments = [
        // Tokenized wrappers.
        "xstock",
        "ondo",
        "tokenized",
        // Structured notes. Twelve Data files these as "Mutual Fund", so the
        // type is no help — the payoff language in the name is the only
        // reliable marker. Taken from the real AAPL response, which returns
        // eight of them: Barclays, JPMorgan, Goldman and Citi notes whose
        // ticker merely references Apple. "Dual directional" is here because
        // JPMorgan's note carries neither "capped" nor "point to point".
        "point to point",
        "buffer note",
        "dual directional",
        "principal protected",
        "worst of",
        "structured",
        "capped",
        "warrant",
        "certificate",
    ]

    /// Leveraged and derivative ETPs: "Direxion Daily AAPL Bull 2X",
    /// "GraniteShares 2x Long AAPL", "YieldMax AAPL Option Income",
    /// "WisdomTree Gold 3x Daily Leveraged".
    ///
    /// **These are never excluded.** A leveraged ETP is a real, listed,
    /// buyable instrument with an ISIN and a price — QQQ3 and 3GOL are held in
    /// this portfolio. Filtering them by name only worked while the user typed
    /// a ticker the filter happened to spare: searching "WisdomTree" or
    /// "gold 3x" — which is how anyone looks for an instrument whose symbol
    /// they do not know by heart — erased the very thing being searched for.
    ///
    /// So the list demotes instead of deleting. Searching AAPL puts NASDAQ's
    /// AAPL first and the 2x funds far below; searching QQQ3 puts QQQ3 first,
    /// because an exact ticker match already outranks everything, this marker
    /// included. Same mechanism as the primary-listing rule: standing, not
    /// existence.
    ///
    /// Matched with word boundaries in mind — "2x ", "3x ", " bull " — so an
    /// ordinary fund with one of these letters in its name is not caught.
    static let derivativeFundMarkers = [
        "2x ", "3x ", "-1x", "1x ", "2x long", "2x daily", "3x daily",
        " bear ", " bull ", "option income", "weekly pay", "inverse", "leverage",
    ]

    /// True when the row is a leveraged or derivative fund — kept, ranked low.
    ///
    /// Not gated on `assetClass == .etf`: the instruments this exists for are
    /// filed as ETP and ETC, not ETF, and a wrong answer here only moves a row
    /// down a list rather than hiding it.
    static func isDerivativeFund(_ result: AssetSearchResult) -> Bool {
        let name = result.name.lowercased()
        return derivativeFundMarkers.contains(where: name.contains)
    }

    // MARK: - The coin and its echo

    /// Drops the equity rows that are really the same coin under another
    /// provider's name.
    ///
    /// Searching BTC returns Bitcoin twice: once from CoinGecko, which prices
    /// it, and once from Twelve Data, which files "BTC · Bitcoin · EUR" as an
    /// ordinary instrument. The second one is not a listed company — it is the
    /// same asset, routed to a pricing path that has nothing to quote, so it
    /// always renders with a dash. Two rows with the same name, one of them
    /// permanently blank, right next to each other.
    ///
    /// Matched on ticker **and** name together, not ticker alone: "Bitcoin
    /// Group SE" is a real German share that must survive a search for
    /// Bitcoin, and an equity that merely shares a coin's ticker is a different
    /// instrument that deserves its row. Only the row that is the coin,
    /// spelled the same way, is removed — and the one that survives is always
    /// the crypto row, because that is the one with a price.
    static func withoutEquityEchoesOfCoins(_ results: [AssetSearchResult]) -> [AssetSearchResult] {
        let coins = Set(
            results
                .filter { $0.assetClass == .crypto }
                .map { "\($0.symbol.uppercased())|\($0.name.lowercased())" }
        )
        guard !coins.isEmpty else { return results }
        return results.filter { result in
            result.assetClass == .crypto
                || !coins.contains("\(result.symbol.uppercased())|\(result.name.lowercased())")
        }
    }

    static let excludedInstrumentTypes = [
        "warrant",
        "structured product",
        "right",
    ]

    /// True when the row is a wrapper or a bet rather than the instrument.
    static func isExcluded(_ result: AssetSearchResult) -> Bool {
        let name = result.name.lowercased()
        if excludedNameFragments.contains(where: name.contains) { return true }

        let type = result.instrumentType?.lowercased() ?? ""
        if !type.isEmpty, excludedInstrumentTypes.contains(where: type.contains) { return true }

        return false
    }

    // MARK: - Ranking

    /// Filtered and ordered. The query decides what counts as an exact match.
    static func rank(_ results: [AssetSearchResult], query: String) -> [AssetSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        let kept = withoutEquityEchoesOfCoins(results.filter { !isExcluded($0) })
        let primary = primaryListingIDs(kept)

        return kept
            .enumerated()
            .sorted { a, b in
                let (l, r) = (a.element, b.element)

                // Exact ticker before near misses, ahead of venue.
                //
                // The venue groups order listings *of the same instrument*.
                // Applied first, they would put a European `AAPL01` above the
                // NASDAQ `AAPL`, which is the opposite of what searching for
                // AAPL means. So identity leads and venue breaks the tie among
                // the rows that are actually the thing.
                let lExact = l.symbol.uppercased() == needle
                let rExact = r.symbol.uppercased() == needle

                // A coin whose ticker *is* the query leads every equity that
                // also carries it.
                //
                // Everything below this line was built for listings: the
                // primary-venue rule and the regional order both read a MIC,
                // and a coin has none — it is not listed anywhere, it trades
                // everywhere. So a crypto row fell to `.other` rank 50 and
                // landed beneath every exchange-traded row that happened to
                // share the ticker. Searching BTC led with the Grayscale
                // trust, Melanion, Vinanz and an Australian health company,
                // with Bitcoin itself far below.
                //
                // The venue rules are right for what they order and simply do
                // not apply here, so identity settles it before they run: BTC
                // means the coin, ETH means Ethereum, and the funds and
                // companies named after them follow. Only an *exact* ticker
                // does this — searching "Bitcoin Group" is a name search, and
                // nothing here promotes a coin over it.
                let lCoinExact = lExact && l.assetClass == .crypto
                let rCoinExact = rExact && r.assetClass == .crypto
                if lCoinExact != rCoinExact { return lCoinExact }

                if lExact != rExact { return lExact }

                // Then a prefix match, so AAPL01 still beats something that
                // merely mentions Apple in its name.
                let lPrefix = l.symbol.uppercased().hasPrefix(needle)
                let rPrefix = r.symbol.uppercased().hasPrefix(needle)
                if lPrefix != rPrefix { return lPrefix }

                // A leveraged or derivative fund ranks below the plain asset.
                //
                // Below identity, above venue: searching "gold" should lead
                // with the physical gold ETC and carry "Gold 3x Daily
                // Leveraged" further down, whichever venue each happens to be
                // listed on — being the simple thing outranks being listed at
                // home. Above this line, an exact ticker has already settled
                // it, which is why searching QQQ3 still puts QQQ3 first.
                let lDerivative = isDerivativeFund(l)
                let rDerivative = isDerivativeFund(r)
                if lDerivative != rDerivative { return rDerivative }

                // The primary listing of an instrument leads every secondary
                // one, ahead of the regional order.
                //
                // The regional order exists to sort secondary venues against
                // each other; applied first it put Apple's Swiss line above
                // NASDAQ, which is not what searching AAPL means. So the home
                // listing wins, and region decides everything beneath it.
                let lPrimary = primary.contains(l.id)
                let rPrimary = primary.contains(r.id)
                if lPrimary != rPrimary { return lPrimary }

                let lVenue = venue(for: l.mic ?? l.exchange)
                let rVenue = venue(for: r.mic ?? r.exchange)
                if lVenue.group != rVenue.group { return lVenue.group < rVenue.group }
                if lVenue.rank != rVenue.rank { return lVenue.rank < rVenue.rank }

                // Shorter tickers ahead of longer ones at equal standing, then
                // the provider's own order — a stable tiebreak, so the list
                // does not shuffle between identical searches.
                if l.symbol.count != r.symbol.count { return l.symbol.count < r.symbol.count }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
