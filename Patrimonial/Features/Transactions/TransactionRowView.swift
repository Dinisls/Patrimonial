import SwiftUI

struct TransactionRowView: View {
    let transaction: FinancialTransaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(iconColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cardTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(amountText)
                .font(.monoValue)
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch transaction.type {
        case .expense: transaction.category?.icon ?? "minus.circle"
        case .income: transaction.category?.icon ?? "plus.circle"
        case .transfer: "arrow.left.arrow.right"
        case .assetPurchase: "cart"
        case .assetSale: "cart.badge.minus"
        case .dividend: "banknote"
        }
    }

    private var iconColor: Color {
        switch transaction.type {
        case .expense: .lossRed
        case .income: .gainGreen
        case .transfer: .primaryAction
        default: .secondary
        }
    }

    private var title: String {
        if !transaction.note.isEmpty { return transaction.note }
        switch transaction.type {
        case .transfer: return String(localized: "transaction_type_transfer")
        default: return transaction.category?.displayName ?? transaction.type.displayName
        }
    }

    private var subtitle: String {
        let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
        switch transaction.type {
        case .transfer:
            let from = transaction.sourceAccount?.name ?? ""
            let to = transaction.destinationAccount?.name ?? ""
            return "\(from) → \(to) · \(dateStr)"
        default:
            return "\(transaction.sourceAccount?.name ?? "") · \(dateStr)"
        }
    }

    private var amountText: String {
        let currency = transaction.sourceAccount?.currency ?? "EUR"
        let formatted = CurrencyFormatter.format(transaction.amount, currency: currency)
        switch transaction.type {
        case .expense: return "-\(formatted)"
        case .income: return "+\(formatted)"
        default: return formatted
        }
    }

    private var amountColor: Color {
        switch transaction.type {
        case .expense: .lossRed
        case .income: .gainGreen
        default: .primary
        }
    }
}
