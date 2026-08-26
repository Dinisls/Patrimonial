import Foundation

/// How the portfolio splits up, by one dimension at a time.
///
/// The rule that shapes the whole type: **a percentage is only ever taken over
/// the strict total**. If one position has no quote, the whole is not 12 % short
/// — it is unknown, and every slice drawn against it would be a wrong number
/// rather than a partial one. So this does not return slices at all in that
/// case; it returns the symbols that are missing, and the screen says so.
///
/// That is deliberately stricter than the header total, which may show a
/// partial figure with a caveat beside it (see
/// `PortfolioCalculator.marketValueTotal`). A caveat works next to one number.
/// It does not work next to a donut, where the reader's eye takes the ring as
/// the whole by construction.
enum PortfolioAllocation {

    enum Dimension: String, CaseIterable, Sendable {
        case assetClass = "Classe"
        case currency = "Moeda"
        case account = "Conta"
    }

    struct Slice: Identifiable, Equatable, Sendable {
        let label: String
        let value: Decimal
        /// Over the strict total, so the slices always sum to 100 %.
        let percent: Decimal
        var id: String { label }
    }

    /// What the allocation tab can draw right now.
    enum Result: Equatable, Sendable {
        /// Every open position is priced; these slices are a complete whole.
        case slices([Slice])
        /// At least one open position has no euro value, so no whole exists to
        /// take percentages over. Carries the symbols, so the screen names them
        /// instead of quietly dropping them from a ring that still looks full.
        case unpriced([String])
        /// Nothing held.
        case empty
    }

    /// Label used when a holding predates the venue/class being recorded.
    /// Naming the gap beats folding it into "Ações", which would be a guess
    /// presented as a fact.
    static let unknownLabel = "Sem classificação"

    static func allocation(
        _ dimension: Dimension,
        holdings: [Holding]
    ) -> Result {
        let open = holdings.filter(\.isOpen)
        guard !open.isEmpty else { return .empty }

        let unpriced = open.filter { $0.marketValueEUR == nil }.map(\.assetSymbol)
        guard unpriced.isEmpty else {
            return .unpriced(unpriced.sorted())
        }

        guard let total = PortfolioCalculator.totalMarketValue(open), total > 0 else {
            // Every position priced, yet nothing adds up to a positive whole —
            // there is no ring to draw and no percentage to take.
            return .unpriced(open.map(\.assetSymbol).sorted())
        }

        var buckets: [String: Decimal] = [:]
        for h in open {
            guard let mv = h.marketValueEUR else { continue }
            buckets[label(for: h, dimension), default: 0] += mv
        }

        var slices: [Slice] = []
        for (label, value) in buckets {
            let percent: Decimal = (value / total) * 100
            slices.append(Slice(label: label, value: value, percent: percent))
        }
        // Largest first; alphabetical between equals so the ring and the list
        // below it do not reshuffle between redraws.
        slices.sort { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }

        return .slices(slices)
    }

    private static func label(for holding: Holding, _ dimension: Dimension) -> String {
        switch dimension {
        case .assetClass:
            holding.assetClass?.displayName ?? unknownLabel
        case .currency:
            holding.currency.flatMap { $0.isEmpty ? nil : $0 } ?? unknownLabel
        case .account:
            holding.accountName.isEmpty ? unknownLabel : holding.accountName
        }
    }
}
