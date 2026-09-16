import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - 5. The generic editor must not touch investments

@MainActor
struct InvestmentTransactionProtectionTests {

    private func makeStore(_ ctx: ModelContext) -> AppStore {
        let store = AppStore()
        store.bind(ctx)
        return store
    }

    private func makePurchase(in ctx: ModelContext, account: Account) throws -> FinancialTransaction {
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 1, unitPrice: 160,
            fxRate: Decimal(string: "0.860813")!, commission: 0,
            account: account, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
                assetClass: .stock, currency: "USD", mic: "XNAS"
            )
        )
        let all = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        return try #require(all.first { $0.assetSymbol == "NVDA" })
    }

    /// The corruption in full: this rewrote `.assetPurchase` to `.expense` while
    /// leaving the symbol, quantity, price and FX rate behind. The portfolio
    /// filters on type, so the position simply vanished — and the row was left
    /// as neither an expense nor a holding.
    @Test func updateTransactionRefusesAnInvestment() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let tx = try makePurchase(in: ctx, account: acc)
        let store = makeStore(ctx)

        try store.updateTransaction(
            id: tx.id, title: "Qualquer coisa", amount: 999, isIncome: false,
            category: .food, account: "Corretora", date: "1/1/2026"
        )

        #expect(tx.type == .assetPurchase)
        #expect(tx.assetSymbol == "NVDA")
        #expect(tx.assetQuantity == 1)
        #expect(tx.amount != 999)
        #expect(tx.note != "Qualquer coisa")
    }

    /// The Despesa/Receita picker specifically: it must not be able to turn a
    /// purchase into income either.
    @Test func incomeToggleCannotRetypeAnInvestment() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let tx = try makePurchase(in: ctx, account: acc)
        let store = makeStore(ctx)

        try store.updateTransaction(
            id: tx.id, title: "x", amount: 10, isIncome: true,
            category: .income, account: "Corretora", date: "1/1/2026"
        )

        #expect(tx.type == .assetPurchase)
    }

    /// And the position survives the attempt.
    @Test func positionSurvivesAnEditAttempt() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let tx = try makePurchase(in: ctx, account: acc)
        try makeStore(ctx).updateTransaction(
            id: tx.id, title: "x", amount: 1, isIncome: false,
            category: .food, account: "Corretora", date: "1/1/2026"
        )

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        vm.loadHoldings()
        #expect(vm.openHoldings.contains { $0.assetSymbol == "NVDA" })
    }

    /// Moving an investment to another account would move the position with it.
    @Test func metaUpdateRefusesAnInvestment() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        let other = Account(name: "Outra", type: .brokerage)
        ctx.insert(acc)
        ctx.insert(other)

        let tx = try makePurchase(in: ctx, account: acc)
        try makeStore(ctx).updateTransactionMeta(id: tx.id, account: "Outra", date: "1/1/2026")

        #expect(tx.sourceAccount?.name == "Corretora")
    }

    /// Deleting is still allowed — it is the one way out of a wrong position
    /// from this screen — and it cleans up like the portfolio's own delete.
    @Test func deletingAnInvestmentAlsoClearsItsAssetAndPrice() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let tx = try makePurchase(in: ctx, account: acc)
        ctx.insert(PriceSnapshot(quote: Quote(
            symbol: "NVDA", price: 200, previousClose: 200, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
        ), listing: ListingID(symbol: "NVDA")))
        try ctx.save()

        try makeStore(ctx).deleteTransaction(id: tx.id)

        #expect(try ctx.fetch(FetchDescriptor<FinancialTransaction>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Asset>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PriceSnapshot>()).isEmpty)
    }

    /// An ordinary expense is untouched by the guard.
    @Test func ordinaryTransactionsAreStillEditable() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Conta", type: .checking)
        ctx.insert(acc)
        let tx = FinancialTransaction(
            type: .expense, amount: 20, date: Date(), note: "Café",
            category: .food, sourceAccount: acc
        )
        ctx.insert(tx)
        try ctx.save()

        try makeStore(ctx).updateTransaction(
            id: tx.id, title: "Almoço", amount: 35, isIncome: false,
            category: .food, account: "Conta", date: "1/1/2026"
        )

        #expect(tx.note == "Almoço")
        #expect(tx.amount == 35)
    }
}

// MARK: - 6. The value pipeline is lossless

struct AmountPipelineTests {

