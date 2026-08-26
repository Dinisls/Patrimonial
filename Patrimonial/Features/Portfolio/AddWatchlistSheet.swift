import SwiftUI

/// Follow a ticker, through exactly the search the buy sheet uses.
///
/// Same provider, same ranking, same priced-top-results rule, same row. The one
/// thing that differs is what gets written: a watchlist flag instead of a
/// transaction. What does *not* differ is the requirement for a venue and a
/// currency — a followed ticker with neither cannot be priced any more reliably
/// than a bought one.
struct AddWatchlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var portfolio: PortfolioViewModel
    var watchlist: WatchlistViewModel
    /// Symbols already held, so the sheet can say a ticker is a position rather
    /// than silently adding an entry the list will then filter out.
    let openListings: Set<ListingID>

    @State private var query = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pesquisar") {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Ticker ou nome...", text: $query)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, newVal in
                                portfolio.searchTicker(newVal)
                            }
                        if portfolio.isSearching {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if !portfolio.searchResults.isEmpty {
                    Section("Resultados") {
                        ForEach(portfolio.visibleSearchResults) { result in
                            Button {
                                follow(result)
                            } label: {
                                HStack(spacing: 10) {
                                    AssetSearchResultRow(
                                        result: result,
                                        quote: portfolio.searchQuote(for: result),
                                        freshness: portfolio.searchFreshness(for: result),
                                        isPricing: portfolio.isPricingSearch
                                    )
                                    statusIcon(for: result)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isUnavailable(result))
                        }

                        // The deep venues stay reachable, one tap away, rather
                        // than being scrolled past on the way to the obvious
                        // listing.
                        if !portfolio.showAllSearchResults, portfolio.hiddenSearchResultCount > 0 {
                            Button {
                                portfolio.showAllSearchResults = true
                            } label: {
                                Label(
                                    "Ver mais \(portfolio.hiddenSearchResultCount) resultados",
                                    systemImage: "chevron.down"
                                )
                                .font(.system(size: 13))
                            }
                            .foregroundStyle(PB.accent)
                        }
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty
                            && !portfolio.isSearching {
                    Section {
                        Text("Sem resultados para \"\(query.trimmingCharacters(in: .whitespaces))\".")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(PB.neg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PB.bg.ignoresSafeArea())
            .navigationTitle("Seguir ativo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .tint(PB.accent)
        .onDisappear { portfolio.clearSearch() }
    }

    /// Says why a row cannot be tapped instead of leaving it inert.
    @ViewBuilder
    private func statusIcon(for result: AssetSearchResult) -> some View {
        if openListings.contains(listing(result)) {
            Text("Em carteira")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if watchlist.isWatchlisted(listing(result)) {
            Image(systemName: "eye.fill")
                .font(.system(size: 13))
                .foregroundStyle(PB.accent)
        } else if (result.mic ?? result.exchange).isEmpty || result.currency.isEmpty {
            // No venue or no currency: it cannot be routed to a provider, so
            // following it would produce a permanent dash.
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
        }
    }

    /// The listing a search row names. "Em carteira" and "já seguido" are
    /// questions about the listing, not the ticker: holding NVIDIA on XETRA must
    /// not grey out the NASDAQ namesake, which is a different instrument the
    /// user may perfectly well want to follow.
    private func listing(_ result: AssetSearchResult) -> ListingID {
        ListingID(symbol: result.symbol, mic: result.mic ?? result.exchange)
    }

    private func isUnavailable(_ result: AssetSearchResult) -> Bool {
        openListings.contains(listing(result))
            || watchlist.isWatchlisted(listing(result))
            || (result.mic ?? result.exchange).isEmpty
            || result.currency.isEmpty
    }

    private func follow(_ result: AssetSearchResult) {
        do {
            try watchlist.add(result, openListings: openListings)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
