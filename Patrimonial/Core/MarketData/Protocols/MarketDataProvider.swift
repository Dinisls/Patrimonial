import Foundation

/// **Deliberately `nonisolated`.** The target compiles with
/// `-default-isolation MainActor` and `InferIsolatedConformances`, so a plain
/// protocol makes every conforming type main-actor isolated *by inference* —
/// and these conformers are HTTP clients that parse JSON off the main thread.
/// The inference then collides with the response types, which are `nonisolated`
/// because decoding is: `TwelveDataQuoteResponse.toQuote()` calling
/// `CurrencyNormalization.normalize` was a nonisolated context reaching into a
/// main-actor one, which is a warning today in Swift 5 mode and an error under
/// Swift 6.
///
/// Marking it here rather than on each conformer is the point: the isolation of
/// a provider is a property of *being* a provider, and one that is inferred
/// silently is one that changes when an unrelated file is edited.
nonisolated protocol MarketDataProvider: Sendable {
    func quote(for symbol: String) async throws -> Quote
    func quotes(for symbols: [String]) async throws -> [Quote]
    func search(_ query: String) async throws -> [AssetSearchResult]
    func candles(symbol: String, range: ChartRange) async throws -> [Candle]
    var supportsStreaming: Bool { get }
}

/// Symbol lookup on its own, without the quote and candle half of
/// `MarketDataProvider`. Twelve Data's `symbol_search` is keyless and free,
/// which is why the search path uses a different provider from the pricing
/// path.
nonisolated protocol SymbolSearchProvider: Sendable {
    func search(_ query: String) async throws -> [AssetSearchResult]
}

/// Any full provider can also stand in as a search provider — the mock does,
/// in the tests that drive both halves of the combined search.
nonisolated extension MarketDataProvider {
    var asSearchProvider: any SymbolSearchProvider { MarketDataSearchAdapter(provider: self) }
}

private nonisolated struct MarketDataSearchAdapter: SymbolSearchProvider {
    let provider: any MarketDataProvider
    func search(_ query: String) async throws -> [AssetSearchResult] {
        try await provider.search(query)
    }
}

nonisolated protocol QuoteStreaming: Sendable {
    func connect() async
    func subscribe(_ symbols: Set<String>) async
    func unsubscribe(_ symbols: Set<String>) async
    func disconnect() async
    var stream: AsyncStream<Quote> { get }
}

nonisolated protocol FXRateProvider: Sendable {
    /// Returns the rate *labelled with the direction it actually converts in*.
    ///
    /// Not a bare `Decimal`. The caller asks for a direction and the answer
    /// carries one, so the two can be compared instead of assumed to match —
    /// which is exactly the assumption that had `provider.rate(from: currency,
    /// to: "EUR")` and `provider.rate(from: "EUR", to: currency)` looking
    /// equally correct at the call site.
    func rate(from: String, to: String, on date: Date?) async throws -> FXRate
}
