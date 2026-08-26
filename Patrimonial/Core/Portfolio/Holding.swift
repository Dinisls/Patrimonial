import Foundation

struct Holding: Identifiable, Sendable {
    /// What is held: ticker **and** venue. A position is a listing in an
    /// account, not a ticker in an account — see `ListingID`.
    let listing: ListingID
    let accountID: String
    let accountName: String

    let quantity: Decimal
    let totalCostEUR: Decimal
    let averagePriceEUR: Decimal
    let commissions: Decimal
    let realizedPL: Decimal
    let dividendsReceived: Decimal

    /// The bare ticker, for the places that legitimately want only that — a row
    /// title, a monogram. Never for looking a price up: that is what `listing`
    /// is for, and reaching for the ticker there is how a Buenos Aires CEDEAR
    /// borrows the NASDAQ close.
    var assetSymbol: String { listing.symbol }
    var assetMIC: String? { listing.mic }

    var isOpen: Bool { quantity != 0 }
    var id: String { "\(listing.storageKey):\(accountID)" }

    init(
        assetSymbol: String,
        assetMIC: String? = nil,
        accountID: String,
        accountName: String,
        quantity: Decimal,
        totalCostEUR: Decimal,
        averagePriceEUR: Decimal,
        commissions: Decimal,
        realizedPL: Decimal,
        dividendsReceived: Decimal
    ) {
        self.listing = ListingID(symbol: assetSymbol, mic: assetMIC)
        self.accountID = accountID
        self.accountName = accountName
        self.quantity = quantity
        self.totalCostEUR = totalCostEUR
        self.averagePriceEUR = averagePriceEUR
        self.commissions = commissions
        self.realizedPL = realizedPL
        self.dividendsReceived = dividendsReceived
    }

    // Filled in by caller when quote is available
    var currentPriceNative: Decimal?
    /// The live rate into EUR, carrying the direction it converts in.
    ///
    /// An `FXRate` rather than a `Decimal` because 0,8669 and 1,1535 are both
    /// credible USD/EUR rates and only one of them is this one. See `FXRate`.
    var currentFXRate: FXRate?
    /// The close of the session before the one the current price belongs to.
    ///
    /// Optional, and it matters that it is. Two providers used to fall back to
    /// `previousClose ?? price`, which turns "no previous close" into a daily
    /// change of exactly zero — indistinguishable from a genuinely flat day, and
    /// it travelled through the whole session rule without tripping anything.
    var previousCloseNative: Decimal?
    var currency: String?
    /// From the stored `Asset` row. Nil for positions bought before the venue
    /// was recorded — allocation labels those rather than guessing a class.
    var assetClass: AssetClass?

    /// Nil whenever the position cannot be honestly valued — no price, no rate,
    /// or a price of zero.
    ///
    /// The zero clause is the one that was missing. A 0,00 quote satisfied
    /// `let price = currentPriceNative` and produced a market value of 0,00 €,
    /// which is not "unknown" but a claim: the position showed −100,00 % and
    /// dragged the portfolio total down with it. A holding with no quote must
    /// be a dash and stay out of every sum, and since `totalMarketValue`
    /// returns nil the moment any holding does, this is what keeps a false
    /// total off the screen.
    ///
    /// The guard lives here rather than only at the provider boundary because
    /// this is the invariant, not the plumbing: whatever new source is added
    /// later, a zero must never become a valuation.
    /// The conversion is performed *by the rate*, which refuses unless the money
    /// it is handed is in the currency it converts out of. A rate that arrived
    /// the wrong way round therefore produces a dash, not a figure 33 % out.
    var marketValueEUR: Decimal? {
        guard let price = currentPriceNative, price > 0,
              let fx = currentFXRate, let currency
        else { return nil }
        return fx.convert(quantity * price, from: currency)
    }

    var unrealizedPL: Decimal? {
        guard let mv = marketValueEUR else { return nil }
        return mv - totalCostEUR
    }

    var unrealizedPLPercent: Decimal? {
        guard let pl = unrealizedPL, totalCostEUR != 0 else { return nil }
        return (pl / totalCostEUR) * 100
    }

    /// Every purchase lot still alive in the position, each with the date it
    /// was made at and the native-currency price paid.
    ///
    /// Kept per lot rather than as one blended figure: two buys on either side
    /// of a period boundary need their own reference, and blending them lets one
    /// contaminate the other. Sales shrink every lot proportionally (average
    /// cost), so the lot distribution reflects the current position, not the
    /// gross history.
    struct PurchaseLot: Equatable, Sendable {
        let date: Date
        let quantity: Decimal
        let unitPriceNative: Decimal
    }
    var purchaseLots: [PurchaseLot] = []

    /// The start of the session the current price belongs to, set by the
    /// ViewModel from the venue's market calendar.
    var sessionStart: Date?
    /// The end of that session, or nil when the session is still open.
    var sessionEnd: Date?

