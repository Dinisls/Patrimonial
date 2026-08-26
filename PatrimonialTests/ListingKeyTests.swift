import Foundation
import Testing
@testable import Patrimonial

// MARK: - A listing is a ticker AND a venue

/// Ponto F, camada 1: identidade e cálculo.
///
/// The bug this closes is not a wrong number on screen. Two instruments sharing
/// a ticker in one account were grouped into a single holding, so the cost basis
/// written to the position was averaged across NVIDIA at 194,22 EUR and a 2x
/// inverse ETF at 3,97 USD. Real figures from 2026-08-07 throughout.
struct ListingKeyTests {

    typealias Tx = PortfolioCalculator.Transaction

    // MARK: - The key itself

    @Test func aVenuelessListingKeysAsTheBareSymbol() {
        // The hinge of the whole migration: every key already on disk is a
        // valid key of the new type and means the same thing. If this stops
        // holding, existing stores lose their prices and their history on the
        // first launch after an update.
        #expect(ListingID(symbol: "NVD").storageKey == "NVD")
        #expect(ListingID(symbol: "NVD", mic: nil).storageKey == "NVD")
        #expect(ListingID(symbol: "NVD", mic: "").storageKey == "NVD")
        #expect(ListingID(symbol: "NVD", mic: "   ").storageKey == "NVD")
    }

    @Test func anEmptyVenueIsTheSameAsNoVenue() {
        // `""` and nil were two spellings of "unknown" in the old code, and they
        // would key apart here — one position each.
        #expect(ListingID(symbol: "NVD", mic: "") == ListingID(symbol: "NVD", mic: nil))
        #expect(ListingID(symbol: "NVD", mic: "").isVenueless)
    }

    @Test func symbolAndVenueAreNormalisedBeforeAnythingHashesThem() {
        #expect(ListingID(symbol: " nvd ", mic: " xetr ") == ListingID(symbol: "NVD", mic: "XETR"))
    }

    @Test func aVenuedListingNeverCollidesWithTheVenuelessOne() {
        #expect(ListingID(symbol: "NVD", mic: "XETR") != ListingID(symbol: "NVD"))
        #expect(ListingID(symbol: "NVD", mic: "XETR").storageKey != "NVD")
    }

    @Test func storageKeysRoundTrip() {
        for listing in [
            ListingID(symbol: "NVD"),
            ListingID(symbol: "NVD", mic: "XETR"),
            ListingID(symbol: "NVD.DE", mic: "XETR"),
            ListingID(symbol: "BTC", mic: "CRYPTO"),
        ] {
            #expect(ListingID.from(storageKey: listing.storageKey) == listing)
        }
    }

    // MARK: - One venue, one spelling

    /// NASDAQ answers as XNGS, XNMS or XNCM depending on the listing tier, and
    /// our own rows sometimes carry the plain name because the buy sheet falls
    /// back to `exchange` when the provider sends no `mic_code`. All of those
    /// are one venue; a key that admits four spellings is four positions.
    @Test func tiersAndNamesOfOneVenueProduceOneKey() {
        let spellings = ["XNAS", "XNMS", "XNGS", "XNCM", "NASDAQ", "nasdaq"]
        let keys = Set(spellings.map { ListingID(symbol: "AAPL", mic: $0).storageKey })
        #expect(keys.count == 1, "AAPL na NASDAQ tem de ser uma só posição, e é \(keys)")
    }

    /// The other half. Frankfurt, Munich and Düsseldorf are separate German
    /// markets with separate prices, and folding them together would be the same
    /// class of bug pointing the other way.
    @Test func differentVenuesKeepDifferentKeys() {
        let keys = Set(["XETR", "XFRA", "XMUN", "XDUS"].map {
            ListingID(symbol: "NVD", mic: $0).storageKey
        })
        #expect(keys.count == 4)
    }

    /// An unknown venue is passed through, not mapped to a neighbour. XBUE has
    /// no entry anywhere, and inventing one would merge Buenos Aires into
    /// whatever happened to be nearby in the table.
    @Test func anUnknownVenueIsKeptAsItself() {
        #expect(ListingID(symbol: "AAPL", mic: "xbue").mic == "XBUE")
    }

