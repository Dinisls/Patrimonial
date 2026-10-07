import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// A dividend is entered as euros received and shares held. The per-share
/// figure is amount ÷ shares, which does not multiply back to the cent — the
/// stored amount and the portfolio total must still be exactly what was received.
@MainActor
struct DividendPerShareTests {

    private func record(
        amount: Decimal, shares: Decimal, in container: ModelContainer
    ) throws -> (FinancialTransaction, PortfolioViewModel) {
        let ctx = container.mainContext
        let acc = Account(name: "Corretora", type: .brokerage)
        ctx.insert(acc)
        let vm = PortfolioViewModel()
        vm.bind(modelContext: ctx, priceStore: PriceStore())

        try vm.addInvestment(
            type: .assetPurchase, symbol: "NVD", quantity: shares, unitPrice: 100,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )
        try vm.addInvestment(
            type: .dividend, symbol: "NVD", quantity: shares, unitPrice: amount / shares,
            fxRate: 1, commission: 0, account: acc, date: Date(), note: "", asset: nil
        )
        vm.loadHoldings()
        let tx = try #require(try ctx.fetch(FetchDescriptor<FinancialTransaction>())
            .first { $0.type == .dividend })
        return (tx, vm)
    }

    @Test(arguments: [
        (Decimal(string: "0.50")!, Decimal(3)),
        (Decimal(string: "0.43")!, Decimal(string: "0.3795")!),
        (Decimal(string: "1.00")!, Decimal(7)),
        (Decimal(string: "12.34")!, Decimal(string: "8.017524")!),
    ])
    func storedAmountAndTotalAreExactlyWhatWasReceived(amount: Decimal, shares: Decimal) throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (tx, vm) = try record(amount: amount, shares: shares, in: container)
        #expect(tx.amount == amount)
        #expect(tx.assetQuantity == shares)
        // Persistence keeps ~15 significant digits, so the per-share figure is
        // only close — which is why totals read the stored amount instead.
        let perShare = try #require(tx.assetUnitPrice)
        let back = perShare * shares - amount
        #expect(abs(back) < Decimal(string: "0.000001")!)
        #expect(vm.holdings.first?.dividendsReceived == amount)
    }
}
