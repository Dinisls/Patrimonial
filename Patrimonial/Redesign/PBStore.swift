// ───────────────────────────────────────────────────────────
// PBStore.swift — Estado mutável da app com persistência SwiftData
// ───────────────────────────────────────────────────────────
import SwiftUI
import SwiftData
import Observation

@MainActor
@Observable
final class AppStore {
    var accounts: [PBAccount] = []
    var transactions: [PBTx] = []
    var customCategories: [PBCustomCategory] = []

    private var ctx: ModelContext?

    init() {}

    func bind(_ context: ModelContext) {
        guard ctx == nil else { return }
        ctx = context
        reload()
    }

    // MARK: - Reload from SwiftData

    /// Not private: the Portfolio module writes through its own ModelContext and
    /// has no other way to tell this store its cached arrays are stale.
    func reload() {
        loadAccounts()
        loadCustomCategories()
        generateRecurringTransactions()
        loadTransactions()
        updateAccountChanges()
    }

    // MARK: Custom Categories

    private func loadCustomCategories() {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<CustomCategory>(sortBy: [SortDescriptor(\.createdAt)])
        let cats = (try? ctx.fetch(descriptor)) ?? []
        customCategories = cats.map { c in
            PBCustomCategory(
                id: c.id.uuidString,
                name: c.name,
                symbol: c.symbol,
                colorHex: hexStringToUInt(c.colorHex),
                isExpense: c.isExpense,
                isIncome: c.isIncome
            )
        }
    }

    func addCustomCategory(name: String, symbol: String, colorHex: UInt, isExpense: Bool, isIncome: Bool) throws {
        guard let ctx else { return }
        let cat = CustomCategory(
            name: name,
            symbol: symbol,
            colorHex: uintToHexString(colorHex),
            isExpense: isExpense,
            isIncome: isIncome
        )
        ctx.insert(cat)
        try save()
    }

    func deleteCustomCategory(id: String) throws {
        guard let ctx, let uuid = UUID(uuidString: id) else { return }
        let descriptor = FetchDescriptor<CustomCategory>(predicate: #Predicate { $0.id == uuid })
        if let cat = try? ctx.fetch(descriptor).first {
            ctx.delete(cat)
            try save()
        }
    }

    private func updateAccountChanges() {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now)
        let y = cal.component(.year, from: now)
        for i in accounts.indices {
            var net = 0.0
            for tx in transactions where tx.account == accounts[i].name {
                guard let d = Self.parseDate(tx.date) else { continue }
                if cal.component(.month, from: d) == m && cal.component(.year, from: d) == y {
                    net += tx.amount
                }
            }
            let prevBalance = accounts[i].balance - net
            accounts[i].change = prevBalance > 0 ? net / prevBalance : 0
        }
    }

    /// Test seam. Production leaves it nil and the real context writes to disk;
    /// a test sets it to throw, exercising the failure path without a context
    /// that has to be coaxed into refusing.
    var saveOverride: ((ModelContext) throws -> Void)?

    /// Every user mutation funnels here, and it no longer swallows a failed
    /// write. On failure it rolls the mutation back — so a retry (the sheet
    /// stays open) starts from clean state instead of committing the change
    /// twice — rethrows, and does NOT `reload()`. Skipping the reload is half
    /// the fix: reload re-reads the context, and the context still holds the
    /// uncommitted change, so reloading would show the user an edit the disk
    /// refused. The in-memory arrays are left at their last-saved truth.
    private func save() throws {
        guard let ctx else { return }
        do {
            if let saveOverride { try saveOverride(ctx) } else { try ctx.save() }
        } catch {
            ctx.rollback()
            throw error
        }
        reload()
    }

    // MARK: Accounts

