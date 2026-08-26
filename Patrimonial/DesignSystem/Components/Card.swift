import SwiftUI

struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.separatorLine.opacity(0.6), lineWidth: 0.5)
            )
    }
}

#Preview {
    ZStack {
        Color.screenBackground.ignoresSafeArea()
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Património Total")
                    .font(.cardBody)
                    .foregroundStyle(.secondary)
                Text("€12.345,67")
                    .font(.heroValue)
            }
        }
        .padding()
    }
}
