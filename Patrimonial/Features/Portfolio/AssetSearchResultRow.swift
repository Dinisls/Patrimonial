import SwiftUI

/// One line of ticker search results.
///
/// Shared by the buy sheet and the watchlist sheet so both show the same thing:
/// the same ranking, the same price rules, and — the part that matters — the
/// same `currency · MIC` line. Following a ticker without its venue is the same
/// mistake as buying one without it.
struct AssetSearchResultRow: View {
    let result: AssetSearchResult
    let quote: Quote?
    let freshness: QuoteFreshness?
    /// True while prices for the top results are still in flight, so a row with
    /// no quote yet shows a spinner rather than a dash it may not deserve.
    let isPricing: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PB.text)
                Text(result.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                priceLabel
                // MIC disambiguates same-ticker listings:
                // IWDA is XAMS in EUR and XLON in USD.
                Text("\(result.currency.isEmpty ? "—" : result.currency) · \(result.mic ?? result.exchange)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The current price of a result row, in the listing's own currency.
    ///
    /// A missing price is a dash, never 0,00 — the same rule the portfolio
    /// follows. European listings show the settled close and the session it
    /// belongs to, because that is what the data actually is.
    @ViewBuilder
    private var priceLabel: some View {
        if let quote {
            if case .dailyClose(let date) = freshness {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Self.formatNative(quote.price, currency: quote.currency))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    Text("fecho \(FreshnessIndicator.closeDateLabel(date))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(Self.formatNative(quote.price, currency: quote.currency))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
        } else if isPricing {
            ProgressView().controlSize(.mini)
        } else if hasNoQuoteRoute {
            // Said before the purchase, not after. A dash on this row normally
            // means "not priced yet"; on a venue no provider reaches it means
            // "never will be", and those two must not look the same — buying on
            // the strength of the first one buys a position condemned to a
            // dash. Crypto is exempt: it is routed by coin id, not by venue.
            Text("sem cotação")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        } else {
            Text("—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// True when no provider can price this listing's venue — see
    /// `MarketCalendar.hasQuoteRoute(mic:)`.
    var hasNoQuoteRoute: Bool {
        guard result.assetClass != .crypto else { return false }
        return !MarketCalendar.hasQuoteRoute(mic: result.mic ?? result.exchange)
    }

    /// Up to 8 decimals so a crypto price is not rounded into meaninglessness.
    ///
    /// The currency is part of the number, not decoration. A bare "313,33" next
    /// to a euro-denominated app reads as euros, and since this value
    /// pre-fills the unit price, misreading it writes a wrong cost basis into
    /// the portfolio. Apple's NASDAQ close is 313,33 **USD**.
    static func formatNative(_ value: Decimal, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = value < 1 ? 8 : 2
        guard let number = f.string(from: value as NSDecimalNumber) else { return "—" }
        return currency.isEmpty ? number : "\(number) \(currency)"
    }
}
