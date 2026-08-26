import SwiftUI

struct TransactionsView: View {
    var body: some View {
        NavigationStack {
            EmptyState(
                icon: "arrow.left.arrow.right",
                title: String(localized: "transactions_empty_title"),
                message: String(localized: "transactions_empty_message")
            )
            .navigationTitle(String(localized: "transactions_title"))
        }
    }
}

#Preview {
    TransactionsView()
}
