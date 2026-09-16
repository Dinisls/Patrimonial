import Foundation
import SwiftData

enum DataBackup {

    // MARK: - Exportable types

    struct Backup: Codable {
        var version: Int = 1
        var exportedAt: Date
        var accounts: [AccountDTO]
        var transactions: [TransactionDTO]
        var customCategories: [CustomCategoryDTO]
        var assets: [AssetDTO]
        var portfolioSnapshots: [PortfolioSnapshotDTO]
    }

    struct AccountDTO: Codable {
        var id: UUID
        var name: String
        var type: String
        var currency: String
        var icon: String
        var colorHex: String
        var createdAt: Date
    }

    struct TransactionDTO: Codable {
        var id: UUID
        var type: String
        var amount: Decimal
        var date: Date
        var note: String
        var category: String?
        var customCategoryID: String?
        var recurrence: String
        var recurrenceDay: Int?
        var recurrenceDay2: Int?
        var recurrenceSourceID: String?

        var assetSymbol: String?
        var assetMIC: String?
        var assetQuantity: Decimal?
        var assetUnitPrice: Decimal?
        var assetFXRate: Decimal?
        var assetFXRateFrom: String?
        var assetFXRateTo: String?
        var commission: Decimal?

        var sourceAccountID: UUID?
        var destinationAccountID: UUID?
    }

    struct CustomCategoryDTO: Codable {
        var id: UUID
        var name: String
        var symbol: String
        var colorHex: String
        var isExpense: Bool
        var isIncome: Bool
        var createdAt: Date
    }

    struct AssetDTO: Codable {
        var id: UUID
        var symbol: String
        var name: String
        var assetClass: String
        var exchange: String
        var currency: String
        var sector: String
        var coingeckoID: String?
        var isWatchlisted: Bool
        var createdAt: Date
    }

    struct PortfolioSnapshotDTO: Codable {
        var date: Date
        var totalValue: Decimal
        var totalCost: Decimal
        var cashTotal: Decimal
        var createdAt: Date
    }

    // MARK: - Export

