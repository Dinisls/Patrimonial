import SwiftUI
import SwiftData

/// The Resumo card, between the cashflow and the recent transactions.
///
/// Two figures, never one: netting "devo" against "devem-me" into a single
/// number would say that 500 € owed to a friend and 500 € owed by one cancel
/// out, and they do not — one is a bill and the other is a hope.
struct DebtsSummaryCard: View {
    let hidden: Bool
    @Query private var debts: [Debt]

    private var iOwe: Decimal { DebtService.totalOutstanding(debts, direction: .iOwe) }
    private var owedToMe: Decimal { DebtService.totalOutstanding(debts, direction: .owedToMe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("DÍVIDAS")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .padding(.top, 24)

            NavigationLink(value: PBRoute.debts) {
                VStack(alignment: .leading, spacing: 0) {
                    if debts.isEmpty {
                        emptyBody
                    } else {
                        filledBody
                    }
                }
                .padding(16)
                .background(PB.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    private var emptyBody: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sem dívidas registadas")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PB.text)
                Text("Regista o que deves e o que te devem")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PB.text3)
        }
    }

    private var filledBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                amountColumn(direction: .iOwe, value: iOwe)
                Spacer(minLength: 12)
                amountColumn(direction: .owedToMe, value: owedToMe)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PB.text3)
            }
            // The card sits under the net-worth total, so it has to say, where
            // it is read, that it is not part of it.
            Text("Fora do património total")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func amountColumn(direction: DebtDirection, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(direction.title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(hidden ? "••••" : Fmt.eur(value.doubleValue))
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(direction == .iOwe ? PB.neg : PB.pos)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// The Contas entry: one line with what is still owed, and the way in.
///
/// Deliberately below the accounts card and outside it — the accounts total
/// above must keep meaning exactly what it meant before debts existed.
struct DebtsAccountsEntry: View {
    @Query private var debts: [Debt]

    private var iOwe: Decimal { DebtService.totalOutstanding(debts, direction: .iOwe) }
    private var owedToMe: Decimal { DebtService.totalOutstanding(debts, direction: .owedToMe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("DÍVIDAS")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .padding(.top, 22)

            NavigationLink(value: PBRoute.debts) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(PB.accent.opacity(0.16))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person.2")
                                .font(.system(size: 15))
                                .foregroundStyle(PB.accent)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dívidas")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(PB.text)
                        Text("Fora do total das contas")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Each figure carries its own label. Two euro amounts
                    // stacked with nothing between them is a riddle: the row
                    // would not say which one is owed by whom.
                    VStack(alignment: .trailing, spacing: 2) {
                        amountLine("Devo", iOwe, color: iOwe > 0 ? PB.neg : PB.text2)
                        amountLine("Devem-me", owedToMe, color: owedToMe > 0 ? PB.pos : PB.text2)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PB.text3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(PB.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    private func amountLine(_ label: String, _ value: Decimal, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Fmt.eur(value.doubleValue))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .fixedSize()
    }
}