    /// The invariant that keeps the buy sheet and the calculator from
    /// disagreeing. `upsertAsset` accepts a purchase as a top-up when
    /// `venuesAgree`; the calculator files it under `storageKey`. Any pair where
    /// those two answers differ is a purchase the app accepts and then files as
    /// a separate position — or worse, refuses while the key says it is the same
    /// row.
    @Test func agreementAndKeyEqualityAreTheSameQuestion() {
        let venues = [
            "XNAS", "XNMS", "XNGS", "XNCM", "XNYS", "ARCX", "BATS", "XASE",
            "NASDAQ", "NYSE", "XETR", "XETRA", "XFRA", "XMUN", "XDUS", "XHAM",
            "XLIS", "XAMS", "XPAR", "LISBON", "XSWX", "XBUE", "XBOG",
        ]
        for a in venues {
            for b in venues {
                let sameKey = ListingID(symbol: "T", mic: a) == ListingID(symbol: "T", mic: b)
                #expect(
                    MarketCalendar.venuesAgree(a, b) == sameKey,
                    "\(a) vs \(b): venuesAgree diz \(MarketCalendar.venuesAgree(a, b)), a chave diz \(sameKey)"
                )
            }
        }
    }

    /// A row with no venue is not a row on "no venue" — it is a row whose venue
    /// was never written down, so it is compatible with any venue for its
    /// ticker. This asymmetry is what the backfill leans on, and it must not
    /// leak into equality, which is what the grouping leans on.
    @Test func aVenuelessRowIsCompatibleWithAnyVenueButEqualToNone() {
        let bare = ListingID(symbol: "NVD")
        let xetr = ListingID(symbol: "NVD", mic: "XETR")
        let xnms = ListingID(symbol: "NVD", mic: "XNMS")

        #expect(bare.couldBe(xetr))
        #expect(bare.couldBe(xnms))
        #expect(xetr.couldBe(bare))
        #expect(!xetr.couldBe(xnms))
        #expect(!bare.couldBe(ListingID(symbol: "AAPL", mic: "XETR")))

        #expect(bare != xetr)
    }

    // MARK: - The corruption, at the calculator

    /// The whole point of ponto F. Same ticker, same account, two venues: two
    /// positions, each with its own cost basis and its own quantity.
    ///
    /// Before this, both landed in the bucket `"NVD:acc"` and came out as a
    /// single holding of 12 units costing 422,86 € — a number that describes no
    /// instrument that exists.
    @Test func twoVenuesUnderOneTickerAreTwoPositions() throws {
        let nvidia = buy("NVD", mic: "XETR", qty: 2, price: Decimal(string: "194.22")!, fx: 1)
        let inverseETF = buy(
            "NVD", mic: "XNMS", qty: 10,
            price: Decimal(string: "3.97")!, fx: Decimal(string: "0.86693")!
        )

        let holdings = try PortfolioCalculator.computeHoldings(from: [nvidia, inverseETF])

        #expect(holdings.count == 2)
        #expect(!holdings.contains { $0.quantity == 12 }, "as duas posições não podem fundir-se")

        let xetra = try #require(holdings.first { $0.assetMIC == "XETR" })
        #expect(xetra.quantity == 2)
        #expect(xetra.totalCostEUR == Decimal(string: "388.44"))

        let nasdaq = try #require(holdings.first { $0.assetMIC == "XNAS" })
        #expect(nasdaq.quantity == 10)
        #expect(nasdaq.totalCostEUR == Decimal(string: "34.417121"))

        // And they are addressable apart — the list identity the UI iterates on.
        #expect(xetra.id != nasdaq.id)
    }

    /// The converse, and the one that would be a regression rather than a bug
    /// fix: buying more of the same listing must stay one position even when the
    /// two purchases recorded different tiers of the same exchange.
    @Test func oneListingSpelledTwoWaysStaysOnePosition() throws {
        let holdings = try PortfolioCalculator.computeHoldings(from: [
            buy("AAPL", mic: "XNMS", qty: 1, price: 300, fx: 1),
            buy("AAPL", mic: "XNAS", qty: 1, price: 313, fx: 1),
        ])

        #expect(holdings.count == 1)
        #expect(holdings[0].quantity == 2)
        #expect(holdings[0].totalCostEUR == 613)
    }

    /// A venueless row and a venued one under the same ticker stay apart. It is
    /// tempting to adopt the bare one into the venued position — it is probably
    /// the same thing — but "probably" is exactly what put a 2x inverse ETF's
    /// price on a NVIDIA position. Adoption happens once, in the backfill, and
    /// only where it is unambiguous; the calculator does not guess.
    @Test func aVenuelessRowIsNotSilentlyAdoptedByAVenuedPosition() throws {
        let holdings = try PortfolioCalculator.computeHoldings(from: [
            buy("NVD", mic: nil, qty: 1, price: 100, fx: 1),
            buy("NVD", mic: "XETR", qty: 1, price: 194, fx: 1),
        ])

        #expect(holdings.count == 2)
        #expect(holdings.contains { $0.assetMIC == nil && $0.quantity == 1 })
        #expect(holdings.contains { $0.assetMIC == "XETR" && $0.quantity == 1 })
    }

    /// A store where nothing has a venue yet — every user's store, the instant
    /// before the backfill runs — must compute exactly what it computed before
    /// this type existed.
    @Test func aStoreWithNoVenuesAtAllBehavesExactlyAsBefore() throws {
        let txs = [
            buy("AAPL", mic: nil, qty: 10, price: 150, fx: Decimal(string: "0.92")!, commission: 5),
            buy("AAPL", mic: nil, qty: 5, price: 160, fx: Decimal(string: "0.90")!, commission: 3),
            buy("NVDA", mic: nil, qty: 2, price: 120, fx: 1),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)

        #expect(holdings.count == 2)
        let apple = try #require(holdings.first { $0.assetSymbol == "AAPL" })
        #expect(apple.quantity == 15)
        // 10 × 150 × 0.92 + 5 = 1385; 5 × 160 × 0.90 + 3 = 723; total 2108
        #expect(apple.totalCostEUR == 2108)
        #expect(apple.assetMIC == nil)
        #expect(apple.id == "AAPL:", "posição unificada tem accountID vazio")
    }

    /// The position is a single pool per listing — accounts are treasury, not
    /// partitions. Two venues under the same ticker are two positions, but two
    /// accounts under the same venue are one.
    @Test func venuesSplitButAccountsUnify() throws {
        let holdings = try PortfolioCalculator.computeHoldings(from: [
            buy("NVD", mic: "XETR", qty: 1, price: 194, fx: 1, account: "a"),
            buy("NVD", mic: "XETR", qty: 1, price: 194, fx: 1, account: "b"),
            buy("NVD", mic: "XNMS", qty: 1, price: 4, fx: 1, account: "a"),
        ])
        #expect(holdings.count == 2)
        let xetr = try #require(holdings.first { $0.assetMIC == "XETR" })
        #expect(xetr.quantity == 2)
        let xnms = try #require(holdings.first { $0.assetMIC == "XNAS" })
        #expect(xnms.quantity == 1)
    }

    // MARK: - The venue reaches the session boundary

    /// Purchase lots carry the transaction date so the session boundary can be
    /// resolved per listing at read time.
    @Test func purchaseLotsCarryTheBuyDate() throws {
        let bought = Date(timeIntervalSince1970: 1_750_000_000)
        let holdings = try PortfolioCalculator.computeHoldings(
            from: [buy("NVD", mic: "XETR", qty: 1, price: 194, fx: 1, date: bought)]
        )
        #expect(holdings[0].purchaseLots.count == 1)
        #expect(holdings[0].purchaseLots[0].date == bought)
        #expect(holdings[0].purchaseLots[0].unitPriceNative == 194)
    }

    /// The session boundary is resolved per listing by the ViewModel, which
    /// reads the MIC. The result shows up in how the day change classifies each
    /// lot.
    ///
    /// Read on the evening of US Thanksgiving 2026, a Thursday: NYSE is shut and
    /// XETRA trades, so XETRA's session began on the 26th while the widest
    /// boundary is still NYSE's Wednesday — eighteen hours apart. A lot bought
    /// on the Wednesday afternoon falls on opposite sides of the two. On an
    /// ordinary day the boundaries coincide and this test would pass while
    /// asserting nothing.
    @Test func theDefaultResolverReadsTheMIC() throws {
        let thanksgivingEvening = iso("2026-11-26T20:00:00+01:00")
        let boughtOnTheWednesday = iso("2026-11-25T15:00:00+01:00")

        var onXetra = try PortfolioCalculator.computeHoldings(
            from: [buy("NVD", mic: "XETR", qty: 1, price: 194, fx: 1, date: boughtOnTheWednesday)]
        )[0]
        // XETRA's current session is Thursday's, which the Wednesday purchase
        // predates: an earlier lot, measured from the previous close.
        let xetraSession = MarketCalendar.currentSessionStart(.xetra, at: thanksgivingEvening)
        onXetra.sessionStart = xetraSession
        onXetra.currentPriceNative = 200
        onXetra.previousCloseNative = 190
        onXetra.currency = "EUR"
        onXetra.currentFXRate = FXRate.identity("EUR")
        // The lot predates XETRA's Thursday session → older lot → uses prevClose.
        #expect(onXetra.dayChangeEUR == 10)

        var venueless = try PortfolioCalculator.computeHoldings(
            from: [buy("NVD", mic: nil, qty: 1, price: 194, fx: 1, date: boughtOnTheWednesday)]
        )[0]
        // With no venue to read, the boundary is the widest — NYSE's Wednesday —
        // so the same lot counts as belonging to the current session and is
        // measured from max(prevClose, purchasePrice) = max(190, 194) = 194.
        let widest = MarketCalendar.widestSessionStart(at: thanksgivingEvening)
        venueless.sessionStart = widest
        venueless.currentPriceNative = 200
        venueless.previousCloseNative = 190
        venueless.currency = "EUR"
        venueless.currentFXRate = FXRate.identity("EUR")
        #expect(venueless.dayChangeEUR == 6)
    }

    // MARK: - Helpers

    private func buy(
        _ symbol: String, mic: String?, qty: Decimal, price: Decimal, fx: Decimal,
        commission: Decimal = 0, account: String = "default",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Tx {
        Tx(
            type: .assetPurchase, assetSymbol: symbol, assetMIC: mic,
            accountID: account, accountName: account,
            quantity: qty, unitPrice: price, fxRate: fx, commission: commission,
            amountEUR: qty * price * fx + commission, date: date
        )
    }

    private func iso(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }
}
