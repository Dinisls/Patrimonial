// ───────────────────────────────────────────────────────────
// PBMonthlyRecap.swift — Resumo do mês em formato story
// ───────────────────────────────────────────────────────────
import SwiftUI

struct MonthlyRecapStoryView: View {
    let recap: MonthlyRecap
    var onClose: () -> Void

    private static let slideDuration: Double = 7

    @State private var index = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var dragOffset: CGFloat = 0
    @State private var touchStart: Date?
    @State private var width: CGFloat = 400

    private var slideCount: Int { 5 }

    var body: some View {
        ZStack(alignment: .top) {
            background
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: index)

            slide
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(.horizontal, 24)
                .padding(.top, 70)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // One gesture for everything, like Instagram: a short touch is a tap
            // (left third back, rest forward), holding pauses, dragging down closes.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if touchStart == nil { touchStart = Date() }
                            paused = true
                            if v.translation.height > 0 { dragOffset = v.translation.height }
                        }
                        .onEnded { v in
                            let held = Date().timeIntervalSince(touchStart ?? Date())
                            touchStart = nil
                            paused = false
                            if v.translation.height > 140 { onClose(); return }
                            withAnimation(.spring) { dragOffset = 0 }
                            let moved = abs(v.translation.width) + abs(v.translation.height)
                            guard held < 0.25, moved < 12 else { return }
                            go(v.location.x < width / 3 ? -1 : 1)
                        }
                )

            header
        }
        .foregroundStyle(.white)
        .offset(y: max(0, dragOffset))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .statusBarHidden()
        .task(id: index) { await runTimer() }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0..<slideCount, id: \.self) { i in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * fill(for: i))
                        }
                    }
                    .frame(height: 3)
                }
            }
            HStack {
                Text("Resumo de \(recap.monthName)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Fechar")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func fill(for i: Int) -> CGFloat {
        i < index ? 1 : (i == index ? progress : 0)
    }

    private func go(_ step: Int) {
        let next = index + step
        if next >= slideCount { onClose(); return }
        withAnimation(.easeInOut(duration: 0.3)) {
            index = max(0, next)
            progress = 0
        }
    }

    private func runTimer() async {
        progress = 0
        let tick = 0.05
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(tick))
            if paused { continue }
            progress += tick / Self.slideDuration
            if progress >= 1 {
                // Last slide stays open until the user closes it.
                if index == slideCount - 1 { progress = 1; return }
                go(1)
                return
            }
        }
    }

    // MARK: Backgrounds

    private var background: LinearGradient {
        let colors: [Color]
        switch index {
        case 0: colors = [Color(hex: 0x1B1464), Color(hex: 0x6A1B9A), Color(hex: 0xEC3013)]
        case 1: colors = tierColors
        case 2: colors = [Color(hex: 0x0F2027), Color(hex: 0x203A43), Color(hex: 0x2C7873)]
        case 3: colors = [Color(hex: 0x141E30), Color(hex: 0x243B55), Color(hex: 0x4F86E0)]
        default: colors = [Color(hex: 0x232526), Color(hex: 0x414345), Color(hex: 0xEC3013)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var tierColors: [Color] {
        switch recap.tier {
        case .negative:  [Color(hex: 0x3A0D0D), Color(hex: 0x8E1B1B), Color(hex: 0xEC3013)]
        case .slow:      [Color(hex: 0x3E2C0A), Color(hex: 0x8A6414), Color(hex: 0xD8B24E)]
        case .good:      [Color(hex: 0x0B3D2E), Color(hex: 0x167A55), Color(hex: 0x34B07A)]
        case .great:     [Color(hex: 0x06373F), Color(hex: 0x0E7C86), Color(hex: 0x3FB8C9)]
        case .amazing:   [Color(hex: 0x2A0B4A), Color(hex: 0x6A1B9A), Color(hex: 0xD45C92)]
        case .legendary: [Color(hex: 0x3B2A00), Color(hex: 0xB8860B), Color(hex: 0xFFD54F)]
        }
    }

    // MARK: Slides

    @ViewBuilder
    private var slide: some View {
        switch index {
        case 0: IntroSlide(recap: recap)
        case 1: CashflowSlide(recap: recap)
        case 2: AccountsSlide(recap: recap)
        case 3: PortfolioSlide(recap: recap)
        default: OutroSlide(recap: recap, onClose: onClose)
        }
    }
}

// MARK: - Slide pieces

private struct Appear<Content: View>: View {
    var delay: Double = 0
    @ViewBuilder var content: Content
    @State private var shown = false
    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(delay)) { shown = true }
            }
    }
}

/// Counts up from 0 to `value` when it appears.
private struct CountingEuro: View {
    let value: Double
    var size: CGFloat = 56
    var signed = false
    var delay: Double = 0.2
    @State private var shown: Double = 0
    var body: some View {
        Text(signed ? Fmt.signedEur(shown) : Fmt.eur(shown))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .contentTransition(.numericText(value: shown))
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).delay(delay)) { shown = value }
            }
    }
}

