import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// The FX rate direction backfill: legacy transactions that stored a bare
/// Decimal get `assetFXRateFrom` / `assetFXRateTo` filled from the Asset's
/// currency. The Decimal itself never changes — only the two string columns
/// that say which way it points.
@MainActor
struct FXRateBackfillTests {

    // MARK: - Helpers

    @discardableResult
    private func legacyBuy(
        _ ctx: ModelContext, symbol: String, account: Account,
        quantity: Decimal, price: Decimal, fx: Decimal,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FinancialTransaction {
        let tx = FinancialTransaction(
            type: .assetPurchase, amount: quantity * price * fx, date: date,
            note: "", category: .investments, sourceAccount: account
        )
        tx.assetSymbol = symbol
        tx.assetQuantity = quantity
        tx.assetUnitPrice = price
        tx.assetFXRate = fx
        // Legacy: no direction fields.
        #expect(tx.assetFXRateFrom == nil)
        #expect(tx.assetFXRateTo == nil)
        ctx.insert(tx)
        return tx
    }

    private func asset(
        _ ctx: ModelContext, symbol: String, currency: String,
        venue: String = "XNGS"
    ) {
        ctx.insert(Asset(
            symbol: symbol, name: "Instrumento", assetClass: .stock,
            exchange: venue, currency: currency
        ))
    }

    private func account(_ ctx: ModelContext) -> Account {
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        return acc
    }

    // MARK: - Round-trip: historicalFXRate survives SwiftData

    @Test func historicalFXRateSurvivesARoundTrip() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let acc = account(ctx)
        let tx = FinancialTransaction(
            type: .assetPurchase, amount: 867, date: Date(),
            note: "", category: .investments, sourceAccount: acc
        )
        tx.assetSymbol = "AAPL"
        tx.assetQuantity = 10
        tx.assetUnitPrice = 100
        tx.assetFXRate = Decimal(string: "0.86693")!
        tx.assetFXRateFrom = "USD"
        tx.assetFXRateTo = "EUR"
        ctx.insert(tx)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<FinancialTransaction>()).first!

