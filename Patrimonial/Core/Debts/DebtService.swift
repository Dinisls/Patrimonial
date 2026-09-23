import Foundation
import SwiftData

/// Everything that writes a debt or a payment, in one place and out of the
/// views.
///
/// Free functions over a `ModelContext` rather than a store object: the rules
/// here — what a payment may be, what it does to an account — are the part worth
/// testing, and a test should not have to stand up an `@Observable` and a view
/// hierarchy to reach them.
///
/// The one rule that governs the rest: **a payment and its transaction are one
/// act.** If an account is chosen, the money leaves (or enters) it, and undoing
/// the payment undoes the movement. There is no path that writes one without
/// the other.
enum DebtService {

    enum DebtError: LocalizedError, Equatable {
        case emptyCounterparty
        case nonPositiveAmount
        case futureDate
        /// The payment is larger than what is still owed. Carries the
        /// outstanding amount so the message can name it.
        case overpayment(outstanding: Decimal)
        case accountNotFound

        var errorDescription: String? {
            switch self {
            case .emptyCounterparty:
                "Indica com quem é a dívida."
            case .nonPositiveAmount:
                "O valor tem de ser maior que zero."
            case .futureDate:
                "A data não pode ser no futuro."
            case .overpayment(let outstanding):
                "Faltam apenas \(Self.eur(outstanding)) para liquidar esta dívida."
            case .accountNotFound:
                "A conta escolhida já não existe."
            }
        }

        private static func eur(_ value: Decimal) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "EUR"
            formatter.locale = Locale(identifier: "pt_PT")
            return formatter.string(from: value as NSDecimalNumber) ?? "—"
        }
    }

    // MARK: - Reading

    @MainActor
    static func allDebts(in ctx: ModelContext) -> [Debt] {
        let descriptor = FetchDescriptor<Debt>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// The sum still owed in one direction.
    ///
    /// Over open debts only, which is what `outstanding` already guarantees —
    /// a settled debt contributes zero. Settled rows stay in the list as
    /// history; they just stop counting.
    static func totalOutstanding(_ debts: [Debt], direction: DebtDirection) -> Decimal {
        debts
            .filter { $0.direction == direction }
            .reduce(Decimal(0)) { $0 + $1.outstanding }
    }

    // MARK: - Writing

    @MainActor
    @discardableResult
    static func addDebt(
        counterparty: String,
        note: String = "",
        principal: Decimal,
        direction: DebtDirection,
        openedAt: Date = Date(),
        dueDate: Date? = nil,
        in ctx: ModelContext,
        now: () -> Date = { Date() }
    ) throws -> Debt {
        let name = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DebtError.emptyCounterparty }
        guard principal > 0 else { throw DebtError.nonPositiveAmount }
        guard openedAt <= now() else { throw DebtError.futureDate }

        let debt = Debt(
            counterparty: name,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            principal: principal,
            direction: direction,
            openedAt: openedAt,
            dueDate: dueDate
        )
        ctx.insert(debt)
        try ctx.save()
        return debt
    }

    /// Registers a partial (or full) payment against a debt.
    ///
    /// `accountID` is optional on purpose: a debt settled in cash is still a
    /// payment, and refusing to record it would push the user to invent a
    /// transaction that never happened. When an account *is* given, the
    /// movement is written to it — an expense against a debt of mine, income
    /// against one owed to me — and the two rows are linked by
    /// `DebtPayment.transactionID`.
    @MainActor
    @discardableResult
    static func registerPayment(
        on debt: Debt,
        amount: Decimal,
        date: Date = Date(),
        note: String = "",
        accountID: UUID? = nil,
        in ctx: ModelContext,
        now: () -> Date = { Date() }
    ) throws -> DebtPayment {
        guard amount > 0 else { throw DebtError.nonPositiveAmount }
        guard date <= now() else { throw DebtError.futureDate }
        // Read before writing anything: a refused payment must leave no trace,
        // and an inserted-then-rolled-back row is a trace.
        let outstanding = debt.outstanding
        guard amount <= outstanding else {
            throw DebtError.overpayment(outstanding: outstanding)
        }

        var account: Account?
        if let accountID {
            let descriptor = FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == accountID }
            )
            guard let found = try? ctx.fetch(descriptor).first else {
                throw DebtError.accountNotFound
            }
            account = found
        }

        let payment = DebtPayment(
            amount: amount,
            date: date,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: account?.id
        )

        if let account {
            let tx = FinancialTransaction(
                type: debt.direction.transactionType,
                amount: amount,
                date: date,
                note: paymentTitle(for: debt),
                category: .other,
                recurrence: .none,
                sourceAccount: account
            )
            ctx.insert(tx)
            payment.transactionID = tx.id
        }

        payment.debt = debt
        ctx.insert(payment)
        try ctx.save()
        return payment
    }

    /// Deletes a payment, and the account movement it caused.
    ///
    /// Leaving the transaction behind would be the worse half of the two: the
    /// debt would go back up while the account stayed down, and nothing on
    /// screen would explain the missing money.
    @MainActor
    static func deletePayment(_ payment: DebtPayment, in ctx: ModelContext) throws {
        if let txID = payment.transactionID {
            let descriptor = FetchDescriptor<FinancialTransaction>(
                predicate: #Predicate { $0.id == txID }
            )
            for tx in (try? ctx.fetch(descriptor)) ?? [] {
                ctx.delete(tx)
            }
        }
        ctx.delete(payment)
        try ctx.save()
    }

    /// Deletes a debt and every payment against it, movements included.
    ///
    /// The cascade rule on `Debt.payments` takes the payment rows, but it knows
    /// nothing about the transactions those payments wrote — so those are
    /// removed here, one by one, before the debt goes.
    @MainActor
    static func deleteDebt(_ debt: Debt, in ctx: ModelContext) throws {
        for payment in debt.payments {
            if let txID = payment.transactionID {
                let descriptor = FetchDescriptor<FinancialTransaction>(
                    predicate: #Predicate { $0.id == txID }
                )
                for tx in (try? ctx.fetch(descriptor)) ?? [] {
                    ctx.delete(tx)
                }
            }
        }
        ctx.delete(debt)
        try ctx.save()
    }

    /// What the movement is called in the transactions list.
    ///
    /// Names the counterparty, because "Pagamento" on its own in a list of
    /// forty movements says nothing about which debt it settled.
    static func paymentTitle(for debt: Debt) -> String {
        switch debt.direction {
        case .iOwe: "Pagamento a \(debt.counterparty)"
        case .owedToMe: "Recebimento de \(debt.counterparty)"
        }
    }
}
