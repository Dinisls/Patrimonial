import SwiftUI
import SwiftData

/// One debt, everything paid against it, and the button that pays more.
///
/// The screen is reached by `Debt.id`, not by the object: a `NavigationPath`
/// holds its value long after the model may have been deleted, and carrying the
/// object would keep a deleted row alive on screen.
struct DebtDetailScreen: View {
    let debtID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query private var debts: [Debt]

    @State private var showPayment = false
    @State private var pendingDelete: DebtPayment?
    @State private var errorMessage: String?

    init(debtID: UUID) {
        self.debtID = debtID
        _debts = Query(filter: #Predicate<Debt> { $0.id == debtID })
    }

    private var debt: Debt? { debts.first }

    var body: some View {
        Group {
            if let debt {
                content(debt)
            } else {
                // Deleted while the screen was open — from the list behind it,
                // or by a restore. Saying so beats an empty screen of zeros.
                ContentUnavailableView(
                    "Dívida apagada",
                    systemImage: "trash",
                    description: Text("Esta dívida já não existe.")
                )
            }
        }
        .background(PB.bg)
        .navigationTitle(debt?.counterparty ?? "Dívida")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPayment) {
            if let debt {
                DebtPaymentSheet(debt: debt)
                    .environment(\.modelContext, modelContext)
                    .environment(store)
            }
        }
        .alert("Apagar pagamento?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { payment in
            Button("Apagar", role: .destructive) { deletePayment(payment) }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { payment in
            Text(payment.transactionID == nil
                 ? "O valor volta a ficar em dívida."
                 : "O valor volta a ficar em dívida e o movimento é apagado da conta, alterando o saldo.")
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

    @ViewBuilder
    private func content(_ debt: Debt) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                summaryCard(debt)
                payButton(debt)
                paymentsSection(debt)
                Spacer(minLength: 100)
            }
        }
    }

    // MARK: - Resumo

    private func summaryCard(_ debt: Debt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(debt.isSettled ? "Liquidada" : "Em dívida")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(Fmt.eur(debt.outstanding.doubleValue))
                .font(.system(size: 36, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(debt.isSettled ? PB.text2 : (debt.direction == .iOwe ? PB.neg : PB.pos))

            if let progress = debt.progress {
                ProgressView(value: progress)
                    .tint(debt.direction == .iOwe ? PB.neg : PB.pos)
                    .padding(.top, 4)
            }

            // Paid and principal always shown together: "1 200 €" alone says
            // nothing about whether that is most of the debt or a tenth of it.
            Text("\(Fmt.eur(debt.paidAmount.doubleValue)) pagos de \(Fmt.eur(debt.principal.doubleValue))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Label(debt.direction.title, systemImage: debt.direction.icon)
                Text("·")
                Text("desde \(DebtFormat.shortDate(debt.openedAt))")
                if let due = debt.dueDate {
                    Text("·")
                    Text("até \(DebtFormat.shortDate(due))")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 2)

            if !debt.note.isEmpty {
                Text(debt.note)
                    .font(.system(size: 13))
                    .foregroundStyle(PB.text)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PB.surface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func payButton(_ debt: Debt) -> some View {
        if !debt.isSettled {
            Button { showPayment = true } label: {
                Text("\(debt.direction.paymentVerb) uma parte")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(PB.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
    }

    // MARK: - Pagamentos

    @ViewBuilder
    private func paymentsSection(_ debt: Debt) -> some View {
        Text("PAGAMENTOS")
            .font(.system(size: 12.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
            .padding(.top, debt.isSettled ? 18 : 0)
            .padding(.bottom, 7)

        if debt.payments.isEmpty {
            Text("Ainda não pagaste nada desta dívida.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        } else {
            let rows = debt.sortedPayments
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, payment in
                    paymentRow(payment)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = payment
                            } label: {
                                Label("Apagar pagamento", systemImage: "trash")
                            }
                        }
                    if i < rows.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(PB.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    private func paymentRow(_ payment: DebtPayment) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DebtFormat.shortDate(payment.date))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PB.text)
                Text(paymentSubtitle(payment))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Fmt.eur(payment.amount.doubleValue))
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PB.text)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Whether the money moved through an account, and which. A payment with no
    /// account is not an error and must not look like missing information —
    /// it says "fora das contas", because that is what it is.
    private func paymentSubtitle(_ payment: DebtPayment) -> String {
        var parts: [String] = []
        if let accountID = payment.accountID {
            parts.append(store.accounts.first { $0.id == accountID.uuidString }?.name ?? "Conta apagada")
        } else {
            parts.append("Fora das contas")
        }
        if !payment.note.isEmpty { parts.append(payment.note) }
        return parts.joined(separator: " · ")
    }

    private func deletePayment(_ payment: DebtPayment) {
        pendingDelete = nil
        do {
            try DebtService.deletePayment(payment, in: modelContext)
            store.reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
