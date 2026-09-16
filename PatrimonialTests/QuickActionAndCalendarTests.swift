import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - Quick actions from the asset detail

@MainActor
struct QuickActionTests {

    /// Two brokerages holding the same ticker: 10 AAPL in one, 3 in the other.
    /// The whole point of the prefill is that an action knows which.
    private func setUp(_ ctx: ModelContext) throws -> (PortfolioViewModel, Account, Account) {
        let corretora = Account(name: "Corretora", type: .brokerage)
        let outra = Account(name: "Outra", type: .brokerage)
        ctx.insert(corretora)
        ctx.insert(outra)

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)

        let asset = AssetSearchResult(
            symbol: "AAPL", name: "Apple Inc.", exchange: "XNGS",
            assetClass: .stock, currency: "USD", mic: "XNGS"
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10, unitPrice: 300,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: corretora,
            date: Date(), note: "", asset: asset
        )
        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 3, unitPrice: 310,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: outra,
            date: Date(), note: "", asset: asset
        )
        return (vm, corretora, outra)
    }

    private func detail(
        _ ctx: ModelContext, _ vm: PortfolioViewModel, account: Account
    ) -> AssetDetailViewModel {
        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let candles = CandleStore(
            usProvider: RecordingCandleProvider(),
            europeanProvider: RecordingCandleProvider(),
            cryptoProvider: RecordingCandleProvider()
        )
        candles.bind(modelContext: ctx)
        let detail = AssetDetailViewModel(listing: ListingID(symbol: "AAPL", mic: "XNAS"), accountID: account.id.uuidString)
        detail.bind(modelContext: ctx, priceStore: priceStore, candleStore: candles, portfolio: vm)
        return detail
    }

    /// The prefill always has nil accountID — the position is a single pool
    /// and the user picks the destination account in the sheet.
    @Test func theActionHasNoPrefilledAccount() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, _, outra) = try setUp(ctx)

        let fromOutra = detail(ctx, vm, account: outra)
        let prefill = try #require(fromOutra.prefill(for: .assetSale))

        #expect(prefill.accountID == nil, "Account is chosen in the sheet, not prefilled")
        #expect(prefill.type == .assetSale)
        #expect(prefill.asset.symbol == "AAPL")
    }

    /// Quantity is validated against the total position. Selling 5 is fine
    /// from any account as long as the total (13) covers it.
    @Test func quantityIsValidatedAgainstTotalPosition() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, corretora, outra) = try setUp(ctx)

        #expect(detail(ctx, vm, account: corretora).availableToSell == 13)
        #expect(detail(ctx, vm, account: outra).availableToSell == 13)

        // Selling 5 to "outra" succeeds — the total (13) covers it.
        try vm.addInvestment(
            type: .assetSale, symbol: "AAPL", quantity: 5, unitPrice: 320,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: outra,
            date: Date(), note: "", asset: nil
        )

        #expect(vm.totalQuantity(listing: ListingID(symbol: "AAPL", mic: "XNGS")) == 8)
    }

    /// A sale reduces the total position, regardless of destination account.
    @Test func aSaleReducesTheTotalPosition() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, corretora, _) = try setUp(ctx)

        try vm.addInvestment(
            type: .assetSale, symbol: "AAPL", quantity: 4, unitPrice: 320,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: corretora,
            date: Date(), note: "", asset: nil
        )

        #expect(vm.totalQuantity(listing: ListingID(symbol: "AAPL", mic: "XNGS")) == 9)
    }

    /// In quick-action mode the asset is fixed: the prefill reproduces the
    /// listing recorded at purchase, MIC and currency included, so the sheet
    /// never has to ask and cannot record a different venue.
    @Test func theAssetIsFixedAndCarriesItsRecordedListing() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, corretora, _) = try setUp(ctx)

        let detail = detail(ctx, vm, account: corretora)
        let asset = try #require(detail.prefillAsset)

        #expect(asset.symbol == "AAPL")
        #expect(asset.mic == "XNGS")
        #expect(asset.currency == "USD")
        #expect(detail.canUseQuickActions)

        // The sheet built from it starts locked on that asset.
        let prefill = try #require(detail.prefill(for: .assetPurchase))
        #expect(prefill.asset.symbol == "AAPL")
    }

    /// A position with no recorded venue — from before the MIC was stored —
    /// hides the buttons rather than opening a sheet that would write a
    /// venue-less asset over a good one.
    @Test func aPositionWithoutARecordedListingHasNoQuickActions() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)
        // No `asset:` — so no Asset row is written.
        try vm.addInvestment(
            type: .assetPurchase, symbol: "MYST", quantity: 1, unitPrice: 10,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )

        let candles = CandleStore(
            usProvider: RecordingCandleProvider(),
            europeanProvider: RecordingCandleProvider(),
            cryptoProvider: RecordingCandleProvider()
        )
        candles.bind(modelContext: ctx)
        let detail = AssetDetailViewModel(listing: ListingID(symbol: "MYST", mic: "XNAS"), accountID: acc.id.uuidString)
        detail.bind(modelContext: ctx, priceStore: priceStore, candleStore: candles, portfolio: vm)

        #expect(detail.prefillAsset == nil)
        #expect(!detail.canUseQuickActions)
        #expect(detail.prefill(for: .assetSale) == nil)
    }
}

