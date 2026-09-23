import SwiftUI
import os.log

struct PositionRowView: View {
    private static let log = Logger(subsystem: "pt.patrimonial", category: "row-layout")
    let holding: Holding
    let privacyMode: Bool
    /// The change over the period selected in the header, already computed by
    /// the ViewModel from the same inputs the header total uses. Nil means the
    /// position has no reference close inside the period, and the row says so
    /// with a dash rather than falling back to some other number.
    let periodChange: PortfolioViewModel.PeriodChange?
    /// The period that figure belongs to, e.g. "1M". Load-bearing: `+3,42%`
    /// with no interval named is a different claim every time the picker moves,
    /// and the row is the only place that can say which one it is.
    let periodLabel: String
    /// Computed by the store against the market calendar, not derived here —
    /// the view has no business deciding whether a market is open.
    let freshness: QuoteFreshness?

    var body: some View {
        HStack(spacing: 14) {
            symbolAvatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(holding.assetSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .fixedSize()
                    // The venue, where it is known. Two rows reading `NVD` with
                    // different prices is exactly what ponto F makes possible,
                    // and without this they are indistinguishable — the user
                    // would see the app inventing a duplicate. On the title line
                    // rather than in the subtitle because the subtitle is the
                    // line that has to truncate.
                    if let mic = holding.assetMIC {
                        Text(mic)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(PB.text2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(PB.text2.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                    if let freshness {
                        FreshnessIndicator(freshness: freshness)
                    }
                }
                // What is held, and where. The close date used to be prefixed
                // onto this line and it pushed the line past the available
                // width: middle truncation then ate `2 un`, so the row named a
                // position without saying how much of it was held. The date is
                // a fact about the price, not about the holding, and it now sits
                // under the price where it belongs — which also leaves this line
                // short enough to survive intact on every width.
                Text("\(formattedQuantity) un · \(holding.accountName)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .background(GeometryReader { geo in
                        Color.clear.onAppear {
                            Self.log.info("\(holding.assetSymbol, privacy: .public) subtitle w=\(geo.size.width, format: .fixed(precision: 1)) h=\(geo.size.height, format: .fixed(precision: 1))")
                        }
                    })
            }
            // This side is the one that gives way, and it is the only side that
            // safely can: what it loses is the middle of a word. The first
            // attempt at "2 un · I" did the opposite — it gave this column the
            // priority — and the row rendered `388,30 €` one digit per line,
            // spilling out of the card. A number that wraps is unreadable; a
            // name that truncates is still a name.
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                if privacyMode {
                    Text("••••")
                        .font(.system(size: 16, weight: .semibold))
                } else if let mv = holding.marketValueEUR {
                    Text(formatDecimalEUR(mv))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                } else {
                    Text("—")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // The period's move, not the lifetime P/L. Whatever interval
                // the header is showing, this line reports the same one — a row
                // that answers a different question from the total above it is
                // how a screen starts lying quietly.
                if !privacyMode {
                    HStack(spacing: 4) {
                        Text(periodLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(PB.text2)
                        if let change = periodChange {
                            let positive = change.percent >= 0
                            Text(formatDecimalPct(change.percent))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(positive ? PB.pos : PB.neg)
                        } else {
                            Text("—")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }

                // Everything qualifying the price, on one line. Two lines would
                // make an end-of-day foreign holding taller than its neighbours,
                // and a list whose rows change height by the currency they are
                // quoted in is harder to scan than one that shrinks a caption.
                if let detail = priceQualifier {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        // Shrinks rather than truncates. On a 375 pt screen this
                        // line was ending "× 0,86…", which is not a shortened
                        // rate but a different one — the same class of lie as
                        // showing 1 for an unknown rate.
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear.onAppear {
                Self.log.info("\(holding.assetSymbol, privacy: .public) row w=\(geo.size.width, format: .fixed(precision: 1))")
            }
        })
    }

    /// What has to be said about the price for the euro figure above it to be
    /// checkable: the session it comes from, when it is a close, and the rate it
    /// was converted at, when it was converted.
    ///
    /// A euro figure derived from a foreign price is unverifiable on its own —
    /// 2 NVDA at 223,96 USD reads as 388,32 €, and nothing on screen separates
    /// that from an unconverted 194,16 USD per share. Euro holdings have nothing
    /// to disclose and get no caption. Hidden in privacy mode only for the part
    /// that carries a price; the close date stays, since a stale price looking
    /// current is a worse leak than none.
    private var priceQualifier: String? {
        var parts: [String] = []
        if case .dailyClose(let closeDate) = freshness {
            parts.append("Fecho \(FreshnessIndicator.closeDateLabel(closeDate))")
        }
        if !privacyMode,
           let native = holding.currentPriceNative,
           let rate = holding.currentFXRate,
           let currency = holding.currency,
           currency != "EUR", !currency.isEmpty {
            // The rate is printed with its own direction, not with an assumed
            // one: "223,96 USD × 0,8669" only means anything if that 0,8669 is
            // known to go from dollars into euros, and the row is the last place
            // that can still say so.
            parts.append(
                "\(formatDecimalNative(native)) \(rate.from) × \(formatRate(rate.value))"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var symbolAvatar: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(PB.accent.opacity(0.14))
            .frame(width: 40, height: 40)
            .overlay(
                Text(String(holding.assetSymbol.prefix(2)))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(PB.accent)
            )
    }

    private var formattedQuantity: String {
        let ns = holding.quantity as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        return formatter.string(from: ns) ?? "\(holding.quantity)"
    }

    private func formatDecimalEUR(_ value: Decimal) -> String {
        let ns = value as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: ns) ?? "—"
    }

    /// The quoted price in its own currency, matching the precision the search
    /// list uses so the two are comparable.
    private func formatDecimalNative(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = value < 1 ? 8 : 2
        return formatter.string(from: value as NSDecimalNumber) ?? "—"
    }

    /// Four decimals: ECB reference rates are published to five, and rounding a
    /// rate to two turns 0,8669 into 0,87 and moves the euro figure by a euro.
    private func formatRate(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "—"
    }

    private func formatDecimalPct(_ value: Decimal) -> String {
        let ns = value as NSDecimalNumber
        let sign = value >= 0 ? "+" : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return sign + (formatter.string(from: ns) ?? "0") + "%"
    }
}
