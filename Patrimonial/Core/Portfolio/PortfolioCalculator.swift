import Foundation

struct PortfolioCalculator {

    struct Transaction {
        let type: TransactionType
        let assetSymbol: String
        /// Nil for rows written before the venue was stored. Those group under
        /// the bare ticker, exactly as they always have.
        let assetMIC: String?
        let accountID: String
        let accountName: String
        let quantity: Decimal
        let unitPrice: Decimal
        let fxRate: Decimal
        let commission: Decimal
        let amountEUR: Decimal
        let date: Date
    }

    enum CalculationError: Error, LocalizedError {
        case methodNotImplemented(CostBasisMethod)
        case insufficientQuantity(symbol: String, requested: Decimal, available: Decimal)

        var errorDescription: String? {
            switch self {
            case .methodNotImplemented(let m):
                "Método de custo \(m.rawValue) não implementado"
            case .insufficientQuantity(let s, let req, let avail):
                "Venda de \(req) \(s) excede quantidade disponível (\(avail))"
            }
        }
    }

    /// The stored rows that describe an investment, as the calculator wants
    /// them.
    ///
    /// Extracted from `PortfolioViewModel.loadHoldings`, which was the only
    /// caller until the reset confirmation had to count open positions without
    /// standing up a whole ViewModel. Two copies of this mapping would be two
    /// definitions of what counts as an investment transaction, and the count in
    /// a destructive confirmation is the last place that should drift.
    static func investmentTransactions(
        from stored: [FinancialTransaction]
    ) -> [Transaction] {
        stored.compactMap { tx -> Transaction? in
            guard let symbol = tx.assetSymbol,
                  let qty = tx.assetQuantity,
                  let price = tx.assetUnitPrice,
                  let fx = tx.assetFXRate,
                  tx.type == .assetPurchase || tx.type == .assetSale || tx.type == .dividend
            else { return nil }

            return Transaction(
                type: tx.type,
                assetSymbol: symbol,
                assetMIC: tx.assetMIC,
                accountID: tx.sourceAccount?.id.uuidString ?? "",
                accountName: tx.sourceAccount?.name ?? "",
                quantity: qty,
                unitPrice: price,
                fxRate: fx,
                commission: tx.commission ?? 0,
                amountEUR: tx.amount,
                date: tx.date
            )
        }
    }

    // MARK: - Compute holdings

    static func computeHoldings(
        from transactions: [Transaction],
        method: CostBasisMethod = .average
    ) throws -> [Holding] {
        if method == .fifo {
            throw CalculationError.methodNotImplemented(.fifo)
        }

        var grouped: [String: [Transaction]] = [:]
        for tx in transactions {
            let listing = ListingID(symbol: tx.assetSymbol, mic: tx.assetMIC)
            grouped[listing.storageKey, default: []].append(tx)
        }

        var holdings: [Holding] = []
        for (_, txs) in grouped {
            let holding = try computeHolding(from: txs, method: method)
            holdings.append(holding)
        }
        return holdings.sorted { $0.listing < $1.listing }
    }

    /// Per-account breakdown from buy transactions only, for allocation by
    /// account. Sales do not partition by account — the position is a single
    /// pool — so this counts what was bought through each account and
    /// proportionally reduces by any sales at the global level.
    static func perAccountHoldings(
        from transactions: [Transaction],
        unified: [Holding]
    ) -> [Holding] {
        var buysByKey: [String: (listing: ListingID, accountID: String, accountName: String, quantity: Decimal, costEUR: Decimal)] = [:]
        for tx in transactions where tx.type == .assetPurchase {
            let listing = ListingID(symbol: tx.assetSymbol, mic: tx.assetMIC)
            let key = "\(listing.storageKey):\(tx.accountID)"
            var entry = buysByKey[key] ?? (listing: listing, accountID: tx.accountID, accountName: tx.accountName, quantity: 0, costEUR: 0)
            let costEUR = tx.quantity * tx.unitPrice * tx.fxRate + tx.commission
            entry.quantity += tx.quantity
            entry.costEUR += costEUR
            buysByKey[key] = entry
        }

        let unifiedByListing = Dictionary(unified.map { ($0.listing, $0) }) { a, _ in a }

        var result: [Holding] = []
        for (_, entry) in buysByKey {
            let globalHolding = unifiedByListing[entry.listing]
            let totalBought = buysByKey
                .filter { $0.value.listing == entry.listing }
                .reduce(Decimal(0)) { $0 + $1.value.quantity }
            let scale: Decimal = totalBought > 0
                ? (globalHolding?.quantity ?? 0) / totalBought
                : 0
            let quantity = entry.quantity * scale
            let costEUR = entry.costEUR * scale
            let avgPrice = quantity > 0 ? costEUR / quantity : 0
            result.append(Holding(
                assetSymbol: entry.listing.symbol,
                assetMIC: entry.listing.mic,
                accountID: entry.accountID,
                accountName: entry.accountName,
                quantity: quantity,
                totalCostEUR: costEUR,
                averagePriceEUR: avgPrice,
                commissions: 0,
                realizedPL: 0,
                dividendsReceived: 0
            ))
        }
        return result.sorted { $0.listing < $1.listing }
    }

