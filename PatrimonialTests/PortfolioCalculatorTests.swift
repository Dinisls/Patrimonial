import Foundation
import Testing
@testable import Patrimonial

struct PortfolioCalculatorTests {

    typealias Tx = PortfolioCalculator.Transaction

    // MARK: - Basic buy

    @Test func singleBuyComputesCorrectly() throws {
        let txs = [buy("AAPL", qty: 10, price: 150, fx: Decimal(string: "0.92")!, commission: 5, date: d("2026-01-15"))]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        #expect(h.quantity == 10)
        // cost = 10 × 150 × 0.92 + 5 = 1380 + 5 = 1385
        #expect(h.totalCostEUR == 1385)
        // avg = 1385 / 10 = 138.5
        #expect(h.averagePriceEUR == Decimal(string: "138.5"))
        #expect(h.realizedPL == 0)
        #expect(h.isOpen == true)
    }

    // MARK: - Multiple buys at different prices and FX rates (USD → EUR)

    @Test func multipleBuysDifferentFXRates() throws {
        let txs = [
            buy("NVDA", qty: 5,  price: 120, fx: Decimal(string: "0.90")!, commission: 3, date: d("2026-01-10")),
            buy("NVDA", qty: 3,  price: 130, fx: Decimal(string: "0.95")!, commission: 2, date: d("2026-02-15")),
            buy("NVDA", qty: 2,  price: 140, fx: Decimal(string: "0.88")!, commission: 4, date: d("2026-03-20")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        #expect(h.quantity == 10)
        // cost1 = 5 × 120 × 0.90 + 3 = 540 + 3 = 543
        // cost2 = 3 × 130 × 0.95 + 2 = 370.5 + 2 = 372.5
        // cost3 = 2 × 140 × 0.88 + 4 = 246.4 + 4 = 250.4
        // total = 543 + 372.5 + 250.4 = 1165.9
        #expect(h.totalCostEUR == Decimal(string: "1165.9"))
        // avg = 1165.9 / 10 = 116.59
        #expect(h.averagePriceEUR == Decimal(string: "116.59"))
        #expect(h.commissions == 9)
    }

    // MARK: - Partial sale

    @Test func partialSaleComputesPLAndRemainder() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 150, fx: Decimal(string: "0.92")!, commission: 5, date: d("2026-01-15")),
            sell("AAPL", qty: 4,  price: 180, fx: Decimal(string: "0.90")!, commission: 3, date: d("2026-06-15")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        // After buy: cost = 1385, qty = 10, avg = 138.5
        // Sale: proceeds = 4 × 180 × 0.90 - 3 = 648 - 3 = 645
        //        costOfSold = 138.5 × 4 = 554
        //        realizedPL = 645 - 554 = 91
        // Remaining: qty = 6, cost = 1385 - 554 = 831
        #expect(h.quantity == 6)
        #expect(h.totalCostEUR == 831)
        // avg = 831 / 6 = 138.5 (same as before)
        #expect(h.averagePriceEUR == Decimal(string: "138.5"))
        #expect(h.realizedPL == 91)
        #expect(h.isOpen == true)
    }

    // MARK: - Full sale then new buy (price resets)

    @Test func fullSaleThenNewBuyResetsPriceAverage() throws {
        let txs = [
            buy("MSFT", qty: 5, price: 400, fx: 1, commission: 0, date: d("2026-01-10")),
            sell("MSFT", qty: 5, price: 450, fx: 1, commission: 0, date: d("2026-03-10")),
            buy("MSFT", qty: 3, price: 420, fx: 1, commission: 0, date: d("2026-05-10")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        // First buy: cost = 5 × 400 = 2000, qty = 5, avg = 400
        // Full sale: proceeds = 5 × 450 = 2250, costOfSold = 2000
        //            realizedPL = 2250 - 2000 = 250
        //            qty = 0, cost resets to 0
        // New buy: cost = 3 × 420 = 1260, qty = 3
        #expect(h.quantity == 3)
        #expect(h.totalCostEUR == 1260)
        // avg should be 420, NOT contaminated by old cost basis
        #expect(h.averagePriceEUR == 420)
        // realizedPL from the first sale is preserved
        #expect(h.realizedPL == 250)
        #expect(h.isOpen == true)
    }

    // MARK: - Closed position

    @Test func closedPositionHasZeroQuantityAndRealizedPL() throws {
        let txs = [
            buy("VOO", qty: 10, price: 480, fx: Decimal(string: "0.92")!, commission: 0, date: d("2026-01-10")),
            sell("VOO", qty: 10, price: 500, fx: Decimal(string: "0.93")!, commission: 0, date: d("2026-06-10")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        #expect(h.quantity == 0)
        #expect(h.isOpen == false)
        #expect(h.totalCostEUR == 0)
        // realizedPL = (10 × 500 × 0.93) - (10 × 480 × 0.92)
        //            = 4650 - 4416 = 234
        #expect(h.realizedPL == 234)
    }

    // MARK: - Overselling fails

    @Test func sellingMoreThanAvailableThrows() throws {
        let txs = [
            buy("AAPL", qty: 5, price: 150, fx: 1, commission: 0, date: d("2026-01-10")),
            sell("AAPL", qty: 8, price: 160, fx: 1, commission: 0, date: d("2026-02-10")),
        ]
        #expect(throws: PortfolioCalculator.CalculationError.self) {
            try PortfolioCalculator.computeHoldings(from: txs)
        }
    }

    @Test func sellingMoreThanAvailableIncludesDetails() {
        let txs = [
            buy("AAPL", qty: 5, price: 150, fx: 1, commission: 0, date: d("2026-01-10")),
            sell("AAPL", qty: 8, price: 160, fx: 1, commission: 0, date: d("2026-02-10")),
        ]
        do {
            _ = try PortfolioCalculator.computeHoldings(from: txs)
            Issue.record("Should have thrown")
        } catch let e as PortfolioCalculator.CalculationError {
            if case .insufficientQuantity(let sym, let req, let avail) = e {
                #expect(sym == "AAPL")
                #expect(req == 8)
                #expect(avail == 5)
            } else {
                Issue.record("Wrong error case")
            }
        } catch {
            Issue.record("Wrong error type")
        }
    }

    // MARK: - Dividend in USD

    @Test func dividendInUSD() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 150, fx: Decimal(string: "0.92")!, commission: 0, date: d("2026-01-10")),
            dividend("AAPL", qty: 10, unitDiv: Decimal(string: "0.96")!, fx: Decimal(string: "0.91")!, commission: 0, date: d("2026-04-15")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        // dividend = 10 × 0.96 × 0.91 - 0 = 8.736
        #expect(h.dividendsReceived == Decimal(string: "8.736"))
        #expect(h.quantity == 10)
    }

    // MARK: - Commissions on everything

    @Test func commissionsAccumulate() throws {
        let txs = [
            buy("VOO", qty: 5, price: 480, fx: 1, commission: 10, date: d("2026-01-10")),
            buy("VOO", qty: 3, price: 490, fx: 1, commission: 8, date: d("2026-02-10")),
            sell("VOO", qty: 2, price: 500, fx: 1, commission: 5, date: d("2026-03-10")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        #expect(holdings[0].commissions == 23)
    }

    // MARK: - FIFO throws not implemented

    @Test func fifoThrowsNotImplemented() {
        let txs = [buy("AAPL", qty: 1, price: 100, fx: 1, commission: 0, date: d("2026-01-10"))]
        #expect(throws: PortfolioCalculator.CalculationError.self) {
            try PortfolioCalculator.computeHoldings(from: txs, method: .fifo)
        }
    }

    // MARK: - Missing quote (no crash, no zero assumption)

    @Test func holdingWithoutQuoteReturnsNilValues() throws {
        let txs = [buy("AAPL", qty: 10, price: 150, fx: 1, commission: 0, date: d("2026-01-10"))]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        // No quote attached
        #expect(h.currentPriceNative == nil)
        #expect(h.marketValueEUR == nil)
        #expect(h.unrealizedPL == nil)
        #expect(h.unrealizedPLPercent == nil)
        #expect(h.dayChangeEUR == nil)
        #expect(h.totalReturn == nil)
        // But cost data is still computed
        #expect(h.totalCostEUR == 1500)
        #expect(h.quantity == 10)
    }

    // MARK: - Holding with quote fills market values

    @Test func holdingWithQuoteFillsMarketValues() throws {
        let txs = [buy("AAPL", qty: 10, price: 150, fx: Decimal(string: "0.92")!, commission: 0, date: d("2026-01-10"))]
        var holdings = try PortfolioCalculator.computeHoldings(from: txs)

        // Simulate attaching a quote
        holdings[0].currentPriceNative = 180
        holdings[0].currency = "USD"
        holdings[0].currentFXRate = FXRate(from: "USD", to: "EUR", value: Decimal(string: "0.90")!)
        holdings[0].previousCloseNative = 178
        holdings[0].sessionStart = Calendar.current.startOfDay(for: Date())

        let h = holdings[0]
        // marketValue = 10 × 180 × 0.90 = 1620
        #expect(h.marketValueEUR == 1620)
        // cost = 10 × 150 × 0.92 = 1380
        // unrealizedPL = 1620 - 1380 = 240
        #expect(h.unrealizedPL == 240)
        // dayChange = 10 × (180 - 178) × 0.90 = 18
        #expect(h.dayChangeEUR == 18)
    }

    // MARK: - Portfolio weights sum to 100

    @Test func portfolioWeightsSumTo100() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 150, fx: 1, commission: 0, date: d("2026-01-10"), account: "A"),
            buy("MSFT", qty: 5,  price: 400, fx: 1, commission: 0, date: d("2026-01-10"), account: "A"),
        ]
        var holdings = try PortfolioCalculator.computeHoldings(from: txs)
        holdings[0].currentPriceNative = 160
        holdings[0].currency = "EUR"
        holdings[0].currentFXRate = FXRate.identity("EUR")
        holdings[1].currentPriceNative = 420
        holdings[1].currency = "EUR"
        holdings[1].currentFXRate = FXRate.identity("EUR")

        guard let totalMV = PortfolioCalculator.totalMarketValue(holdings) else {
            Issue.record("totalMarketValue should not be nil")
            return
        }

        var totalWeight: Decimal = 0
        for h in holdings {
            guard let mv = h.marketValueEUR else { continue }
            totalWeight += PortfolioCalculator.portfolioWeight(holdingMarketValue: mv, totalMarketValue: totalMV)
        }
        let diff = abs(totalWeight - 100)
        #expect(diff < Decimal(string: "0.0001")!)
    }

    // MARK: - Division by zero when quantity = 0

    @Test func zeroQuantityDoesNotCrash() throws {
        let txs = [
            buy("AAPL", qty: 5, price: 150, fx: 1, commission: 0, date: d("2026-01-10")),
            sell("AAPL", qty: 5, price: 160, fx: 1, commission: 0, date: d("2026-02-10")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]
        #expect(h.averagePriceEUR == 0)
        #expect(h.yieldOnCost == nil)
    }

    // MARK: - Multiple assets in same account

    @Test func multipleAssetsGroupCorrectly() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 150, fx: 1, commission: 0, date: d("2026-01-10")),
            buy("MSFT", qty: 5,  price: 400, fx: 1, commission: 0, date: d("2026-01-15")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        #expect(holdings.count == 2)
        let symbols = Set(holdings.map(\.assetSymbol))
        #expect(symbols == ["AAPL", "MSFT"])
    }

    // MARK: - Same asset in different accounts

    @Test func sameAssetDifferentAccountsUnifiesIntoOnePosition() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 150, fx: 1, commission: 0, date: d("2026-01-10"), account: "TR"),
            buy("AAPL", qty: 5,  price: 160, fx: 1, commission: 0, date: d("2026-01-10"), account: "IBKR"),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        #expect(holdings.count == 1)
        let h = holdings[0]
        #expect(h.quantity == 15)
        #expect(h.totalCostEUR == Decimal(2300))
        #expect(h.accountID.isEmpty)
    }

    // MARK: - Yield on cost

    @Test func yieldOnCostCalculation() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 150, fx: 1, commission: 0, date: d("2026-01-10")),
            dividend("AAPL", qty: 10, unitDiv: 1, fx: 1, commission: 0, date: d("2026-04-15")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]
        // dividends = 10, cost = 1500
        // yield = 10 / 1500 × 100 = 0.666...
        let expected = (Decimal(10) / Decimal(1500)) * 100
        #expect(h.yieldOnCost == expected)
    }

    // MARK: - Portfolio aggregations

    @Test func totalRealizedPLAcrossHoldings() throws {
        let txs = [
            buy("AAPL", qty: 10, price: 100, fx: 1, commission: 0, date: d("2026-01-10")),
            sell("AAPL", qty: 10, price: 120, fx: 1, commission: 0, date: d("2026-02-10")),
            buy("MSFT", qty: 5, price: 400, fx: 1, commission: 0, date: d("2026-01-10")),
            sell("MSFT", qty: 5, price: 380, fx: 1, commission: 0, date: d("2026-02-10")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        // AAPL PL = (120-100) × 10 = 200
        // MSFT PL = (380-400) × 5 = -100
        // Total = 100
        #expect(PortfolioCalculator.totalRealizedPL(holdings) == 100)
    }

    // MARK: - Repeating decimal average: 5 successive partial sales preserve total cost

    @Test func successivePartialSalesPreserveTotalCost() throws {
        // 3 buys totaling 15 units at cost 1000 EUR → avg = 1000/15 = 66.666...
        let txs: [Tx] = [
            buy("TEST", qty: 5, price: 60, fx: 1, commission: Decimal(string: "33.33")!, date: d("2026-01-01")),
            buy("TEST", qty: 5, price: 70, fx: 1, commission: Decimal(string: "16.67")!, date: d("2026-01-02")),
            buy("TEST", qty: 5, price: 80, fx: 1, commission: 0, date: d("2026-01-03")),
            // cost1 = 5×60 + 33.33 = 333.33
            // cost2 = 5×70 + 16.67 = 366.67
            // cost3 = 5×80 + 0     = 400.00
            // totalCost = 1100.00, qty = 15, avg = 73.333...

            // 5 successive partial sales of 3 units each
            sell("TEST", qty: 3, price: 90, fx: 1, commission: 0, date: d("2026-02-01")),
            sell("TEST", qty: 3, price: 85, fx: 1, commission: 0, date: d("2026-02-02")),
            sell("TEST", qty: 3, price: 95, fx: 1, commission: 0, date: d("2026-02-03")),
            sell("TEST", qty: 3, price: 88, fx: 1, commission: 0, date: d("2026-02-04")),
            sell("TEST", qty: 3, price: 92, fx: 1, commission: 0, date: d("2026-02-05")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        let originalTotalCost: Decimal = 1100
        // All 15 units sold → totalCostEUR should be 0 (position closed)
        #expect(h.quantity == 0)
        #expect(h.totalCostEUR == 0)

        // Sum of all costOfSold across 5 sales must equal original total cost.
        // We verify this indirectly: realizedPL = totalProceeds - totalCostSold
        // totalProceeds = 3×90 + 3×85 + 3×95 + 3×88 + 3×92 = 270+255+285+264+276 = 1350
        let totalProceeds: Decimal = 1350
        // realizedPL = totalProceeds - originalTotalCost = 1350 - 1100 = 250
        // With repeating decimal avg price, Decimal rounding may drift past the 30th digit.
        // Verify to the cent.
        let plDiff = abs(h.realizedPL - (totalProceeds - originalTotalCost))
        #expect(plDiff < Decimal(string: "0.01")!)
        let plDiff2 = abs(h.realizedPL - 250)
        #expect(plDiff2 < Decimal(string: "0.01")!)
    }

    @Test func partialSalesWithRepeatingDecimalKeepCostConsistent() throws {
        // 1000 EUR across 3 units → avg = 333.333... per unit
        let txs: [Tx] = [
            buy("XYZ", qty: 3, price: Decimal(string: "333.3333333")!, fx: 1, commission: Decimal(string: "0.0001")!, date: d("2026-01-01")),
            // cost = 3 × 333.3333333 + 0.0001 = 999.9999999 + 0.0001 = 1000.0000
            sell("XYZ", qty: 1, price: 400, fx: 1, commission: 0, date: d("2026-02-01")),
            sell("XYZ", qty: 1, price: 400, fx: 1, commission: 0, date: d("2026-03-01")),
        ]
        let holdings = try PortfolioCalculator.computeHoldings(from: txs)
        let h = holdings[0]

        #expect(h.quantity == 1)
        let originalCost: Decimal = 1000
        // After selling 2 of 3 units, remaining cost should be exactly 1/3 of original
        let expectedRemaining = originalCost * (1 as Decimal / 3 as Decimal)
        // costOfSold1 = 1000 × (1/3) = 333.333...
        // remaining after sale1 = 1000 - 333.333... = 666.666...
        // costOfSold2 = 666.666... × (1/2) = 333.333...
        // remaining after sale2 = 666.666... - 333.333... = 333.333...
        let diff = abs(h.totalCostEUR - expectedRemaining)
        #expect(diff < Decimal(string: "0.01")!)
    }

    // MARK: - Helpers

    private func buy(_ symbol: String, qty: Decimal, price: Decimal, fx: Decimal,
                     commission: Decimal, date: Date, account: String = "default",
                     mic: String? = nil) -> Tx {
        Tx(type: .assetPurchase, assetSymbol: symbol, assetMIC: mic, accountID: account,
           accountName: account, quantity: qty, unitPrice: price,
           fxRate: fx, commission: commission,
           amountEUR: qty * price * fx + commission, date: date)
    }

    private func sell(_ symbol: String, qty: Decimal, price: Decimal, fx: Decimal,
                      commission: Decimal, date: Date, account: String = "default",
                      mic: String? = nil) -> Tx {
        Tx(type: .assetSale, assetSymbol: symbol, assetMIC: mic, accountID: account,
           accountName: account, quantity: qty, unitPrice: price,
           fxRate: fx, commission: commission,
           amountEUR: qty * price * fx - commission, date: date)
    }

    private func dividend(_ symbol: String, qty: Decimal, unitDiv: Decimal, fx: Decimal,
                          commission: Decimal, date: Date, account: String = "default",
                          mic: String? = nil) -> Tx {
        Tx(type: .dividend, assetSymbol: symbol, assetMIC: mic, accountID: account,
           accountName: account, quantity: qty, unitPrice: unitDiv,
           fxRate: fx, commission: commission,
           amountEUR: qty * unitDiv * fx - commission, date: date)
    }

    private func d(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)!
    }
}
