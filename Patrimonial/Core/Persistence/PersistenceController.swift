import Foundation
import SwiftData

enum PersistenceController {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            FinancialTransaction.self,
            CustomCategory.self,
            Asset.self,
            PriceSnapshot.self,
            PortfolioSnapshot.self,
            FXRateCache.self,
            CoinGeckoCache.self,
            CandleCache.self,
            Debt.self,
            DebtPayment.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            groupContainer: .automatic
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
