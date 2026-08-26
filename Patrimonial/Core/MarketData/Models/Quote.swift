import Foundation

nonisolated struct Quote: Sendable {
    let symbol: String
    let price: Decimal
    /// The previous session's close, when the source reports one.
    ///
    /// Optional — ponto I. Two providers used to write `previous_close ?? price`
    /// at the parsing boundary, which converts "this source did not say" into a
    /// daily change of exactly zero. Zero is a claim: it says the instrument did
    /// not move. It then travelled through the entire per-lot session rule
    /// without tripping anything, because every step of that rule is arithmetic
    /// on a number that was already there.
    ///
    /// Nil instead, and the day change becomes nil with it — the position keeps
    /// its value and its P/L and simply has no "Hoje", which is the truth.
    let previousClose: Decimal?
    /// Both nil exactly when `previousClose` is: a change is a difference, and
    /// there is nothing to differ from.
    let changeAbsolute: Decimal?
    let changePercent: Decimal?
    let currency: String
    let timestamp: Date
    let source: QuoteSource

    /// The session this price closed on, for end-of-day sources. Deliberately
    /// separate from `timestamp`: `timestamp` is when *we* fetched, which is what
    /// "most recent wins" orders on, while this is what the number actually
    /// describes. Folding them together would make a close fetched today look
    /// older than a stale cache entry and never get applied.
    var closeDate: Date?

    /// The venue the provider says this price came from, when it says.
    ///
    /// The point of the field is that a quote can now be checked against the
    /// listing it was asked about. `NVD` is NVIDIA on XETRA and a 2x inverse ETF
    /// on NASDAQ; Twelve Data answered about the second while the position was
    /// the first, and reported `mic_code: XNMS` in the very same response. The
    /// field was there all along and was being discarded at decode.
    ///
    /// Nil from providers that do not report a venue (Finnhub reports none), so
    /// an absent value means "cannot be checked", never "checked and fine" —
    /// see `PriceStore.mayAskUSProviders`, which is what protects those.
    var venueMIC: String?

    var freshness: QuoteFreshness {
        // End-of-day data can never be live, no matter how recently it arrived.
        if source == .dailyClose {
            return .dailyClose(closeDate ?? timestamp)
        }

        let age = Date().timeIntervalSince(timestamp)
        switch source {
        case .websocket:
            return age < 30 ? .live : .stale
        case .rest:
            return age < 60 ? .delayed(15) : .stale
        case .cache, .dailyClose:
            return .stale
        }
    }
}

/// Persisted raw in `PriceSnapshot.sourceRaw` — cases may be added but never
/// removed or renamed, or previously stored snapshots stop decoding.
nonisolated enum QuoteSource: String, Sendable, Codable {
    case websocket
    case rest
    case cache
    /// Alpha Vantage's end-of-day close for European listings, which no free
    /// intraday source covers.
    case dailyClose
}

nonisolated enum QuoteFreshness: Sendable, Equatable {
    case live
    case delayed(Int)
    /// The market is shut right now.
    case closed
    /// The price itself is a settled close from the given session.
    case dailyClose(Date)
    case stale
    case unknown
}

nonisolated struct AssetSearchResult: Sendable, Identifiable {
    let symbol: String
    let name: String
    let exchange: String
    let assetClass: AssetClass
    let currency: String
    var mic: String?
    var coingeckoID: String?
    /// The provider's own classification, verbatim — "Common Stock", "ETF",
    /// "Depositary Receipt". Kept alongside `assetClass`, which collapses
    /// everything unrecognised into `.stock` and so cannot tell a share from a
    /// receipt over one. Search ranking needs that distinction to drop the
    /// wrappers.
    var instrumentType: String?

    /// The same ticker can be listed on several venues in different currencies
    /// (IWDA is XAMS/EUR *and* XLON/USD). Identity has to include the venue and
    /// currency, otherwise SwiftUI collapses the rows and the user cannot pick
    /// the line they actually hold.
    var id: String { "\(symbol)|\(mic ?? exchange)|\(currency)" }
}

nonisolated enum AssetClass: String, Codable, CaseIterable, Sendable {
    case stock
    case etf
    case crypto
    case bond
    case cash

    var displayName: String {
        switch self {
        case .stock: "Ações"
        case .etf: "ETF"
        case .crypto: "Cripto"
        case .bond: "Obrigações"
        case .cash: "Liquidez"
        }
    }
}

nonisolated struct Candle: Sendable, Equatable {
    let date: Date
    let open: Decimal
    let high: Decimal
    let low: Decimal
    let close: Decimal
    let volume: Int
}

// MARK: - Sub-unit currency normalization

/// Some exchanges quote prices in a sub-unit of the currency — pence instead
/// of pounds, cents instead of rand. Providers report the sub-unit code as the
/// currency (e.g. "GBp"), and treating it as the major unit makes every value
/// 100× wrong. Normalize at the parsing boundary: convert the code to the
/// major unit and divide the price.
nonisolated enum CurrencyNormalization {
    struct Result {
        let code: String
        let divisor: Decimal
    }

    static func normalize(_ raw: String) -> Result {
        switch raw {
        case "GBp", "GBX":  return Result(code: "GBP", divisor: 100)
        case "ZAc", "ZAR¢": return Result(code: "ZAR", divisor: 100)
        case "ILA":          return Result(code: "ILS", divisor: 100)
        default:             return Result(code: raw, divisor: 1)
        }
    }
}

nonisolated enum ChartRange: String, CaseIterable, Sendable {
    case oneDay = "1D"
    case oneWeek = "1S"
    case oneMonth = "1M"
    case oneYear = "1A"
    case max = "Máx"

    var finnhubResolution: String {
        switch self {
        case .oneDay: "5"
        case .oneWeek: "15"
        case .oneMonth: "60"
        case .oneYear: "D"
        case .max: "W"
        }
    }

    var fromDate: Date { cutoffDate(from: Date()) }

    func cutoffDate(from reference: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .oneDay: return cal.date(byAdding: .day, value: -1, to: reference)!
        case .oneWeek: return cal.date(byAdding: .day, value: -7, to: reference)!
        case .oneMonth: return cal.date(byAdding: .month, value: -1, to: reference)!
        case .oneYear: return cal.date(byAdding: .year, value: -1, to: reference)!
        case .max: return cal.date(byAdding: .year, value: -10, to: reference)!
        }
    }
}