    /// Rules out the locale/parsing theory: the stored Decimal survives the trip
    /// through PBTx's Double and the editor's editable string unchanged, in both
    /// directions. Whatever made the two screens disagree, it was not this.
    @Test func amountSurvivesTheRoundTrip() throws {
        for value in [Decimal(string: "137.73")!, Decimal(string: "173.39")!,
                      Decimal(string: "0.01")!, Decimal(string: "1234.56")!] {
            let asDouble = Double(truncating: value as NSDecimalNumber)
            let field = TransactionEditSheet.amountFieldText(for: -asDouble)
            let parsed = try #require(TransactionEditSheet.parseAmountField(field))
            // Written back the way the store writes it — through the decimal
            // string, not `Decimal(Double)`, which would smuggle in
            // 1234,5599999999997952 for 1234,56.
            #expect(AppStore.money(from: parsed) == value)
        }
    }

    /// The write-back conversion in isolation.
    @Test func moneyConversionCarriesNoBinaryResidue() {
        #expect(AppStore.money(from: 1234.56) == Decimal(string: "1234.56"))
        #expect(AppStore.money(from: 137.73) == Decimal(string: "137.73"))
        #expect(AppStore.money(from: 0.1 + 0.2) == Decimal(string: "0.30"))
    }

    /// The field is comma-separated for the Portuguese keyboard, and the sign is
    /// dropped because direction comes from the Despesa/Receita picker.
    @Test func amountFieldUsesCommaAndDropsTheSign() {
        #expect(TransactionEditSheet.amountFieldText(for: -137.73) == "137,73")
        #expect(TransactionEditSheet.amountFieldText(for: 137.73) == "137,73")
    }

    @Test func amountFieldAcceptsBothSeparators() {
        #expect(TransactionEditSheet.parseAmountField("137,73") == 137.73)
        #expect(TransactionEditSheet.parseAmountField("137.73") == 137.73)
    }
}

// MARK: - 1. The FX chain

@MainActor
struct CurrentFXRateTests {

    private func setUp(_ ctx: ModelContext) throws -> (PortfolioViewModel, PriceStore, Account) {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 1, unitPrice: 160,
            fxRate: Decimal(string: "0.860813")!, commission: 0,
            account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "NVDA", name: "NVIDIA", exchange: "XNAS",
                assetClass: .stock, currency: "USD", mic: "XNAS"
            )
        )
        return (vm, store, acc)
    }

    private func usdQuote(_ price: Decimal) -> Quote {
        Quote(
            symbol: "NVDA", price: price, previousClose: price, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
        )
    }

    /// The bug, pinned. A USD price with no known rate was published as euros:
    /// 223,98 USD became a market value of 223,98 € against a cost of 137,73 €,
    /// inventing +62 % on a position bought the same day. It must be a dash.
    @Test func unknownRateYieldsNoValueRatherThanTreatingUSDAsEUR() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, store, _) = try setUp(ctx)

        store.applyQuote(usdQuote(Decimal(string: "223.98")!), as: ListingID(symbol: "NVDA", mic: "XNAS"))
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first { $0.assetSymbol == "NVDA" })
        #expect(holding.currentFXRate == nil)
        #expect(holding.marketValueEUR == nil)
        #expect(holding.unrealizedPLPercent == nil)
        #expect(vm.totalMarketValue == nil)
        #expect(vm.hasMissingFXRates)
    }

    /// With the rate known, the conversion runs native → EUR, the same direction
    /// as the rate stored on the purchase. Getting this inverted is what broke
    /// it last time, so the assertion is on the direction, not just the value.
    @Test func knownRateConvertsNativeIntoEUR() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, store, _) = try setUp(ctx)

        store.applyQuote(usdQuote(Decimal(string: "223.98")!), as: ListingID(symbol: "NVDA", mic: "XNAS"))
        vm.setCurrentFXRateForTesting(
            FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.860813")!)!
        )

        let holding = try #require(vm.openHoldings.first { $0.assetSymbol == "NVDA" })
        let marketValue = try #require(holding.marketValueEUR)

        // 223,98 × 0,860813 ≈ 192,80 — below the native number, not above it.
        #expect(marketValue < Decimal(string: "223.98")!)
        #expect(marketValue > Decimal(string: "192")! && marketValue < Decimal(string: "194")!)

        // Cost was 160 × 0,860813 = 137,73, so the gain is real but modest.
        let pct = try #require(holding.unrealizedPLPercent)
        #expect(pct > 39 && pct < 41)
    }

    /// A EUR-quoted asset needs no rate and must never be blocked waiting for one.
    @Test func euroAssetsNeedNoRate() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store)

        try vm.addInvestment(
            type: .assetPurchase, symbol: "GALP.LS", quantity: 10, unitPrice: 19,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "GALP.LS", name: "Galp", exchange: "XLIS",
                assetClass: .stock, currency: "EUR", mic: "XLIS"
            )
        )
        store.applyQuote(Quote(
            symbol: "GALP.LS", price: 20, previousClose: 20, changeAbsolute: 0,
            changePercent: 0, currency: "EUR", timestamp: Date(), source: .rest
        ), as: ListingID(symbol: "GALP.LS", mic: "XLIS"))
        vm.loadHoldings()

        let holding = try #require(vm.openHoldings.first { $0.assetSymbol == "GALP.LS" })
        // Euro against euro, stated as such — not the bare `1` that used to be
        // indistinguishable from "não sei a taxa".
        #expect(holding.currentFXRate == FXRate.identity("EUR"))
        #expect(holding.marketValueEUR == 200)
        #expect(!vm.hasMissingFXRates)
    }
}

