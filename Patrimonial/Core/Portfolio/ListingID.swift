import Foundation

/// A ticker together with the venue it trades on — the smallest thing that
/// actually identifies an instrument.
///
/// `NVD` on its own is two instruments: NVIDIA on XETRA at ~194 EUR and the
/// GraniteShares 2x Short NVIDIA ETF on NASDAQ at ~3,97 USD. Everything that
/// was keyed by a bare ticker was therefore keyed by something that is not an
/// identity, and in one account the calculator summed the two into a single
/// holding whose cost basis was averaged across unrelated instruments.
///
/// **The MIC is optional on purpose.** Rows written before the venue was stored
/// have no venue to recover, and inventing one here would be the same guess
/// this type exists to stop. A venueless listing keys as the bare symbol —
/// byte for byte what those rows already use — so they keep behaving exactly as
/// they do today, while never sharing a key with a listing that does name a
/// venue.
struct ListingID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let symbol: String
    /// The canonical venue, or nil when unknown. Never the empty string: `""`
    /// and `nil` would be two spellings of "no venue" and would key apart.
    let mic: String?

    init(symbol: String, mic: String? = nil) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let venue = (mic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Canonicalised at the boundary, once. A listing stored as XNMS and the
        // same listing stored as XNAS are one position, and the only way to
        // guarantee that is for them to be one string before anything hashes it.
        self.mic = venue.isEmpty ? nil : MarketCalendar.canonicalVenue(venue)
    }

    /// True when the venue is unknown — a legacy row, or a manual asset with no
    /// venue given. Callers that must not guess check this rather than testing
    /// `mic == nil` themselves.
    var isVenueless: Bool { mic == nil }

    /// The string this listing is stored and looked up under.
    ///
    /// The venueless form is the bare symbol, which is what makes the migration
    /// possible without a schema version: every key already on disk is a valid
    /// key of this type, and it means the same thing.
    var storageKey: String {
        guard let mic else { return symbol }
        return "\(symbol)\(Self.separator)\(mic)"
    }

    /// Reads back a `storageKey`. A key with no separator is a venueless
    /// listing, not a parse failure.
    static func from(storageKey: String) -> ListingID {
        guard let range = storageKey.range(of: separator) else {
            return ListingID(symbol: storageKey)
        }
        return ListingID(
            symbol: String(storageKey[storageKey.startIndex..<range.lowerBound]),
            mic: String(storageKey[range.upperBound...])
        )
    }

    /// `|` is not legal in a ticker or a MIC, so it cannot occur inside either
    /// half and the split is unambiguous.
    private static let separator = "|"

    /// Whether this listing may be the one a venueless row was talking about.
    ///
    /// Asymmetric on purpose, and not equality: a row with no venue is not a
    /// row on "no venue", it is a row whose venue was never written down. It is
    /// compatible with any venue for the same ticker, which is what lets the
    /// backfill adopt a listing for it — but only where exactly one candidate
    /// exists. See `ListingBackfill`.
    func couldBe(_ other: ListingID) -> Bool {
        guard symbol == other.symbol else { return false }
        guard let mine = mic, let theirs = other.mic else { return true }
        return mine == theirs
    }

    static func < (lhs: ListingID, rhs: ListingID) -> Bool {
        lhs.symbol == rhs.symbol
            ? (lhs.mic ?? "") < (rhs.mic ?? "")
            : lhs.symbol < rhs.symbol
    }

    /// What a person should see: `NVD · XETR`, and just `NVD` when the venue is
    /// unknown. Never `NVD · nil`, and never an invented venue.
    var description: String {
        guard let mic else { return symbol }
        return "\(symbol) · \(mic)"
    }
}
