import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// Driven by the real Twelve Data response for "AAPL" — 38 rows, captured
/// live. The clutter in these tests is the clutter the user actually saw.
struct SearchRankingTests {

    private func liveAAPLResults() throws -> [AssetSearchResult] {
        let bundle = Bundle(for: RankingBundleToken.self)
        guard let url = bundle.url(forResource: "twelvedata_search_aapl", withExtension: "json")
        else {
            struct FixtureNotFound: Error {}
            throw FixtureNotFound()
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(TwelveDataSearchResponse.self, from: data)
        return decoded.data.compactMap { $0.toSearchResult() }
    }

    private func ranked() throws -> [AssetSearchResult] {
        SearchRanking.rank(try liveAAPLResults(), query: "AAPL")
    }

    // MARK: - Exclusions

    /// The structured notes. Eight of them come back for "AAPL" — Barclays,
    /// JPMorgan, Goldman, Citi — none of which is Apple. Twelve Data files them
    /// as "Mutual Fund", so only the payoff language in the name gives them
    /// away.
    @Test func structuredNotesAreDiscarded() throws {
        let symbols = try ranked().map(\.symbol)
        for note in ["AAPLDXX", "AAPLIXX", "AAPLJXX", "AAPLOXX", "AAPLVXX", "AAPLWXX", "AAPLYXX"] {
            #expect(!symbols.contains(note), "\(note) is a structured note, not Apple")
        }
        // The one the user named, specifically.
        #expect(!(try ranked().contains { $0.name.contains("Capped Point to Point") }))
        // And the one that carries none of the obvious markers: JPMorgan's
        // "Dual Directional Buffer Note" has no "capped" and no "point to
        // point" in its name, and slipped through the first pass.
        #expect(!(try ranked().contains { $0.name.contains("Dual Directional") }))
    }

    /// Depositary receipts are **kept**. A CEDEAR or a BDR is the asset bought
    /// another way — it can be held as a real position, and the portfolio
    /// prices it — so it belongs at the bottom of the list, not in the bin.
    /// Filtering them out took AAPL.BA and the Canadian line with it.
    @Test func depositaryReceiptsAreKeptNotDiscarded() throws {
        let symbols = try ranked().map(\.symbol)
        // Argentine CEDEARs, Thai DRs, a Brazilian BDR.
        for receipt in ["AAPLC", "AAPLD", "AAPL19", "AAPL01", "AAPL03", "AAPL34", "AAPL80"] {
            #expect(symbols.contains(receipt), "\(receipt) is the asset, bought another way")
        }
        // And the exact-ticker receipts: Buenos Aires and the two Canadian
        // venues.
        let exact = try ranked().filter { $0.symbol == "AAPL" }
        #expect(exact.contains { $0.mic == "XBUE" })
        #expect(exact.contains { $0.mic == "XTSE" })
    }

    /// Leveraged and derivative funds are **kept**. They are real, listed,
    /// buyable instruments — this portfolio holds QQQ3 and 3GOL — so no search
    /// may erase them. Searching AAPL simply is not asking for them, which is
    /// a question of order, not of existence.
    @Test func leveragedFundsAreKeptNotDiscarded() throws {
        let symbols = try ranked().map(\.symbol)
        for fund in ["AAPD", "AAPU", "AAPB", "AAPE", "APLY", "AAPW", "IOSX"] {
            #expect(symbols.contains(fund), "\(fund) is a real instrument and must survive")
        }
    }

    /// …and they rank below every plain Apple listing, including the receipts.
    @Test func leveragedFundsRankBelowThePlainListings() throws {
        let results = try ranked()
        let firstDerivative = try #require(
            results.firstIndex { SearchRanking.isDerivativeFund($0) }
        )
        let lastPlain = try #require(
            results.lastIndex { !SearchRanking.isDerivativeFund($0) }
        )
        #expect(firstDerivative > lastPlain,
                "every derivative fund must follow every ordinary listing")
        // Concretely: the NASDAQ share leads, Direxion's 2x does not.
        #expect(results.first?.symbol == "AAPL")
    }

    /// The case the name filter got wrong: a search that does not name the
    /// ticker. "WisdomTree" and "gold 3x" are how anyone looks for an
    /// instrument whose symbol they do not know by heart, and the filter
    /// deleted the answer both times.
    @Test func aLeveragedETPSurvivesASearchByName() {
        let rows = [
            AssetSearchResult(symbol: "SGLN", name: "iShares Physical Gold ETC",
                              exchange: "LSE", assetClass: .etf, currency: "GBP", mic: "XLON"),
            AssetSearchResult(symbol: "3GOL", name: "WisdomTree Gold 3x Daily Leveraged",
                              exchange: "LSE", assetClass: .etf, currency: "GBP", mic: "XLON"),
        ]
        for query in ["WisdomTree", "gold 3x"] {
            let ranked = SearchRanking.rank(rows, query: query)
            #expect(ranked.contains { $0.symbol == "3GOL" },
                    "searching \"\(query)\" must still find 3GOL")
        }
    }

    /// The demotion, isolated so that nothing else can produce the answer.
    ///
    /// The two rows are arranged so every *other* rule ranks the leveraged ETP
    /// first: it is on Lisbon, the top venue in the preferred group, and it is
    /// the primary listing of its own ticker; the plain ETC sits on Frankfurt,
    /// a secondary venue in the last group. Neither symbol matches the query,
    /// so identity does not intervene. Ordering the ETC first is therefore
    /// something only the derivative demotion can do — with that one comparison
    /// removed, the venue rule fires and the order flips.
    @Test func onlyTheDemotionCanPutThePlainAssetAboveALeveragedOne() {
        let rows = [
            AssetSearchResult(symbol: "3GOL", name: "WisdomTree Gold 3x Daily Leveraged",
                              exchange: "Euronext Lisbon", assetClass: .etf,
                              currency: "EUR", mic: "XLIS"),
            AssetSearchResult(symbol: "SGLD", name: "Invesco Physical Gold",
                              exchange: "Frankfurt", assetClass: .etf,
                              currency: "EUR", mic: "XFRA"),
        ]
        #expect(SearchRanking.rank(rows, query: "gold").map(\.symbol) == ["SGLD", "3GOL"])
    }

    /// An exact ticker outranks the demotion: searching the leveraged ETP by
    /// its own symbol puts it first, exactly as searching AAPL does for Apple.
    @Test func anExactTickerPutsTheLeveragedETPFirst() {
        let rows = [
            AssetSearchResult(symbol: "QQQ", name: "Invesco QQQ Trust Series 1",
                              exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNGS"),
            AssetSearchResult(symbol: "QQQ3", name: "Leverage Shares 3x Long Nasdaq 100 ETP",
                              exchange: "LSE", assetClass: .etf, currency: "GBP", mic: "XLON"),
        ]
        #expect(SearchRanking.rank(rows, query: "QQQ3").first?.symbol == "QQQ3")
        // And the reverse still holds: QQQ means the tracker, not the 3x.
        #expect(SearchRanking.rank(rows, query: "QQQ").first?.symbol == "QQQ")
    }

    /// Tokenized wrappers track a share without being one.
    @Test func tokenizedWrappersAreDiscarded() {
        let tokenized = [
            AssetSearchResult(symbol: "AAPLX", name: "Apple xStock", exchange: "X",
                              assetClass: .stock, currency: "USD", mic: "XNGS"),
            AssetSearchResult(symbol: "AAPLON", name: "Ondo Tokenized Stock Apple",
                              exchange: "X", assetClass: .stock, currency: "USD", mic: "XNGS"),
            AssetSearchResult(symbol: "AAPLT", name: "Apple Inc. Tokenized Share",
                              exchange: "X", assetClass: .stock, currency: "USD", mic: "XNGS"),
        ]
        #expect(SearchRanking.rank(tokenized, query: "AAPL").isEmpty)
    }

    /// Exclusion is not over-eager: the plain listings survive.
    @Test func ordinaryListingsAreKept() throws {
        let symbols = try ranked().map(\.symbol)
        #expect(symbols.contains("AAPL"))
        #expect(symbols.filter { $0 == "AAPL" }.count >= 5)
    }

    // MARK: - Ordering

    /// The headline: what the user sees first is a real Apple listing, not a
    /// Thai receipt.
    @Test func theFirstRowIsAnExactAppleListing() throws {
        let first = try #require(try ranked().first)
        #expect(first.symbol == "AAPL")
        #expect(first.name.contains("Apple"))
    }

    /// Exact ticker before near misses, across venue groups. This is the rule
    /// that has to outrank the venue ordering: applied the other way round, a
    /// European `AAPL01` would sit above the NASDAQ `AAPL`.
    @Test func exactSymbolsComeBeforeApproximations() throws {
        let symbols = try ranked().map(\.symbol)
        let lastExact = symbols.lastIndex(of: "AAPL")!
        for approximate in ["AAPL1", "AAPLCL", "AAPLCL1", "AAPLUSTRAD"] {
            if let index = symbols.firstIndex(of: approximate) {
                #expect(index > lastExact, "\(approximate) must follow every exact AAPL")
            }
        }
    }

    /// The primary listing wins, ahead of the regional order.
    ///
    /// Apple's home venue is NASDAQ, and the Swiss line is a cross-listing.
    /// Ranking Europe first put XSWX above XNGS, which is not what searching
    /// AAPL means — the geographic order is for sorting *secondary* venues.
    @Test func theHomeListingLeadsEvenWhenItIsNotEuropean() throws {
        let exact = try ranked().filter { $0.symbol == "AAPL" }
        let first = try #require(exact.first)
        #expect(first.mic == "XNGS")
        // Europe still leads everything below the primary.
        let secondary = Array(exact.dropFirst())
        #expect(secondary.first?.mic == "XSWX")
        #expect(SearchRanking.venue(for: secondary.first?.mic ?? "").group == .europe)
    }

    /// The same rule for a European instrument: XETRA is QDVE's home, and the
    /// four secondary German venues follow it.
    @Test func theHomeListingLeadsForAEuropeanInstrument() {
        let mics = ["XHAM", "XFRA", "XETR", "XMUN", "XDUS"]
        let results = mics.map {
            AssetSearchResult(symbol: "QDVE", name: "iShares S&P 500 IT", exchange: $0,
                              assetClass: .etf, currency: "EUR", mic: $0)
        }
        let ordered = SearchRanking.rank(results, query: "QDVE").compactMap(\.mic)
        #expect(ordered == ["XETR", "XFRA", "XMUN", "XDUS", "XHAM"])
    }

    /// And for a Portuguese one, where the home venue is also the top of the
    /// regional order, so both rules agree.
    @Test func lisbonLeadsForAPortugueseInstrument() {
        let results = [
            AssetSearchResult(symbol: "GALP", name: "Galp Energia", exchange: "XMUN",
                              assetClass: .stock, currency: "EUR", mic: "XMUN"),
            AssetSearchResult(symbol: "GALP", name: "Galp Energia", exchange: "XLIS",
                              assetClass: .stock, currency: "EUR", mic: "XLIS"),
        ]
        #expect(SearchRanking.rank(results, query: "GALP").first?.mic == "XLIS")
    }

    /// Beneath the primary, the regional order applies in full: Europe, then
    /// the US, then Canada, then Asia, then the rest. Synthetic because the
    /// live AAPL response has no Tokyo listing.
    @Test func secondaryVenuesFollowTheRegionalOrder() {
        let mics = ["XBKK", "XTKS", "XTSE", "XNGS", "XLIS", "XSWX"]
        let results = mics.map {
            AssetSearchResult(symbol: "TEST", name: "Test Inc", exchange: $0,
                              assetClass: .stock, currency: "EUR", mic: $0)
        }
        let ordered = SearchRanking.rank(results, query: "TEST").compactMap(\.mic)
        // XNGS is the primary; everything after it is regional order.
        #expect(ordered == ["XNGS", "XLIS", "XSWX", "XTSE", "XTKS", "XBKK"])
    }

    /// Vienna and Warsaw are European venues and rank as such, below the named
    /// markets but above the Americas.
    @Test func viennaAndWarsawCountAsEuropean() {
        #expect(SearchRanking.venue(for: "XWBO").group == .europe)
        #expect(SearchRanking.venue(for: "XWAR").group == .europe)

        let mics = ["XBOG", "XWAR", "XWBO", "XSWX"]
        let results = mics.map {
            AssetSearchResult(symbol: "TEST", name: "Test Inc", exchange: $0,
                              assetClass: .stock, currency: "EUR", mic: $0)
        }
        let ordered = SearchRanking.rank(results, query: "TEST").compactMap(\.mic)
        #expect(ordered == ["XSWX", "XWBO", "XWAR", "XBOG"])
    }

    /// Inside the US group, the NASDAQ Global Select tier leads.
    @Test func nasdaqGlobalSelectLeadsTheUSVenues() {
        let mics = ["BATS", "XNYS", "XNGS", "ARCX"]
        let results = mics.map {
            AssetSearchResult(symbol: "AAPL", name: "Apple Inc.", exchange: $0,
                              assetClass: .stock, currency: "USD", mic: $0)
        }
        let ordered = SearchRanking.rank(results, query: "AAPL").compactMap(\.mic)
        #expect(ordered == ["XNGS", "XNYS", "ARCX", "BATS"])
    }

    /// Ordering is stable: the same query twice gives the same list, so the row
    /// under the user's finger does not move.
    @Test func orderingIsStable() throws {
        let once = try ranked().map(\.id)
        let twice = try ranked().map(\.id)
        #expect(once == twice)
    }

    // MARK: - Crypto

    /// The BTC list as it actually came back: CoinGecko's Bitcoin arrives last,
    /// behind four exchange-traded things whose ticker is also BTC.
    ///
    /// Every one of these is a real instrument that must stay in the list —
    /// nothing here is excluded, only ordered.
    private func btcResults() -> [AssetSearchResult] {
        [
            AssetSearchResult(symbol: "BTC", name: "Grayscale Bitcoin Mini Trust",
                              exchange: "NYSE Arca", assetClass: .etf,
                              currency: "USD", mic: "ARCX"),
            AssetSearchResult(symbol: "BTC", name: "Melanion Bitcoin Equities ETF",
                              exchange: "Euronext Paris", assetClass: .etf,
                              currency: "EUR", mic: "XPAR"),
            AssetSearchResult(symbol: "BTC", name: "Vinanz Limited",
                              exchange: "LSE", assetClass: .stock,
                              currency: "GBP", mic: "XLON"),
            AssetSearchResult(symbol: "BTC", name: "BTC Health Ltd",
                              exchange: "ASX", assetClass: .stock,
                              currency: "AUD", mic: "XASX"),
            AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "",
                              assetClass: .crypto, currency: "EUR",
                              coingeckoID: "bitcoin"),
        ]
    }

    /// The bug, stated as the user stated it: searching BTC leads with Bitcoin.
    @Test func anExactTickerPutsTheCoinFirst() {
        let ranked = SearchRanking.rank(btcResults(), query: "BTC")
        #expect(ranked.first?.assetClass == .crypto)
        #expect(ranked.first?.name == "Bitcoin")
        // And nothing was dropped to achieve it — the funds and the companies
        // are all still there, just below.
        #expect(ranked.count == 5)
    }

    /// The same rule with a different coin, so the answer cannot be an accident
    /// of one fixture's order: ETH means Ethereum, not the fund named after it.
    @Test func theCoinLeadsForEveryExactTicker() {
        let rows = [
            AssetSearchResult(symbol: "ETH", name: "21Shares Ethereum Staking ETP",
                              exchange: "Xetra", assetClass: .etf,
                              currency: "EUR", mic: "XETR"),
            AssetSearchResult(symbol: "ETH", name: "Ethereum", exchange: "",
                              assetClass: .crypto, currency: "EUR",
                              coingeckoID: "ethereum"),
        ]
        #expect(SearchRanking.rank(rows, query: "ETH").first?.assetClass == .crypto)
    }

    /// Only the coin rule can produce that order.
    ///
    /// Every other comparison ranks the ETF first: it is the primary listing of
    /// its ticker (the coin has no MIC, so it falls to the bottom of the global
    /// precedence), it sits on XETR in the preferred region, and it arrived
    /// first. Both symbols match the query exactly, so identity does not
    /// separate them either. With the coin comparison removed the ETF wins,
    /// which is what made this a bug in the first place.
    @Test func onlyTheCoinRuleCanPutBitcoinAboveTheFundsNamedAfterIt() {
        let rows = [
            AssetSearchResult(symbol: "BTC", name: "Melanion Bitcoin Equities ETF",
                              exchange: "Xetra", assetClass: .etf,
                              currency: "EUR", mic: "XETR"),
            AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "",
                              assetClass: .crypto, currency: "EUR",
                              coingeckoID: "bitcoin"),
        ]
        #expect(SearchRanking.rank(rows, query: "BTC").map(\.name) == ["Bitcoin", "Melanion Bitcoin Equities ETF"])
    }

    /// The promotion is an *exact ticker* rule, not a preference for crypto.
    /// Searching a name still ranks by everything else, so a coin cannot jump
    /// a company that is the actual match.
    @Test func aCoinIsNotPromotedOnANameSearch() {
        let rows = [
            AssetSearchResult(symbol: "ADE", name: "Bitcoin Group SE",
                              exchange: "Xetra", assetClass: .stock,
                              currency: "EUR", mic: "XETR"),
            AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "",
                              assetClass: .crypto, currency: "EUR",
                              coingeckoID: "bitcoin"),
        ]
        #expect(SearchRanking.rank(rows, query: "Bitcoin Group").first?.symbol == "ADE")
    }

    /// The ghost row: Twelve Data returns "BTC · Bitcoin · EUR" as an ordinary
    /// instrument. It is the same asset as CoinGecko's Bitcoin and it never
    /// gets a price, so it would sit directly under the coin as a duplicate
    /// with a dash. One of the two survives, and it is the one that quotes.
    @Test func theEquityEchoOfACoinIsRemoved() {
        let rows = btcResults() + [
            AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "Binance",
                              assetClass: .stock, currency: "EUR",
                              instrumentType: "Digital Currency"),
        ]
        let ranked = SearchRanking.rank(rows, query: "BTC")
        let bitcoins = ranked.filter { $0.name == "Bitcoin" }
        #expect(bitcoins.count == 1)
        #expect(bitcoins.first?.assetClass == .crypto)
        #expect(bitcoins.first?.coingeckoID == "bitcoin")
    }

    /// Dedup matches ticker *and* name together. A company that merely shares a
    /// coin's ticker is a different instrument and keeps its row — losing
    /// Vinanz or BTC Health to a search for BTC would be the same class of bug
    /// as burying Bitcoin.
    @Test func anEquitySharingACoinsTickerIsKept() {
        let ranked = SearchRanking.rank(btcResults(), query: "BTC")
        #expect(ranked.contains { $0.name == "Vinanz Limited" })
        #expect(ranked.contains { $0.name == "BTC Health Ltd" })
        #expect(ranked.contains { $0.name == "Grayscale Bitcoin Mini Trust" })
    }

    // MARK: - Paging

    /// Eight rows to start, the rest one tap away — never discarded.
    @Test func theListStartsShortAndKeepsEverythingAvailable() throws {
        let all = try ranked()
        #expect(all.count > SearchRanking.initialDisplayCount)
        #expect(SearchRanking.initialDisplayCount == 8)
    }

    /// The instrument the search is for must be reachable without expanding.
    @Test func theWantedListingIsVisibleWithoutTappingVerMais() throws {
        let visible = try ranked().prefix(SearchRanking.initialDisplayCount)
        #expect(visible.contains { $0.symbol == "AAPL" && $0.mic == "XNGS" })
    }
}