    private func loadAccounts() {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)])
        let accs = (try? ctx.fetch(descriptor)) ?? []
        accounts = accs.map { a in
            let balance = Double(truncating: a.balance as NSNumber)
            return PBAccount(
                id: a.id.uuidString,
                name: a.name,
                sub: a.type.displayName,
                balance: balance,
                colorHex: hexStringToUInt(a.colorHex),
                kind: .cash,
                change: 0
            )
        }
    }

    // MARK: Transactions

    private func loadTransactions() {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<FinancialTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let txs = (try? ctx.fetch(descriptor)) ?? []
        var result: [PBTx] = []
        var idx = 0
        for tx in txs {
            let amount = Double(truncating: tx.amount as NSNumber)

            if tx.type == .transfer {
                let srcName = tx.sourceAccount?.name ?? ""
                let dstName = tx.destinationAccount?.name ?? ""
                let title = tx.note.isEmpty ? "Transferência" : tx.note
                let dateStr = formatDate(tx.date)

                idx += 1
                var outTx = PBTx(id: idx, txID: tx.id, title: title,
                                 cat: .transfer, account: srcName, date: dateStr, amount: -amount,
                                 recurrence: tx.recurrence, recurrenceDay: tx.recurrenceDay, recurrenceDay2: tx.recurrenceDay2)
                if !dstName.isEmpty { outTx.sub = "→ \(dstName)" }
                result.append(outTx)

                idx += 1
                var inTx = PBTx(id: idx, txID: tx.id, title: title,
                                cat: .transfer, account: dstName, date: dateStr, amount: amount,
                                recurrence: tx.recurrence, recurrenceDay: tx.recurrenceDay, recurrenceDay2: tx.recurrenceDay2)
                if !srcName.isEmpty { inTx.sub = "← \(srcName)" }
                result.append(inTx)
            } else {
                let signed: Double
                switch tx.type {
                case .income: signed = amount
                default: signed = -amount
                }
                let cat = mapCategory(tx.category, type: tx.type)
                idx += 1
                var pbTx = PBTx(
                    id: idx, txID: tx.id,
                    title: tx.note.isEmpty ? tx.type.displayName : tx.note,
                    cat: cat, account: tx.sourceAccount?.name ?? "",
                    date: formatDate(tx.date), amount: signed,
                    recurrence: tx.recurrence, recurrenceDay: tx.recurrenceDay, recurrenceDay2: tx.recurrenceDay2
                )
                if let symbol = tx.assetSymbol {
                    pbTx.assetSymbol = symbol
                    pbTx.assetQuantity = tx.assetQuantity
                    pbTx.assetUnitPrice = tx.assetUnitPrice
                    pbTx.assetFXRate = tx.assetFXRate
                    pbTx.assetFXRateFrom = tx.assetFXRateFrom
                    pbTx.assetFXRateTo = tx.assetFXRateTo
                    pbTx.assetCommission = tx.commission
                    pbTx.assetCurrency = assetCurrency(for: symbol)
                    if let qty = tx.assetQuantity {
                        pbTx.sub = "\(formatQuantity(qty)) un"
                    }
                }
                if let customID = tx.customCategoryID,
                   let customCat = customCategories.first(where: { $0.id == customID }) {
                    pbTx.customCatID = customCat.id
                    pbTx.customCatName = customCat.name
                    pbTx.customCatSymbol = customCat.symbol
                    pbTx.customCatColorHex = customCat.colorHex
                }
                result.append(pbTx)
            }
        }
        transactions = result
    }

    // MARK: - Balance history

    /// Real end-of-day balance series for an account, reconstructed by walking
    /// its own transactions backwards from the current balance.
    ///
    /// Returns `nil` when there is not enough real history to draw an honest
    /// line — the caller must hide the chart rather than show a flat or
    /// invented one. This replaced a seeded random generator that fabricated
    /// months of movement for accounts that had none.
    func balanceSeries(accountID: String, days: Int) -> [Double]? {
        guard let ctx, days > 1, let uuid = UUID(uuidString: accountID) else { return nil }
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == uuid })
        guard let account = (try? ctx.fetch(descriptor))?.first else { return nil }

        // Signed movement per transaction, from this account's point of view.
        var deltas: [(date: Date, amount: Decimal)] = []
        for tx in account.outgoingTransactions {
            switch tx.type {
            case .income, .assetSale, .dividend:
                deltas.append((tx.date, tx.amount))
            case .expense, .assetPurchase, .transfer:
                deltas.append((tx.date, -tx.amount))
            }
        }
        for tx in account.incomingTransactions where tx.type == .transfer {
            deltas.append((tx.date, tx.amount))
        }

        let cal = Calendar.current
        let movementDays = Set(deltas.map { cal.startOfDay(for: $0.date) })

        // One day of activity is a point, not a history.
        guard movementDays.count >= 2 else { return nil }

        let today = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return nil }

        // Nothing moved inside the requested window: the line would be flat and
        // the percentage meaningless.
        guard movementDays.contains(where: { $0 >= windowStart }) else { return nil }

        // The series must not reach back past the account's own first movement.
        // Walking the balance backwards beyond that point produces a flat line
        // at a balance the account never had — a week-old account was drawing
        // six months of invented history that way.
        guard let firstMovement = movementDays.min() else { return nil }
        let start = max(windowStart, firstMovement)
        let span = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        guard span >= 2 else { return nil }

        let current = account.balance
        var points: [Double] = []
        for offset in stride(from: span - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: day)
            else { continue }
            let laterMovement = deltas
                .filter { $0.date >= dayEnd }
                .reduce(Decimal(0)) { $0 + $1.amount }
            points.append(Double(truncating: (current - laterMovement) as NSNumber))
        }
        return points.count >= 2 ? points : nil
    }

    /// How many days of real history the account has, counting from its first
    /// movement. Nil when it has none. Used to grey out range buttons that would
    /// reach back further than the account has existed.
    func historyDays(accountID: String) -> Int? {
        guard let ctx, let uuid = UUID(uuidString: accountID) else { return nil }
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == uuid })
        guard let account = (try? ctx.fetch(descriptor))?.first else { return nil }

        var dates = account.outgoingTransactions.map(\.date)
        dates.append(contentsOf: account.incomingTransactions.map(\.date))
        guard let earliest = dates.min() else { return nil }

        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: earliest), to: cal.startOfDay(for: Date())
        ).day ?? 0
        return days + 1
    }

    // MARK: Derivados
    var totalBalance: Double { accounts.reduce(0) { $0 + $1.balance } }

    func account(named name: String) -> PBAccount? { accounts.first { $0.name == name } }
    func transactions(forAccount name: String) -> [PBTx] { transactions.filter { $0.account == name } }

    func categoryTotals(isExpense: Bool) -> [PBCategoryTotal] {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now)
        let y = cal.component(.year, from: now)

        var buckets: [String: (name: String, symbol: String, colorHex: UInt, total: Double, count: Int)] = [:]

        for tx in transactions {
            guard tx.cat != .transfer else { continue }
            let txIsIncome = tx.amount > 0
            guard txIsIncome == !isExpense else { continue }
            guard let d = Self.parseDate(tx.date),
                  cal.component(.month, from: d) == m,
                  cal.component(.year, from: d) == y else { continue }

            let key: String
            let name: String
            let symbol: String
            let colorHex: UInt

            if let customID = tx.customCatID,
               let customCat = customCategories.first(where: { $0.id == customID }) {
                key = "c:\(customID)"
                name = customCat.name
                symbol = customCat.symbol
                colorHex = customCat.colorHex
            } else {
                key = "b:\(tx.cat.rawValue)"
                name = txCatLabel(tx.cat)
                symbol = Icon.catSymbol(tx.cat)
                colorHex = txCatColorHex(tx.cat)
            }

            let amount = abs(tx.amount)
            if var b = buckets[key] {
                b.total += amount; b.count += 1; buckets[key] = b
            } else {
                buckets[key] = (name, symbol, colorHex, amount, 1)
            }
        }

        guard !buckets.isEmpty else { return [] }
        let maxTotal = buckets.values.map(\.total).max() ?? 1
        return buckets.map { key, val in
            PBCategoryTotal(id: key, name: val.name, symbol: val.symbol,
                            colorHex: val.colorHex, total: val.total, count: val.count,
                            fraction: val.total / maxTotal)
        }.sorted { $0.total > $1.total }
    }

    var cashflow: (net: Double, receita: Double, despesas: Double) {
        cashflowFor(month: Calendar.current.component(.month, from: Date()),
                    year: Calendar.current.component(.year, from: Date()))
    }

    func cashflowFor(month m: Int, year y: Int) -> (net: Double, receita: Double, despesas: Double) {
        let cal = Calendar.current
        var receita = 0.0, despesas = 0.0
        for t in transactions {
            guard let d = Self.parseDate(t.date) else { continue }
            if cal.component(.month, from: d) == m && cal.component(.year, from: d) == y {
                if t.amount > 0 { receita += t.amount } else { despesas += -t.amount }
            }
        }
        return (receita - despesas, receita, despesas)
    }

    func dailyCashflow(month m: Int, year y: Int) -> [(d: Int, inn: Double, out: Double)] {
        let cal = Calendar.current
        guard let monthDate = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let daysRange = cal.range(of: .day, in: .month, for: monthDate) else { return [] }
        var daily: [Int: (inn: Double, out: Double)] = [:]
        for day in daysRange { daily[day] = (0, 0) }

        for t in transactions {
            guard t.cat != .transfer,
                  let d = Self.parseDate(t.date),
                  cal.component(.month, from: d) == m,
                  cal.component(.year, from: d) == y else { continue }
            let day = cal.component(.day, from: d)
            let current = daily[day] ?? (0, 0)
            if t.amount > 0 {
                daily[day] = (current.inn + t.amount, current.out)
            } else {
                daily[day] = (current.inn, current.out + abs(t.amount))
            }
        }
        return daysRange.map { d in (d: d, inn: daily[d]?.inn ?? 0, out: daily[d]?.out ?? 0) }
    }

    func categoryTotalsFor(isExpense: Bool, month m: Int, year y: Int) -> [PBCategoryTotal] {
        let cal = Calendar.current
        var buckets: [String: (name: String, symbol: String, colorHex: UInt, total: Double, count: Int)] = [:]

        for tx in transactions {
            guard tx.cat != .transfer else { continue }
            let txIsIncome = tx.amount > 0
            guard txIsIncome == !isExpense else { continue }
            guard let d = Self.parseDate(tx.date),
                  cal.component(.month, from: d) == m,
                  cal.component(.year, from: d) == y else { continue }

            let key: String
            let name: String
            let symbol: String
            let colorHex: UInt

            if let customID = tx.customCatID,
               let customCat = customCategories.first(where: { $0.id == customID }) {
                key = "c:\(customID)"
                name = customCat.name
                symbol = customCat.symbol
                colorHex = customCat.colorHex
            } else {
                key = "b:\(tx.cat.rawValue)"
                name = txCatLabel(tx.cat)
                symbol = Icon.catSymbol(tx.cat)
                colorHex = txCatColorHex(tx.cat)
            }

            let amount = abs(tx.amount)
            if var b = buckets[key] {
                b.total += amount; b.count += 1; buckets[key] = b
            } else {
                buckets[key] = (name, symbol, colorHex, amount, 1)
            }
        }

        guard !buckets.isEmpty else { return [] }
        let maxTotal = buckets.values.map(\.total).max() ?? 1
        return buckets.map { key, val in
            PBCategoryTotal(id: key, name: val.name, symbol: val.symbol,
                            colorHex: val.colorHex, total: val.total, count: val.count,
                            fraction: val.total / maxTotal)
        }.sorted { $0.total > $1.total }
    }

    func topTransactions(month m: Int, year y: Int, limit: Int = 3) -> [PBTx] {
        let cal = Calendar.current
        return transactions
            .filter { tx in
                guard let d = Self.parseDate(tx.date) else { return false }
                return cal.component(.month, from: d) == m && cal.component(.year, from: d) == y
            }
            .sorted { abs($0.amount) > abs($1.amount) }
            .prefix(limit)
            .map { $0 }
    }

    private nonisolated static let shortMonthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "MMM"
        return f
    }()

    var availableMonths: [(month: Int, year: Int, label: String)] {
        let cal = Calendar.current
        var seen = Set<String>()
        var result: [(month: Int, year: Int, label: String)] = []

        for t in transactions {
            guard let d = Self.parseDate(t.date) else { continue }
            let m = cal.component(.month, from: d)
            let y = cal.component(.year, from: d)
            let key = "\(y)-\(m)"
            if seen.insert(key).inserted {
                let label = Self.shortMonthFmt.string(from: d).capitalized
                result.append((month: m, year: y, label: label))
            }
        }

        let now = Date()
        let cm = cal.component(.month, from: now)
        let cy = cal.component(.year, from: now)
        let key = "\(cy)-\(cm)"
        if seen.insert(key).inserted {
            result.append((month: cm, year: cy, label: Self.shortMonthFmt.string(from: now).capitalized))
        }

        return result.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    private nonisolated static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "d/M/yyyy"
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        dateFmt.date(from: s)
    }
    static func todayString() -> String {
        dateFmt.string(from: Date())
    }

    // MARK: - Recurring transaction generation

    private func generateRecurringTransactions() {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<FinancialTransaction>()
        let allTx = (try? ctx.fetch(descriptor)) ?? []
        let recurring = allTx.filter { $0.recurrence != .none && $0.recurrenceSourceID == nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var didInsert = false

        for src in recurring {
            let sourceID = src.id.uuidString
            let existing = allTx.filter { $0.recurrenceSourceID == sourceID }
            let latestDate = existing.map(\.date).max() ?? src.date

            let datesToGenerate = nextDates(after: latestDate, recurrence: src.recurrence,
                                            day1: src.recurrenceDay, day2: src.recurrenceDay2,
                                            until: today, calendar: cal)
            for d in datesToGenerate {
                let child = FinancialTransaction(
                    type: src.type,
                    amount: src.amount,
                    date: d,
                    note: src.note,
                    category: src.category,
                    sourceAccount: src.sourceAccount,
                    destinationAccount: src.destinationAccount
                )
                child.customCategoryID = src.customCategoryID
                child.recurrenceSourceID = sourceID
                ctx.insert(child)
                didInsert = true
            }
        }
        if didInsert { try? ctx.save() }
    }

    private func nextDates(after latest: Date, recurrence: Recurrence,
                           day1: Int?, day2: Int?,
                           until today: Date, calendar cal: Calendar) -> [Date] {
        var results: [Date] = []
        switch recurrence {
        case .none:
            break
        case .weekly:
            let weekday = day1 ?? cal.component(.weekday, from: latest)
            var cursor = latest
            while true {
                cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
                if cal.component(.weekday, from: cursor) == weekday {
                    guard cursor <= today else { break }
                    results.append(cursor)
                }
            }
        case .monthly:
            let targetDay = day1 ?? cal.component(.day, from: latest)
            var comps = cal.dateComponents([.year, .month], from: latest)
            while true {
                comps.month! += 1
                if comps.month! > 12 { comps.month = 1; comps.year! += 1 }
                let d = clampedDate(year: comps.year!, month: comps.month!, day: targetDay, calendar: cal)
                guard d <= today else { break }
                results.append(d)
            }
        case .bimonthly:
            let d1 = min(day1 ?? 1, day2 ?? 15)
            let d2 = max(day1 ?? 1, day2 ?? 15)
            var comps = cal.dateComponents([.year, .month], from: latest)
            var started = false
            while true {
                let first = clampedDate(year: comps.year!, month: comps.month!, day: d1, calendar: cal)
                let second = clampedDate(year: comps.year!, month: comps.month!, day: d2, calendar: cal)
                for candidate in [first, second] {
                    if candidate > latest || (started && candidate > latest) {
                        guard candidate <= today else { return results }
                        results.append(candidate)
                    }
                }
                started = true
                comps.month! += 1
                if comps.month! > 12 { comps.month = 1; comps.year! += 1 }
            }
        }
        return results
    }

    private func clampedDate(year: Int, month: Int, day: Int, calendar cal: Calendar) -> Date {
        var comps = DateComponents(year: year, month: month, day: 1)
        let firstOfMonth = cal.date(from: comps)!
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        comps.day = min(day, daysInMonth)
        return cal.date(from: comps)!
    }

    // MARK: - Mutações

    func addTransaction(title: String, amount: Double, isIncome: Bool,
                        category: TxCategory, customCatID: String? = nil,
                        account: String, date: String,
                        recurrence: Recurrence = .none,
                        recurrenceDay: Int? = nil, recurrenceDay2: Int? = nil) throws {
        guard let ctx, let acc = findAccount(named: account) else { return }
        let txType: TransactionType = isIncome ? .income : .expense
        let txCat = mapTxCatToTransactionCategory(category)
        let tx = FinancialTransaction(
            type: txType,
            amount: Decimal(abs(amount)),
            date: Self.parseDate(date) ?? Date(),
            note: title,
            category: txCat,
            recurrence: recurrence,
            sourceAccount: acc
        )
        tx.customCategoryID = customCatID
        tx.recurrenceDay = recurrenceDay
        tx.recurrenceDay2 = recurrenceDay2
        ctx.insert(tx)
        try save()
    }

    func addTransfer(fromAccount: String, toAccount: String, amount: Double, note: String, date: String) throws {
        guard let ctx,
              let src = findAccount(named: fromAccount),
              let dst = findAccount(named: toAccount) else { return }
        let tx = FinancialTransaction(
            type: .transfer,
            amount: Decimal(abs(amount)),
            date: Self.parseDate(date) ?? Date(),
            note: note.isEmpty ? "Transferência" : note,
            sourceAccount: src,
            destinationAccount: dst
        )
        ctx.insert(tx)
        try save()
    }

    func updateTransaction(id: UUID, title: String, amount: Double, isIncome: Bool,
                           category: TxCategory, customCatID: String? = nil,
                           account: String, date: String,
                           recurrence: Recurrence = .none,
                           recurrenceDay: Int? = nil, recurrenceDay2: Int? = nil) throws {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<FinancialTransaction>(predicate: #Predicate { $0.id == id })
        guard let tx = try? ctx.fetch(descriptor).first else { return }

        // An investment transaction is off limits to the generic editor, which
        // has no field for symbol, quantity, unit price, FX rate or commission.
        // Writing through it rewrote `.assetPurchase` to `.expense` while those
        // fields stayed behind: the position disappeared from the portfolio and
        // the row became neither an expense nor a holding. The UI now opens
        // these read-only; this is the guarantee that does not depend on it.
        guard tx.assetSymbol == nil else { return }

        tx.note = title
        // Via the decimal string, not `Decimal(Double)`: the latter carries the
        // binary representation across and writes 1234,5599999999997952 into a
        // money field. The PB layer's amounts are two-decimal by construction,
        // so this is exact.
        tx.amount = Self.money(from: abs(amount))
        tx.type = isIncome ? .income : .expense
        tx.category = mapTxCatToTransactionCategory(category)
        tx.customCategoryID = customCatID
        tx.recurrence = recurrence
        tx.recurrenceDay = recurrenceDay
        tx.recurrenceDay2 = recurrenceDay2
        if let d = Self.parseDate(date) { tx.date = d }
        if let acc = findAccount(named: account) { tx.sourceAccount = acc }
        try save()
    }

    func updateTransactionMeta(id: UUID, account: String, date: String) throws {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<FinancialTransaction>(predicate: #Predicate { $0.id == id })
        guard let tx = try? ctx.fetch(descriptor).first else { return }
        // Same rule as `updateTransaction`: moving an investment to another
        // account would silently move the position with it.
        guard tx.assetSymbol == nil else { return }
        if let d = Self.parseDate(date) { tx.date = d }
        if let acc = findAccount(named: account) { tx.sourceAccount = acc }
        try save()
    }

    func deleteTransaction(id: UUID) throws {
        guard let ctx else { return }
        let descriptor = FetchDescriptor<FinancialTransaction>(predicate: #Predicate { $0.id == id })
        guard let tx = try? ctx.fetch(descriptor).first else { return }

        let symbol = tx.assetSymbol
        ctx.delete(tx)

        // Deleting the last transaction of a symbol has to take its metadata
        // with it, exactly as deleting the position does. Otherwise the ticker
        // survives in every future search and keeps a cached price for a
        // holding that no longer exists.
        if let symbol {
            let remaining = (try? ctx.fetch(FetchDescriptor<FinancialTransaction>()))?
                .contains { $0.assetSymbol == symbol && $0.id != id } ?? true
            if !remaining {
                for asset in (try? ctx.fetch(FetchDescriptor<Asset>(
                    predicate: #Predicate { $0.symbol == symbol }
                ))) ?? [] { ctx.delete(asset) }
                for snapshot in (try? ctx.fetch(FetchDescriptor<PriceSnapshot>(
                    predicate: #Predicate { $0.symbol == symbol }
                ))) ?? [] { ctx.delete(snapshot) }
            }
        }

        try save()
    }

    func updateAccount(id: String, name: String, sub: String, colorHex: UInt, balance: Double) throws {
        guard let ctx, let acc = findAccountByID(id) else { return }
        let oldBalance = Double(truncating: acc.balance as NSNumber)
        let delta = balance - oldBalance

        acc.name = name
        acc.colorHex = uintToHexString(colorHex)

        if abs(delta) >= 0.01 {
            let txType: TransactionType = delta > 0 ? .income : .expense
            let tx = FinancialTransaction(
                type: txType,
                amount: Decimal(abs(delta)),
                date: Date(),
                note: "Ajuste de saldo",
                category: .other,
                sourceAccount: acc
            )
            ctx.insert(tx)
        }
        try save()
    }

    func deleteAccount(id: String) throws {
        guard let ctx, let acc = findAccountByID(id) else { return }
        ctx.delete(acc)
        try save()
    }

    func investmentCountForAccount(id: String) -> Int {
        guard let acc = findAccountByID(id) else { return 0 }
        return acc.outgoingTransactions.filter(\.isInvestmentTransaction).count
    }

    func deletionImpact(forAccountID id: String) -> AccountsViewModel.DeletionImpact? {
        guard let ctx, let acc = findAccountByID(id) else { return nil }
        let vm = AccountsViewModel(modelContext: ctx)
        return vm.deletionImpact(for: acc)
    }

    func moveBalanceDelta(forAccountID id: String) -> Decimal {
        guard let ctx, let acc = findAccountByID(id) else { return 0 }
        let vm = AccountsViewModel(modelContext: ctx)
        return vm.moveBalanceDelta(for: acc)
    }

    func moveInvestmentsAndDeleteAccount(sourceID: String, destinationID: String) throws {
        guard let ctx,
              let source = findAccountByID(sourceID),
              let destination = findAccountByID(destinationID)
        else { return }
        let vm = AccountsViewModel(modelContext: ctx)
        try vm.moveInvestmentsAndDelete(from: source, to: destination)
        reload()
    }

    func deleteAccountWithEverything(id: String) throws {
        guard let ctx, let acc = findAccountByID(id) else { return }
        let vm = AccountsViewModel(modelContext: ctx)
        try vm.deleteWithEverything(acc)
        reload()
    }

    func addAccount(name: String, sub: String, kind: AccountKind, colorHex: UInt, initialBalance: Double) throws {
        guard let ctx else { return }
        let type: AccountType = .checking
        let acc = Account(name: name, type: type, colorHex: uintToHexString(colorHex))
        ctx.insert(acc)

        if initialBalance > 0 {
            let tx = FinancialTransaction(
                type: .income,
                amount: Decimal(initialBalance),
                date: Date(),
                note: "Saldo inicial",
                category: .other,
                sourceAccount: acc
            )
            ctx.insert(tx)
        }
        try save()
    }

    /// Drops the cached arrays after the stored rows have gone.
    ///
    /// Separate from the deleting, which `DataReset` owns: this store used to do
    /// both and knew about only three of the nine models, so a "reset" left the
    /// entire portfolio side of the app on disk. Its job now is the part only it
    /// can do — its own caches.
    func clearInMemoryState() {
        accounts = []
        transactions = []
        customCategories = []
    }

    /// What the reset needs from this store: the numbers behind the
    /// confirmation come from `DataReset.inventory`, and the erase itself needs
    /// a context to work in.
    var modelContext: ModelContext? { ctx }

    // MARK: - SwiftData helpers

    private func findAccount(named name: String) -> Account? {
        guard let ctx else { return nil }
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.name == name })
        return try? ctx.fetch(descriptor).first
    }

    private func findAccountByID(_ id: String) -> Account? {
        guard let ctx, let uuid = UUID(uuidString: id) else { return nil }
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == uuid })
        return try? ctx.fetch(descriptor).first
    }

    // MARK: - Conversion helpers

    private func hexStringToUInt(_ hex: String) -> UInt {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.hasPrefix("0x") || h.hasPrefix("0X") { h.removeFirst(2) }
        return UInt(h, radix: 16) ?? 0x3F7BE0
    }

    private func uintToHexString(_ v: UInt) -> String {
        String(format: "%06X", v)
    }

    private func formatDate(_ d: Date) -> String {
        Self.dateFmt.string(from: d)
    }

    private func mapCategory(_ cat: TransactionCategory?, type: TransactionType) -> TxCategory {
        if type == .transfer { return .transfer }
        // Checked before `.income` so a sale or a dividend reads as an
        // investment rather than as ordinary income.
        if type == .assetPurchase || type == .assetSale || type == .dividend {
            return .investments
        }
        if type == .income { return .income }
        switch cat {
        case .food: return .food
        case .transport: return .transport
        case .salary: return .income
        case .investments: return .investments
        default: return .other
        }
    }

    /// A money amount as an exact two-decimal `Decimal`, avoiding the binary
    /// float residue that `Decimal(someDouble)` drags in.
    nonisolated static func money(from amount: Double) -> Decimal {
        Decimal(string: String(format: "%.2f", amount)) ?? Decimal(amount)
    }

    /// The currency an asset trades in, from the `Asset` row written when the
    /// position was registered. Nil when unknown — never guessed.
    private func assetCurrency(for symbol: String) -> String? {
        guard let ctx else { return nil }
        let descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.symbol == symbol })
        guard let asset = try? ctx.fetch(descriptor).first, !asset.currency.isEmpty else { return nil }
        return asset.currency
    }

    private nonisolated static let quantityFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 8
        return f
    }()

    private func formatQuantity(_ qty: Decimal) -> String {
        Self.quantityFmt.string(from: qty as NSDecimalNumber) ?? "\(qty)"
    }

    private func mapTxCatToTransactionCategory(_ cat: TxCategory) -> TransactionCategory {
        switch cat {
        case .food: .food
        case .transport: .transport
        case .work: .salary
        case .income: .salary
        case .other: .other
        case .transfer: .other
        case .investments: .investments
        }
    }
}
