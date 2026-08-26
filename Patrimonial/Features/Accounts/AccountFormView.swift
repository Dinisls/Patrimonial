import SwiftUI
import SwiftData

struct AccountFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: Account?

    @State private var name: String
    @State private var type: AccountType
    @State private var colorHex: String

    init(account: Account? = nil) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _type = State(initialValue: account?.type ?? .checking)
        _colorHex = State(initialValue: account?.colorHex ?? "007AFF")
    }

    private var isEditing: Bool { account != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "account_form_name"), text: $name)
                    Picker(String(localized: "account_form_type"), selection: $type) {
                        ForEach(AccountType.allCases) { accountType in
                            Label(accountType.displayName, systemImage: accountType.icon)
                                .tag(accountType)
                        }
                    }
                }

                Section(String(localized: "account_form_color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(Color.accountColorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if colorHex == hex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.headline)
                                    }
                                }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(isEditing
                ? String(localized: "account_form_title_edit")
                : String(localized: "account_form_title_add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "form_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "form_save")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let vm = AccountsViewModel(modelContext: modelContext)
        if let account {
            vm.update(account, name: trimmedName, type: type, colorHex: colorHex)
        } else {
            vm.add(name: trimmedName, type: type, colorHex: colorHex)
        }
        dismiss()
    }
}

#Preview {
    AccountFormView()
        .modelContainer(for: Account.self, inMemory: true)
}