// MARK: - 2. Freshness against the market calendar

@MainActor
struct FreshnessRoutingTests {

    private func store(_ ctx: ModelContext) -> PriceStore {
        let s = PriceStore()
        s.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        return s
    }

    /// Midnight in Lisbon with the NYSE long shut used to read "desatualizado"
    /// (red) because the quote's own age was all anyone looked at. The calendar
    /// is what knows the market is simply closed.
    @Test func closedMarketReadsAsClosedNotStale() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)

        // A Sunday: no exchange is open, whatever the hour.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 9; comps.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let sunday = try #require(cal.date(from: comps))

        s.applyQuote(Quote(
            symbol: "NVDA", price: 200, previousClose: 200, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: sunday, source: .rest
        ), as: ListingID(symbol: "NVDA"))

        // Judged as of that Sunday, not as of whenever the suite happens to
        // run — otherwise this is green in the evening and red at lunchtime.
        #expect(MarketCalendar.freshness(
            for: .nyse, quoteTimestamp: sunday, source: .rest, now: sunday
        ) == .closed)
    }

    /// Crypto never closes, so it must not be routed to the NYSE calendar just
    /// because its ticker has no exchange suffix.
    @Test func cryptoIsNeverClosed() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)
        s.registerCoinID(symbol: "BTC", coinID: "bitcoin")
        s.applyQuote(Quote(
            symbol: "BTC", price: 60_000, previousClose: 59_000, changeAbsolute: 1000,
            changePercent: 1.7, currency: "EUR", timestamp: Date(), source: .rest
        ), as: ListingID(symbol: "BTC"))

        #expect(s.freshness(for: ListingID(symbol: "BTC")) != .closed)
    }

    /// A daily close outranks the calendar: it reports as a close with its
    /// session date whether or not the market happens to be trading.
    @Test func dailyCloseOutranksOpeningHours() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = store(container.mainContext)
        let closeDate = try #require(AlphaVantageGlobalQuote.parseTradingDay("2026-08-06"))

        s.applyQuote(Quote(
            symbol: "GALP.LS", price: Decimal(string: "19.75")!,
            previousClose: Decimal(string: "19.69")!, changeAbsolute: 0,
            changePercent: 0, currency: "EUR", timestamp: Date(),
            source: .dailyClose, closeDate: closeDate
        ), as: ListingID(symbol: "GALP.LS"))

        guard case .dailyClose(let date) = s.freshness(for: ListingID(symbol: "GALP.LS")) else {
            Issue.record("Esperava fecho diário, veio \(s.freshness(for: ListingID(symbol: "GALP.LS")))")
            return
        }
        #expect(date == closeDate)
    }

    @Test func unknownSymbolHasUnknownFreshness() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        #expect(store(container.mainContext).freshness(for: ListingID(symbol: "NOPE")) == .unknown)
    }
}

// MARK: - 3. The balance series cannot predate the account

@MainActor
struct BalanceSeriesRangeTests {

