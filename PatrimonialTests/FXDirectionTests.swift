import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - The direction of a conversion, pinned as a property

/// Inverting the FX direction used to fail exactly one test out of 464.
///
/// The reason was not that the suite injects rates. It was that almost every
/// test values a position at a rate of **1**, and one is the fixed point of
/// inversion: multiplying and dividing by it give the same answer, so those
/// tests are structurally incapable of noticing. Adding more of them would not
/// have helped.
///
/// So this pins the property instead of an example — see the rule about testing
/// the cartesian product rather than cases. Every rate here is deliberately far
/// from 1 and far from its own inverse, so a flipped conversion is a different
/// number at every single assertion.
struct FXDirectionTests {

    /// Rates chosen so that `value`, `1/value` and `1` are three clearly
    /// different numbers, and the euro figure lands somewhere unmistakable.
    private static let pairs: [(currency: String, rate: Decimal, inverse: Decimal)] = [
        ("USD", Decimal(string: "0.86693")!, Decimal(string: "1.153495")!),
        ("GBP", Decimal(string: "1.16")!, Decimal(string: "0.862069")!),
        ("CHF", Decimal(string: "1.07")!, Decimal(string: "0.934579")!),
        ("JPY", Decimal(string: "0.0059")!, Decimal(string: "169.4915")!),
    ]

    // MARK: - The type itself

    @Test(arguments: FXDirectionTests.pairs.indices)
    func aRateOnlyConvertsOutOfTheCurrencyItIsFrom(index: Int) throws {
        let (currency, value, _) = Self.pairs[index]
        let rate = try #require(FXRate(from: currency, to: "EUR", value: value))

        #expect(rate.convert(100, from: currency) == 100 * value)
        // The whole point: handed euros, a native→EUR rate refuses rather than
        // multiplying anyway.
        #expect(rate.convert(100, from: "EUR") == nil)
        #expect(rate.convert(100, from: "XXX") == nil)
    }

    @Test(arguments: FXDirectionTests.pairs.indices)
    func anInvertedRateIsNotInterchangeableWithTheRightOne(index: Int) throws {
        let (currency, value, inverse) = Self.pairs[index]
        let correct = try #require(FXRate(from: currency, to: "EUR", value: value))
        let flipped = try #require(FXRate(from: "EUR", to: currency, value: inverse))

        #expect(correct != flipped)
        // A flipped rate cannot be used on the money that needs converting…
        #expect(flipped.convert(100, from: currency) == nil)
        // …and the two really do produce different numbers, so this is not
        // passing on a coincidence of the fixture.
        let a = try #require(correct.convert(100, from: currency))
        let b = 100 * inverse
        #expect(a != b)
    }

    @Test func aRateCannotBeZeroOrNegativeOrUnnamed() {
        #expect(FXRate(from: "USD", to: "EUR", value: 0) == nil)
        #expect(FXRate(from: "USD", to: "EUR", value: -1) == nil)
        #expect(FXRate(from: "", to: "EUR", value: 1) == nil)
        #expect(FXRate(from: "USD", to: "", value: 1) == nil)
    }

    @Test(arguments: FXDirectionTests.pairs.indices)
    func invertingTwiceReturnsTheOriginalPair(index: Int) throws {
        let (currency, value, _) = Self.pairs[index]
        let rate = try #require(FXRate(from: currency, to: "EUR", value: value))
        let back = try #require(rate.inverted?.inverted)
        #expect(back.from == rate.from)
        #expect(back.to == rate.to)
    }

    // MARK: - Through the holding

    /// The property at the layer that produces the euro figure on screen: a
    /// position valued with a rate pointing the wrong way has no value at all.
    @Test(arguments: FXDirectionTests.pairs.indices)
    func aHoldingWithAFlippedRateHasNoValue(index: Int) throws {
        let (currency, value, inverse) = Self.pairs[index]

        var right = holding(currency: currency)
        right.currentFXRate = FXRate(from: currency, to: "EUR", value: value)
        let mv = try #require(right.marketValueEUR)
        #expect(mv == 10 * 200 * value)

        var wrong = holding(currency: currency)
        wrong.currentFXRate = FXRate(from: "EUR", to: currency, value: inverse)
        #expect(wrong.marketValueEUR == nil)
        #expect(wrong.unrealizedPL == nil)
        #expect(wrong.dayChangeEUR == nil)
    }

