import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// The account chart used to be drawn from a seeded random generator, which
/// invented months of movement for accounts that had none. These tests pin the
/// replacement: real data, or no chart.
///
/// Each test holds its own `ModelContainer` for its whole body. Handing a
/// `mainContext` back from a helper that owned the container lets the container
/// deallocate and leaves the context dangling, which takes the test host down.
struct BalanceSeriesTests {

    @MainActor
    private func makeStore(_ container: ModelContainer) -> AppStore {
        let store = AppStore()
        store.bind(container.mainContext)
        return store
    }

    @MainActor
    private func addTx(
        _ ctx: ModelContext,
        account: Account,
        type: TransactionType,
        amount: Decimal,
        daysAgo: Int
    ) throws {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let tx = FinancialTransaction(
            type: type, amount: amount, date: date,
            note: "t", category: .investments, sourceAccount: account
        )
        ctx.insert(tx)
        try ctx.save()
    }

    /// The exact case from the bug report: an account created today with a
    /// single transaction must not produce a chart.
    @MainActor
    @Test func singleDayOfActivityHasNoSeries() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Investimentos", type: .brokerage)
        ctx.insert(acc)
        try addTx(ctx, account: acc, type: .income, amount: 1000, daysAgo: 0)

        #expect(store.balanceSeries(accountID: acc.id.uuidString, days: 180) == nil)
    }

    @MainActor
    @Test func noTransactionsHasNoSeries() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Vazia", type: .checking)
        ctx.insert(acc)
        try ctx.save()

        #expect(store.balanceSeries(accountID: acc.id.uuidString, days: 30) == nil)
    }

    /// Activity older than the window must not be stretched into it.
    @MainActor
    @Test func movementOutsideWindowHasNoSeries() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Antiga", type: .checking)
        ctx.insert(acc)
        try addTx(ctx, account: acc, type: .income, amount: 500, daysAgo: 400)
        try addTx(ctx, account: acc, type: .expense, amount: 100, daysAgo: 380)

        #expect(store.balanceSeries(accountID: acc.id.uuidString, days: 30) == nil)
    }

    @MainActor
    @Test func seriesEndsAtCurrentBalance() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Corrente", type: .checking)
        ctx.insert(acc)
        try addTx(ctx, account: acc, type: .income, amount: 1000, daysAgo: 20)
        try addTx(ctx, account: acc, type: .expense, amount: 250, daysAgo: 5)

        let series = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 30))
        // 21 points, not 30: the account's first movement was 20 days ago and
        // the series is clamped there. Walking further back produced a flat run
        // at a balance the account never had — a week-old account was drawing
        // six months of line that way.
        #expect(series.count == 21)
        #expect(series.last == 750)
    }

    /// The line must reconstruct history, not repeat today's balance backwards.
    @MainActor
    @Test func seriesReflectsBalanceBeforeEachMovement() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Corrente", type: .checking)
        ctx.insert(acc)
        try addTx(ctx, account: acc, type: .income, amount: 1000, daysAgo: 20)
        try addTx(ctx, account: acc, type: .expense, amount: 250, daysAgo: 5)

        let series = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 30))
        // Index 0 is now the first movement's own day, 20 days ago, closing at
        // the 1000 that arrived that day.
        #expect(series.first == 1000)
        // Index n is (20 − n) days ago, so six days ago — the day before the
        // expense — is index 14, still 1000.
        #expect(series[14] == 1000)
        // And the day of the expense onwards is 750.
        #expect(series[15] == 750)
    }

    /// The clamp in isolation: asking for a year of an account that is 20 days
    /// old returns the same 21 points as asking for a month, instead of padding
    /// the difference with a balance that never existed.
    @MainActor
    @Test func longerWindowDoesNotExtendBeforeTheFirstMovement() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Corrente", type: .checking)
        ctx.insert(acc)
        try addTx(ctx, account: acc, type: .income, amount: 1000, daysAgo: 20)
        try addTx(ctx, account: acc, type: .expense, amount: 250, daysAgo: 5)

        let month = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 30))
        let year = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 365))
        #expect(month.count == year.count)
        #expect(month == year)
    }

    @MainActor
    @Test func assetPurchaseLowersTheSeries() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let store = makeStore(container)
        let acc = Account(name: "Investimentos", type: .brokerage)
        ctx.insert(acc)
        try addTx(ctx, account: acc, type: .income, amount: 1000, daysAgo: 10)
        try addTx(ctx, account: acc, type: .assetPurchase, amount: 649.12, daysAgo: 2)

        let series = try #require(store.balanceSeries(accountID: acc.id.uuidString, days: 30))
        #expect(series.last == 350.88)
    }
}
