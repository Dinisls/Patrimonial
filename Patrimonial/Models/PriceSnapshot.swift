import Foundation
import SwiftData

@Model
final class PriceSnapshot {
    var symbol: String
    var price: Decimal
    /// Optional, matching `Quote` — ponto I. Making an existing attribute
    /// optional is the direction SwiftData migrates lightly: rows already on
    /// disk keep their value, and rows written from now on can record that the
    /// source had no previous close instead of recording that the instrument
    /// did not move.
    var previousClose: Decimal?
    var changeAbsolute: Decimal?
    var changePercent: Decimal?
    var currency: String
    var timestamp: Date
    var sourceRaw: String
    var updatedAt: Date
    /// Optional so existing stores migrate without a schema version bump.
    var closeDate: Date? = nil
    /// The venue this price is for. Same rules as `FinancialTransaction.assetMIC`
    /// — optional, no unique attribute, uniqueness enforced in code.
    ///
    /// Without it a cached price is keyed by ticker, which is how NVD's 3,97 USD
    /// from a NASDAQ ETF sat in the row a XETRA position read on every launch.
    /// The currency purge in `hydrateFromCache` catches that particular one
    /// because the currencies contradict; two listings in the *same* currency
    /// would have overwritten each other in silence.
    var mic: String? = nil

    /// What this row is a price for.
    var listing: ListingID { ListingID(symbol: symbol, mic: mic) }

    var source: QuoteSource {
        QuoteSource(rawValue: sourceRaw) ?? .cache
    }

    init(quote: Quote, listing: ListingID) {
        self.symbol = listing.symbol
        self.mic = listing.mic
        self.price = quote.price
        self.previousClose = quote.previousClose
        self.changeAbsolute = quote.changeAbsolute
        self.changePercent = quote.changePercent
        self.currency = quote.currency
        self.timestamp = quote.timestamp
        self.sourceRaw = quote.source.rawValue
        self.updatedAt = Date()
        self.closeDate = quote.closeDate
    }

    /// A daily close stays a daily close after a relaunch. Flattening it to
    /// `.cache` like everything else would drop the session date the position
    /// row has to show, and would relabel a settled close as merely stale.
    func toQuote() -> Quote {
        Quote(
            symbol: symbol,
            price: price,
            previousClose: previousClose,
            changeAbsolute: changeAbsolute,
            changePercent: changePercent,
            currency: currency,
            timestamp: timestamp,
            source: source == .dailyClose ? .dailyClose : .cache,
            closeDate: closeDate
        )
    }

    func update(from quote: Quote) {
        self.price = quote.price
        self.previousClose = quote.previousClose
        self.changeAbsolute = quote.changeAbsolute
        self.changePercent = quote.changePercent
        self.currency = quote.currency
        self.timestamp = quote.timestamp
        self.sourceRaw = quote.source.rawValue
        self.updatedAt = Date()
        self.closeDate = quote.closeDate
    }
}
