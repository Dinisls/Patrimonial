import Foundation
import Testing
import SwiftData
@testable import Patrimonial

/// What a debt is, and what paying one does.
///
/// The two properties worth pinning here are the ones a screen cannot show you
/// are broken: that the outstanding amount is always the principal minus the
/// payments — never a stored number that drifted — and that a payment tied to an
/// account and the movement it wrote live and die together.
@MainActor
struct DebtTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { date(2026, 9, 22, 15) }

    private func makeAccount(_ name: String = "Conta à Ordem", in ctx: ModelContext) -> Account {
        let acc = Account(name: name, type: .checking)
        ctx.insert(acc)
        try! ctx.save()
        return acc
    }

    // MARK: - Saldo em aberto

    /// The property the whole feature rests on: partial payments subtract, and
    /// nothing else does.
    @Test(arguments: [DebtDirection.iOwe, .owedToMe])
    func outstandingIsPrincipalMinusPayments(direction: DebtDirection) throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let debt = try DebtService.addDebt(
            counterparty: "João", principal: 500, direction: direction,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        #expect(debt.outstanding == 500)
        #expect(debt.isSettled == false)

        try DebtService.registerPayment(
            on: debt, amount: 120, date: date(2026, 9, 10), in: ctx, now: { now }
        )
        #expect(debt.paidAmount == 120)
        #expect(debt.outstanding == 380)

        try DebtService.registerPayment(
            on: debt, amount: 380, date: date(2026, 9, 20), in: ctx, now: { now }
        )
        #expect(debt.outstanding == 0)
        #expect(debt.isSettled)
    }

    /// The ceiling. Without it a debt goes negative, and a negative debt reads
    /// on screen as one in the other direction.
    @Test func aPaymentLargerThanWhatIsOwedIsRefused() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let debt = try DebtService.addDebt(
            counterparty: "Ana", principal: 100, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 60, date: date(2026, 9, 5), in: ctx, now: { now }
        )

        #expect(throws: DebtService.DebtError.overpayment(outstanding: 40)) {
            try DebtService.registerPayment(
                on: debt, amount: 41, date: date(2026, 9, 6), in: ctx, now: { now }
            )
        }
        // Refused means nothing happened — not "happened and was undone".
        #expect(debt.payments.count == 1)
        #expect(debt.outstanding == 40)
    }

    @Test func aPaymentInTheFutureIsRefused() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let debt = try DebtService.addDebt(
            counterparty: "Ana", principal: 100, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        #expect(throws: DebtService.DebtError.futureDate) {
            try DebtService.registerPayment(
                on: debt, amount: 10, date: date(2026, 9, 23), in: ctx, now: { now }
            )
        }
        #expect(debt.payments.isEmpty)
    }

    @Test(arguments: [Decimal(0), Decimal(-5)])
    func aPaymentOfNothingOrLessIsRefused(amount: Decimal) throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let debt = try DebtService.addDebt(
            counterparty: "Ana", principal: 100, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        #expect(throws: DebtService.DebtError.nonPositiveAmount) {
            try DebtService.registerPayment(
                on: debt, amount: amount, date: date(2026, 9, 5), in: ctx, now: { now }
            )
        }
    }

    // MARK: - Conta e movimento

    /// The direction decides the sign of the movement, and getting it backwards
    /// is the one mistake the balance would hide: both an expense and an income
    /// of 50 € leave a plausible-looking account.
    @Test func payingADebtOfMineTakesTheMoneyOutOfTheChosenAccount() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)

        let debt = try DebtService.addDebt(
            counterparty: "Banco", principal: 200, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10),
            accountID: account.id, in: ctx, now: { now }
        )

        #expect(account.balance == -50)
        let tx = try #require(account.outgoingTransactions.first)
        #expect(tx.type == .expense)
        #expect(tx.amount == 50)
        #expect(tx.note == "Pagamento a Banco")
    }

    @Test func receivingADebtOwedToMePutsTheMoneyIntoTheChosenAccount() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)

        let debt = try DebtService.addDebt(
            counterparty: "Pedro", principal: 200, direction: .owedToMe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10),
            accountID: account.id, in: ctx, now: { now }
        )

        #expect(account.balance == 50)
        let tx = try #require(account.outgoingTransactions.first)
        #expect(tx.type == .income)
        #expect(tx.note == "Recebimento de Pedro")
    }

    /// A payment made in cash. The debt goes down and no balance moves — the
    /// case that would be unrecordable if the account were mandatory.
    @Test func aPaymentWithoutAnAccountTouchesNoBalance() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)

        let debt = try DebtService.addDebt(
            counterparty: "Rui", principal: 200, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        let payment = try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10), in: ctx, now: { now }
        )

        #expect(debt.outstanding == 150)
        #expect(payment.transactionID == nil)
        #expect(account.balance == 0)
        #expect((try ctx.fetch(FetchDescriptor<FinancialTransaction>())).isEmpty)
    }

    // MARK: - Apagar

    /// The two halves of one act. Deleting the payment without its movement
    /// would raise the debt back up while the account stayed down, and the
    /// missing money would have no explanation anywhere on screen.
    @Test func deletingAPaymentUndoesItsMovement() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)

        let debt = try DebtService.addDebt(
            counterparty: "Banco", principal: 200, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        let payment = try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10),
            accountID: account.id, in: ctx, now: { now }
        )

        try DebtService.deletePayment(payment, in: ctx)

        #expect(debt.outstanding == 200)
        #expect(account.balance == 0)
        #expect((try ctx.fetch(FetchDescriptor<FinancialTransaction>())).isEmpty)
    }

    @Test func deletingADebtTakesItsPaymentsAndMovementsWithIt() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)

        let debt = try DebtService.addDebt(
            counterparty: "Banco", principal: 200, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10),
            accountID: account.id, in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 20, date: date(2026, 9, 11), in: ctx, now: { now }
        )

        try DebtService.deleteDebt(debt, in: ctx)

        #expect((try ctx.fetch(FetchDescriptor<Debt>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<DebtPayment>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<FinancialTransaction>())).isEmpty)
        #expect(account.balance == 0)
    }

    // MARK: - Totais

    /// Each direction is summed on its own. Netting them would claim that money
    /// owed to a friend and money owed by one cancel out.
    @Test func totalsAreSeparatePerDirectionAndIgnoreSettledDebts() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext

        let mine = try DebtService.addDebt(
            counterparty: "Banco", principal: 300, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: mine, amount: 100, date: date(2026, 9, 5), in: ctx, now: { now }
        )
        let theirs = try DebtService.addDebt(
            counterparty: "Pedro", principal: 80, direction: .owedToMe,
            openedAt: date(2026, 9, 2), in: ctx, now: { now }
        )
        let settled = try DebtService.addDebt(
            counterparty: "Ana", principal: 40, direction: .iOwe,
            openedAt: date(2026, 9, 3), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: settled, amount: 40, date: date(2026, 9, 4), in: ctx, now: { now }
        )

        let all = DebtService.allDebts(in: ctx)
        #expect(DebtService.totalOutstanding(all, direction: .iOwe) == 200)
        #expect(DebtService.totalOutstanding(all, direction: .owedToMe) == 80)
        #expect(theirs.outstanding == 80)
    }

    // MARK: - Reset e cópia de segurança

    /// A model registered in the schema and forgotten in the reset comes back
    /// from the dead — the exact failure `DataReset`'s own comment warns about.
    @Test func aResetErasesDebtsAndTheirPayments() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)

        let debt = try DebtService.addDebt(
            counterparty: "Banco", principal: 200, direction: .iOwe,
            openedAt: date(2026, 9, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10),
            accountID: account.id, in: ctx, now: { now }
        )

        #expect(DataReset.inventory(in: ctx).debts == 1)
        try DataReset.eraseEverything(in: ctx)

        #expect((try ctx.fetch(FetchDescriptor<Debt>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<DebtPayment>())).isEmpty)
    }

    /// A debt survives an export/import round trip with its payments, its
    /// direction and the link to the movement intact.
    @Test func debtsSurviveABackupRoundTrip() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let account = makeAccount(in: ctx)
        // Held before the restore: `restore` erases everything first, and
        // reading `account.id` off a deleted model afterwards is a crash.
        let accountID = account.id

        let debt = try DebtService.addDebt(
            counterparty: "Pedro", note: "almoço", principal: 200,
            direction: .owedToMe, openedAt: date(2026, 9, 1),
            dueDate: date(2026, 12, 1), in: ctx, now: { now }
        )
        try DebtService.registerPayment(
            on: debt, amount: 50, date: date(2026, 9, 10),
            accountID: accountID, in: ctx, now: { now }
        )

        let data = try DataBackup.export(from: ctx)
        let result = try DataBackup.restore(from: data, into: ctx)
        #expect(result.debts == 1)

        let restored = try #require(DebtService.allDebts(in: ctx).first)
        #expect(restored.counterparty == "Pedro")
        #expect(restored.note == "almoço")
        // The direction above all: restoring it wrong turns money owed to the
        // user into money they owe, and every figure still looks reasonable.
        #expect(restored.direction == .owedToMe)
        #expect(restored.principal == 200)
        #expect(restored.dueDate == date(2026, 12, 1))
        #expect(restored.outstanding == 150)
        #expect(restored.payments.count == 1)
        #expect(restored.payments.first?.accountID == accountID)
    }

    /// A backup written before debts existed has no such key at all. It has to
    /// keep restoring.
    @Test func aBackupWithoutDebtsStillRestores() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let ctx = container.mainContext
        _ = makeAccount(in: ctx)

        let data = try DataBackup.export(from: ctx)
        var json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json.removeValue(forKey: "debts")
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let result = try DataBackup.restore(from: legacy, into: ctx)
        #expect(result.debts == 0)
        #expect(result.accounts == 1)
    }

    // MARK: - Leitura do que o utilizador escreve

    /// Nil, never zero. A "0,00 €" the user never typed is a silent answer to a
    /// question they got wrong — here it would save a debt of nothing.
    @Test func anUnparseableAmountIsNothing() {
        #expect(DebtAmount.parse("") == nil)
        #expect(DebtAmount.parse("abc") == nil)
        #expect(DebtAmount.parse("12abc") == nil)
        #expect(DebtAmount.parse("12,50") == Decimal(string: "12.50"))
        #expect(DebtAmount.parse("12.50") == Decimal(string: "12.50"))
    }

    /// What the payment sheet puts in the field has to be readable back by the
    /// parser that validates it — a pre-filled value the app itself rejects is
    /// a button that is disabled the moment the sheet opens.
    // Built from strings, not Double literals: `Decimal(1234.56)` goes through
    // a binary Double and is not exactly 1234,56, which would make this test
    // about floating point rather than about the field.
    @Test(arguments: [
        Decimal(string: "0.50")!, Decimal(string: "40")!, Decimal(string: "1234.56")!
    ])
    func theEditableFormIsParsedBackToTheSameNumber(value: Decimal) {
        let text = DebtAmount.editable(value)
        #expect(DebtAmount.parse(text) == value)
    }
}