    // MARK: - Single holding from transactions of the same listing

    private static func computeHolding(
        from transactions: [Transaction],
        method: CostBasisMethod
    ) throws -> Holding {
        let sorted = transactions.sorted { $0.date < $1.date }
        guard let first = sorted.first else {
            return emptyHolding(symbol: "", accountID: "", accountName: "")
        }

        let listing = ListingID(symbol: first.assetSymbol, mic: first.assetMIC)
        let symbol = listing.symbol

        let accountNames = Set(sorted.filter { $0.type == .assetPurchase }.map(\.accountName))
            .filter { !$0.isEmpty }
            .sorted()
        let accountLabel = accountNames.count <= 2
            ? accountNames.joined(separator: " · ")
            : "\(accountNames.count) contas"

        var quantity: Decimal = 0
        var totalCostEUR: Decimal = 0
        var totalCommissions: Decimal = 0
        var realizedPL: Decimal = 0
        var dividendsReceived: Decimal = 0
        var purchaseLots: [Holding.PurchaseLot] = []

        for tx in sorted {
            switch tx.type {
            case .assetPurchase:
                let costEUR = tx.quantity * tx.unitPrice * tx.fxRate + tx.commission
                totalCostEUR += costEUR
                quantity += tx.quantity
                totalCommissions += tx.commission
                purchaseLots.append(Holding.PurchaseLot(
                    date: tx.date,
                    quantity: tx.quantity,
                    unitPriceNative: tx.unitPrice
                ))

            case .assetSale:
                guard quantity >= tx.quantity else {
                    throw CalculationError.insufficientQuantity(
                        symbol: symbol,
                        requested: tx.quantity,
                        available: quantity
                    )
                }
                let costOfSold = quantity > 0 ? totalCostEUR * (tx.quantity / quantity) : 0
                let saleProceeds = tx.quantity * tx.unitPrice * tx.fxRate - tx.commission
                realizedPL += saleProceeds - costOfSold
                totalCostEUR -= costOfSold
                let quantityBefore = quantity
                quantity -= tx.quantity
                totalCommissions += tx.commission

                if quantityBefore > 0, quantity > 0 {
                    let remaining = quantity / quantityBefore
                    purchaseLots = purchaseLots.map {
                        Holding.PurchaseLot(
                            date: $0.date,
                            quantity: $0.quantity * remaining,
                            unitPriceNative: $0.unitPriceNative
                        )
                    }
                }

                if quantity == 0 {
                    totalCostEUR = 0
                    purchaseLots = []
                }

            case .dividend:
                let dividendEUR = tx.quantity * tx.unitPrice * tx.fxRate - tx.commission
                dividendsReceived += dividendEUR

            case .expense, .income, .transfer:
                break
            }
        }

        let averagePriceEUR = quantity > 0 ? totalCostEUR / quantity : 0

        var holding = Holding(
            assetSymbol: symbol,
            assetMIC: listing.mic,
            accountID: "",
            accountName: accountLabel,
            quantity: quantity,
            totalCostEUR: totalCostEUR,
            averagePriceEUR: averagePriceEUR,
            commissions: totalCommissions,
            realizedPL: realizedPL,
            dividendsReceived: dividendsReceived
        )
        holding.purchaseLots = purchaseLots
        return holding
    }

    // MARK: - Portfolio-level aggregations

    static func portfolioWeight(holdingMarketValue: Decimal, totalMarketValue: Decimal) -> Decimal {
        guard totalMarketValue != 0 else { return 0 }
        return (holdingMarketValue / totalMarketValue) * 100
    }

    /// The portfolio's value, over the positions that actually have one.
    ///
    /// This used to return nil the moment any single holding was unpriced,
    /// which is defensible but unhelpful: one ETF with no quote hid 388 € of
    /// NVDA. A partial total is fine as long as it is *labelled* partial, so
    /// `excluded` is part of the answer rather than something the caller has to
    /// work out — and the header refuses to render the number without also
    /// rendering the exclusion.
    ///
    /// Cost is summed over the very same positions. Dividing a partial value by
    /// a full cost is how a fully-priced −12 % turns into −45 %, which would be
    /// a worse lie than the dash this replaces.
    struct MarketValueTotal: Equatable {
        let value: Decimal
        /// Cost basis of the priced positions only, so P/L over this total is
        /// like for like.
        let costOfPriced: Decimal
        let pricedCount: Int
        let excludedCount: Int

