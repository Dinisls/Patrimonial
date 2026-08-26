import Foundation

/// A conversion rate together with the direction it converts in.
///
/// The type exists because `0,8669` and `1,1535` are both plausible USD/EUR
/// rates and a bare `Decimal` cannot tell them apart. Every failure this module
/// has had with currency was a direction failure — a dollar price wearing a euro
/// sign, a rate of 1 standing in for one that was not known — and each time the
/// number itself looked entirely reasonable.
///
/// Swift cannot make the inversion a compile error: currencies arrive as strings
/// from providers, so they cannot be static types, and phantom types over an
/// enum would only move the guess to wherever the string is turned into a case.
/// What this can do is make an inverted rate **unusable**: the conversion
/// refuses to run unless the money it is given is in the currency the rate
/// converts *from*, so a flipped rate produces a dash rather than a number
/// 33 % out. That is the same trade the rest of the module makes everywhere —
/// a visible absence over an invisible error.
nonisolated struct FXRate: Equatable, Sendable {
    /// The currency this rate converts *out of*.
    let from: String
    /// The currency it converts *into*.
    let to: String
    /// Units of `to` per one unit of `from`.
    let value: Decimal

    /// Nil for anything that could not be a rate: an unnamed currency, or a
    /// value of zero or less. A rate of zero would value every position at
    /// 0,00 €, which is the shape of bug that took longest to see the last time.
    init?(from: String, to: String, value: Decimal) {
        guard !from.isEmpty, !to.isEmpty, value > 0 else { return nil }
        self.from = from
        self.to = to
        self.value = value
    }

    /// A currency against itself. Not a special case in the arithmetic — one is
    /// genuinely the rate — but worth naming so the call sites read as a
    /// decision rather than as a magic number.
    static func identity(_ currency: String) -> FXRate? {
        FXRate(from: currency, to: currency, value: 1)
    }

    /// Converts an amount, or refuses to.
    ///
    /// The `currency` argument is the whole point: it is the caller stating what
    /// it is holding, and the rate checking that against what it converts from.
    /// A mismatch returns nil, so a rate that arrived the wrong way round cannot
    /// silently multiply where it should divide.
    func convert(_ amount: Decimal, from currency: String) -> Decimal? {
        guard currency == from else { return nil }
        return amount * value
    }

    /// The same rate read backwards. Only for display and for talking to sources
    /// that quote the other way — never to rescue a mismatched conversion, which
    /// would be the inversion this type exists to prevent, performed on purpose.
    var inverted: FXRate? {
        FXRate(from: to, to: from, value: 1 / value)
    }

    /// Whether this rate converts the pair the caller means to convert.
    func converts(_ currency: String, into target: String) -> Bool {
        from == currency && to == target
    }
}
