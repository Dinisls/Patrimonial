import Foundation
import SwiftData

@Observable
final class AccountsViewModel {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func add(name: String, type: AccountType, currency: String = "EUR", colorHex: String = "007AFF") {
        let account = Account(name: name, type: type, currency: currency, colorHex: colorHex)
        modelContext.insert(account)
        try? modelContext.save()
    }

    func delete(_ account: Account) {
        modelContext.delete(account)
        try? modelContext.save()
    }

    func update(_ account: Account, name: String, type: AccountType, colorHex: String) {
        account.name = name
        account.type = type
        account.icon = type.icon
        account.colorHex = colorHex
        try? modelContext.save()
    }

    // MARK: - Account deletion with investment awareness

    struct DeletionImpact {
        struct PositionChange {
            let symbol: String
            let mic: String?
            let currentQuantity: Decimal
            let newQuantity: Decimal
            var disappears: Bool { newQuantity == 0 }
        }

        let investmentCount: Int
        let nonInvestmentCount: Int
        let symbols: [String]
        let positionChanges: [PositionChange]

        var hasInvestments: Bool { investmentCount > 0 }
    }

    func deletionImpact(for account: Account) -> DeletionImpact {
        let investmentTxs = account.outgoingTransactions.filter(\.isInvestmentTransaction)
        let nonInvestmentCount = account.outgoingTransactions.count - investmentTxs.count
        let symbols = Set(investmentTxs.compactMap(\.assetSymbol)).sorted()

        guard !investmentTxs.isEmpty else {
            return DeletionImpact(
                investmentCount: 0, nonInvestmentCount: nonInvestmentCount,
                symbols: [], positionChanges: []
            )
        }

        let allStored = (try? modelContext.fetch(FetchDescriptor<FinancialTransaction>())) ?? []
        let allInvestment = PortfolioCalculator.investmentTransactions(from: allStored)
        let currentHoldings = (try? PortfolioCalculator.computeHoldings(from: allInvestment)) ?? []

        let doomedIDs = Set(investmentTxs.map(\.id))
        let surviving = allStored.filter { !doomedIDs.contains($0.id) }
        let survivingInvestment = PortfolioCalculator.investmentTransactions(from: surviving)
        let afterHoldings = (try? PortfolioCalculator.computeHoldings(from: survivingInvestment)) ?? []
        let afterByListing = Dictionary(afterHoldings.map { ($0.listing, $0) }) { a, _ in a }

        let affectedListings = Set(investmentTxs.compactMap { tx in
            tx.assetSymbol.map { ListingID(symbol: $0, mic: tx.assetMIC) }
        })

        var changes: [DeletionImpact.PositionChange] = []
        for h in currentHoldings where h.isOpen && affectedListings.contains(h.listing) {
            let newQty = afterByListing[h.listing]?.quantity ?? 0
            changes.append(.init(
                symbol: h.listing.symbol, mic: h.listing.mic,
                currentQuantity: h.quantity, newQuantity: newQty
            ))
        }

        return DeletionImpact(
            investmentCount: investmentTxs.count, nonInvestmentCount: nonInvestmentCount,
            symbols: symbols, positionChanges: changes
        )
    }

    /// Balance delta that the investment transactions of `source` would cause on
    /// the destination if moved there. Negative = money left (buys).
    func moveBalanceDelta(for source: Account) -> Decimal {
        var delta: Decimal = 0
        for tx in source.outgoingTransactions where tx.isInvestmentTransaction {
            switch tx.type {
            case .assetPurchase: delta -= tx.amount
            case .assetSale, .dividend: delta += tx.amount
            default: break
            }
        }
        return delta
    }

    /// Atomic: reassign investment txs to destination, then cascade-delete
    /// source (which removes remaining non-investment txs). Single save().
    func moveInvestmentsAndDelete(from source: Account, to destination: Account) throws {
        for tx in source.outgoingTransactions where tx.isInvestmentTransaction {
            tx.sourceAccount = destination
        }
        modelContext.delete(source)
        try modelContext.save()
    }

    func deleteWithEverything(_ account: Account) throws {
        modelContext.delete(account)
        try modelContext.save()
    }
}
