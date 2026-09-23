import SwiftUI
import SwiftData

// ───────────────────────────────────────────────────────────
// DebtsScreen.swift — Dívidas: o que devo e o que me devem
//
// Fora do património. Nada aqui entra no total do Resumo, no total das
// contas, no widget ou no recap mensal — uma dívida é um compromisso, não um
// saldo, e somá-la a um número que o utilizador já lê todos os dias mudaria o
// significado desse número sem o dizer.
// ───────────────────────────────────────────────────────────

struct DebtsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppStore.self) private var store
    @Query(sort: \Debt.createdAt, order: .reverse) private var debts: [Debt]

    @State private var newDebtDirection: DebtDirection?
    @State private var payingDebt: Debt?
    @State private var pendingDelete: Debt?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection

                if debts.isEmpty {
                    ContentUnavailableView(
                        "Sem dívidas",
                        systemImage: "person.2.slash",
                        description: Text("Regista uma dívida tua ou de alguém para contigo.")
                    )
                    .padding(.top, 40)
                } else {
                    section(for: .iOwe)
                    section(for: .owedToMe)
                }

                Spacer(minLength: 100)
            }
        }
        .background(PB.bg)
        .navigationTitle("Dívidas")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(DebtDirection.allCases) { direction in
                        Button {
                            newDebtDirection = direction
                        } label: {
                            Label(direction.singular, systemImage: direction.icon)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        // `.id` on both sheets: they seed @State in init and SwiftUI reuses the
        // sheet's identity between presentations, so without it the second debt
        // opened shows the first one's values. Same fix as TransactionEditSheet.
        .sheet(item: $newDebtDirection) { direction in
            DebtFormSheet(direction: direction)
                .environment(\.modelContext, modelContext)
                .id(direction.rawValue)
        }
        .sheet(item: $payingDebt) { debt in
            DebtPaymentSheet(debt: debt)
                .environment(\.modelContext, modelContext)
                .environment(store)
                .id(debt.id)
        }
        // Bindings with a real setter, not `.constant`: an alert dismissed by
        // any route other than its own buttons writes `false` back, and a
        // constant swallows that — the state stays set and the alert cannot be
        // opened a second time.
        .alert("Apagar dívida?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { debt in
            Button("Apagar", role: .destructive) { delete(debt) }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { debt in
            Text(deleteWarning(debt))
        }
        .alert("Não foi possível", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                totalCard(for: .iOwe)
                totalCard(for: .owedToMe)
            }
            // Said once, here, rather than left for the user to work out from
            // the fact that the numbers do not add up to anything they know.
            Text("As dívidas não entram no património total nem no saldo das contas.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func totalCard(for direction: DebtDirection) -> some View {
        let total = DebtService.totalOutstanding(debts, direction: direction)
        return VStack(alignment: .leading, spacing: 4) {
            Label(direction.title, systemImage: direction.icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(Fmt.eur(total.doubleValue))
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(direction == .iOwe ? PB.neg : PB.pos)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PB.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(for direction: DebtDirection) -> some View {
        let rows = debts.filter { $0.direction == direction }
        if !rows.isEmpty {
            Text(direction.title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .padding(.top, 18)
                .padding(.bottom, 7)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, debt in
                    NavigationLink(value: PBRoute.debt(debt.id)) {
                        DebtRow(debt: debt)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            payingDebt = debt
                        } label: {
                            Label(debt.direction.paymentVerb, systemImage: "eurosign.circle")
                        }
                        .disabled(debt.isSettled)
                        Button(role: .destructive) {
                            pendingDelete = debt
                        } label: {
                            Label("Apagar dívida", systemImage: "trash")
                        }
                    }
                    if i < rows.count - 1 {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .background(PB.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Actions

    /// Names what deleting takes with it. A debt with account-backed payments
    /// also owns the movements those payments wrote, and removing them changes
    /// balances — the user has to be told that before, not discover it after.
    private func deleteWarning(_ debt: Debt) -> String {
        let linked = debt.payments.count(where: { $0.transactionID != nil })
        var text = "Apaga a dívida com \(debt.counterparty) e os \(debt.payments.count) pagamentos registados."
        if linked > 0 {
            text += " \(linked) \(linked == 1 ? "movimento é apagado" : "movimentos são apagados") das contas, e os saldos mudam."
        }
        text += " Não pode ser anulado."
        return text
    }

    private func delete(_ debt: Debt) {
        pendingDelete = nil
        do {
            try DebtService.deleteDebt(debt, in: modelContext)
            store.reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Linha

struct DebtRow: View {
    let debt: Debt

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(tint.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: debt.isSettled ? "checkmark" : debt.direction.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(debt.counterparty)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PB.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let progress = debt.progress, !debt.isSettled {
                    ProgressView(value: progress)
                        .tint(tint)
                        .frame(height: 3)
                }
            }
            // Só este lado cede, e o que perde é o meio de um nome. O número do
            // lado direito nunca quebra de linha.
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.eur(debt.outstanding.doubleValue))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(debt.isSettled ? PB.text2 : PB.text)
                    .fixedSize()
                Text(debt.isSettled ? "liquidada" : "de \(Fmt.eur(debt.principal.doubleValue))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PB.text3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        if debt.isSettled { return PB.text2 }
        return debt.direction == .iOwe ? PB.neg : PB.pos
    }

    private var subtitle: String {
        var parts: [String] = []
        if debt.payments.isEmpty {
            parts.append("sem pagamentos")
        } else {
            parts.append("\(debt.payments.count) \(debt.payments.count == 1 ? "pagamento" : "pagamentos")")
        }
        if let due = debt.dueDate, !debt.isSettled {
            parts.append("até \(DebtFormat.shortDate(due))")
        }
        if !debt.note.isEmpty {
            parts.append(debt.note)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Formatação partilhada

enum DebtFormat {
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    static func shortDate(_ date: Date) -> String {
        shortFormatter.string(from: date)
    }
}

extension Decimal {
    /// Only for handing a figure to `Fmt`, which speaks Double. Every sum and
    /// every comparison stays in Decimal — this is the last step before the
    /// string, never a step before more arithmetic.
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }
}
