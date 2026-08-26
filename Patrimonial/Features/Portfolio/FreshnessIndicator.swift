import SwiftUI

/// The dot beside a price, saying where that price came from.
///
/// Shape as well as colour, deliberately. `.closed` and `.dailyClose` were both
/// plain grey circles and they are not the same statement: one says *the market
/// is shut*, the other says *this is the best quote obtainable, and the market
/// may well be open right now*. On the reported screen a XETRA position showed
/// grey at 16:00 Berlin with XETRA trading, and grey was read — reasonably — as
/// "fechado".
///
/// Colour alone would also have failed about 8 % of men outright.
struct FreshnessIndicator: View {
    let freshness: QuoteFreshness

    /// How each state is drawn. One table, so the dot, the legend and the
    /// accessibility label cannot drift apart — a legend that describes a
    /// different indicator than the one on screen is worse than none.
    enum Style {
        /// Filled circle: a price arriving now.
        case liveDot(Color)
        /// Hollow circle: nothing is coming, the venue is shut.
        case hollowDot(Color)
        /// Filled square: a settled close. Square because "this session is
        /// finished" is a different kind of fact, not a weaker version of live.
        case settledSquare(Color)
    }

    static func style(for freshness: QuoteFreshness) -> Style {
        switch freshness {
        case .live: .liveDot(.green)
        case .delayed: .liveDot(.orange)
        case .stale: .liveDot(.red)
        case .closed: .hollowDot(.gray)
        case .dailyClose: .settledSquare(.gray)
        case .unknown: .hollowDot(Color.gray.opacity(0.5))
        }
    }

    static func label(for freshness: QuoteFreshness) -> String {
        switch freshness {
        case .live: "Em tempo real"
        case .delayed(let s): "Cotação viva, com atraso de \(s) segundos"
        case .closed: "Mercado fechado"
        case .dailyClose(let date): "Fecho de \(Self.closeDateLabel(date)) — a cotação mais recente disponível"
        case .stale: "Desatualizado: o mercado está aberto e a cotação não é recente"
        case .unknown: "Origem desconhecida"
        }
    }

    /// Shown next to the price, so it stays short: "6 ago". The year appears
    /// only when the close is not from this year, where its absence would be
    /// misleading.
    static func closeDateLabel(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        // An explicit format, not `setLocalizedDateFormatFromTemplate`: pt_PT
        // resolves that template to the all-numeric `7/08/2025`, which is both
        // longer than the abbreviation intended here and easy to misread as a
        // quantity in a line that already carries one.
        f.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }

    var body: some View {
        Self.shape(for: Self.style(for: freshness))
            .accessibilityLabel(Self.label(for: freshness))
    }

    @ViewBuilder
    static func shape(for style: Style, size: CGFloat = 8) -> some View {
        switch style {
        case .liveDot(let color):
            Circle().fill(color).frame(width: size, height: size)
        case .hollowDot(let color):
            Circle()
                .strokeBorder(color, lineWidth: max(1, size / 6))
                .frame(width: size, height: size)
        case .settledSquare(let color):
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(color)
                .frame(width: size * 0.85, height: size * 0.85)
        }
    }
}

// MARK: - Legend

/// What the dots mean, in words, reachable from every screen that draws one.
///
/// The indicator is eight points of colour with no text anywhere near it. Two
/// of its six states were being guessed at, and a guess about freshness is a
/// guess about whether a number can be trusted.
struct FreshnessLegend: View {
    @Environment(\.dismiss) private var dismiss

    /// One example of each state, in the order a price degrades.
    private static let entries: [(QuoteFreshness, String)] = [
        (.live, "Cotação em tempo real, no mercado aberto."),
        (.delayed(15), "Cotação viva com um pequeno atraso. É o normal nas ações americanas em plano gratuito."),
        (.closed, "O mercado está fechado. A cotação é a do último momento em que negociou."),
        (.dailyClose(Date()), "É um fecho de sessão, e é a cotação mais recente que existe para esta praça — mesmo com o mercado aberto agora. As bolsas europeias não têm fonte intradiária gratuita, por isso mostram sempre isto. A data do fecho aparece ao lado do preço."),
        (.stale, "O mercado está aberto e a cotação não é recente. Vale a pena puxar para atualizar."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(Self.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 12) {
                            FreshnessIndicator.shape(
                                for: FreshnessIndicator.style(for: entry.0), size: 11
                            )
                            .padding(.top, 4)
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.title(entry.0))
                                    .font(.system(size: 15, weight: .semibold))
                                Text(entry.1)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("Uma posição sem cotação nenhuma não mostra ponto: aparece um travessão no valor e fica fora dos totais, com o cabeçalho a dizer quantas ficaram de fora.")
                }
            }
            .navigationTitle("O que significam os pontos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }

    private static func title(_ freshness: QuoteFreshness) -> String {
        switch freshness {
        case .live: "Em tempo real"
        case .delayed: "Com atraso"
        case .closed: "Mercado fechado"
        case .dailyClose: "Fecho de sessão"
        case .stale: "Desatualizada"
        case .unknown: "Desconhecida"
        }
    }
}

/// The affordance that opens the legend. Placed on every screen that draws a
/// dot — the legend is useless on the one screen the user is not looking at.
struct FreshnessLegendButton: View {
    @State private var showLegend = false

    var body: some View {
        Button {
            showLegend = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("O que significam os pontos de frescura")
        .sheet(isPresented: $showLegend) {
            FreshnessLegend()
        }
    }
}