    private func makeAccount(_ ctx: ModelContext, firstMovementDaysAgo: Int) throws -> (AppStore, Account) {
        let acc = Account(name: "Conta", type: .checking)
        ctx.insert(acc)
        let cal = Calendar.current
        for offset in [firstMovementDaysAgo, firstMovementDaysAgo - 2, 0] {
            let date = try #require(cal.date(byAdding: .day, value: -offset, to: Date()))
            ctx.insert(FinancialTransaction(
                type: .expense, amount: 10, date: date, note: "x",
                category: .other, sourceAccount: acc
            ))
        }
        try ctx.save()
        let store = AppStore()
        store.bind(ctx)
        return (store, acc)
    }

    /// A week-old account was drawing six months of line by walking the balance
    /// backwards past its own first transaction — a flat stretch at a balance it
    /// never had.
    @Test func seriesIsClampedToTheFirstMovement() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (store, acc) = try makeAccount(ctx, firstMovementDaysAgo: 7)

        let series = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 180))
        // Eight days inclusive, not 180.
        #expect(series.count <= 9)
        #expect(series.count >= 2)
    }

    @Test func historyDaysReflectsTheFirstMovement() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (store, acc) = try makeAccount(ctx, firstMovementDaysAgo: 7)

        let days = try #require(store.historyDays(accountID: acc.id.uuidString))
        #expect(days == 8)
    }

    @Test func accountWithNoTransactionsHasNoHistory() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Vazia", type: .checking)
        ctx.insert(acc)
        try ctx.save()
        let store = AppStore()
        store.bind(ctx)

        #expect(store.historyDays(accountID: acc.id.uuidString) == nil)
        #expect(store.balanceSeries(accountID: acc.id.uuidString, days: 30) == nil)
    }

    /// A longer window than the account has must not produce more points than a
    /// shorter one — that was what made "1M" and "6M" draw the same line while
    /// claiming to be different ranges.
    @Test func longerWindowDoesNotInventMorePoints() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (store, acc) = try makeAccount(ctx, firstMovementDaysAgo: 7)

        let short = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 30))
        let long = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 365))
        #expect(short.count == long.count)
    }
}

// MARK: - 4. Investment rows say what they are

@MainActor
struct InvestmentRowLabellingTests {

    @Test func purchaseTitleNamesTheAsset() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 1, unitPrice: 160,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )

        let tx = try #require(try ctx.fetch(FetchDescriptor<FinancialTransaction>()).first)
        #expect(tx.note == "Compra NVDA")
    }

    /// A user-written note still wins over the generated one.
    @Test func explicitNoteIsKept() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 1, unitPrice: 160,
            fxRate: 1, commission: 0, account: acc, date: Date(),
            note: "Reforço mensal", asset: nil
        )

        let tx = try #require(try ctx.fetch(FetchDescriptor<FinancialTransaction>()).first)
        #expect(tx.note == "Reforço mensal")
    }

    /// It was showing "Outras". Investments have their own category.
    @Test func investmentRowsCarryQuantityAndCategory() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 1, unitPrice: 160,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )

        let store = AppStore()
        store.bind(ctx)
        let row = try #require(store.transactions.first { $0.assetSymbol == "NVDA" })

        #expect(row.cat == .investments)
        #expect(txCatLabel(row.cat) == "Investimentos")
        #expect(row.sub == "1 un")
        #expect(row.isInvestment)
    }
}

// MARK: - 7. Prices on search results

@MainActor
struct SearchPricingTests {

    /// The MIC is what places a listing on a venue — a search result carries no
    /// suffix, so it is the MIC, not the ticker, that decides which provider is
    /// asked and in which currency the answer comes back.
    private func result(_ symbol: String, currency: String = "USD", mic: String = "XNAS") -> AssetSearchResult {
        AssetSearchResult(
            symbol: symbol, name: symbol, exchange: mic,
            assetClass: .stock, currency: currency, mic: mic
        )
    }