private class RankingBundleToken {}

// MARK: - Through the screen

/// The ranking tests above call `SearchRanking.rank` directly, which proves the
/// comparator and nothing about the list the user sees: the rows reach the
/// screen through `PriceStore.search`, which fetches equities and crypto from
/// two different providers and concatenates them, and then through
/// `PortfolioViewModel.searchResults`, which is the property the search view
/// actually reads. This drives that whole path with both halves stubbed —
/// equities arriving first and the coin arriving last, exactly as the live log
/// showed.
@MainActor
struct SearchResultsThroughTheViewModelTests {

    /// The four exchange-traded things whose ticker is BTC.
    private static let equities = [
        AssetSearchResult(symbol: "BTC", name: "Grayscale Bitcoin Mini Trust",
                          exchange: "NYSE Arca", assetClass: .etf,
                          currency: "USD", mic: "ARCX"),
        AssetSearchResult(symbol: "BTC", name: "Melanion Bitcoin Equities ETF",
                          exchange: "Euronext Paris", assetClass: .etf,
                          currency: "EUR", mic: "XPAR"),
        AssetSearchResult(symbol: "BTC", name: "Vinanz Limited",
                          exchange: "LSE", assetClass: .stock,
                          currency: "GBP", mic: "XLON"),
        // The ghost: Twelve Data files the coin itself as an ordinary
        // instrument, and it never gets a price.
        AssetSearchResult(symbol: "BTC", name: "Bitcoin", exchange: "Binance",
                          assetClass: .stock, currency: "EUR",
                          instrumentType: "Digital Currency"),
    ]

