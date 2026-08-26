import Foundation
import Testing
import SwiftData
@testable import Patrimonial

@MainActor
struct AssetDetailViewModelTests {

    private let today = Date(timeIntervalSince1970: 1_786_060_800)  // 2026-08-08 UTC

    private func candle(_ offset: Int, close: Decimal) -> Candle {
        let date = CandleStore.sessionDate(today.addingTimeInterval(TimeInterval(offset) * 86_400))
        return Candle(date: date, open: close, high: close, low: close, close: close, volume: 1)
    }

    /// A position with `days` of cached history and a live USD quote.
    /// `latestOffset` is where the cached series ends: 0 means "up to date"
    /// (and therefore no refresh is needed at all), negative means the cache is
    /// that many days behind and a refresh will go out.
    private func setUp(
        _ ctx: ModelContext,
        days: Int,
        latestOffset: Int = 0,
        provider: RecordingCandleProvider = RecordingCandleProvider()
    ) async throws -> (AssetDetailViewModel, CandleStore, PortfolioViewModel, PriceStore) {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)

        let portfolio = PortfolioViewModel()
        portfolio.bind(modelContext: ctx, priceStore: priceStore)
        try portfolio.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 2, unitPrice: 300,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: acc,
            date: today.addingTimeInterval(-20 * 86_400), note: "",
            asset: AssetSearchResult(
                symbol: "AAPL", name: "Apple Inc.", exchange: "XNGS",
                assetClass: .stock, currency: "USD", mic: "XNGS"
            )
        )
        priceStore.applyQuote(Quote(
            symbol: "AAPL", price: Decimal(string: "313.33")!,
            previousClose: Decimal(string: "312.41")!, changeAbsolute: 0,
            changePercent: 0, currency: "USD", timestamp: today, source: .rest
        ), as: ListingID(symbol: "AAPL", mic: "XNGS"))
        // Through the real chain, not injected. `setCurrentFXRateForTesting`
        // put a rate straight into the dictionary, so these eleven tests valued
        // a dollar position without ever asking anything which way round the
        // conversion goes.
        portfolio.bind(
            modelContext: ctx, priceStore: priceStore,
            fxProvider: StubRate(value: Decimal(string: "0.86693")!)
        )
        await portfolio.refreshCurrentFXRates()

        let candleStore = CandleStore(
            usProvider: provider, europeanProvider: provider, cryptoProvider: provider,
            now: { [today] in today }
        )
        candleStore.bind(modelContext: ctx)
        if days > 0 {
            candleStore.merge(
                (0..<days).map { candle(latestOffset - $0, close: Decimal(300 + $0)) },
                listing: ListingID(symbol: "AAPL", mic: "XNGS"), source: "test"
            )
        }

        let vm = AssetDetailViewModel(listing: ListingID(symbol: "AAPL", mic: "XNGS"), accountID: "")
        vm.bind(modelContext: ctx, priceStore: priceStore, candleStore: candleStore, portfolio: portfolio)
        return (vm, candleStore, portfolio, priceStore)
    }

    /// A range longer than the stored history draws what exists and says since
    /// when — never a padded window falling to zero.
    @Test func aRangeLongerThanTheHistoryMarksTheShortfall() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 10)

        vm.selectedRange = .oneYear

        #expect(vm.showsChart)
        let series = try #require(vm.series)
        #expect(series.candles.count == 10)
        #expect(!series.coversFullRange)

        let shortfall = try #require(vm.shortfallDescription)
        #expect(shortfall.contains("Histórico desde"))
        // Nothing was invented to fill the window.
        #expect(series.candles.allSatisfy { $0.close > 0 })
    }

    /// And a range the history does cover reports no shortfall.
    @Test func aCoveredRangeHasNoShortfall() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 40)

        vm.selectedRange = .oneMonth

        #expect(vm.showsChart)
        #expect(vm.shortfallDescription == nil)
    }

    /// Ranges the history cannot fill are drawable (2+ candles exist inside the
    /// window) but report a shortfall, so the UI can dim them or annotate.
    @Test func rangesBeyondTheHistoryAreDrawableButIncomplete() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 10)

        #expect(vm.isRangeAvailable(.oneWeek))
        #expect(vm.isRangeAvailable(.oneMonth))
        // 10 candles sit inside the 1Y window — drawable, but far from full.
        #expect(vm.isRangeAvailable(.oneYear))
        vm.selectedRange = .oneYear
        #expect(vm.shortfallDescription != nil)
        #expect(ChartRange.chartSelectable.count == 4)
    }

    /// No history at all: the chart hides and every other figure still works.
    @Test func anEmptySeriesHidesTheChartAndLeavesTheRestWorking() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 0)

        #expect(!vm.showsChart)
        #expect(vm.series?.isEmpty == true)
        #expect(vm.shortfallDescription == nil)

        // The rest of the screen is unaffected.
        #expect(vm.quantity == 2)
        #expect(vm.totalCostEUR == 516)          // 2 × 300 × 0,86
        #expect(vm.marketValueEUR != nil)
        #expect(vm.unrealizedPL != nil)
        #expect(vm.portfolioWeightPercent != nil)
        #expect(vm.transactions.count == 1)
        #expect(vm.quote != nil)
    }

    /// A single point is not a line, so the chart still hides.
    @Test func oneCandleIsNotAChart() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 1)

        #expect(!vm.showsChart)
    }

    /// Changing range is a filter over the cached series, never a fetch.
    @Test func changingRangeIssuesNoRequest() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 400, provider: provider)

        vm.selectedRange = .oneWeek
        vm.selectedRange = .oneYear
        vm.selectedRange = .max
        vm.selectedRange = .oneMonth

        #expect(provider.callCount == 0)
        #expect(vm.showsChart)
    }

    /// An exhausted budget throws inside the provider; the screen keeps the
    /// cached chart and publishes no error.
    @Test func anExhaustedBudgetServesCacheWithoutError() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        provider.shouldFail = true
        // Three days behind, so a refresh genuinely goes out and is refused.
        let (vm, _, _, _) = try await setUp(
            container.mainContext, days: 30, latestOffset: -3, provider: provider
        )

        vm.selectedRange = .max
        await vm.refreshHistory()

        #expect(provider.callCount == 1)
        // Refused, so nothing was added — and nothing was lost either.
        #expect(vm.showsChart)
        #expect(vm.series?.candles.count == 30)
        #expect(!vm.isLoadingHistory)
    }

    /// The skeleton is only for a genuinely empty screen. A refresh over
    /// existing candles must not blank the chart.
    @Test func aRefreshOverCachedDataNeverShowsTheSkeleton() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let provider = RecordingCandleProvider()
        provider.shouldFail = true
        let (vm, _, _, _) = try await setUp(
            container.mainContext, days: 30, latestOffset: -3, provider: provider
        )

        async let refresh: Void = vm.refreshHistory()
        // Cached data means the chart is drawable throughout.
        #expect(vm.showsChart)
        await refresh
        #expect(!vm.isLoadingHistory)
    }

    /// History is routed by the recorded MIC, like every other provider choice
    /// in this app — never by a ticker suffix.
    @Test func historyIsRoutedByTheRecordedMIC() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 0)

        #expect(vm.route == .unitedStates(symbol: "AAPL"))
        #expect(!vm.hasNoHistoryProvider)
    }

    /// A venue only Yahoo reaches has a quote but no chart — the agreed trade,
    /// stated on screen rather than shown as an empty frame.
    @Test func aVenueWithoutAHistoryProviderSaysSo() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let portfolio = PortfolioViewModel()
        portfolio.bind(modelContext: ctx, priceStore: priceStore)
        try portfolio.addInvestment(
            type: .assetPurchase, symbol: "QDVE", quantity: 5, unitPrice: 44,
            fxRate: 1, commission: 0, account: acc, date: today, note: "",
            asset: AssetSearchResult(
                symbol: "QDVE", name: "iShares", exchange: "XFRA",
                assetClass: .etf, currency: "EUR", mic: "XFRA"
            )
        )

        let candleStore = CandleStore(
            usProvider: RecordingCandleProvider(),
            europeanProvider: RecordingCandleProvider(),
            cryptoProvider: RecordingCandleProvider(),
            now: { [today] in today }
        )
        candleStore.bind(modelContext: ctx)

        let vm = AssetDetailViewModel(listing: ListingID(symbol: "QDVE", mic: "XFRA"), accountID: "")
        vm.bind(modelContext: ctx, priceStore: priceStore, candleStore: candleStore, portfolio: portfolio)

        // Frankfurt has no history provider — Yahoo is quotes only.
        #expect(vm.route == nil)
        #expect(vm.hasNoHistoryProvider)
        #expect(!vm.showsChart)
        // And the position figures still work.
        #expect(vm.quantity == 5)
        #expect(vm.totalCostEUR == 220)
    }

    /// The chart is drawn in the listing's own currency, and the label says
    /// which. No FX conversion happens on this path.
    @Test func theChartCurrencyIsTheListingsOwn() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, _, _) = try await setUp(container.mainContext, days: 10)

        #expect(vm.nativeCurrency == "USD")
        // The candles are the native series, untouched by the 0,86693 rate that
        // the EUR figures use.
        let series = try #require(vm.series)
        #expect(series.candles.contains { $0.close >= 300 })
        // While the euro figures do come from PortfolioCalculator.
        #expect(vm.totalCostEUR == 516)
    }

    /// Weight is measured against the same partial total the portfolio header
    /// shows, so the two screens cannot disagree.
    @Test func weightUsesTheSameTotalAsTheHeader() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (vm, _, portfolio, _) = try await setUp(container.mainContext, days: 0)

        let weight = try #require(vm.portfolioWeightPercent)
        // Sole position, so it is the whole portfolio.
        #expect(weight > 99 && weight <= 100)
        #expect(portfolio.marketValueTotal?.pricedCount == 1)
    }
}
