import SwiftUI

/// Tickers followed without a position.
///
/// Deliberately outside every portfolio total: a watchlist entry is a thing the
/// user is looking at, not a thing they own, and letting it into the value or
/// the allocation would invent a holding. The only thing it shares with the
/// positions is the price engine.
struct WatchlistTabView: View {
    @Bindable var watchlist: WatchlistViewModel
    var portfolio: PortfolioViewModel
    @Binding var showAdd: Bool

    var body: some View {
        Group {
            if watchlist.entries.isEmpty {
                ContentUnavailableView {
                    Label("Sem ativos seguidos", systemImage: "eye")
                } description: {
                    Text("Segue um ativo para acompanhar a cotação sem ter posição. Não conta para o valor da carteira.")
                } actions: {
                    Button("Seguir ativo") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                        .tint(PB.accent)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    HStack(spacing: 6) {
                        Text("SEGUIDOS")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        // These rows carry dots too, so the legend has to be
                        // reachable from here and not only from the portfolio.
                        FreshnessLegendButton()
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    VStack(spacing: 0) {
                        ForEach(Array(watchlist.entries.enumerated()), id: \.element.id) { i, asset in
                            NavigationLink(value: WatchlistRoute(listing: asset.listing)) {
                                row(asset)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    watchlist.remove(listing: asset.listing)
                                } label: {
                                    Label("Deixar de seguir", systemImage: "eye.slash")
                                }
                            }
                            if i < watchlist.entries.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(
                        Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Text("Os ativos seguidos não entram no valor nem na alocação da carteira.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    Spacer(minLength: 100)
                }
            }
        }
    }

    private func row(_ asset: Asset) -> some View {
        let quote = watchlist.quote(for: asset)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(asset.symbol)
                        .font(.system(size: 16, weight: .semibold))
                    if let freshness = watchlist.freshness(for: asset) {
                        FreshnessIndicator(freshness: freshness)
                    }
                }
                Text("\(asset.name.isEmpty ? asset.assetClass.displayName : asset.name) · \(asset.exchange)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // No price is a dash, never a zero — the same rule the
                // positions follow.
                if let quote {
                    Text(AssetSearchResultRow.formatNative(quote.price, currency: asset.currency))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    changeLabel(quote)
                } else {
                    Text("—")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// Day change in the listing's own currency. Nothing here is converted:
    /// there is no position, so there is no euro figure to be consistent with.
    @ViewBuilder
    private func changeLabel(_ quote: Quote) -> some View {
        // No previous close means no day change to report, and the row simply
        // does not carry one. It used to be able to arrive here as a fabricated
        // 0,00 % that read as a flat day.
        if let previousClose = quote.previousClose, previousClose > 0,
           let changeAbsolute = quote.changeAbsolute,
           let changePercent = quote.changePercent {
            let positive = changeAbsolute >= 0
            Text("\(positive ? "+" : "−")\(formatPercent(changePercent))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(positive ? PB.pos : PB.neg)
        }
    }

    private func formatPercent(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let magnitude = value < 0 ? -value : value
        return (f.string(from: magnitude as NSDecimalNumber) ?? "0") + "%"
    }
}

/// Navigation route for a followed listing. Distinct from the position route,
/// which is keyed by holding — a watchlist entry has no account and no holding
/// to be keyed by.
struct WatchlistRoute: Hashable {
    let listing: ListingID
}
