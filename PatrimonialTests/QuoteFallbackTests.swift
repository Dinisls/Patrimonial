import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// Step 2 routing: Twelve Data first, Finnhub only when it fails, crypto always
/// on CoinGecko. Plus the guarantee that simulated data is never silent.
struct QuoteFallbackTests {

    @MainActor
    private func quote(_ symbol: String, price: Decimal, currency: String = "USD") -> Quote {
        Quote(
            symbol: symbol, price: price, previousClose: price,
            changeAbsolute: 0, changePercent: 0, currency: currency,
            timestamp: Date(), source: .rest
        )
    }

    @MainActor
    @Test func primaryProviderIsUsedWhenItWorks() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.mockQuotes = ["NVDA": quote("NVDA", price: 211.84)]
        var fallback = MockMarketDataProvider()
        fallback.mockQuotes = ["NVDA": quote("NVDA", price: 999)]

        let store = PriceStore()
        store.configure(provider: primary, fallbackProvider: fallback, modelContext: container.mainContext)
        await store.refresh([ListingID(symbol: "NVDA")])

        #expect(store.quote(for: ListingID(symbol: "NVDA"))?.price == 211.84)
    }

    /// Finnhub's /quote was returning 502s intermittently; a primary outage must
    /// not leave the portfolio blank when another source can answer.
    @MainActor
    @Test func fallbackTakesOverWhenPrimaryFails() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.shouldFail = true
        primary.failError = .httpError(502)
        var fallback = MockMarketDataProvider()
        fallback.mockQuotes = ["NVDA": quote("NVDA", price: 211.84)]

        let store = PriceStore()
        store.configure(provider: primary, fallbackProvider: fallback, modelContext: container.mainContext)
        await store.refresh([ListingID(symbol: "NVDA")])

        #expect(store.quote(for: ListingID(symbol: "NVDA"))?.price == 211.84)
        #expect(store.lastError == nil)
    }

    /// Twelve Data serves US listings and refuses European ones in the same
    /// batch, so the fallback has to run per symbol rather than all-or-nothing.
    @MainActor
    @Test func fallbackFillsOnlyTheSymbolsPrimaryMissed() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.answersOnlyKnownSymbols = true
        primary.mockQuotes = ["NVDA": quote("NVDA", price: 211.84)]
        var fallback = MockMarketDataProvider()
        fallback.mockQuotes = [
            "NVDA": quote("NVDA", price: 999),
            "GALP.LS": quote("GALP.LS", price: 19.75, currency: "EUR")
        ]

        let store = PriceStore()
        store.configure(provider: primary, fallbackProvider: fallback, modelContext: container.mainContext)
        await store.refresh([ListingID(symbol: "NVDA"), ListingID(symbol: "GALP.LS")])

        // Primary's answer wins where it had one.
        #expect(store.quote(for: ListingID(symbol: "NVDA"))?.price == 211.84)
        // The gap is filled by the fallback.
        #expect(store.quote(for: ListingID(symbol: "GALP.LS"))?.price == 19.75)
        #expect(store.quote(for: ListingID(symbol: "GALP.LS"))?.currency == "EUR")
    }

    @MainActor
    @Test func errorSurfacesOnlyWhenBothFail() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.shouldFail = true
        primary.failError = .httpError(502)
        var fallback = MockMarketDataProvider()
        fallback.shouldFail = true
        fallback.failError = .rateLimited

        let store = PriceStore()
        store.configure(provider: primary, fallbackProvider: fallback, modelContext: container.mainContext)
        await store.refresh([ListingID(symbol: "NVDA")])

        #expect(store.quote(for: ListingID(symbol: "NVDA")) == nil)
        #expect(store.lastError != nil)
    }

    /// The currency has to survive the trip, otherwise the FX conversion is
    /// applied against the wrong rate.
    @MainActor
    @Test func currencyIsPreservedThroughRefresh() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var primary = MockMarketDataProvider()
        primary.mockQuotes = ["IWDA.AS": quote("IWDA.AS", price: 105.42, currency: "EUR")]

        let store = PriceStore()
        store.configure(provider: primary, modelContext: container.mainContext)
        await store.refresh([ListingID(symbol: "IWDA.AS")])

        #expect(store.quote(for: ListingID(symbol: "IWDA.AS"))?.currency == "EUR")
    }

    // MARK: - Mock must never be silent

    @MainActor
    @Test func defaultInitIsFlaggedAsMock() {
        #expect(PriceStore().isUsingMockData == true)
    }

    @MainActor
    @Test func configuringWithMockKeepsTheFlag() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: container.mainContext)
        #expect(store.isUsingMockData == true)
    }

    @MainActor
    @Test func configuringWithLiveProviderClearsTheFlag() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PriceStore()
        store.configure(
            provider: TwelveDataProvider(apiKey: "k"),
            fallbackProvider: FinnhubProvider(apiKey: "k"),
            modelContext: container.mainContext
        )
        #expect(store.isUsingMockData == false)
    }

    /// Views reload derived values off `revision`; replacing a price leaves the
    /// dictionary count unchanged, so the counter has to move.
    @MainActor
    @Test func revisionAdvancesOnEveryAppliedQuote() {
        let store = PriceStore()
        let before = store.revision
        store.applyQuote(quote("NVDA", price: 100), as: ListingID(symbol: "NVDA"))
        store.applyQuote(quote("NVDA", price: 101), as: ListingID(symbol: "NVDA"))
        #expect(store.revision > before)
    }
}
