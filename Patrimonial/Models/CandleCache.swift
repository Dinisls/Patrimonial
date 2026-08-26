import Foundation
import SwiftData

/// One cached daily candle, unique by symbol + interval + session date.
///
/// The cache is not an optimisation here, it is the only way the app ever
/// accumulates history. Alpha Vantage's `compact` output is 100 points and the
/// free tier allows 25 calls a day, so a chart longer than 100 sessions can
/// only be built by keeping what previous days returned. That makes one rule
/// absolute: **refreshing appends, never replaces**. A closed session's candle
/// is immutable — it is fetched once and then belongs to the device.
@Model
final class CandleCache {
    var symbol: String
    /// The venue whose sessions these candles are. Optional and unattributed by
    /// default, exactly like `PriceSnapshot.mic`.
    ///
    /// A chart is where a shared ticker is least obvious and most damaging: two
    /// instruments' closes merged into one series produce a line that is not a
    /// price history of anything, and because a closed session is never
    /// re-fetched, whichever venue got there first owns that day forever.
    var mic: String? = nil
    /// Daily only, for now. Stored rather than assumed so an intraday interval
    /// can be added later without colliding with these rows.
    var interval: String
    /// Midnight UTC of the session. The uniqueness key, so it must be built
    /// the same way every time — see `CandleStore.sessionDate(_:)`.
    var date: Date

    var open: Decimal
    var high: Decimal
    var low: Decimal
    var close: Decimal
    var volume: Int

    /// Which provider it came from, for diagnosing a series that disagrees with
    /// itself after a provider change.
    var source: String
    var createdAt: Date

    /// What this row is history for.
    var listing: ListingID { ListingID(symbol: symbol, mic: mic) }

    init(
        symbol: String,
        mic: String? = nil,
        interval: String = CandleInterval.daily.rawValue,
        date: Date,
        open: Decimal,
        high: Decimal,
        low: Decimal,
        close: Decimal,
        volume: Int,
        source: String
    ) {
        self.symbol = symbol
        self.mic = mic
        self.interval = interval
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.source = source
        self.createdAt = Date()
    }

    var candle: Candle {
        Candle(date: date, open: open, high: high, low: low, close: close, volume: volume)
    }
}

enum CandleInterval: String, Sendable {
    case daily = "1day"
}
