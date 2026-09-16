import SwiftUI
import SwiftData

struct AccountsView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @State private var activeSheet: MovementsSheet?
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var accountPendingDeletion: Account?
    @State private var showDeleteOptions = false
    @State private var showDeleteConfirm = false
    @State private var showMoveSheet = false
    @State private var deleteError: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var totalBalance: Decimal {
        accounts.reduce(0) { $0 + $1.balance }
    }

    private var otherAccounts: [Account] {
        guard let pending = accountPendingDeletion else { return [] }
        return accounts.filter { $0.id != pending.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    EmptyState(
                        icon: "banknote",
                        title: String(localized: "accounts_empty_title"),
                        message: String(localized: "accounts_empty_message"),
                        actionTitle: String(localized: "accounts_add_button")
                    ) {
                        activeSheet = .addAccount
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            headerSection

                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "movements_total_balance"))
                                    .font(.cardBody)
                                    .foregroundStyle(.secondary)
                                Text(CurrencyFormatter.format(totalBalance))
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 16)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(accounts) { account in
                                    NavigationLink {
                                        AccountDetailView(account: account)
                                    } label: {
                                        AccountCardTile(account: account)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            accountPendingDeletion = account
                                            let vm = AccountsViewModel(modelContext: modelContext)
                                            let impact = vm.deletionImpact(for: account)
                                            if impact.hasInvestments && otherAccounts.count > 0 {
                                                showDeleteOptions = true
                                            } else if impact.hasInvestments {
                                                showDeleteConfirm = true
                                            } else {
                                                showDeleteConfirm = true
                                            }
                                        } label: {
                                            Label(String(localized: "action_delete"), systemImage: "trash")
                                        }
                                    }
                                }

                                Button { activeSheet = .addAccount } label: {
                                    AddAccountTile()
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 24)
                    }
                    .background(Color.screenBackground)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            appTheme = appTheme == "dark" ? "light" : "dark"
                        } label: {
                            Image(systemName: appTheme == "dark" ? "sun.max" : "moon")
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Color.cardBackground, in: Circle())
                        }
                        Menu {
                            Button { activeSheet = .addExpense } label: {
                                Label(String(localized: "movements_add_expense"), systemImage: "minus.circle")
                            }
                            .disabled(accounts.isEmpty)
                            Button { activeSheet = .addIncome } label: {
                                Label(String(localized: "movements_add_income"), systemImage: "plus.circle")
                            }
                            .disabled(accounts.isEmpty)
                            Button { activeSheet = .addTransfer } label: {
                                Label(String(localized: "movements_add_transfer"), systemImage: "arrow.left.arrow.right")
                            }
                            .disabled(accounts.count < 2)
                            Divider()
                            Button { activeSheet = .addAccount } label: {
                                Label(String(localized: "movements_add_account"), systemImage: "banknote")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Color.cardBackground, in: Circle())
                        }
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addAccount:
                    AccountFormView()
                case .addExpense:
                    TransactionFormView(initialType: .expense)
                case .addIncome:
                    TransactionFormView(initialType: .income)
                case .addTransfer:
                    TransferFormView()
                }
            }
            .confirmationDialog(
                deleteOptionsTitle,
                isPresented: $showDeleteOptions,
                titleVisibility: .visible
            ) {
                Button("Mover investimentos para outra conta") {
                    showMoveSheet = true
                }
                Button("Apagar tudo", role: .destructive) {
                    showDeleteConfirm = true
                }
                Button("Cancelar", role: .cancel) {
                    accountPendingDeletion = nil
                }
            }
            .confirmationDialog(
                deleteConfirmTitle,
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Apagar", role: .destructive) {
                    guard let acc = accountPendingDeletion else { return }
                    let vm = AccountsViewModel(modelContext: modelContext)
                    do {
                        try vm.deleteWithEverything(acc)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                    accountPendingDeletion = nil
                }
                Button("Cancelar", role: .cancel) {
                    accountPendingDeletion = nil
                }
            }
            .sheet(isPresented: $showMoveSheet) {
                if let acc = accountPendingDeletion {
                    MoveInvestmentsSheet(
                        source: acc,
                        destinations: otherAccounts,
                        modelContext: modelContext
                    ) {
                        accountPendingDeletion = nil
                    }
                }
            }
            .alert("Erro", isPresented: .init(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    private var deleteOptionsTitle: String {
        guard let acc = accountPendingDeletion else { return "" }
        let vm = AccountsViewModel(modelContext: modelContext)
        let impact = vm.deletionImpact(for: acc)
        let symbols = impact.symbols.joined(separator: ", ")
        return "A conta \"\(acc.name)\" tem \(impact.investmentCount) transações de investimento (\(symbols)). O que fazer?"
    }

    private var deleteConfirmTitle: String {
        guard let acc = accountPendingDeletion else { return "" }
        let vm = AccountsViewModel(modelContext: modelContext)
        let impact = vm.deletionImpact(for: acc)
        if !impact.hasInvestments {
            return "Apagar a conta \"\(acc.name)\" e as suas \(impact.nonInvestmentCount) transações?"
        }
        var lines = ["Apagar a conta \"\(acc.name)\" e todas as suas transações?"]
        for change in impact.positionChanges {
            if change.disappears {
                lines.append("\(change.symbol): posição desaparece (\(change.currentQuantity) unidades)")
            } else {
                lines.append("\(change.symbol): \(change.currentQuantity) → \(change.newQuantity) unidades")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var headerSection: some View {
        Text("Movimentos")
            .font(.system(.largeTitle, design: .default, weight: .bold))
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}

// MARK: - Move Investments Sheet

struct MoveInvestmentsSheet: View {
    let source: Account
    let destinations: [Account]
    let modelContext: ModelContext
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let vm = AccountsViewModel(modelContext: modelContext)
                    let delta = vm.moveBalanceDelta(for: source)
                    let symbols = vm.deletionImpact(for: source).symbols.joined(separator: ", ")
                    Text("Mover \(symbols) da conta \"\(source.name)\" para:")
                        .font(.subheadline)
                    if delta != 0 {
                        Text("O saldo da conta de destino será ajustado em \(CurrencyFormatter.format(delta)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Escolher conta de destino") {
                    ForEach(destinations) { dest in
                        Button {
                            moveAndDelete(to: dest)
                        } label: {
                            HStack {
                                Image(systemName: dest.icon)
                                    .foregroundStyle(Color(hex: dest.colorHex))
                                VStack(alignment: .leading) {
                                    Text(dest.name)
                                    let vm = AccountsViewModel(modelContext: modelContext)
                                    let delta = vm.moveBalanceDelta(for: source)
                                    Text("Saldo: \(CurrencyFormatter.format(dest.balance)) → \(CurrencyFormatter.format(dest.balance + delta))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Mover Investimentos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
            .alert("Erro", isPresented: .init(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func moveAndDelete(to destination: Account) {
        let vm = AccountsViewModel(modelContext: modelContext)
        do {
            try vm.moveInvestmentsAndDelete(from: source, to: destination)
            onDismiss()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Account Card Tile

struct AccountCardTile: View {
    let account: Account

    private var percentChange: Double? {
        let chartData = computeSingleAccountHistory(account: account, days: 30)
        guard chartData.count >= 2,
              let first = chartData.first,
              first.value != 0 else { return nil }
        let lastValue = chartData[chartData.count - 1].value
        return ((lastValue - first.value) / abs(first.value)) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: account.icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(hex: account.colorHex), in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                if let pct = percentChange {
                    PercentBadge(value: pct)
                }
            }

            Spacer(minLength: 16)

            Text(account.name.uppercased())
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 4)

            Text(CurrencyFormatter.format(account.balance, currency: account.currency))
                .font(.title2.weight(.bold))
                .foregroundStyle(account.balance >= 0 ? Color.primary : Color.lossRed)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.separatorLine.opacity(0.6), lineWidth: 0.5)
        )
    }
}

// MARK: - Add Account Tile

private struct AddAccountTile: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primaryAction)
                .frame(width: 56, height: 56)
                .background(Color.primaryAction.opacity(0.15), in: Circle())

            Text(String(localized: "accounts_add_button"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.separatorLine, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }
}

// MARK: - Sheet Enum

enum MovementsSheet: String, Identifiable {
    case addAccount
    case addExpense
    case addIncome
    case addTransfer

    var id: String { rawValue }
}

#Preview {
    AccountsView()
        .modelContainer(for: [Account.self, FinancialTransaction.self], inMemory: true)
}