    /// The change over a period, measured from each lot's own reference.
    ///
    /// One function for every period — 1D through 1Y and YTD — with different
    /// inputs, never different code. The "Hoje" that was is the 1D case with
    /// `clampToReference: true` and a `sessionEnd`.
    ///
    /// - `referenceClose`: the close at the period's start (for 1D: the previous
    ///   session's close; for other periods: the candle close at the cutoff).
    ///   Nil means the position has no reference and is excluded.
    /// - `periodStart`: the instant that separates older lots from within-period
    ///   lots (for 1D: the session start; for other periods: the cutoff date).
    /// - `clampToReference`: for 1D, a within-session lot bought below the
    ///   previous close is clamped to the reference, so the day change never
    ///   exceeds the instrument's session move. Longer periods do not clamp.
    /// - `sessionEnd`: lots bought after this instant are excluded entirely
    ///   (end-of-day data: no newer price exists for them to have moved to).
    ///   Nil means the session is open and no lot can be newer than the price.
    func periodChangeEUR(
        referenceClose: Decimal?,
        periodStart: Date,
        clampToReference: Bool,
        sessionEnd: Date?
    ) -> Decimal? {
        guard let price = currentPriceNative,
              let fx = currentFXRate, let currency
        else { return nil }
        guard let refClose = referenceClose else { return nil }

        if purchaseLots.isEmpty {
            return fx.convert(quantity * (price - refClose), from: currency)
        }

        var change: Decimal = 0
        for lot in purchaseLots {
            if let end = sessionEnd, lot.date > end {
                continue
            }
            if lot.date >= periodStart {
                let ref = clampToReference
                    ? max(refClose, lot.unitPriceNative)
                    : lot.unitPriceNative
                change += lot.quantity * (price - ref)
            } else {
                change += lot.quantity * (price - refClose)
            }
        }
        return fx.convert(change, from: currency)
    }

    /// The 1D case of `periodChangeEUR`, kept as a named property so per-row
    /// display and the day-change total read the same expression.
    var dayChangeEUR: Decimal? {
        guard let start = sessionStart else { return nil }
        return periodChangeEUR(
            referenceClose: previousCloseNative,
            periodStart: start,
            clampToReference: true,
            sessionEnd: sessionEnd
        )
    }

    var totalReturn: Decimal? {
        guard let upl = unrealizedPL else { return nil }
        return upl + realizedPL + dividendsReceived
    }

    var yieldOnCost: Decimal? {
        guard totalCostEUR != 0 else { return nil }
        return (dividendsReceived / totalCostEUR) * 100
    }

    // MARK: - Unified holdings

    /// Merges per-account holdings into one holding per listing. The display
    /// sees one line; validation and future FIFO keep per-account data.
    static func unify(_ holdings: [Holding]) -> [Holding] {
        var grouped: [ListingID: [Holding]] = [:]
        for h in holdings { grouped[h.listing, default: []].append(h) }

        return grouped.map { _, group in
            group.count == 1 ? group[0] : merge(group)
        }.sorted { $0.listing < $1.listing }
    }

    private static func merge(_ group: [Holding]) -> Holding {
        let listing = group[0].listing
        let quantity = group.reduce(Decimal(0)) { $0 + $1.quantity }
        let totalCostEUR = group.reduce(Decimal(0)) { $0 + $1.totalCostEUR }
        let commissions = group.reduce(Decimal(0)) { $0 + $1.commissions }
        let realizedPL = group.reduce(Decimal(0)) { $0 + $1.realizedPL }
        let dividends = group.reduce(Decimal(0)) { $0 + $1.dividendsReceived }
        let averagePriceEUR = quantity > 0 ? totalCostEUR / quantity : 0
        let names = group.map(\.accountName).filter { !$0.isEmpty }
        let accountLabel = names.count <= 2
            ? names.joined(separator: " · ")
            : "\(names.count) contas"

        var merged = Holding(
            assetSymbol: listing.symbol,
            assetMIC: listing.mic,
            accountID: "",
            accountName: accountLabel,
            quantity: quantity,
            totalCostEUR: totalCostEUR,
            averagePriceEUR: averagePriceEUR,
            commissions: commissions,
            realizedPL: realizedPL,
            dividendsReceived: dividends
        )
        merged.currentPriceNative = group.first(where: { $0.currentPriceNative != nil })?.currentPriceNative
        merged.currentFXRate = group.first(where: { $0.currentFXRate != nil })?.currentFXRate
        merged.previousCloseNative = group.first(where: { $0.previousCloseNative != nil })?.previousCloseNative
        merged.currency = group.first(where: { $0.currency != nil })?.currency
        merged.assetClass = group.first(where: { $0.assetClass != nil })?.assetClass
        merged.purchaseLots = group.flatMap(\.purchaseLots)
        merged.sessionStart = group.compactMap(\.sessionStart).first
        merged.sessionEnd = group.compactMap(\.sessionEnd).first
        return merged
    }

    var isUnified: Bool { accountID.isEmpty && !accountName.isEmpty }
}
