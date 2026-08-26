import Foundation
import SwiftData

@Model
final class Asset {
    var id: UUID
    var symbol: String
    var name: String
    var assetClass: AssetClass
    var exchange: String
    var currency: String
    var sector: String
    var coingeckoID: String?
    var isWatchlisted: Bool
    var createdAt: Date

    /// The listing this row describes.
    ///
    /// `exchange` has held the MIC since `upsertAsset` started refusing to write
    /// a row without one, so this is a reading of what is already on disk, not a
    /// new field. It is also the evidence the backfill runs on — see
    /// `ListingBackfill`.
    var listing: ListingID { ListingID(symbol: symbol, mic: exchange) }

    init(
        symbol: String,
        name: String,
        assetClass: AssetClass,
        exchange: String = "",
        currency: String = "USD",
        sector: String = "",
        coingeckoID: String? = nil,
        isWatchlisted: Bool = false
    ) {
        self.id = UUID()
        self.symbol = symbol
        self.name = name
        self.assetClass = assetClass
        self.exchange = exchange
        self.currency = currency
        self.sector = sector
        self.coingeckoID = coingeckoID
        self.isWatchlisted = isWatchlisted
        self.createdAt = Date()
    }
}
