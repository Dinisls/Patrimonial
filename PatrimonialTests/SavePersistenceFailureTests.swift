import Foundation
import Testing
import SwiftData
@testable import Patrimonial

// MARK: - PD-2: the mutation funnel must not swallow a failed write
//
// `AppStore.save()` is where every user mutation lands. It used to be
// `try? ctx.save()`: a refused write was swallowed, and `reload()` ran anyway —
// re-reading the context, which still held the uncommitted change, so the UI
// showed an edit the disk had rejected and only lost it on the next launch.
//
// The fix: on failure `save()` rolls the mutation back, does NOT reload, and
// rethrows. The sheets catch that throw, show an alert and stay open. These
// tests exercise the store half through the `saveOverride` seam; the sheets'
// dismiss is gated on the same throw (dismiss only runs if the call returned
// without error), so a throwing store is exactly what keeps the sheet open.

@MainActor
struct SavePersistenceFailureTests {

    private struct SaveRefused: Error {}

    /// The caller keeps the returned `ModelContainer` alive for the whole test
    /// body: binding a context from a container that is then deallocated leaves
    /// the context dangling and takes the entire test host down with it.
    private func makeStore(_ container: ModelContainer) throws -> AppStore {
        let store = AppStore()
        store.bind(container.mainContext)
        try store.addAccount(name: "Corrente", sub: "", kind: .cash,
                             colorHex: 0x3F7BE0, initialBalance: 0)
        return store
    }

    /// A refused save throws instead of being swallowed, and the new row does
    /// not appear in the arrays the UI reads — reload was skipped and the
    /// pending insert rolled back.
    @Test func aFailedSaveThrowsAndDoesNotCommitTheInsert() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)
        let before = store.transactions.count

        store.saveOverride = { _ in throw SaveRefused() }

        #expect(throws: SaveRefused.self) {
            try store.addTransaction(title: "Café", amount: 3, isIncome: false,
                                     category: .other, account: "Corrente", date: "1/1/2026")
        }

        #expect(store.transactions.count == before)
        #expect(!store.transactions.contains { $0.title == "Café" })

        // And the rollback held: dropping the failing override and reloading
        // does not resurrect the discarded insert.
        store.saveOverride = nil
        store.reload()
        #expect(!store.transactions.contains { $0.title == "Café" })
    }

    /// The PD-2 shape in miniature: editing an existing row while the disk
    /// refuses must not leave the in-memory row showing the new values. The
    /// rollback reverts the property mutation; the UI keeps the last-saved truth.
    @Test func aFailedSaveDoesNotMutateAnExistingTransaction() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)
        try store.addTransaction(title: "Original", amount: 5, isIncome: false,
                                 category: .other, account: "Corrente", date: "1/1/2026")
        let id = try #require(store.transactions.first { $0.title == "Original" }?.txID)

        store.saveOverride = { _ in throw SaveRefused() }

        #expect(throws: SaveRefused.self) {
            try store.updateTransaction(id: id, title: "Adulterado", amount: 999, isIncome: false,
                                        category: .other, account: "Corrente", date: "1/1/2026")
        }

        #expect(store.transactions.contains { $0.title == "Original" })
        #expect(!store.transactions.contains { $0.title == "Adulterado" })
    }

    /// The happy path is untouched: a save that succeeds still commits and the
    /// reload surfaces the row.
    @Test func aSuccessfulSaveCommitsAndReloads() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = try makeStore(container)

        try store.addTransaction(title: "Café", amount: 3, isIncome: false,
                                 category: .other, account: "Corrente", date: "1/1/2026")

        #expect(store.transactions.contains { $0.title == "Café" })
    }
}