        var isPartial: Bool { excludedCount > 0 }
        var unrealizedPL: Decimal { value - costOfPriced }
        var unrealizedPLPercent: Decimal? {
            guard costOfPriced != 0 else { return nil }
            return (unrealizedPL / costOfPriced) * 100
        }
    }

    /// Nil only when nothing at all could be priced — there is no partial total
    /// to show, so the header falls back to a dash.
    static func marketValueTotal(_ holdings: [Holding]) -> MarketValueTotal? {
        var total: Decimal = 0
        var cost: Decimal = 0
        var priced = 0
        var excluded = 0
        for h in holdings where h.isOpen {
            if let mv = h.marketValueEUR {
                total += mv
                cost += h.totalCostEUR
                priced += 1
            } else {
                excluded += 1
            }
        }
        guard priced > 0 else { return nil }
        return MarketValueTotal(
            value: total, costOfPriced: cost, pricedCount: priced, excludedCount: excluded
        )
    }

    /// The strict total: nil unless every open position is priced. Kept for the
    /// places that must not show a partial figure — allocation percentages,
    /// where a slice of an incomplete whole would be wrong rather than partial.
    static func totalMarketValue(_ holdings: [Holding]) -> Decimal? {
        var total: Decimal = 0
        for h in holdings where h.isOpen {
            guard let mv = h.marketValueEUR else { return nil }
            total += mv
        }
        return total
    }

    static func totalCost(_ holdings: [Holding]) -> Decimal {
        holdings.filter(\.isOpen).reduce(0) { $0 + $1.totalCostEUR }
    }

    static func totalUnrealizedPL(_ holdings: [Holding]) -> Decimal? {
        var total: Decimal = 0
        for h in holdings where h.isOpen {
            guard let pl = h.unrealizedPL else { return nil }
            total += pl
        }
        return total
    }

    static func totalRealizedPL(_ holdings: [Holding]) -> Decimal {
        holdings.reduce(0) { $0 + $1.realizedPL }
    }

    static func totalDividends(_ holdings: [Holding]) -> Decimal {
        holdings.reduce(0) { $0 + $1.dividendsReceived }
    }

    /// The day change, over the positions that have one, with its own account of
    /// what it leaves out.
    ///
    /// Deliberately the same shape as `MarketValueTotal`. The two numbers sit
    /// side by side in the header and used to disagree about what to do with an
    /// unpriced position: the value showed a partial total with a caveat while
    /// the day change vanished entirely the moment any single holding lost its
    /// quote. Nothing surfaced that inconsistency while every position was
    /// priced, which is exactly the kind of difference that shows up for the
    /// first time on the day something breaks.
    struct DayChangeTotal: Equatable {
        let value: Decimal
        let includedCount: Int
        let excludedCount: Int

        var isPartial: Bool { excludedCount > 0 }
    }

    /// Nil only when nothing at all could be measured.
    static func dayChangeTotal(_ holdings: [Holding]) -> DayChangeTotal? {
        changeTotal(holdings) { $0.dayChangeEUR }
    }

    /// The generic version: sums whatever per-holding change the closure
    /// returns, with the same partial/excluded accounting.
    static func changeTotal(
        _ holdings: [Holding],
        change: (Holding) -> Decimal?
    ) -> DayChangeTotal? {
        var total: Decimal = 0
        var included = 0
        var excluded = 0
        for h in holdings where h.isOpen {
            if let dc = change(h) {
                total += dc
                included += 1
            } else {
                excluded += 1
            }
        }
        guard included > 0 else { return nil }
        return DayChangeTotal(value: total, includedCount: included, excludedCount: excluded)
    }

    // MARK: - Allocation

    struct AllocationSlice: Identifiable {
        let label: String
        let value: Decimal
        let percent: Decimal
        var id: String { label }
    }

    static func allocationBy(
        _ keyPath: (Holding) -> String,
        holdings: [Holding]
    ) -> [AllocationSlice] {
        let open = holdings.filter(\.isOpen)
        guard let totalMV = totalMarketValue(open), totalMV > 0 else { return [] }

        var buckets: [String: Decimal] = [:]
        for h in open {
            guard let mv = h.marketValueEUR else { continue }
            let key = keyPath(h)
            buckets[key, default: 0] += mv
        }

        return buckets.map { key, value in
            AllocationSlice(label: key, value: value, percent: (value / totalMV) * 100)
        }.sorted { $0.value > $1.value }
    }

    // MARK: - Helper

    private static func emptyHolding(symbol: String, accountID: String, accountName: String) -> Holding {
        Holding(
            assetSymbol: symbol,
            accountID: accountID,
            accountName: accountName,
            quantity: 0,
            totalCostEUR: 0,
            averagePriceEUR: 0,
            commissions: 0,
            realizedPL: 0,
            dividendsReceived: 0
        )
    }
}