// MARK: - US market holidays

/// `Calendar.weekOfMonth` was counting something else entirely: the week of the
/// month a date falls in, where week 1 is the partial week containing the 1st.
/// It coincides with "the Nth Monday" only by accident, and it shifts with the
/// calendar's `firstWeekday`, so the answer changed with the device locale.
struct USMarketHolidayTests {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: c)!
    }

    private func isOpen(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        MarketCalendar.isOpen(.nasdaq, at: date(y, m, d))
    }

    /// The arithmetic, in isolation: days 15–21 are the third of each weekday.
    @Test func theOrdinalOfAWeekdayIsDerivedFromTheDayOfMonth() {
        #expect(MarketCalendar.ordinalWeekday(1) == 1)
        #expect(MarketCalendar.ordinalWeekday(7) == 1)
        #expect(MarketCalendar.ordinalWeekday(8) == 2)
        #expect(MarketCalendar.ordinalWeekday(19) == 3)   // MLK 2026
        #expect(MarketCalendar.ordinalWeekday(22) == 4)
        #expect(MarketCalendar.ordinalWeekday(26) == 4)   // Thanksgiving 2026
        #expect(MarketCalendar.ordinalWeekday(28) == 4)   // Thanksgiving 2024
    }

    /// Martin Luther King Day, third Monday of January. Missed in every year
    /// tested before the fix: `weekOfMonth` reported 4 for all of them.
    @Test func martinLutherKingDayIsClosed() {
        #expect(!isOpen(2026, 1, 19))
        #expect(!isOpen(2025, 1, 20))
        #expect(!isOpen(2024, 1, 15))
        // And the Mondays either side are ordinary trading days.
        #expect(isOpen(2026, 1, 12))
        #expect(isOpen(2026, 1, 26))
    }

    /// Presidents Day, third Monday of February.
    @Test func presidentsDayIsClosed() {
        #expect(!isOpen(2026, 2, 16))
        #expect(!isOpen(2025, 2, 17))
        #expect(!isOpen(2024, 2, 19))
        #expect(isOpen(2026, 2, 9))
        #expect(isOpen(2026, 2, 23))
    }

    /// Thanksgiving, fourth Thursday of November. `weekOfMonth` gave 5 in 2024
    /// and 2025, and 5 in 2026 too under the Monday-first calendar a Portuguese
    /// device uses — so this failed on the user's own phone.
    @Test func thanksgivingIsClosed() {
        #expect(!isOpen(2026, 11, 26))
        #expect(!isOpen(2025, 11, 27))
        #expect(!isOpen(2024, 11, 28))
        // The Thursday before, and the one after, are open.
        #expect(isOpen(2026, 11, 19))
        #expect(isOpen(2025, 11, 20))
    }

    /// Memorial Day, last Monday of May. This one was already right — it never
    /// used `weekOfMonth`, only `day > 24`, which holds because May has 31 days.
    @Test func memorialDayIsClosed() {
        #expect(!isOpen(2026, 5, 25))
        #expect(!isOpen(2025, 5, 26))
        #expect(!isOpen(2024, 5, 27))
        #expect(isOpen(2026, 5, 18))
    }

    /// Labor Day, first Monday of September. Also already right.
    @Test func laborDayIsClosed() {
        #expect(!isOpen(2026, 9, 7))
        #expect(!isOpen(2025, 9, 1))
        #expect(!isOpen(2024, 9, 2))
        #expect(isOpen(2026, 9, 14))
    }

    /// Juneteenth, an NYSE closure since 2021 and simply absent from the list.
    @Test func juneteenthIsClosedFrom2021() {
        #expect(!isOpen(2026, 6, 19))
        #expect(!isOpen(2025, 6, 19))
        // A Thursday in 2019, before it became a market holiday.
        #expect(isOpen(2019, 6, 19))
    }

    /// The fixed-date closures.
    @Test func fixedDateHolidaysAreClosed() {
        #expect(!isOpen(2026, 1, 1))
        #expect(!isOpen(2026, 12, 25))
        #expect(!isOpen(2025, 7, 4))
    }

    /// Observed closures: a fixed holiday landing on a weekend shuts the
    /// exchange on the adjacent weekday. 4 July 2026 is a Saturday, so NYSE
    /// closes on Friday the 3rd — which the app previously called a normal
    /// session and would have shown live prices for.
    @Test func aHolidayOnAWeekendClosesTheAdjacentWeekday() {
        #expect(!isOpen(2026, 7, 3))     // Sat 4 July 2026 → observed Friday
        #expect(!isOpen(2027, 7, 5))     // Sun 4 July 2027 → observed Monday
        #expect(!isOpen(2027, 12, 24))   // Sat 25 Dec 2027 → observed Friday
        // The Friday before an ordinary Saturday is still a trading day.
        #expect(isOpen(2026, 7, 10))
    }

    /// An ordinary Tuesday in the middle of the session is open — the guard
    /// against a holiday rule that closes everything.
    @Test func anOrdinaryTradingDayIsOpen() {
        #expect(isOpen(2026, 8, 4))
        #expect(isOpen(2026, 3, 10))
    }
}

