import SwiftUI
import SwiftData

// MARK: - Nova dívida

struct DebtFormSheet: View {
    let direction: DebtDirection

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var counterparty = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var openedAt = Date()
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var errorMessage: String?

    /// Saving is allowed only when both required fields are *valid*, not merely
    /// non-empty: an amount of "abc" parses to nil, and a disabled button is a
    /// better answer than an alert after the fact.
    private var parsedAmount: Decimal? { DebtAmount.parse(amount) }
    private var canSave: Bool {
        !counterparty.trimmingCharacters(in: .whitespaces).isEmpty
            && (parsedAmount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Detalhes") {
                    TextField(
                        direction == .iOwe ? "A quem devo" : "Quem me deve",
                        text: $counterparty
                    )
                    HStack {
                        Text("Valor"); Spacer()
                        TextField("0,00", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(PB.text3)
                    }
                    TextField("Nota (opcional)", text: $note)
                }
                Section("Datas") {
                    DatePicker("Início", selection: $openedAt, in: ...Date(), displayedComponents: .date)
                    Toggle("Tem prazo", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Prazo", selection: $dueDate, displayedComponents: .date)
                    }
                }
                Section {
                    Text("As dívidas não entram no património total nem no saldo das contas. Só os pagamentos que associares a uma conta é que mexem no saldo.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            .pbFormChrome(direction.singular)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .alert("Não foi possível", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        guard let principal = parsedAmount else { return }
        do {
            try DebtService.addDebt(
                counterparty: counterparty,
                note: note,
                principal: principal,
                direction: direction,
                openedAt: openedAt,
                dueDate: hasDueDate ? dueDate : nil,
                in: modelContext
            )
            DebtReminders.scheduleAll(in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pagamento

struct DebtPaymentSheet: View {
    let debt: Debt

    @Environment(\.modelContext) private var modelContext
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var amount: String
    @State private var date = Date()
    @State private var note = ""
    /// Nil means "fora das contas" — a payment made in cash, which has to stay
    /// recordable. Only a chosen account writes a movement.
    @State private var accountID: UUID?
    @State private var errorMessage: String?

    init(debt: Debt) {
        self.debt = debt
        // Pre-filled with what is still owed, because settling in full is the
        // common case and retyping the figure is where a typo gets in. Any
        // smaller amount is a partial payment; anything larger is refused.
        _amount = State(initialValue: DebtAmount.editable(debt.outstanding))
    }

    private var parsedAmount: Decimal? { DebtAmount.parse(amount) }
    private var canSave: Bool {
        guard let value = parsedAmount else { return false }
        return value > 0 && value <= debt.outstanding
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Valor") {
                    HStack {
                        Text(debt.direction.paymentVerb); Spacer()
                        TextField("0,00", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(PB.text3)
                    }
                    // The ceiling, always visible. Without it the only way to
                    // find out the payment is too large is to be refused by it.
                    Text("Em dívida: \(Fmt.eur(debt.outstanding.doubleValue))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    DatePicker("Data", selection: $date, in: ...Date(), displayedComponents: .date)
                }

                Section(debt.direction.accountPrompt) {
                    Picker("Conta", selection: $accountID) {
                        Text("Fora das contas").tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    Text(accountID == nil
                         ? "Nenhum saldo é alterado — fica só registado na dívida."
                         : accountExplanation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Section("Nota") {
                    TextField("Nota (opcional)", text: $note)
                }
            }
            .pbFormChrome("\(debt.direction.paymentVerb) — \(debt.counterparty)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Registar") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .alert("Não foi possível", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Spells out the movement about to be written, in the direction it goes.
    /// "Cria uma despesa" and "Cria uma receita" are not interchangeable, and
    /// the picker label alone does not say which one this will be.
    private var accountExplanation: String {
        switch debt.direction {
        case .iOwe: "Cria uma despesa nesta conta e o saldo desce."
        case .owedToMe: "Cria uma receita nesta conta e o saldo sobe."
        }
    }

    private func save() {
        guard let value = parsedAmount else { return }
        do {
            try DebtService.registerPayment(
                on: debt,
                amount: value,
                date: date,
                note: note,
                accountID: accountID,
                in: modelContext
            )
            // The movement was written through this context, not through the
            // store's caches — without a reload the account row behind the
            // sheet still shows the old balance.
            DebtReminders.scheduleAll(in: modelContext)
            store.reload()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Valores

enum DebtAmount {
    /// Parses what the user typed into a Decimal, or nothing.
    ///
    /// Nil rather than zero for unparseable input: a "0,00 €" that the user
    /// never typed is a silent answer to a question they got wrong, and here it
    /// would mean a debt of nothing or a payment of nothing being saved.
    /// Accepts both separators, because a decimal keypad on a pt-PT phone emits
    /// a comma and a paste from anywhere else emits a dot.
    static func parse(_ text: String) -> Decimal? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        // `Decimal(string:)` accepts "12abc" as 12, which would turn a typo
        // into a number. The character check refuses it.
        guard cleaned.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A Decimal as the text field should show it: plain digits and a comma,
    /// with no currency symbol or grouping separator to strip back out.
    static func editable(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? ""
    }
}
