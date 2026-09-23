import Foundation
import SwiftData

/// Which way the money owes.
///
/// Two cases and no third: a debt is either mine to pay or mine to collect, and
/// the sign of every figure on the screen follows from this one field. Stored as
/// a raw string in SwiftData — the cases are permanent, and a case removed here
/// is a row that no longer decodes.
enum DebtDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Money the user owes someone else.
    case iOwe = "iOwe"
    /// Money someone else owes the user.
    case owedToMe = "owedToMe"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iOwe: "O que devo"
        case .owedToMe: "O que me devem"
        }
    }

    /// What one debt of this direction is, in the singular.
    var singular: String {
        switch self {
        case .iOwe: "Dívida minha"
        case .owedToMe: "Dívida a meu favor"
        }
    }

    /// What registering a payment does, from the user's side.
    var paymentVerb: String {
        switch self {
        case .iOwe: "Pagar"
        case .owedToMe: "Receber"
        }
    }

    /// The account field's meaning, which is the opposite in each direction and
    /// is the whole reason the payment sheet cannot use one fixed label.
    var accountPrompt: String {
        switch self {
        case .iOwe: "Conta de onde sai o dinheiro"
        case .owedToMe: "Conta onde entra o dinheiro"
        }
    }

    var icon: String {
        switch self {
        case .iOwe: "arrow.up.right"
        case .owedToMe: "arrow.down.left"
        }
    }

    /// The transaction a payment in this direction writes to the chosen account.
    var transactionType: TransactionType {
        switch self {
        case .iOwe: .expense
        case .owedToMe: .income
        }
    }
}

/// A sum owed, in one direction, and everything paid against it so far.
///
/// The amount still open is **derived**, never stored: a stored balance and a
/// list of payments are two records of the same fact, and they drift the first
/// time a payment is deleted from one and not the other. `outstanding` reads the
/// payments every time, so the two can never disagree.
///
/// Debts stay out of the net-worth total by design. They have their own screen
/// and their own totals; nothing that already reports a figure — the hero total,
/// the accounts total, the widget, the monthly recap — changes meaning because
/// this model exists.
@Model
final class Debt {
    var id: UUID
    /// Who the debt is with. Free text: a person, a bank, a shop.
    var counterparty: String
    var note: String
    /// The full sum owed when the debt was created, before any payment.
    var principal: Decimal
    var direction: DebtDirection
    var openedAt: Date
    var dueDate: Date?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \DebtPayment.debt)
    var payments: [DebtPayment] = []

    init(
        id: UUID = UUID(),
        counterparty: String,
        note: String = "",
        principal: Decimal,
        direction: DebtDirection,
        openedAt: Date = Date(),
        dueDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.counterparty = counterparty
        self.note = note
        self.principal = principal
        self.direction = direction
        self.openedAt = openedAt
        self.dueDate = dueDate
        self.createdAt = createdAt
    }

    /// Everything paid against this debt so far.
    var paidAmount: Decimal {
        payments.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// What is still owed.
    ///
    /// Clamped at zero rather than allowed to go negative: an overpayment is
    /// refused at the point of entry, so a negative here would mean data written
    /// by an older build or an import, and "−20 € em dívida" reads as a debt in
    /// the other direction, which it is not.
    var outstanding: Decimal {
        max(0, principal - paidAmount)
    }

    var isSettled: Bool { outstanding == 0 }

    /// How much of the debt is done with, 0…1. Nil when the principal is zero —
    /// there is no fraction of nothing, and 0/0 would otherwise draw a full bar.
    var progress: Double? {
        guard principal > 0 else { return nil }
        let ratio = (paidAmount / principal) as NSDecimalNumber
        return min(1, max(0, ratio.doubleValue))
    }

    var sortedPayments: [DebtPayment] {
        payments.sorted { $0.date > $1.date }
    }
}

/// One payment against a debt.
///
/// `accountID` and `transactionID` travel together: either the payment moved
/// real money through an account — in which case there is a transaction and
/// deleting the payment must delete it too — or it did not, and both are nil.
/// A payment with an account but no transaction would be money the accounts
/// never saw.
@Model
final class DebtPayment {
    var id: UUID
    var amount: Decimal
    var date: Date
    var note: String
    /// The account the money moved through, when one was chosen. Nil for cash
    /// settled outside the tracked accounts, which has to stay recordable.
    var accountID: UUID?
    /// The `FinancialTransaction` written for this payment, when an account was
    /// chosen. The link is what lets deleting the payment undo the movement.
    var transactionID: UUID?
    var debt: Debt?

    init(
        id: UUID = UUID(),
        amount: Decimal,
        date: Date = Date(),
        note: String = "",
        accountID: UUID? = nil,
        transactionID: UUID? = nil
    ) {
        self.id = id
        self.amount = amount
        self.date = date
        self.note = note
        self.accountID = accountID
        self.transactionID = transactionID
    }
}