// MARK: - Frankfurter host

struct FrankfurterHostTests {

    /// `api.frankfurter.app` answers 301 to `api.frankfurter.dev/v1`.
    /// URLSession follows it, so nothing looked broken — which is why this is
    /// pinned rather than left to chance. A redirect-policy change would take
    /// FX down silently, and a silent FX failure is every foreign position
    /// showing a dash with no explanation.
    @Test func theCanonicalHostIsRequestedDirectly() {
        #expect(FrankfurterProvider.baseURL == "https://api.frankfurter.dev/v1")
        #expect(!FrankfurterProvider.baseURL.contains("frankfurter.app"))
    }
}

// MARK: - Daily snapshots

@MainActor
struct PortfolioSnapshotRecorderTests {

    private func setUp(_ ctx: ModelContext, priced: Bool) async throws -> (PortfolioViewModel, [Account]) {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)

        let priceStore = PriceStore()
        priceStore.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: priceStore)
        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVDA", quantity: 2, unitPrice: 181,
            fxRate: Decimal(string: "0.86")!, commission: 0, account: acc,
            date: Date(), note: "",
            asset: AssetSearchResult(symbol: "NVDA", name: "NVIDIA", exchange: "XNGS",
                                     assetClass: .stock, currency: "USD", mic: "XNGS")
        )
        if priced {
            priceStore.applyQuote(Quote(
                symbol: "NVDA", price: Decimal(string: "223.96")!,
                previousClose: Decimal(string: "218.99")!, changeAbsolute: 0,
                changePercent: 0, currency: "USD", timestamp: Date(), source: .rest
            ), as: ListingID(symbol: "NVDA", mic: "XNAS"))
            // The real chain, for the same reason as in the detail tests.
            vm.bind(
                modelContext: ctx, priceStore: priceStore,
                fxProvider: StubRate(value: Decimal(string: "0.86693")!)
            )
            await vm.refreshCurrentFXRates()
        }
        return (vm, [acc])
    }

    /// The gap this closes: `PortfolioSnapshot` was in the schema and nothing
    /// ever wrote one, so Evolução could only ever be empty.
    @Test func afullyPricedPortfolioIsRecorded() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, accounts) = try await setUp(ctx, priced: true)

        #expect(PortfolioSnapshotRecorder.record(
            holdings: vm.holdings, accounts: accounts, in: ctx
        ))

        let series = PortfolioSnapshotRecorder.series(in: ctx)
        #expect(series.count == 1)
        let snapshot = try #require(series.first)
        #expect(snapshot.totalValue > Decimal(string: "388.30")!)
        #expect(snapshot.totalCost == Decimal(string: "311.32")!)
    }

    /// One point per day: a second call the same day overwrites rather than
    /// appending, so relaunching does not turn one day into six.
    @Test func recordingTwiceInADayOverwritesRatherThanAppends() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, accounts) = try await setUp(ctx, priced: true)

        PortfolioSnapshotRecorder.record(holdings: vm.holdings, accounts: accounts, in: ctx)
        PortfolioSnapshotRecorder.record(holdings: vm.holdings, accounts: accounts, in: ctx)
        PortfolioSnapshotRecorder.record(holdings: vm.holdings, accounts: accounts, in: ctx)

        #expect(PortfolioSnapshotRecorder.series(in: ctx).count == 1)
    }

    /// A different day is a different point.
    @Test func adifferentDayAddsAPoint() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, accounts) = try await setUp(ctx, priced: true)

        PortfolioSnapshotRecorder.record(holdings: vm.holdings, accounts: accounts, in: ctx)
        PortfolioSnapshotRecorder.record(
            holdings: vm.holdings, accounts: accounts, in: ctx,
            now: Date().addingTimeInterval(-86_400)
        )

        #expect(PortfolioSnapshotRecorder.series(in: ctx).count == 2)
    }

    /// A partially priced portfolio is not recorded at all.
    ///
    /// The header may show a partial figure with a caveat beside it. A stored
    /// point has no caveat: a year from now, a dip caused by a provider outage
    /// would be indistinguishable from a real one, and the chart would show a
    /// crash that never happened.
    @Test func apartiallyPricedPortfolioIsNotRecorded() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, accounts) = try await setUp(ctx, priced: false)

        #expect(!PortfolioSnapshotRecorder.record(
            holdings: vm.holdings, accounts: accounts, in: ctx
        ))
        #expect(PortfolioSnapshotRecorder.series(in: ctx).isEmpty)
    }

    /// The silent half of the hole: `save()` could throw and the method
    /// returned `true` regardless, so `true` no longer meant "on disk". With a
    /// store that cannot hold a `PortfolioSnapshot`, a fully priced portfolio
    /// must report `false` — the same-day retry (a later revision, or a reopen)
    /// is what recovers, and it can only fire because the caller was told the
    /// truth.
    @Test func afailedSaveReportsFalseNotTrue() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let (vm, accounts) = try await setUp(ctx, priced: true)

        struct SaveRefused: Error {}
        // A fully priced portfolio, but the store refuses the write. Before the
        // fix this returned true regardless; now the caller is told false.
        #expect(!PortfolioSnapshotRecorder.record(
            holdings: vm.holdings, accounts: accounts, in: ctx,
            save: { _ in throw SaveRefused() }
        ))
    }

    /// An empty app records nothing — a row of zeros would draw a flat line at
    /// zero for as long as it took to add a first position.
    @Test func anEmptyPortfolioRecordsNothing() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        #expect(!PortfolioSnapshotRecorder.record(holdings: [], accounts: [], in: ctx))
        #expect(PortfolioSnapshotRecorder.series(in: ctx).isEmpty)
    }
}
