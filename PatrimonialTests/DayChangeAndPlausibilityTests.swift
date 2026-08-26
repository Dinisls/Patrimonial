import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - "Hoje" is about the position, not the instrument

/// The header read "Hoje +5,46 €" beside a P/L of exactly +0,00 €. Both were
/// arithmetically right and described different holding periods: the P/L
/// measured from what was paid, the day change from a close that predated the
/// purchase. Real numbers from 2026-08-07 throughout.
@MainActor
struct DayChangeTests {

    typealias Tx = PortfolioCalculator.Transaction

    private func buy(
        _ symbol: String, qty: Decimal, price: Decimal, fx: Decimal = 1, date: Date,
        mic: String? = nil
    ) -> Tx {
        Tx(
            type: .assetPurchase, assetSymbol: symbol, assetMIC: mic,
            accountID: "a", accountName: "Corretora",
            quantity: qty, unitPrice: price, fxRate: fx, commission: 0,
            amountEUR: qty * price * fx, date: date
        )
    }

    private func sell(
        _ symbol: String, qty: Decimal, price: Decimal, fx: Decimal = 1, date: Date,
        mic: String? = nil
    ) -> Tx {
        Tx(
            type: .assetSale, assetSymbol: symbol, assetMIC: mic,
            accountID: "a", accountName: "Corretora",
            quantity: qty, unitPrice: price, fxRate: fx, commission: 0,
            amountEUR: qty * price * fx, date: date
        )
    }

    private let now = Date()
    private var today: Date { Calendar.current.startOfDay(for: now).addingTimeInterval(11 * 3600) }
    private var lastWeek: Date { now.addingTimeInterval(-7 * 86_400) }

    private func priced(
        _ holding: Holding, price: Decimal, previousClose: Decimal, fx: Decimal = 1
    ) -> Holding {
        var h = holding
        h.currentPriceNative = price
        h.previousCloseNative = previousClose
        h.currency = "EUR"
        h.currentFXRate = FXRate(from: "EUR", to: "EUR", value: fx)
        h.sessionStart = Calendar.current.startOfDay(for: now)
        return h
    }

    // MARK: - The reported bug

    /// Bought this morning at today's close: P/L zero and day change zero. The
    /// position did not gain the 189,16 → 194,22 move — it did not exist for it.
    @Test func aPositionOpenedTodayAtTodaysPriceGainedNothingToday() throws {
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [buy("NVD", qty: 1, price: Decimal(string: "194.22")!, date: today)]
        )
        let h = priced(
            holdings[0],
            price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!
        )

