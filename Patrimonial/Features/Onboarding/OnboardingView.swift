import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0

    private let pages: [(icon: String, title: String, subtitle: String)] = [
        ("chart.pie.fill",
         "O teu património, num lugar só",
         "Contas bancárias, investimentos e dívidas — tudo organizado e sempre atualizado."),
        ("chart.line.uptrend.xyaxis",
         "Acompanha os teus investimentos",
         "Ações, ETFs, cripto e ativos manuais com cotações em tempo real e evolução do portfolio."),
        ("calendar.badge.checkmark",
         "Controla receitas e despesas",
         "Transações recorrentes, categorias personalizadas e um resumo mensal automático do teu mês.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: p.icon)
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(PB.accent)
                            .padding(.bottom, 8)
                        Text(p.title)
                            .font(.system(size: 24, weight: .bold))
                            .multilineTextAlignment(.center)
                        Text(p.subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut(duration: 0.3), value: page)

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    hasSeenOnboarding = true
                }
            } label: {
                Text(page < pages.count - 1 ? "Seguinte" : "Começar")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(PB.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if page < pages.count - 1 {
                Button {
                    hasSeenOnboarding = true
                } label: {
                    Text("Saltar")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            } else {
                Color.clear.frame(height: 32)
            }
        }
        .background(PB.bg.ignoresSafeArea())
    }
}
