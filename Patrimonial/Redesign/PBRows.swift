// ───────────────────────────────────────────────────────────
// PBRows.swift — Rotas de navegação + linhas reutilizáveis
// ───────────────────────────────────────────────────────────
import SwiftUI

// MARK: - Rotas
enum PBRoute: Hashable {
    case cashflow
    case account(String)
    case newAccount
    case debts
    /// By id, never by the model object: a `NavigationPath` outlives the row it
    /// points at, and a deleted debt carried in the path would keep a dead
    /// object on screen.
    case debt(UUID)
}

// MARK: - Linha de transação (estilo iOS grouped list)
struct TxListRow: View {
    let tx: PBTx
    private var pos: Bool { tx.amount > 0 }
    private var isTransfer: Bool { tx.cat == .transfer }

    var body: some View {
        HStack(spacing: 12) {
            Text(String(tx.title.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconFg)
                .frame(width: 34, height: 34)
                .background(iconBg, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(tx.title)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(PB.text)
                    .lineLimit(1)
                Text(metaText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(amountText)
                .font(.system(size: 15.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var iconBg: Color {
        pos ? PB.green.opacity(0.16) : Color(UIColor.systemFill)
    }
    private var iconFg: Color {
        pos ? PB.green : .secondary
    }
    private var amountColor: Color {
        isTransfer ? .secondary : (pos ? PB.green : PB.text)
    }
    private var amountText: String {
        (pos ? "+" : "") + Fmt.eur(tx.amount)
    }
    private var metaText: String {
        let catLabel = tx.customCatName ?? txCatLabel(tx.cat)
        // `sub` carries the quantity for investments and the counterparty for
        // transfers; it was being set and never shown.
        var text = tx.sub.map { "\($0) · " } ?? ""
        text += "\(catLabel) · \(tx.account) · \(tx.date)"
        switch tx.recurrence {
        case .weekly: text += " · ↻ Semanal"
        case .bimonthly: text += " · ↻ 2x/mês"
        case .monthly: text += " · ↻ Mensal"
        case .none: break
        }
        return text
    }
}

// MARK: - Cartão de conta (grid 2 col) - mantido para compatibilidade
struct AccountCardView: View {
    let acc: PBAccount
    var body: some View {
        PBCard(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    TileView(color: acc.color, symbol: Icon.accountSymbol(acc.kind), size: 44)
                    Spacer()
                    DeltaChip(pct: acc.change * 100, up: acc.change >= 0, soft: false)
                }
                Text(acc.name.uppercased())
                    .font(PB.sans(11.5, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(PB.text3)
                    .lineLimit(1)
                    .padding(.top, 18)
                Text(Fmt.eur(acc.balance))
                    .font(PB.mono(21, .bold))
                    .foregroundStyle(PB.text)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Old TxRowView (mantido para compatibilidade)
struct TxRowView: View {
    let tx: PBTx
    private var pos: Bool { tx.amount > 0 }
    var body: some View {
        HStack(spacing: 13) {
            CatAvatar(cat: tx.cat, amount: tx.amount,
                      customSymbol: tx.customCatSymbol,
                      customColor: tx.customCatColorHex.map { Color(hex: $0) })
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.title).font(PB.sans(16, .semibold)).foregroundStyle(PB.text).lineLimit(1)
                Text("\(tx.account) · \(tx.date)").font(PB.sans(12.5)).foregroundStyle(PB.text3)
            }
            Spacer(minLength: 6)
            Text(Fmt.signedEur(tx.amount)).font(PB.mono(15.5, .semibold)).foregroundStyle(pos ? PB.pos : PB.neg)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
