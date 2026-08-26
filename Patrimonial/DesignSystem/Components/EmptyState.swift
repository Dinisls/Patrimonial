import SwiftUI

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview {
    EmptyState(
        icon: "banknote",
        title: "Sem Contas",
        message: "Adiciona a tua primeira conta para começar.",
        actionTitle: "Adicionar Conta"
    ) {}
}
