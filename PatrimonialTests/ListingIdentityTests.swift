import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - A quote must be about the listing it was asked about

/// The NVD bug, pinned at every level it can come back.
///
/// `NVD` is NVIDIA on XETRA at ~194 EUR **and** the GraniteShares 2x Short
/// NVIDIA ETF on NASDAQ at ~3,97 USD. Twelve Data and Finnhub both answer with
/// the NASDAQ one for a bare ticker, and neither can be told otherwise on a free
/// plan — `mic_code` is a paid parameter (verified live: 404 with an upgrade
/// notice). The provider was not malfunctioning; it answered correctly to a
/// question that could not name the venue.
///
/// The numbers below are the real ones from 2026-08-07.
@MainActor
struct ListingIdentityTests {

    private func quote(
        _ symbol: String, _ price: Decimal, _ currency: String, mic: String? = nil
    ) -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: price, changeAbsolute: 0,
            changePercent: 0, currency: currency, timestamp: Date(), source: .rest,
            venueMIC: mic
        )
    }

    // MARK: - B: the venue was in the response all along

    /// Twelve Data has always sent `mic_code`. It was decoded into nothing,
    /// which is why the collision was invisible: the evidence arrived in the
    /// same response as the wrong price.
    @Test func twelveDataQuoteCarriesItsVenue() throws {
        let json = Data("""
        {"symbol":"NVD","name":"GraniteShares 2x Short Nvidia ETF USD",
         "exchange":"NASDAQ","mic_code":"XNMS","currency":"USD",
         "close":"3.97000","previous_close":"4.16000",
         "change":"-0.18999982","percent_change":"-4.56730","timestamp":1786109400}
        """.utf8)

        let decoded = try JSONDecoder().decode(TwelveDataQuoteResponse.self, from: json)
        #expect(decoded.mic_code == "XNMS")

        let quote = try #require(decoded.toQuote())
        #expect(quote.venueMIC == "XNMS")
        #expect(quote.price == Decimal(string: "3.97"))
    }

    /// A reply with no venue field reports nil, not a guess. Absence has to stay
    /// distinguishable from agreement.
    @Test func aMissingVenueIsNilNotAssumed() throws {
        let json = Data(#"{"symbol":"AAPL","currency":"USD","close":"313.33"}"#.utf8)
        let quote = try #require(
            try JSONDecoder().decode(TwelveDataQuoteResponse.self, from: json).toQuote()
        )
        #expect(quote.venueMIC == nil)
    }

    /// The parsing boundary refuses a zero on its own, without relying on
    /// `applyQuote` downstream.
    @Test func twelveDataRefusesAZeroAtParseTime() throws {
        let json = Data(#"{"symbol":"QDVE","currency":"EUR","close":"0.00000"}"#.utf8)
        let decoded = try JSONDecoder().decode(TwelveDataQuoteResponse.self, from: json)
        #expect(decoded.toQuote() == nil)
    }

    // MARK: - A: a foreign venue never reaches the US-only providers

    /// The core fix. A XETRA position must not even be offered to Twelve Data
    /// or Finnhub — filtering their reply is not enough, because Finnhub
    /// reports no venue to filter on and returns the same 3,97.
    @Test func aEuropeanListingIsNeverAskedOfTheUSProviders() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let us = RecordingProvider(returns: [
            quote("NVD", Decimal(string: "3.97")!, "USD", mic: "XNMS")
        ])
        let av = RecordingProvider(returns: [
            quote("NVD.DE", Decimal(string: "194.22")!, "EUR")
        ])

        let store = PriceStore()
        store.configure(
            provider: us, fallbackProvider: us,
            europeanProvider: av, lastResortProvider: RecordingProvider(),
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "NVD", mic: "XETR"), currency: "EUR")

        await store.refresh([ListingID(symbol: "NVD", mic: "XETR")])

        #expect(us.received.isEmpty, "os providers americanos não podem ser perguntados")
        #expect(av.received == ["NVD.DE"])
        #expect(store.quote(for: ListingID(symbol: "NVD", mic: "XETR"))?.price == Decimal(string: "194.22"))
    }

    /// The whole chain, end to end: the wrong instrument's price must never
    /// reach a holding's market value. 2 × 3,97 = 7,94 € against a cost of
    /// 388,44 € is the −97,96 % that was on screen.
    @Test func theWrongInstrumentNeverReachesTheHolding() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let us = RecordingProvider(returns: [
            quote("NVD", Decimal(string: "3.97")!, "USD", mic: "XNMS")
        ])
        let av = RecordingProvider(returns: [
            quote("NVD.DE", Decimal(string: "194.22")!, "EUR")
        ])

        let store = PriceStore()
        store.configure(
            provider: us, fallbackProvider: us,
            europeanProvider: av, lastResortProvider: RecordingProvider(),
            modelContext: ctx
        )

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 2,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "NVIDIA Corporation", exchange: "XETR",
                assetClass: .stock, currency: "EUR", mic: "XETR"
            )
        )

        await store.refresh([ListingID(symbol: "NVD", mic: "XETR")])
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first)
        #expect(holding.marketValueEUR == Decimal(string: "388.44"))
        // The symptom, stated as the thing that must not happen.
        #expect(holding.unrealizedPLPercent == 0)
        #expect(holding.marketValueEUR != Decimal(string: "7.94"))
    }

    /// Twelve Data reports its venue, so even where it is legitimately asked, a
    /// reply about another exchange is refused — and, critically, does not count
    /// as coverage, so the venue-routed providers still get their turn.
    @Test func aContradictingVenueIsRefusedAndDoesNotBlockTheFallback() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        // Recorded on NYSE; the provider answers about a Frankfurt listing.
        let us = RecordingProvider(returns: [
            quote("XYZ", Decimal(string: "12.00")!, "EUR", mic: "XFRA")
        ])
        let yahoo = RecordingProvider(returns: [
            quote("XYZ", Decimal(string: "340.00")!, "USD")
        ])

        let store = PriceStore()
        store.configure(
            provider: us, fallbackProvider: us,
            europeanProvider: RecordingProvider(), lastResortProvider: yahoo,
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "XYZ", mic: "XNYS"), currency: "USD")

        await store.refresh([ListingID(symbol: "XYZ", mic: "XNYS")])

        #expect(us.received.contains("XYZ"))
        #expect(store.quote(for: ListingID(symbol: "XYZ", mic: "XNYS"))?.price != Decimal(string: "12.00"))
    }

    /// NASDAQ reports itself as XNGS, XNMS or XNCM depending on tier. A position
    /// recorded as XNAS is on the same venue, and refusing that would be a
    /// different bug in the same family — this time showing a dash where a
    /// perfectly good price exists.
    @Test func tiersOfTheSameVenueAgree() {
        #expect(MarketCalendar.venuesAgree("XNMS", "XNAS"))
        #expect(MarketCalendar.venuesAgree("XNGS", "XNCM"))
        #expect(MarketCalendar.venuesAgree("XNYS", "ARCX"))
        #expect(MarketCalendar.venuesAgree("XETR", "XETR"))
        // Different venues, and the German secondaries are not XETRA.
        #expect(!MarketCalendar.venuesAgree("XNMS", "XETR"))
        #expect(!MarketCalendar.venuesAgree("XFRA", "XETR"))
        #expect(!MarketCalendar.venuesAgree("XMUN", "XDUS"))
    }

    /// A position bought before venues were recorded has nothing to check
    /// against, so it keeps the old routing. Refusing it would blank prices that
    /// work today, which is a regression, not a safeguard.
    @Test func aSymbolWithNoRecordedVenueIsStillAsked() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let us = RecordingProvider(returns: [quote("AAPL", Decimal(string: "313.33")!, "USD")])

        let store = PriceStore()
        store.configure(
            provider: us, fallbackProvider: us,
            europeanProvider: RecordingProvider(), lastResortProvider: RecordingProvider(),
            modelContext: container.mainContext
        )

        await store.refresh([ListingID(symbol: "AAPL")])

        #expect(us.received == ["AAPL"])
        #expect(store.quote(for: ListingID(symbol: "AAPL"))?.price == Decimal(string: "313.33"))
    }

    // MARK: - D: the recorded currency is applied on every path

    /// `rekeyed` used to be skipped on the primary and fallback paths — the two
    /// the invented currencies actually come from.
    @Test func theRecordedCurrencyIsAppliedOnThePrimaryPath() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        // Finnhub-shaped: a real price with no currency at all.
        let us = RecordingProvider(returns: [quote("AAPL", Decimal(string: "313.33")!, "")])

        let store = PriceStore()
        store.configure(
            provider: us, fallbackProvider: us,
            europeanProvider: RecordingProvider(), lastResortProvider: RecordingProvider(),
            modelContext: container.mainContext
        )
        store.register(ListingID(symbol: "AAPL", mic: "XNAS"), currency: "USD")

        await store.refresh([ListingID(symbol: "AAPL", mic: "XNAS")])

        #expect(store.quote(for: ListingID(symbol: "AAPL", mic: "XNAS"))?.currency == "USD")
    }

    // MARK: - C: Finnhub invents no currency

    /// The guess that was corrected in `/search` and left standing in `/quote`.
    @Test func finnhubReportsNoCurrencyRatherThanDollars() {
        let response = FinnhubQuoteResponse(
            c: Decimal(string: "3.97"), d: 0, dp: 0, h: 0, l: 0, o: 0,
            pc: Decimal(string: "4.16"), t: 1_786_132_800
        )
        let quote = try? #require(response.toQuote(symbol: "NVD"))
        #expect(quote?.currency == "")
    }

    // MARK: - The poisoned snapshot

    /// The cached 3,97 outlives the fix exactly as QDVE's zero did, and cannot
    /// be spotted by value — 3,97 is a perfectly ordinary price. The
    /// contradiction is structural: a snapshot in USD for a listing recorded in
    /// EUR was never this position's price.
    @Test func aSnapshotContradictingTheRecordedCurrencyIsPurged() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        ctx.insert(Asset(
            symbol: "NVD", name: "NVIDIA Corporation", assetClass: .stock,
            exchange: "XETR", currency: "EUR"
        ))
        ctx.insert(PriceSnapshot(quote: quote("NVD", Decimal(string: "3.97")!, "USD"), listing: ListingID(symbol: "NVD", mic: "XETR")))
        try ctx.save()

        let store = PriceStore()
        store.configure(
            provider: MockMarketDataProvider(), modelContext: ctx
        )
        store.hydrateFromCache()

        #expect(store.quote(for: ListingID(symbol: "NVD", mic: "XETR")) == nil, "o preço envenenado não pode hidratar")
        #expect(try ctx.fetch(FetchDescriptor<PriceSnapshot>()).isEmpty)
    }

    // MARK: - One row per instrument

    /// Ponto F, at the ViewModel. This test used to assert the opposite: that
    /// the second listing was **refused**, because the app could only store one
    /// venue per ticker and refusing was the only way to leave the first intact.
    ///
    /// That interim guard did its job — it is what kept every ticker to a single
    /// venue, which is precisely what made the backfill unambiguous — and it is
    /// now gone. Both instruments are held, each with its own cost basis.
    @Test func bothVenuesUnderOneTickerAreHeldSideBySide() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        // NVIDIA on XETRA.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 1,
            unitPrice: Decimal(string: "194.22")!, fxRate: 1, commission: 0,
            account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "NVIDIA Corporation", exchange: "XETR",
                assetClass: .stock, currency: "EUR", mic: "XETR"
            )
        )

        // The 2x inverse ETF on NASDAQ — same ticker, different instrument.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: 10,
            unitPrice: Decimal(string: "3.97")!, fxRate: Decimal(string: "0.86693")!,
            commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
                exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
            )
        )

        vm.loadHoldings()
        #expect(vm.openHoldings.count == 2)

        let nvidia = try #require(vm.openHoldings.first { $0.assetMIC == "XETR" })
        #expect(nvidia.quantity == 1)
        #expect(nvidia.totalCostEUR == Decimal(string: "194.22"))
        #expect(nvidia.currency == "EUR")

        let etf = try #require(vm.openHoldings.first { $0.assetMIC == "XNAS" })
        #expect(etf.quantity == 10)
        #expect(etf.currency == "USD")

        // Two `Asset` rows, each keeping its own name and class. One row per
        // ticker is what let the ETF overwrite NVIDIA's metadata.
        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        #expect(assets.count == 2)
        #expect(assets.first { $0.listing.mic == "XETR" }?.assetClass == .stock)
        #expect(assets.first { $0.listing.mic == "XNAS" }?.assetClass == .etf)
    }

    /// What survives of the guard, and the only thing it now protects.
    ///
    /// A ticker with transactions written before venues were stored can still be
    /// attributed, because exactly one venue exists for it. Admitting a second
    /// would strand those rows for good — and split the user's average price
    /// across two positions with no way to explain why. So it is refused, and
    /// nothing is written.
    @Test func aSecondVenueIsRefusedWhileUnattributedRowsSurvive() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        // A legacy purchase: symbol, no venue. Exactly what an old store holds.
        let legacy = FinancialTransaction(
            type: .assetPurchase, amount: Decimal(string: "194.22")!,
            date: Date(), note: "", category: .investments, sourceAccount: acc
        )
        legacy.assetSymbol = "NVD"
        legacy.assetQuantity = 1
        legacy.assetUnitPrice = Decimal(string: "194.22")!
        legacy.assetFXRate = 1
        ctx.insert(legacy)
        ctx.insert(Asset(
            symbol: "NVD", name: "NVIDIA Corporation", assetClass: .stock,
            exchange: "XETR", currency: "EUR"
        ))
        try ctx.save()

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        #expect(throws: PortfolioViewModel.AssetConflictError.self) {
            try vm.addInvestment(
                type: .assetPurchase, symbol: "NVD", quantity: 10,
                unitPrice: Decimal(string: "3.97")!, fxRate: Decimal(string: "0.86693")!,
                commission: 0, account: acc, date: Date(), note: "",
                asset: AssetSearchResult(
                    symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
                    exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
                )
            )
        }

        // Nothing of the refused purchase survived, and the legacy row is
        // untouched — still attributable.
        let txs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        #expect(txs.count == 1)
        #expect(txs[0].assetMIC == nil)
        #expect(try ctx.fetch(FetchDescriptor<Asset>()).count == 1)
    }

    /// The watchlist writes the same rows and obeys the same narrowed rule.
    @Test func followingANamesakeIsRefusedOnlyWhileRowsAreUnattributed() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let legacy = FinancialTransaction(
            type: .assetPurchase, amount: 100, date: Date(), note: "",
            category: .investments, sourceAccount: acc
        )
        legacy.assetSymbol = "NVD"
        legacy.assetQuantity = 1
        legacy.assetUnitPrice = 100
        legacy.assetFXRate = 1
        ctx.insert(legacy)
        ctx.insert(Asset(
            symbol: "NVD", name: "NVIDIA Corporation", assetClass: .stock,
            exchange: "XETR", currency: "EUR"
        ))
        try ctx.save()

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)

        #expect(throws: WatchlistViewModel.AddError.self) {
            try watchlist.add(AssetSearchResult(
                symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
                exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
            ))
        }

        // Once the row is attributed — which the launch backfill does — the very
        // same namesake is perfectly followable.
        ListingBackfill.run(in: ctx)
        try watchlist.add(AssetSearchResult(
            symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
            exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
        ))

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        #expect(assets.count == 2)
        // And the held listing was not repointed or unfollowed in the process.
        let nvidia = try #require(assets.first { $0.listing.mic == "XETR" })
        #expect(nvidia.currency == "EUR")
        #expect(nvidia.isWatchlisted == false)
    }

    /// Buying more of the *same* listing is an ordinary purchase and must not be
    /// caught by the guard — including when the venue arrives as a different
    /// tier of the same exchange.
    @Test func buyingMoreOfTheSameListingIsUnaffected() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        let nasdaq = AssetSearchResult(
            symbol: "AAPL", name: "Apple Inc", exchange: "NASDAQ",
            assetClass: .stock, currency: "USD", mic: "XNAS"
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 1, unitPrice: 300,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nasdaq
        )
        // XNGS is NASDAQ too — a different tier, not a different venue.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 1, unitPrice: 313,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "AAPL", name: "Apple Inc", exchange: "NASDAQ",
                assetClass: .stock, currency: "USD", mic: "XNGS"
            )
        )

        vm.loadHoldings()
        #expect(vm.openHoldings.first?.quantity == 2)
    }

    /// The invariant that outlives the guard: following a namesake never
    /// repoints the row of a listing that already exists.
    ///
    /// It used to be enforced by refusing the namesake outright. It is now
    /// enforced by giving it a row of its own — which is the better answer to
    /// the same question, and the one the user asked for.
    @Test func followingANamesakeNeverRepointsTheExistingListing() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        ctx.insert(Asset(
            symbol: "NVD", name: "NVIDIA Corporation", assetClass: .stock,
            exchange: "XETR", currency: "EUR"
        ))
        try ctx.save()

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let watchlist = WatchlistViewModel()
        watchlist.bind(modelContext: ctx, priceStore: store)

        try watchlist.add(AssetSearchResult(
            symbol: "NVD", name: "GraniteShares 2x Short Nvidia ETF",
            exchange: "NASDAQ", assetClass: .etf, currency: "USD", mic: "XNMS"
        ))

        let assets = try ctx.fetch(FetchDescriptor<Asset>())
        #expect(assets.count == 2)

        let nvidia = try #require(assets.first { $0.listing.mic == "XETR" })
        #expect(nvidia.name == "NVIDIA Corporation")
        #expect(nvidia.currency == "EUR")
        #expect(nvidia.assetClass == .stock)
        #expect(nvidia.isWatchlisted == false, "seguir o homónimo não pode marcar a NVIDIA")

        let etf = try #require(assets.first { $0.listing.mic == "XNAS" })
        #expect(etf.isWatchlisted)
        #expect(etf.currency == "USD")
    }

    /// A snapshot that agrees with its listing survives — the purge must not
    /// take the good cache with it, or every launch starts blank.
    @Test func anAgreeingSnapshotSurvivesHydration() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        ctx.insert(Asset(
            symbol: "NVD", name: "NVIDIA Corporation", assetClass: .stock,
            exchange: "XETR", currency: "EUR"
        ))
        ctx.insert(PriceSnapshot(quote: quote("NVD", Decimal(string: "194.22")!, "EUR"), listing: ListingID(symbol: "NVD", mic: "XETR")))
        try ctx.save()

        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        store.hydrateFromCache()

        #expect(store.quote(for: ListingID(symbol: "NVD", mic: "XETR"))?.price == Decimal(string: "194.22"))
        #expect(try ctx.fetch(FetchDescriptor<PriceSnapshot>()).count == 1)
    }
}
