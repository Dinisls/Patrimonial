import SwiftUI

struct AccountRowView: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.icon)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: account.colorHex), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.cardTitle)
                Text(account.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(CurrencyFormatter.format(account.balance, currency: account.currency))
                .font(.monoValue)
                .foregroundStyle(account.balance >= 0 ? Color.primary : Color.lossRed)
        }
    }
}
