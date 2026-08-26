import SwiftUI

struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.brandGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.primaryAction.opacity(0.35), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Subtle scale-down feedback on press, reused by primary CTAs.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        Color.screenBackground.ignoresSafeArea()
        VStack(spacing: 16) {
            PrimaryButton(title: "Adicionar Conta") {}
            PrimaryButton(title: "Guardar") {}
        }
        .padding()
    }
}