    /// And the day change converts in the same direction as the value. These two
    /// used to multiply by the same bare `Decimal` and there was nothing to stop
    /// one of them being changed without the other.
    @Test(arguments: FXDirectionTests.pairs.indices)
    func theDayChangeConvertsTheSameWayAsTheValue(index: Int) throws {
        let (currency, value, _) = Self.pairs[index]
        var h = holding(currency: currency)
        h.currentFXRate = FXRate(from: currency, to: "EUR", value: value)

        let change = try #require(h.dayChangeEUR)
        // 10 × (200 − 190) × rate
        #expect(change == 10 * 10 * value)
    }

    private func holding(currency: String) -> Holding {
        var h = Holding(
            assetSymbol: "TEST", assetMIC: "XNGS",
            accountID: "a", accountName: "Corretora",
            quantity: 10, totalCostEUR: 1000, averagePriceEUR: 100,
            commissions: 0, realizedPL: 0, dividendsReceived: 0
        )
        h.currentPriceNative = 200
        h.previousCloseNative = 190
        h.currency = currency
        h.sessionStart = Calendar.current.startOfDay(for: Date())
        return h
    }
}

// MARK: - The same property, through the view model the screen reads

@MainActor
struct FXDirectionThroughTheViewModelTests {

    private func makeVM(
        _ ctx: ModelContext, currency: String, mic: String, provider: any FXRateProvider
    ) throws -> (PortfolioViewModel, PriceStore) {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: provider)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "TEST", quantity: 10, unitPrice: 100,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "TEST", name: "Test", exchange: mic,
                assetClass: .stock, currency: currency, mic: mic
            )
        )
        store.applyQuote(
            Quote(
                symbol: "TEST", price: 200, previousClose: 190,
                changeAbsolute: 10, changePercent: 5,
                currency: currency, timestamp: Date(), source: .rest
            ),
            as: ListingID(symbol: "TEST", mic: mic)
        )
        vm.loadHoldings()
        return (vm, store)
    }

    /// The chain end to end: provider asked native→EUR, holding valued in euros.
    @Test func theRefreshAsksNativeToEuroAndValuesThePosition() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _) = try makeVM(
            ctx, currency: "USD", mic: "XNGS",
            provider: StubRate(value: Decimal(string: "0.86693")!)
        )

        #expect(vm.openHoldings.first?.marketValueEUR == nil)
        await vm.refreshCurrentFXRates()

        let mv = try #require(vm.openHoldings.first?.marketValueEUR)
        #expect(mv == 10 * 200 * Decimal(string: "0.86693")!)
    }

    /// A provider that only knows the *inverse* direction cannot serve this
    /// position. It is not asked the wrong question, so it answers nothing, and
    /// the position keeps a dash — the failure is visible instead of being a
    /// number 15 % too large.
    @Test func aProviderThatOnlyKnowsTheInverseLeavesThePositionUnpriced() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _) = try makeVM(
            ctx, currency: "USD", mic: "XNGS",
            provider: StubRate(value: Decimal(string: "1.153495")!, from: "EUR", to: "USD")
        )

        await vm.refreshCurrentFXRates()

        #expect(vm.currentFXRates["USD"] == nil)
        #expect(vm.openHoldings.first?.marketValueEUR == nil)
        #expect(vm.hasMissingFXRates)
    }

    /// And a provider that answers with a *correctly valued but wrongly
    /// labelled* rate is refused too. This is the case a bare `Decimal` could
    /// never have caught: the number is right, the direction claim is not.
    @Test func aRateLabelledWithTheWrongPairIsRefused() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        struct MislabellingProvider: FXRateProvider {
            func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
                // Answers about EUR→USD however it is asked.
                FXRate(from: "EUR", to: "USD", value: Decimal(string: "0.86693")!)!
            }
        }

        let (vm, _) = try makeVM(
            ctx, currency: "USD", mic: "XNGS", provider: MislabellingProvider()
        )
        await vm.refreshCurrentFXRates()

        #expect(vm.currentFXRates["USD"] == nil)
        #expect(vm.openHoldings.first?.marketValueEUR == nil)
    }

    /// A euro position needs no rate and must not be held hostage to one.
    @Test func aEuroPositionIsValuedWithoutAskingAnybody() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _) = try makeVM(
            ctx, currency: "EUR", mic: "XLIS",
            provider: StubRate(value: 1, from: "NEVER", to: "ASKED")
        )

        let mv = try #require(vm.openHoldings.first?.marketValueEUR)
        #expect(mv == 2000)
    }
}