        let fx = try #require(fetched.historicalFXRate)
        #expect(fx.from == "USD")
        #expect(fx.to == "EUR")
        #expect(fx.value == Decimal(string: "0.86693")!)
        #expect(fx.convert(100, from: "USD") == 100 * Decimal(string: "0.86693")!)
        #expect(fx.convert(100, from: "EUR") == nil)
    }

    // MARK: - Backfill fills legacy rows

    @Test func backfillFillsDirectionFromAssetCurrency() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        asset(ctx, symbol: "AAPL", currency: "USD")
        let tx = legacyBuy(ctx, symbol: "AAPL", account: acc,
                           quantity: 10, price: 100, fx: Decimal(string: "0.86693")!)
        try ctx.save()

        let report = ListingBackfill.backfillFXRateDirection(in: ctx)

        #expect(report.filled == 1)
        #expect(report.unresolved.isEmpty)
        #expect(tx.assetFXRateFrom == "USD")
        #expect(tx.assetFXRateTo == "EUR")
        #expect(tx.assetFXRate == Decimal(string: "0.86693")!)

        let fx = try #require(tx.historicalFXRate)
        #expect(fx.convert(100, from: "USD") == 100 * Decimal(string: "0.86693")!)
        #expect(fx.convert(100, from: "EUR") == nil)
    }

    @Test func backfillHandlesEURAssetsAsIdentity() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        asset(ctx, symbol: "GALP", currency: "EUR", venue: "XLIS")
        legacyBuy(ctx, symbol: "GALP", account: acc, quantity: 50, price: 10, fx: 1)
        try ctx.save()

        let report = ListingBackfill.backfillFXRateDirection(in: ctx)

        #expect(report.filled == 1)
        let tx = try ctx.fetch(FetchDescriptor<FinancialTransaction>()).first!
        #expect(tx.assetFXRateFrom == "EUR")
        #expect(tx.assetFXRateTo == "EUR")
        let fx = try #require(tx.historicalFXRate)
        #expect(fx.convert(100, from: "EUR") == 100)
    }

    @Test func backfillIsIdempotent() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        asset(ctx, symbol: "AAPL", currency: "USD")
        legacyBuy(ctx, symbol: "AAPL", account: acc,
                  quantity: 10, price: 100, fx: Decimal(string: "0.86693")!)
        try ctx.save()

        let first = ListingBackfill.backfillFXRateDirection(in: ctx)
        let second = ListingBackfill.backfillFXRateDirection(in: ctx)

        #expect(first.filled == 1)
        #expect(second.filled == 0)
    }

    @Test func backfillLeavesUnresolvedWhenNoAssetRow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        // No Asset row for MYSTERY.
        legacyBuy(ctx, symbol: "MYSTERY", account: acc,
                  quantity: 5, price: 50, fx: Decimal(string: "0.92")!)
        try ctx.save()

        let report = ListingBackfill.backfillFXRateDirection(in: ctx)

        #expect(report.filled == 0)
        #expect(report.unresolved.contains("MYSTERY"))
        let tx = try ctx.fetch(FetchDescriptor<FinancialTransaction>()).first!
        #expect(tx.assetFXRateFrom == nil)
        #expect(tx.historicalFXRate == nil)
    }

    @Test func backfillHandlesMultipleCurrencies() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)

        asset(ctx, symbol: "AAPL", currency: "USD")
        asset(ctx, symbol: "AZN", currency: "GBP", venue: "XLON")
        asset(ctx, symbol: "GALP", currency: "EUR", venue: "XLIS")

        legacyBuy(ctx, symbol: "AAPL", account: acc,
                  quantity: 10, price: 100, fx: Decimal(string: "0.86693")!)
        legacyBuy(ctx, symbol: "AZN", account: acc,
                  quantity: 5, price: 120, fx: Decimal(string: "1.16")!)
        legacyBuy(ctx, symbol: "GALP", account: acc,
                  quantity: 50, price: 10, fx: 1)
        try ctx.save()

        let report = ListingBackfill.backfillFXRateDirection(in: ctx)

        #expect(report.filled == 3)
        #expect(report.unresolved.isEmpty)

        let txs = try ctx.fetch(FetchDescriptor<FinancialTransaction>())
        let aapl = txs.first { $0.assetSymbol == "AAPL" }!
        let azn = txs.first { $0.assetSymbol == "AZN" }!
        let galp = txs.first { $0.assetSymbol == "GALP" }!

        #expect(aapl.assetFXRateFrom == "USD")
        #expect(azn.assetFXRateFrom == "GBP")
        #expect(galp.assetFXRateFrom == "EUR")
        #expect(aapl.assetFXRateTo == "EUR")
        #expect(azn.assetFXRateTo == "EUR")
        #expect(galp.assetFXRateTo == "EUR")
    }

    // MARK: - New transactions write direction at creation

    @Test func addInvestmentWritesDirectionFields() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let acc = account(ctx)
        let store = PriceStore()
        store.configure(provider: MockMarketDataProvider(), modelContext: ctx)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: store, fxProvider: MockFXRateProvider())

        try vm.addInvestment(
            type: .assetPurchase, symbol: "AAPL", quantity: 10, unitPrice: 150,
            fxRate: Decimal(string: "0.86693")!, commission: 0, account: acc,
            date: Date(), note: "",
            asset: AssetSearchResult(
                symbol: "AAPL", name: "Apple", exchange: "XNGS",
                assetClass: .stock, currency: "USD", mic: "XNGS"
            )
        )

        let tx = try ctx.fetch(FetchDescriptor<FinancialTransaction>()).first!
        #expect(tx.assetFXRateFrom == "USD")
        #expect(tx.assetFXRateTo == "EUR")
        #expect(tx.assetFXRate == Decimal(string: "0.86693")!)

        let fx = try #require(tx.historicalFXRate)
        #expect(fx.convert(150, from: "USD") == 150 * Decimal(string: "0.86693")!)
        #expect(fx.convert(150, from: "EUR") == nil)
    }
}