    private func quote(_ symbol: String, _ price: Decimal, currency: String = "USD") -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: price, changeAbsolute: 0,
            changePercent: 0, currency: currency, timestamp: Date(), source: .rest
        )
    }

    @Test func pricesComeBackForTheResults() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var provider = MockMarketDataProvider()
        provider.answersOnlyKnownSymbols = true
        provider.mockQuotes = ["NVDA": quote("NVDA", Decimal(string: "223.98")!)]

        let store = PriceStore()
        store.configure(provider: provider, modelContext: container.mainContext)

        let nvda = result("NVDA")
        let prices = await store.quotesForSearch([nvda])
        #expect(prices[nvda.id]?.price == Decimal(string: "223.98"))
    }

    /// Reuse before spending: a listing already priced must not cost a request.
    @Test func alreadyKnownPricesAreReusedNotRefetched() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let recorder = RecordingProvider()
        let store = PriceStore()
        store.configure(provider: recorder, modelContext: container.mainContext)
        let nvda = result("NVDA")
        // Cached under the listing, which is what reuse now matches on. A quote
        // filed under the bare ticker is deliberately *not* reused for a venued
        // row — that reuse is how the NASDAQ close reached a Buenos Aires CEDEAR.
        store.applyQuote(
            quote("NVDA", 200),
            as: ListingID(symbol: nvda.symbol, mic: nvda.mic)
        )
        let prices = await store.quotesForSearch([nvda])
        #expect(prices[nvda.id]?.price == 200)
        #expect(recorder.received.isEmpty)
    }

    /// Reuse stops at the currency line. A cached USD quote for AAPL is the
    /// NASDAQ listing; handing it to the Buenos Aires CEDEAR, which trades in
    /// pesos, is the conflation the listing key exists to prevent — and no
    /// amount of budget saving justifies it.
    @Test func aCachedQuoteIsNotReusedForADifferentCurrency() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var provider = MockMarketDataProvider()
        provider.answersOnlyKnownSymbols = true
        provider.mockQuotes = [:]
        let store = PriceStore()
        store.configure(provider: provider, fallbackProvider: provider,
                        modelContext: container.mainContext)
        store.applyQuote(quote("AAPL", Decimal(string: "313.33")!), as: ListingID(symbol: "AAPL"))

        let cedear = result("AAPL", currency: "ARS", mic: "XBUE")
        let prices = await store.quotesForSearch([cedear])
        #expect(prices[cedear.id] == nil)
    }

    /// A symbol nobody can price is absent, so the row shows a dash. It must
    /// never come back as zero.
    @Test func unpricedSymbolIsAbsentNotZero() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var provider = MockMarketDataProvider()
        provider.answersOnlyKnownSymbols = true
        provider.mockQuotes = [:]

        let store = PriceStore()
        store.configure(provider: provider, modelContext: container.mainContext)

        let unknown = result("ZZZZ")
        let prices = await store.quotesForSearch([unknown])
        #expect(prices[unknown.id] == nil)
    }

    /// European rows route to the same third fallback, and so to the same one
    /// call per symbol per day — and they now get there straight from the MIC,
    /// with the venue's suffix appended, rather than waiting for a suffix the
    /// search result never had.
    @Test func europeanResultsGoThroughTheAlphaVantageFallback() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var provider = MockMarketDataProvider()
        provider.answersOnlyKnownSymbols = true
        provider.mockQuotes = [:]
        let european = RecordingProvider()

        let store = PriceStore()
        store.configure(
            provider: provider, fallbackProvider: provider,
            europeanProvider: european, modelContext: container.mainContext
        )

        _ = await store.quotesForSearch([
            result("GALP", currency: "EUR", mic: "XLIS"),
            result("NVDA"),
        ])
        #expect(european.received == ["GALP.LS"])
    }

    /// Search failures must stay inside search: the portfolio header reads
    /// `lastError`, and a blank price on a search row is not a portfolio outage.
    @Test func searchPricingNeverRaisesAPortfolioError() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var provider = MockMarketDataProvider()
        provider.shouldFail = true

        let store = PriceStore()
        store.configure(provider: provider, modelContext: container.mainContext)

        _ = await store.quotesForSearch([result("NVDA")])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
    }

    /// The prefill is a reference, so it has to be a string the decimal keypad
    /// can keep editing: comma separator, no grouping, no currency symbol.
    @Test func prefillIsEditableText() {
        #expect(AddPositionSheet.editableDecimal(Decimal(string: "223.98")!) == "223,98")
        #expect(AddPositionSheet.editableDecimal(Decimal(string: "1234.5")!) == "1234,5")
    }

    /// Only the visible rows are priced — every extra one is a symbol charged
    /// against the daily budgets. Raised from five to eight so that every row
    /// shown before "ver mais" carries a price rather than a dash; the two
    /// numbers are deliberately the same one.
    @Test func onlyTheVisibleResultsArePriced() {
        #expect(PortfolioViewModel.pricedSearchResultLimit == 8)
        #expect(PortfolioViewModel.pricedSearchResultLimit == SearchRanking.initialDisplayCount)
    }
}
