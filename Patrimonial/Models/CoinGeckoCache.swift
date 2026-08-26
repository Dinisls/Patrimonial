import Foundation
import SwiftData

@Model
final class CoinGeckoCache {
    var coinID: String
    var symbol: String
    var name: String
    var marketCapRank: Int
    var updatedAt: Date

    init(coinID: String, symbol: String, name: String, marketCapRank: Int = Int.max) {
        self.coinID = coinID
        self.symbol = symbol.lowercased()
        self.name = name
        self.marketCapRank = marketCapRank
        self.updatedAt = Date()
    }
}