    @MainActor
    static func export(from ctx: ModelContext) throws -> Data {
        let accounts = (try? ctx.fetch(FetchDescriptor<Account>())) ?? []
        let transactions = (try? ctx.fetch(FetchDescriptor<FinancialTransaction>())) ?? []
        let categories = (try? ctx.fetch(FetchDescriptor<CustomCategory>())) ?? []
        let assets = (try? ctx.fetch(FetchDescriptor<Asset>())) ?? []
        let snapshots = (try? ctx.fetch(FetchDescriptor<PortfolioSnapshot>())) ?? []

        let backup = Backup(
            exportedAt: Date(),
            accounts: accounts.map { a in
                AccountDTO(
                    id: a.id, name: a.name, type: a.type.rawValue,
                    currency: a.currency, icon: a.icon, colorHex: a.colorHex,
                    createdAt: a.createdAt
                )
            },
            transactions: transactions.map { t in
                TransactionDTO(
                    id: t.id, type: t.type.rawValue, amount: t.amount,
                    date: t.date, note: t.note,
                    category: t.category?.rawValue,
                    customCategoryID: t.customCategoryID,
                    recurrence: t.recurrence.rawValue,
                    recurrenceDay: t.recurrenceDay,
                    recurrenceDay2: t.recurrenceDay2,
                    recurrenceSourceID: t.recurrenceSourceID,
                    assetSymbol: t.assetSymbol, assetMIC: t.assetMIC,
                    assetQuantity: t.assetQuantity,
                    assetUnitPrice: t.assetUnitPrice,
                    assetFXRate: t.assetFXRate,
                    assetFXRateFrom: t.assetFXRateFrom,
                    assetFXRateTo: t.assetFXRateTo,
                    commission: t.commission,
                    sourceAccountID: t.sourceAccount?.id,
                    destinationAccountID: t.destinationAccount?.id
                )
            },
            customCategories: categories.map { c in
                CustomCategoryDTO(
                    id: c.id, name: c.name, symbol: c.symbol,
                    colorHex: c.colorHex, isExpense: c.isExpense,
                    isIncome: c.isIncome, createdAt: c.createdAt
                )
            },
            assets: assets.map { a in
                AssetDTO(
                    id: a.id, symbol: a.symbol, name: a.name,
                    assetClass: a.assetClass.rawValue, exchange: a.exchange,
                    currency: a.currency, sector: a.sector,
                    coingeckoID: a.coingeckoID,
                    isWatchlisted: a.isWatchlisted, createdAt: a.createdAt
                )
            },
            portfolioSnapshots: snapshots.map { s in
                PortfolioSnapshotDTO(
                    date: s.date, totalValue: s.totalValue,
                    totalCost: s.totalCost, cashTotal: s.cashTotal,
                    createdAt: s.createdAt
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    // MARK: - Import

    @MainActor
    static func restore(from data: Data, into ctx: ModelContext) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)

        try DataReset.eraseEverything(in: ctx)

        var accountsByID: [UUID: Account] = [:]

        for dto in backup.accounts {
            let account = Account(
                name: dto.name,
                type: AccountType(rawValue: dto.type) ?? .checking,
                currency: dto.currency,
                icon: dto.icon,
                colorHex: dto.colorHex
            )
            account.id = dto.id
            account.createdAt = dto.createdAt
            ctx.insert(account)
            accountsByID[dto.id] = account
        }

        for dto in backup.customCategories {
            let cat = CustomCategory(
                name: dto.name, symbol: dto.symbol,
                colorHex: dto.colorHex,
                isExpense: dto.isExpense, isIncome: dto.isIncome
            )
            cat.id = dto.id
            cat.createdAt = dto.createdAt
            ctx.insert(cat)
        }

        for dto in backup.assets {
            let asset = Asset(
                symbol: dto.symbol, name: dto.name,
                assetClass: AssetClass(rawValue: dto.assetClass) ?? .stock,
                exchange: dto.exchange, currency: dto.currency,
                sector: dto.sector, coingeckoID: dto.coingeckoID,
                isWatchlisted: dto.isWatchlisted
            )
            asset.id = dto.id
            asset.createdAt = dto.createdAt
            ctx.insert(asset)
        }

        for dto in backup.transactions {
            let tx = FinancialTransaction(
                type: TransactionType(rawValue: dto.type) ?? .expense,
                amount: dto.amount,
                date: dto.date,
                note: dto.note,
                category: dto.category.flatMap { TransactionCategory(rawValue: $0) },
                recurrence: Recurrence(rawValue: dto.recurrence) ?? .none,
                sourceAccount: dto.sourceAccountID.flatMap { accountsByID[$0] },
                destinationAccount: dto.destinationAccountID.flatMap { accountsByID[$0] }
            )
            tx.id = dto.id
            tx.customCategoryID = dto.customCategoryID
            tx.recurrenceDay = dto.recurrenceDay
            tx.recurrenceDay2 = dto.recurrenceDay2
            tx.recurrenceSourceID = dto.recurrenceSourceID
            tx.assetSymbol = dto.assetSymbol
            tx.assetMIC = dto.assetMIC
            tx.assetQuantity = dto.assetQuantity
            tx.assetUnitPrice = dto.assetUnitPrice
            tx.assetFXRate = dto.assetFXRate
            tx.assetFXRateFrom = dto.assetFXRateFrom
            tx.assetFXRateTo = dto.assetFXRateTo
            tx.commission = dto.commission
            ctx.insert(tx)
        }

        for dto in backup.portfolioSnapshots {
            let snap = PortfolioSnapshot(
                date: dto.date, totalValue: dto.totalValue,
                totalCost: dto.totalCost, cashTotal: dto.cashTotal
            )
            snap.createdAt = dto.createdAt
            ctx.insert(snap)
        }

        try ctx.save()

        return ImportResult(
            accounts: backup.accounts.count,
            transactions: backup.transactions.count,
            customCategories: backup.customCategories.count,
            assets: backup.assets.count,
            portfolioSnapshots: backup.portfolioSnapshots.count
        )
    }

    struct ImportResult {
        let accounts: Int
        let transactions: Int
        let customCategories: Int
        let assets: Int
        let portfolioSnapshots: Int
    }
}
