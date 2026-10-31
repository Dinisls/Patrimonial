import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// A category can be both expense and income, so each kind keeps its own order:
// reordering one list must never move anything in the other.
@MainActor
struct CategoryOrderTests {

    private func makeStore(_ container: ModelContainer) throws -> AppStore {
        let store = AppStore()
        store.bind(container.mainContext)
        try store.addCustomCategory(name: "A", symbol: "tag", colorHex: 0x3F7BE0, isExpense: true, isIncome: true)
        try store.addCustomCategory(name: "B", symbol: "tag", colorHex: 0x3F7BE0, isExpense: true, isIncome: false)
        try store.addCustomCategory(name: "C", symbol: "tag", colorHex: 0x3F7BE0, isExpense: true, isIncome: true)
        try store.addCustomCategory(name: "D", symbol: "tag", colorHex: 0x3F7BE0, isExpense: false, isIncome: true)
        return store
    }

    private func names(_ store: AppStore, income: Bool) -> [String] {
        store.orderedCustomCategories(income: income).map(\.name)
    }

    @Test func neverReorderedCategoriesKeepCreationOrderPerKind() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)
        #expect(names(store, income: false) == ["A", "B", "C"])
        #expect(names(store, income: true) == ["A", "C", "D"])
    }

    @Test func movingExpensesLeavesIncomeOrderUntouched() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)

        try store.moveCustomCategories(income: false, from: IndexSet(integer: 2), to: 0)

        #expect(names(store, income: false) == ["C", "A", "B"])
        #expect(names(store, income: true) == ["A", "C", "D"])
    }

    @Test func movingIncomeLeavesExpenseOrderUntouched() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)

        try store.moveCustomCategories(income: true, from: IndexSet(integer: 0), to: 3)

        #expect(names(store, income: true) == ["C", "D", "A"])
        #expect(names(store, income: false) == ["A", "B", "C"])
    }

    @Test func aCategoryCreatedAfterReorderingGoesLast() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)
        try store.moveCustomCategories(income: false, from: IndexSet(integer: 2), to: 0)

        try store.addCustomCategory(name: "E", symbol: "tag", colorHex: 0x3F7BE0, isExpense: true, isIncome: false)

        #expect(names(store, income: false) == ["C", "A", "B", "E"])
    }

    @Test func theOrderSurvivesAReload() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)
        try store.moveCustomCategories(income: false, from: IndexSet(integer: 2), to: 0)

        store.reload()

        #expect(names(store, income: false) == ["C", "A", "B"])
    }
}
