import SwiftUI
import SwiftData

struct TransferFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    let preselectedSource: Account?
    let editing: FinancialTransaction?

    @State private var sourceAccountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var amountText: String
    @State private var note: String
    @State private var date: Date

    init(preselectedSource: Account? = nil, editing: FinancialTransaction? = nil) {
        self.preselectedSource = preselectedSource
        self.editing = editing
        if let tx = editing {
            _sourceAccountID = State(initialValue: tx.sourceAccount?.id)
            _destinationAccountID = State(initialValue: tx.destinationAccount?.id)
            _amountText = State(initialValue: Self.formatAmount(tx.amount))
            _note = State(initialValue: tx.note)
            _date = State(initialValue: tx.date)
        } else {
            _sourceAccountID = State(initialValue: preselectedSource?.id)
            _destinationAccountID = State(initialValue: nil)
            _amountText = State(initialValue: "")
            _note = State(initialValue: "")
            _date = State(initialValue: Date())
        }
    }

    private var isValid: Bool {
        guard let amount = parseAmount(amountText), amount > 0 else { return false }
        guard let source = sourceAccountID, let dest = destinationAccountID else { return false }
        return source != dest
    }

    private var destinationAccounts: [Account] {
        accounts.filter { $0.id != sourceAccountID }
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Picker(String(localized: "transfer_from"), selection: $sourceAccountID) {
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
                    .onChange(of: sourceAccountID) { _, newValue in
                        if destinationAccountID == newValue {
                            destinationAccountID = nil
                        }
                    }

                    Picker(String(localized: "transfer_to"), selection: $destinationAccountID) {
                        Text(String(localized: "form_select_account"))
                            .tag(nil as UUID?)
                        ForEach(destinationAccounts) { account in
                            HStack {
                                Image(systemName: account.icon)
                                Text(account.name)
                            }
                            .tag(Optional(account.id))
                        }
                    }
                }

                Section {
                    TextField(String(localized: "transfer_note"), text: $note)
                    DatePicker(String(localized: "form_date"), selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle(editing != nil
                ? String(localized: "transfer_edit_title")
                : String(localized: "movements_add_transfer"))
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
              let srcID = sourceAccountID,
              let dstID = destinationAccountID,
              let source = accounts.first(where: { $0.id == srcID }),
              let destination = accounts.first(where: { $0.id == dstID }) else { return }

        if let tx = editing {
            tx.amount = amount
            tx.sourceAccount = source
            tx.destinationAccount = destination
            tx.note = note
            tx.date = date
            try? modelContext.save()
        } else {
            let vm = TransactionsViewModel(modelContext: modelContext)
            vm.addTransfer(amount: amount, from: source, to: destination, note: note, date: date)
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
    TransferFormView()
        .modelContainer(for: [Account.self, FinancialTransaction.self], inMemory: true)
}