        #expect(h.unrealizedPL == 0)
        #expect(h.dayChangeEUR == 0, "creditou uma subida anterior à compra")
    }

    /// The same instrument held since last week *did* gain 5,06 today. The fix
    /// must not flatten every day change to zero.
    @Test func aPositionHeldSinceBeforeTodayKeepsTheFullDayChange() throws {
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [buy("NVD", qty: 1, price: Decimal(string: "170.00")!, date: lastWeek)]
        )
        let h = priced(
            holdings[0],
            price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!
        )

        #expect(h.dayChangeEUR == Decimal(string: "5.06"))
    }

    // MARK: - Per lot, not per position

    /// The rule that stops a purchase made today from contaminating the older
    /// shares: 1 held since last week contributes the full 5,06, 1 bought this
    /// morning at 194,22 contributes nothing. Blending them into one average
    /// purchase price would give 2 × (194,22 − 182,11) = 24,22.
    @Test func todaysPurchaseDoesNotContaminateOlderLots() throws {
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [
                buy("NVD", qty: 1, price: Decimal(string: "170.00")!, date: lastWeek),
                buy("NVD", qty: 1, price: Decimal(string: "194.22")!, date: today),
            ]
        )
        let h = priced(
            holdings[0],
            price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!
        )

        #expect(h.quantity == 2)
        #expect(h.dayChangeEUR == Decimal(string: "5.06"))
    }

    /// Two purchases today at different prices each get their own reference.
    /// One above the previous close, one below.
    @Test func eachLotBoughtTodayIsMeasuredFromItsOwnPrice() throws {
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [
                // Above the previous close: reference is the purchase price.
                buy("NVD", qty: 1, price: Decimal(string: "192.00")!, date: today),
                // Below it: capped at the previous close, so this lot reports the
                // instrument's move and not more.
                buy("NVD", qty: 1, price: Decimal(string: "185.00")!, date: today),
            ]
        )
        let h = priced(
            holdings[0],
            price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!
        )

        // (194.22 − 192.00) + (194.22 − 189.16) = 2.22 + 5.06
        #expect(h.dayChangeEUR == Decimal(string: "7.28"))
    }

    /// Selling most of a position bought this morning must not leave the day
    /// change measuring shares that are gone.
    @Test func aSaleShrinksTodaysLotsProportionally() throws {
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [
                buy("NVD", qty: 4, price: Decimal(string: "194.22")!, date: today),
                sell("NVD", qty: 3, price: Decimal(string: "194.22")!, date: today),
            ]
        )
        let h = priced(
            holdings[0],
            price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!
        )

        #expect(h.quantity == 1)
        #expect(h.purchaseLots.reduce(Decimal(0)) { $0 + $1.quantity } == 1)
        #expect(h.dayChangeEUR == 0)
    }

    /// Closing a position entirely clears its lots, so a fresh buy later is not
    /// measured against a closed one.
    @Test func closingAPositionClearsItsSessionLots() throws {
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [
                buy("NVD", qty: 1, price: Decimal(string: "180.00")!, date: today),
                sell("NVD", qty: 1, price: Decimal(string: "194.22")!, date: today),
                buy("NVD", qty: 1, price: Decimal(string: "194.22")!, date: today),
            ]
        )
        let h = priced(
            holdings[0],
            price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!
        )

        #expect(h.purchaseLots.count == 1)
        #expect(h.dayChangeEUR == 0)
    }

    /// The whole-portfolio figure, matching what the phone showed: 1 NVD and
    /// 0,5 AAPL, both opened today at the pre-filled price. It read +5,46 €.
    @Test func theReportedHeaderFigureBecomesZero() throws {
        let nvd = try PortfolioCalculator.computeHoldings(
            from: [buy("NVD", qty: 1, price: Decimal(string: "194.22")!, date: today)]
        )[0]
        let aapl = try PortfolioCalculator.computeHoldings(
            from: [buy("AAPL", qty: Decimal(string: "0.5")!,
                       price: Decimal(string: "313.33")!,
                       fx: Decimal(string: "0.86693")!, date: today)]
        )[0]

        let holdings = [
            priced(nvd, price: Decimal(string: "194.22")!, previousClose: Decimal(string: "189.16")!),
            priced(aapl, price: Decimal(string: "313.33")!,
                   previousClose: Decimal(string: "312.41")!, fx: Decimal(string: "0.86693")!),
        ]

        let total = try #require(PortfolioCalculator.dayChangeTotal(holdings))
        #expect(total.value == 0)
        #expect(total.excludedCount == 0)
    }

    // MARK: - Same exclusion rules as the value

    /// The day change used to vanish entirely when any one position lost its
    /// quote, while the value total showed a partial figure with a caveat. Now
    /// both are partial and both count what they left out.
    @Test func theDayChangeIsPartialLikeTheValueTotal() throws {
        var priced = Holding(
            assetSymbol: "NVD", accountID: "a", accountName: "Corretora",
            quantity: 1, totalCostEUR: Decimal(string: "170")!,
            averagePriceEUR: Decimal(string: "170")!,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        priced.currentPriceNative = Decimal(string: "194.22")!
        priced.previousCloseNative = Decimal(string: "189.16")!
        priced.currency = "EUR"
        priced.currentFXRate = FXRate.identity("EUR")
        priced.sessionStart = Calendar.current.startOfDay(for: now)

        let unpriced = Holding(
            assetSymbol: "QDVE", accountID: "a", accountName: "Corretora",
            quantity: 5, totalCostEUR: 200, averagePriceEUR: 40,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )

        let day = try #require(PortfolioCalculator.dayChangeTotal([priced, unpriced]))
        let value = try #require(PortfolioCalculator.marketValueTotal([priced, unpriced]))

        #expect(day.value == Decimal(string: "5.06"))
        #expect(day.isPartial)
        // The point of the alignment: the two agree on what they exclude.
        #expect(day.excludedCount == value.excludedCount)
        #expect(day.includedCount == value.pricedCount)
    }

    /// Nil only when nothing at all could be measured — same rule as the value.
    @Test func nothingMeasurableIsNilNotZero() {
        let unpriced = Holding(
            assetSymbol: "QDVE", accountID: "a", accountName: "Corretora",
            quantity: 5, totalCostEUR: 200, averagePriceEUR: 40,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        #expect(PortfolioCalculator.dayChangeTotal([unpriced]) == nil)
    }

    /// A price with no previous close is priced but has no day change. This is
    /// the case where the two totals legitimately exclude different positions,
    /// which is why the chip carries its own "parcial" rather than relying on
    /// the caveat under the value.
    @Test func aQuoteWithoutAPreviousCloseIsValuedButHasNoDayChange() {
        var h = Holding(
            assetSymbol: "NVD", accountID: "a", accountName: "Corretora",
            quantity: 1, totalCostEUR: 170, averagePriceEUR: 170,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        h.currentPriceNative = Decimal(string: "194.22")!
        h.currency = "EUR"
        h.currentFXRate = FXRate.identity("EUR")
        h.sessionStart = Calendar.current.startOfDay(for: now)

        #expect(h.marketValueEUR == Decimal(string: "194.22"))
        #expect(h.dayChangeEUR == nil)
        #expect(PortfolioCalculator.dayChangeTotal([h]) == nil)
        #expect(PortfolioCalculator.marketValueTotal([h])?.excludedCount == 0)
    }
}

// MARK: - Layer 2: a price must be plausible for the instrument

/// The backstop for providers that report no venue. Finnhub answers 3,97 for
/// `NVD` with nothing to say which NVD it means; the symbol's own history
/// settles it.
@MainActor
struct PlausibilityTests {

    private func quote(_ symbol: String, _ price: Decimal) -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: price, changeAbsolute: 0,
            changePercent: 0, currency: "EUR", timestamp: Date(), source: .rest
        )
    }

    private func store(
        _ ctx: ModelContext, reference: @escaping (ListingID) -> Decimal?
    ) -> PriceStore {
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        store.referenceClose = reference
        return store
    }

    /// The NVD case, at the publishing chokepoint. 3,97 against a history of
    /// 194,22 is a factor of 49.
    @Test func aPriceTwoOrdersFromTheHistoryIsRefused() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = store(container.mainContext) { _ in Decimal(string: "194.22") }

        store.applyQuote(quote("NVD", Decimal(string: "3.97")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD")) == nil, "o preço não pode ser publicado")
        let discrepancy = try #require(store.discrepancy(for: ListingID(symbol: "NVD")))
        #expect(discrepancy.refused == Decimal(string: "3.97"))
        #expect(discrepancy.reference == Decimal(string: "194.22"))
    }

    /// Nothing is written to the SwiftData cache either — the reason the check
    /// lives here and not in the view.
    @Test func aRefusedPriceIsNotPersisted() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = store(ctx) { _ in Decimal(string: "194.22") }

        store.applyQuote(quote("NVD", Decimal(string: "3.97")!), as: ListingID(symbol: "NVD"))

        #expect(try ctx.fetch(FetchDescriptor<PriceSnapshot>()).isEmpty)
    }

    /// An ordinary session moves a few percent and must pass untouched.
    @Test func anOrdinaryMoveIsPublished() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = store(container.mainContext) { _ in Decimal(string: "189.16") }

        store.applyQuote(quote("NVD", Decimal(string: "194.22")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD"))?.price == Decimal(string: "194.22"))
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) == nil)
    }

    /// Even a genuine crash is a crash, not another instrument. −40 % in a day
    /// happens and must not be censored.
    @Test func aRealCrashIsNotCensored() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = store(container.mainContext) { _ in Decimal(string: "194.22") }

        store.applyQuote(quote("NVD", Decimal(string: "116.53")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD"))?.price == Decimal(string: "116.53"))
    }

    // MARK: - Splits

    /// The steady state: a split moves the price and the series together, so
    /// there is no discrepancy to detect. This is the case that actually
    /// matters, because the candle cache and the quote come from the same
    /// listing and the same provider.
    @Test func aSplitMovesTheSeriesAndThePriceTogether() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        // 10:1 split: history already at the post-split scale.
        let store = store(container.mainContext) { _ in Decimal(string: "19.42") }

        store.applyQuote(quote("NVD", Decimal(string: "19.30")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD"))?.price == Decimal(string: "19.30"))
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) == nil)
    }

    /// The narrow window, stated rather than assumed: a 10:1 split whose quote
    /// arrives before the candle refresh lands exactly on the ratio, and the
    /// test is strictly greater, so it passes.
    @Test func aTenToOneSplitAheadOfTheHistoryStillPasses() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = store(container.mainContext) { _ in Decimal(string: "194.20") }

        store.applyQuote(quote("NVD", Decimal(string: "19.42")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD"))?.price == Decimal(string: "19.42"))
    }

    /// And the honest limit of the rule: a split larger than 10:1, in that same
    /// window, is refused. The position shows a dash with the reason until the
    /// history catches up — the correct direction to fail, and self-healing.
    @Test func aSplitLargerThanTenToOneIsRefusedUntilTheHistoryCatchesUp() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var historyClose = Decimal(string: "194.20")!
        let store = store(container.mainContext) { _ in historyClose }

        store.applyQuote(quote("NVD", Decimal(string: "9.71")!), as: ListingID(symbol: "NVD"))  // 20:1
        #expect(store.quote(for: ListingID(symbol: "NVD")) == nil)
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) != nil)

        // The candle refresh lands; the same price is now plausible.
        historyClose = Decimal(string: "9.80")!
        store.applyQuote(quote("NVD", Decimal(string: "9.71")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD"))?.price == Decimal(string: "9.71"))
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) == nil, "a marca tem de desaparecer")
    }

    /// No history, no second opinion. A position whose chart has never loaded
    /// must not lose its price to a check that cannot be performed.
    @Test func noHistoryMeansNoRefusal() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = store(container.mainContext) { _ in nil }

        store.applyQuote(quote("NVD", Decimal(string: "3.97")!), as: ListingID(symbol: "NVD"))

        #expect(store.quote(for: ListingID(symbol: "NVD"))?.price == Decimal(string: "3.97"))
    }

    /// Forgetting a deleted position clears its mark too, or the warning
    /// outlives the position it was about.
    @Test func forgettingASymbolClearsItsDiscrepancy() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = store(container.mainContext) { _ in Decimal(string: "194.22") }

        store.applyQuote(quote("NVD", Decimal(string: "3.97")!), as: ListingID(symbol: "NVD"))
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) != nil)

        store.forget(listing: ListingID(symbol: "NVD"))
        #expect(store.discrepancy(for: ListingID(symbol: "NVD")) == nil)
    }
}
