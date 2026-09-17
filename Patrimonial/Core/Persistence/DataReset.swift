import Foundation
import SwiftData

/// Erasing everything the user has entered, and everything derived from it.
///
/// Deliberately one place rather than a method on `AppStore`. `AppStore.resetApp`
/// deleted accounts, transactions and custom categories, which is what that
/// store happens to know about — and left `Asset`, `PriceSnapshot`,
/// `PortfolioSnapshot`, `FXRateCache`, `CoinGeckoCache` and `CandleCache` on
/// disk. The result was worse than not resetting: an empty app whose next
/// search still knew a deleted ticker and whose portfolio chart still had a
/// history for positions that no longer existed. A reset that leaves ghosts is
/// not a reset.
///
/// The list below is the schema, and it is meant to be read against
/// `PersistenceController.makeContainer`. A model added there and not here comes
/// back from the dead.
enum DataReset {

    /// What a reset would destroy, in the terms the user recognises.
    ///
    /// Gathered before anything is deleted and shown in the confirmation,
    /// because "apagar todos os dados" is an abstraction and "42 transações e 3
    /// posições" is not.
    struct Inventory: Equatable {
        let accounts: Int
        let transactions: Int
        /// Open positions — the ones with a non-zero quantity. A position is not
        /// a stored row; it is what its transactions add up to, so this is
        /// computed the same way the portfolio screen computes it.
        let positions: Int
        let customCategories: Int
        /// Days of recorded portfolio history. The one number here that no
        /// amount of re-entry brings back.
        let portfolioSnapshots: Int
        let watchlisted: Int

        var isEmpty: Bool {
            accounts == 0 && transactions == 0 && positions == 0
                && customCategories == 0 && portfolioSnapshots == 0 && watchlisted == 0
        }
    }

    @MainActor
    static func inventory(in ctx: ModelContext) -> Inventory {
        let transactions = (try? ctx.fetch(FetchDescriptor<FinancialTransaction>())) ?? []
        let assets = (try? ctx.fetch(FetchDescriptor<Asset>())) ?? []

        // Same derivation as the portfolio screen, so the number in the
        // confirmation is the number of rows the user is looking at.
        let holdings = (try? PortfolioCalculator.computeHoldings(
            from: PortfolioCalculator.investmentTransactions(from: transactions)
        )) ?? []

        return Inventory(
            accounts: ((try? ctx.fetch(FetchDescriptor<Account>())) ?? []).count,
            transactions: transactions.count,
            positions: holdings.count(where: \.isOpen),
            customCategories: ((try? ctx.fetch(FetchDescriptor<CustomCategory>())) ?? []).count,
            portfolioSnapshots: ((try? ctx.fetch(FetchDescriptor<PortfolioSnapshot>())) ?? []).count,
            watchlisted: assets.count(where: \.isWatchlisted)
        )
    }

    /// Deletes every stored row, then clears the in-memory state that would
    /// otherwise outlive it.
    ///
    /// One by one rather than a batch predicate delete: batch deletes leave rows
    /// behind in this project, and a reset that half-works is the one failure
    /// mode that cannot be spotted by looking at the screen.
    ///
    /// API keys are untouched by construction, not by care: they live in
    /// `Secrets.plist` inside the bundle and `AppConfig` reads them from there.
    /// Nothing in this function can reach them.
    @MainActor
    static func eraseEverything(
        in ctx: ModelContext,
        priceStore: PriceStore? = nil,
        appStore: AppStore? = nil
    ) throws {
        // Order matters only for the relationships: transactions reference
        // accounts, so they go first and no delete rule has to fire on a row
        // that is already gone.
        deleteAll(FinancialTransaction.self, in: ctx)
        deleteAll(Account.self, in: ctx)
        deleteAll(CustomCategory.self, in: ctx)
        deleteAll(Asset.self, in: ctx)
        deleteAll(PriceSnapshot.self, in: ctx)
        deleteAll(PortfolioSnapshot.self, in: ctx)
        deleteAll(FXRateCache.self, in: ctx)
        deleteAll(CoinGeckoCache.self, in: ctx)
        deleteAll(CandleCache.self, in: ctx)

        try ctx.save()

        // Disk is not the whole of it. A quote held in memory would repopulate
        // the cache on the next poll, and a listing left behind would keep
        // routing a ticker nothing refers to any more.
        priceStore?.reset()
        appStore?.clearInMemoryState()
        UserDefaults.standard.removeObject(forKey: MonthlyRecapSchedule.defaultsKey)
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in ctx: ModelContext) {
        for row in (try? ctx.fetch(FetchDescriptor<T>())) ?? [] {
            ctx.delete(row)
        }
    }
}