    private static let coin = AssetSearchResult(
        symbol: "BTC", name: "Bitcoin", exchange: "",
        assetClass: .crypto, currency: "EUR", coingeckoID: "bitcoin"
    )

    private func searchedResults() async throws -> [AssetSearchResult] {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = PriceStore()
        var equityProvider = MockMarketDataProvider()
        equityProvider.mockSearchResults = Self.equities
        var cryptoProvider = MockMarketDataProvider()
        cryptoProvider.mockSearchResults = [Self.coin]
        store.configure(
            provider: MockMarketDataProvider(),
            cryptoProvider: cryptoProvider,
            equitySearchProvider: equityProvider.asSearchProvider,
            modelContext: ctx
        )
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        vm.searchTicker("BTC")
        // The view model debounces by 300 ms before it calls the store, so the
        // wait is for the results to land, not for a fixed delay.
        for _ in 0..<100 where vm.searchResults.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        return vm.searchResults
    }

    /// The assertion that was missing: the property the search screen reads has
    /// the coin at index 0.
    @Test func searchingBTCPutsTheCoinAtTheTopOfTheList() async throws {
        let results = try await searchedResults()
        #expect(results.first?.assetClass == .crypto)
        #expect(results.first?.coingeckoID == "bitcoin")
    }

    /// And the duplicate that would sit right under it is gone, while the
    /// genuinely different instruments are all still on screen.
    @Test func theListShowsOneBitcoinAndKeepsTheRest() async throws {
        let results = try await searchedResults()
        #expect(results.filter { $0.name == "Bitcoin" }.count == 1)
        #expect(results.contains { $0.name == "Grayscale Bitcoin Mini Trust" })
        #expect(results.contains { $0.name == "Melanion Bitcoin Equities ETF" })
        #expect(results.contains { $0.name == "Vinanz Limited" })
        #expect(results.count == 4)
    }
}
