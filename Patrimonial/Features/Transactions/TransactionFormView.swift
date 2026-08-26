import SwiftUI
import SwiftData

struct TransactionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    let preselectedAccount: Account?
    let editing: FinancialTransaction?

    @State private var transactionType: TransactionType
    @State private var amountText: String
    @State private var selectedAccountID: UUID?
    @State private var category: TransactionCategory
    @State private var note: String
    @State private var date: Date

    init(preselectedAccount: Account? = nil, initialType: TransactionType = .expense, editing: FinancialTransaction? = nil) {
        self.preselectedAccount = preselectedAccount
        self.editing = editing
        if let tx = editing {
            _transactionType = State(initialValue: tx.type)
            _amountText = State(initialValue: Self.formatAmount(tx.amount))
            _selectedAccountID = State(initialValue: tx.sourceAccount?.id)
            _category = State(initialValue: tx.category ?? .other)
            _note = State(initialValue: tx.note)
            _date = State(initialValue: tx.date)
        } else {
            _transactionType = State(initialValue: initialType)
            _amountText = State(initialValue: "")
            _selectedAccountID = State(initialValue: preselectedAccount?.id)
            _category = State(initialValue: .other)
            _note = State(initialValue: "")
            _date = State(initialValue: Date())
        }
    }

    private var isValid: Bool {
        guard let amount = parseAmount(amountText), amount > 0 else { return false }
        return selectedAccountID != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "form_type"), selection: $transactionType) {
                        Text(String(localized: "transaction_type_expense")).tag(TransactionType.expense)
                        Text(String(localized: "transaction_type_income")).tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                }

                Section {
                    HStack {
                        Text("€")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "form_amount"), text: $amountText)
                            .font(.system(.title, design: .monospaced, weight: .bold))
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Picker(String(localized: "form_account"), selection: $selectedAccountID) {
                        Text(String(localized: "form_select_account"))
                            .tag(nil as UUID?)
                        ForEach(accounts) { account in
                            HStack {
                                Image(systemName: account.icon)
                                Text(account.name)
                            }
                            .tag(Optional(account.id))
                        }
                    }

                    Picker(String(localized: "form_category"), selection: $category) {
                        ForEach(TransactionCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                }

                Section {
                    TextField(String(localized: "form_description"), text: $note)
                    DatePicker(String(localized: "form_date"), selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle(editing != nil
                ? String(localized: "transaction_edit_title")
                : (transactionType == .expense
                    ? String(localized: "movements_add_expense")
                    : String(localized: "movements_add_income")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "form_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "form_save")) { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        guard let amount = parseAmount(amountText),
              let accountID = selectedAccountID,
              let account = accounts.first(where: { $0.id == accountID }) else { return }

        if let tx = editing {
            tx.type = transactionType
            tx.amount = amount
            tx.date = date
            tx.note = note
            tx.category = category
            tx.sourceAccount = account
            try? modelContext.save()
        } else {
            let vm = TransactionsViewModel(modelContext: modelContext)
            if transactionType == .expense {
                vm.addExpense(amount: amount, account: account, category: category, note: note, date: date)
            } else {
                vm.addIncome(amount: amount, account: account, category: category, note: note, date: date)
            }
        }
        dismiss()
    }

    private func parseAmount(_ text: String) -> Decimal? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalized)
    }

    private static func formatAmount(_ value: Decimal) -> String {
        let n = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        f.groupingSeparator = ""
        return f.string(from: n) ?? "\(value)"
    }
}

#Preview {
    TransactionFormView()
        .modelContainer(for: [Account.self, FinancialTransaction.self], inMemory: true)
}