private struct IntroSlide: View {
    let recap: MonthlyRecap
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Appear { Text("📅").font(.system(size: 72)) }
            Appear(delay: 0.15) {
                Text("O teu \(recap.monthName)\nem números")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
            }
            Appear(delay: 0.35) {
                Text("Mais um mês fechado. Vamos ver como correu.")
                    .font(.system(size: 19, weight: .medium))
                    .opacity(0.85)
            }
            Spacer()
            Appear(delay: 0.6) {
                Label("Toca para avançar", systemImage: "hand.tap")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CashflowSlide: View {
    let recap: MonthlyRecap
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Appear { Text("Fluxo de caixa").font(.system(size: 20, weight: .semibold)).opacity(0.85) }
            CountingEuro(value: recap.net, size: 60, signed: true)
            Appear(delay: 0.9) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(recap.tier.emoji) \(recap.tier.title)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text(recap.tier.message)
                        .font(.system(size: 19, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Appear(delay: 1.3) {
                HStack(spacing: 12) {
                    pill("Receitas", Fmt.eur(recap.income), "arrow.down.left")
                    pill("Despesas", Fmt.eur(recap.expenses), "arrow.up.right")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).font(.system(size: 13, weight: .semibold)).opacity(0.8)
            Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AccountsSlide: View {
    let recap: MonthlyRecap
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Appear { Text("As tuas contas").font(.system(size: 34, weight: .heavy, design: .rounded)) }
            Appear(delay: 0.1) {
                HStack {
                    Text("1 \(recap.monthName)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("fim do mês").frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 13, weight: .semibold)).opacity(0.7)
            }

            if recap.accounts.isEmpty {
                Text("Sem contas neste mês.").font(.system(size: 18)).opacity(0.8)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(recap.accounts.enumerated()), id: \.element.id) { i, acc in
                            Appear(delay: 0.2 + Double(i) * 0.12) { row(acc) }
                        }
                    }
                }
                Appear(delay: 0.4 + Double(recap.accounts.count) * 0.12) {
                    totalRow
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ acc: MonthlyRecap.AccountLine) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: UInt(acc.colorHex, radix: 16) ?? 0xFFFFFF)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(acc.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    if acc.isNew {
                        Text("NOVA").font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.white.opacity(0.25), in: Capsule())
                    }
                }
                Text(Fmt.eur(acc.start)).font(.system(size: 14)).monospacedDigit().opacity(0.75)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.eur(acc.end)).font(.system(size: 17, weight: .bold)).monospacedDigit()
                Text(Fmt.signedEur(acc.delta)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(deltaColor(acc.delta))
            }
        }
        .padding(14)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
    }

    private var totalRow: some View {
        let delta = recap.accountsEnd - recap.accountsStart
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total").font(.system(size: 13, weight: .semibold)).opacity(0.75)
                Text("\(Fmt.eur(recap.accountsStart)) → \(Fmt.eur(recap.accountsEnd))")
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            Spacer()
            Text(Fmt.signedEur(delta)).font(.system(size: 18, weight: .heavy)).monospacedDigit()
                .foregroundStyle(deltaColor(delta))
        }
        .padding(14)
        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
    }
}

private func deltaColor(_ v: Double) -> Color {
    v > 0 ? Color(hex: 0x7CF5A6) : (v < 0 ? Color(hex: 0xFF9A8A) : .white)
}

private struct PortfolioSlide: View {
    let recap: MonthlyRecap

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "d MMM"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Appear { Text("O teu portefólio").font(.system(size: 34, weight: .heavy, design: .rounded)) }
            if let p = recap.portfolio {
                Appear(delay: 0.2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A \(Self.dayFmt.string(from: p.startDate)) valia").font(.system(size: 16, weight: .medium)).opacity(0.75)
                        Text(Fmt.eur(p.start)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                Appear(delay: 0.5) {
                    Image(systemName: "arrow.down").font(.system(size: 22, weight: .bold)).opacity(0.6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Appear(delay: 0.6) {
                        Text("A \(Self.dayFmt.string(from: p.endDate)) valia").font(.system(size: 16, weight: .medium)).opacity(0.75)
                    }
                    CountingEuro(value: p.end, size: 50, delay: 0.7)
                }
                Appear(delay: 1.5) {
                    HStack(spacing: 10) {
                        Text(Fmt.signedEur(p.delta))
                        if let f = p.deltaFraction { Text("(\(Fmt.pct(f * 100)))") }
                    }
                    .font(.system(size: 22, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor(p.delta))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white.opacity(0.15), in: Capsule())
                }
                if p.invested != 0 {
                    Appear(delay: 1.8) {
                        HStack(spacing: 8) {
                            Image(systemName: p.invested > 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 18))
                            Text(p.invested > 0 ? "Investiste \(Fmt.eur(p.invested))"
                                                : "Resgataste \(Fmt.eur(abs(p.invested)))")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Appear(delay: p.invested != 0 ? 2.1 : 1.8) {
                    Text(p.delta >= 0 ? "Os teus investimentos trabalharam para ti. 📈"
                                      : "Mês vermelho nos mercados. Paciência é o nome do jogo. 📉")
                        .font(.system(size: 18, weight: .medium))
                }
            } else {
                Appear(delay: 0.2) {
                    Text("Não há registos do valor do portefólio neste mês, por isso não há comparação para mostrar.")
                        .font(.system(size: 19, weight: .medium)).opacity(0.85)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OutroSlide: View {
    let recap: MonthlyRecap
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Appear { Text(recap.tier.emoji).font(.system(size: 80)) }
            Appear(delay: 0.15) {
                Text("Até ao fim\ndo próximo mês")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
            }
            Appear(delay: 0.3) {
                Text(recap.net >= 0 ? "Bora repetir — ou fazer ainda melhor."
                                    : "Um mês mau não define o ano. Bora recuperar.")
                    .font(.system(size: 19, weight: .medium)).opacity(0.85)
            }
            Spacer()
            Appear(delay: 0.5) {
                Button(action: onClose) {
                    Text("Fechar")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
