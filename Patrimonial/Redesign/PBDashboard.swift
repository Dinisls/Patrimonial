// ───────────────────────────────────────────────────────────
// PBDashboard.swift — Ecrã "Resumo" + Fluxo de Caixa
// ───────────────────────────────────────────────────────────
import SwiftUI

// MARK: - Dashboard
struct DashboardScreen: View {
    @Binding var selectedTab: Int
    var onShowRecap: (() -> Void)?
    @Environment(AppStore.self) private var store
    @Environment(PriceStore.self) private var priceStore
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var hidden = false
    @State private var editTx: PBTx? = nil
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                accountCardsSection
                cashflowCard
                recentTransactions
                Spacer(minLength: 100)
            }
        }
        .background(PB.bg)
        .navigationTitle("Resumo")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    if onShowRecap != nil {
                        Button { onShowRecap?() } label: {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    Button {
                        appTheme = appTheme == "dark" ? "light" : "dark"
                    } label: {
                        Image(systemName: appTheme == "dark" ? "sun.max" : "moon")
                            .font(.system(size: 16, weight: .medium))
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            // A sheet gets its own environment root, so both stores are handed
            // over explicitly. Settings needs the price store to clear the
            // in-memory quotes on a data reset.
            NavigationStack { SettingsScreen() }
                .environment(store)
                .environment(priceStore)
        }
        .sheet(item: $editTx) { tx in
            // `.id` is load-bearing. TransactionEditSheet seeds its
            // @State in init, and SwiftUI reuses the sheet's view
            // identity between presentations — so the second
            // transaction opened kept the first one's values on screen,
            // and Guardar would have written them back. Keying on the
            // transaction's own UUID forces fresh state every time.
            TransactionEditSheet(tx: tx)
                .environment(store)
                .id(tx.txID)
        }
        .navigationDestination(for: PBRoute.self) { route in
            switch route {
            case .account(let id): AccountScreen(id: id)
            case .cashflow: CashflowScreen()
            case .newAccount: AccountFormSheet()
            }
        }
    }

    // MARK: - Hero (patrimonio total)
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Património total")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hidden ? "••••" : Fmt.eur(store.totalBalance))
                    .font(.system(size: 44, weight: .bold, design: .default))
                    .monospacedDigit()
                Button(hidden ? "Mostrar" : "Ocultar") { hidden.toggle() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PB.accent)
            }
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(PB.green)
                    Text(monthDeltaText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PB.green)
                }
                Text("este mês · \(currentMonthYear)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var monthDeltaText: String {
        let cf = store.cashflow
        let total = store.totalBalance
        guard total != 0 else { return "0%" }
        let pct = cf.net / (total - cf.net) * 100
        return String(format: "%+.1f%%", pct)
    }

    private var currentMonthYear: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Date()).capitalized
    }

    // MARK: - Account cards (horizontal scroll)
    private var accountCardsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CONTAS")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.accounts) { a in
                        NavigationLink(value: PBRoute.account(a.id)) {
                            accountCard(a)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink(value: PBRoute.newAccount) {
                        newAccountCard
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }

    private func accountCard(_ a: PBAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(a.color.opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "creditcard")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(a.color)
                )
            Text(a.name)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(hidden ? "••••" : Fmt.eur(a.balance))
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PB.text)
        }
        .frame(width: 158, alignment: .leading)
        .padding(14)
        .frame(minHeight: 112)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var newAccountCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
            Text("Nova conta")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(PB.accent)
        .frame(width: 112, alignment: .leading)
        .frame(minHeight: 112)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        )
    }

    // MARK: - Cashflow card
    private var cashflowCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("FLUXO DE CAIXA")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .padding(.top, 24)

            NavigationLink(value: PBRoute.cashflow) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(currentMonth) · receitas − despesas")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(hidden ? "••••" : Fmt.eur(store.cashflow.net))
                                .font(.system(size: 30, weight: .bold))
                                .monospacedDigit()
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(UIColor.tertiaryLabel))
                    }

                    miniBarChart
                        .padding(.top, 16)
                        .padding(.bottom, 10)

                    HStack(spacing: 18) {
                        legendDot(color: PB.green, label: "Receitas \(hidden ? "••••" : Fmt.eur(store.cashflow.receita))")
                        legendDot(color: PB.accent, label: "Despesas \(hidden ? "••••" : Fmt.eur(store.cashflow.despesas))")
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    private var currentMonth: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "MMMM"
        return f.string(from: Date()).capitalized
    }

    private var miniBarChart: some View {
        let maxH: CGFloat = 80
        let cf = store.cashflow
        let maxVal = max(cf.receita, cf.despesas, 1)
        let inH = max(CGFloat(cf.receita / maxVal) * maxH, 4)
        let outH = max(CGFloat(cf.despesas / maxVal) * maxH, 4)
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(PB.green)
                        .frame(width: 11, height: inH)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(PB.accent.opacity(0.85))
                        .frame(width: 11, height: outH)
                }
            }
        }
        .frame(height: maxH + 8, alignment: .bottom)
        .clipped()
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - Recent transactions
    private var recentTransactions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("TRANSAÇÕES RECENTES")
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ver tudo") { selectedTab = 3 }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PB.accent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)

            VStack(spacing: 0) {
                ForEach(Array(store.transactions.prefix(5).enumerated()), id: \.element.id) { i, tx in
                    Button { editTx = tx } label: {
                        TxListRow(tx: tx)
                    }
                    .buttonStyle(.plain)
                    if i < min(4, store.transactions.count - 1) {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Cashflow detail screen
struct CashflowScreen: View {
    @Environment(AppStore.self) private var store
    @State private var selectedIndex = -1

    private var months: [(month: Int, year: Int, label: String)] {
        store.availableMonths
    }
    private var sel: (month: Int, year: Int) {
        let idx = selectedIndex >= 0 && selectedIndex < months.count ? selectedIndex : months.count - 1
        guard idx >= 0, idx < months.count else {
            let cal = Calendar.current; let now = Date()
            return (cal.component(.month, from: now), cal.component(.year, from: now))
        }
        return (months[idx].month, months[idx].year)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if months.count > 1 { monthSelector }
                summaryCard
                categoriesSection(isExpense: false)
                categoriesSection(isExpense: true)
                topMovements
                Spacer(minLength: 100)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(PB.bg)
        .navigationTitle("Fluxo de caixa")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if selectedIndex < 0 { selectedIndex = months.count - 1 }
        }
    }

    private var monthSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = i }
                    } label: {
                        Text(m.label)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(selectedIndex == i ? Color(UIColor.secondarySystemGroupedBackground) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .shadow(color: selectedIndex == i ? .black.opacity(0.14) : .clear, radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
        }
        .background(Color(UIColor.systemFill), in: RoundedRectangle(cornerRadius: 9))
    }

    private var summaryCard: some View {
        let cf = store.cashflowFor(month: sel.month, year: sel.year)
        let days = store.dailyCashflow(month: sel.month, year: sel.year)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Saldo do mês")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(Fmt.eur(cf.net))
                .font(.system(size: 38, weight: .bold))
                .monospacedDigit()
                .padding(.bottom, 14)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receitas").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(Fmt.eur(cf.receita))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(PB.green)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color(UIColor.systemFill), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Despesas").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(Fmt.eur(cf.despesas))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(PB.accent)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color(UIColor.systemFill), in: RoundedRectangle(cornerRadius: 10))
            }

            if !days.isEmpty {
                FlowBarsView(days: days, height: 140, animKey: "\(sel.month)-\(sel.year)")
                    .padding(.top, 20)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func categoriesSection(isExpense: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(isExpense ? "DESPESAS POR CATEGORIA" : "RECEITAS POR ORIGEM")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 8)

            let cats = store.categoryTotalsFor(isExpense: isExpense, month: sel.month, year: sel.year)
            if cats.isEmpty {
                Text(isExpense ? "Sem despesas neste mês" : "Sem receitas neste mês")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(cats.enumerated()), id: \.element.id) { i, cat in
                        VStack(spacing: 7) {
                            HStack {
                                Text(cat.name).font(.system(size: 14.5, weight: .medium))
                                Spacer()
                                Text(Fmt.eur(cat.total))
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(UIColor.systemFill))
                                        .frame(height: 6)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isExpense ? PB.accent : PB.green)
                                        .frame(width: geo.size.width * cat.fraction, height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(.vertical, 10)
                        if i < cats.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var topMovements: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("MAIORES MOVIMENTOS")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 8)

            let top = store.topTransactions(month: sel.month, year: sel.year)
            if top.isEmpty {
                Text("Sem movimentos neste mês")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, tx in
                        TxListRow(tx: tx)
                        if i < top.count - 1 { Divider().padding(.leading, 62) }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
