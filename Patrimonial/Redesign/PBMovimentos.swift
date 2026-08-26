// ───────────────────────────────────────────────────────────
// PBMovimentos.swift — Contas (lista), Detalhe da conta, Transações (lista)
// ───────────────────────────────────────────────────────────
import SwiftUI

// MARK: - Tab "Contas"
struct AccountsListScreen: View {
    @Environment(AppStore.self) private var store
    @State private var showNewAccount = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total das contas")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(Fmt.eur(store.totalBalance))
                        .font(.system(size: 32, weight: .bold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

                Text("À ORDEM E POUPANÇA")
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.bottom, 7)

                VStack(spacing: 0) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, a in
                        NavigationLink(value: PBRoute.account(a.id)) {
                            accountRow(a)
                        }
                        .buttonStyle(.plain)
                        if i < store.accounts.count - 1 {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)

                Button { showNewAccount = true } label: {
                    Text("Adicionar conta")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(PB.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)

                Spacer(minLength: 90)
            }
        }
        .background(PB.bg)
        .navigationTitle("Contas")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewAccount = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: PBRoute.self) { route in
            switch route {
            case .account(let id): AccountScreen(id: id)
            case .cashflow: CashflowScreen()
            case .newAccount: AccountFormSheet()
            }
        }
        .sheet(isPresented: $showNewAccount) {
            AccountFormSheet().environment(store)
        }
    }

    private func accountRow(_ a: PBAccount) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(a.color.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "creditcard")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(a.color)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(a.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PB.text)
                Text(a.sub)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.eur(a.balance))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(PB.text)
                Text(Fmt.pct(a.change * 100))
                    .font(.system(size: 12))
                    .foregroundStyle(a.change >= 0 ? PB.green : PB.accent)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Detalhe da conta
struct AccountScreen: View {
    @Environment(AppStore.self) private var store
    let id: String
    private let ranges = ["1M", "3M", "6M", "1A", "Tudo"]
    @State private var range = "6M"
    @State private var showAddExpense = false
    @State private var showAddIncome = false
    @State private var showTransfer = false
    @State private var showEditAccount = false
    @State private var editTx: PBTx? = nil
    @State private var scrubValue: Double? = nil

    private var acc: PBAccount? { store.accounts.first { $0.id == id } }
    private var accountTx: [PBTx] { guard let acc else { return [] }; return store.transactions(forAccount: acc.name) }
    private var rangeDays: Int { days(for: effectiveRange) }

    /// Nil when there is not enough real history — the chart is hidden instead
    /// of drawn from invented data.
    private var data: [Double]? {
        store.balanceSeries(accountID: id, days: rangeDays)
    }

    private var historyDays: Int? { store.historyDays(accountID: id) }

    /// A range the account cannot fill is not a choice, it is a lie: the series
    /// is clamped to the first movement, so "6M" and "1M" would draw exactly the
    /// same week-long line. Those buttons are shown greyed instead.
    private func isRangeAvailable(_ r: String) -> Bool {
        guard let historyDays else { return false }
        if r == "Tudo" { return true }
        return days(for: r) <= historyDays
    }

    private func days(for r: String) -> Int {
        switch r {
        case "1M": 30
        case "3M": 90
        case "6M": 180
        case "1A": 365
        case "Tudo": 1825
        default: 30
        }
    }

    /// Falls back to "Tudo" so a young account still lands on something real
    /// instead of on a disabled default.
    private var effectiveRange: String {
        isRangeAvailable(range) ? range : "Tudo"
    }

    var body: some View {
        Group {
            if let acc {
                ScrollView {
                    VStack(spacing: 0) {
                        heroHeader
                        // Range selector only makes sense next to a chart.
                        if data != nil {
                            rangeSelector
                        }
                        chartCard
                        actionButtons
                        transactionsSection
                        Spacer(minLength: 100)
                    }
                }
                .background(PB.bg)
                .navigationTitle(acc.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showEditAccount = true } label: {
                                Label("Editar Conta", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) { store.deleteAccount(id: id) } label: {
                                Label("Apagar Conta", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showAddExpense) {
                    TransactionFormSheet(prefilledAccount: acc.name, initialIsIncome: false).environment(store)
                }
                .sheet(isPresented: $showAddIncome) {
                    TransactionFormSheet(prefilledAccount: acc.name, initialIsIncome: true).environment(store)
                }
                .sheet(isPresented: $showTransfer) {
                    TransferFormSheet(prefilledFromAccount: acc.name).environment(store)
                }
                .sheet(isPresented: $showEditAccount) {
                    AccountEditSheet(account: acc).environment(store)
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
            } else {
                ContentUnavailableView("Conta não encontrada", systemImage: "xmark.circle")
            }
        }
    }

    private var displayValue: Double {
        scrubValue ?? (acc?.balance ?? 0)
    }

    private var displayPct: Double? {
        guard let data, let first = data.first, first != 0 else { return nil }
        let end = scrubValue ?? (data.last ?? first)
        return (end - first) / abs(first) * 100
    }

    private var isScrubbing: Bool { scrubValue != nil }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(acc?.sub ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(Fmt.eur(displayValue))
                .font(.system(size: 40, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.1), value: displayValue)
            // No percentage without a real series behind it.
            if let pct = displayPct {
                Text(Fmt.pct(pct) + " no período")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pct >= 0 ? PB.green : PB.accent)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.1), value: pct)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var rangeSelector: some View {
        HStack(spacing: 2) {
            ForEach(ranges, id: \.self) { r in
                let available = isRangeAvailable(r)
                let selected = effectiveRange == r
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { range = r }
                } label: {
                    Text(r)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(available ? PB.text : Color(UIColor.tertiaryLabel))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected ? Color(UIColor.secondarySystemGroupedBackground) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .shadow(color: selected ? .black.opacity(0.14) : .clear, radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(!available)
            }
        }
        .padding(2)
        .background(Color(UIColor.systemFill), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var chartCard: some View {
        if let data {
            VStack(spacing: 0) {
                AreaChartView(data: data, up: (data.last ?? 0) >= (data.first ?? 0),
                              color: PB.accent, height: 170, animKey: effectiveRange,
                              scrubValue: $scrubValue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            actionBtn("+ Receita") { showAddIncome = true }
            actionBtn("− Despesa") { showAddExpense = true }
            actionBtn("⇄ Transferir") { showTransfer = true }
        }
        .padding(16)
    }

    private func actionBtn(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TRANSAÇÕES DA CONTA")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            if accountTx.isEmpty {
                Text("Sem transações")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accountTx.enumerated()), id: \.element.id) { i, tx in
                        Button { editTx = tx } label: { TxListRow(tx: tx) }
                            .buttonStyle(.plain)
                        if i < accountTx.count - 1 { Divider().padding(.leading, 62) }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Tab "Transações"
struct TransactionsListScreen: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var filter = "Todas"
    @State private var editTx: PBTx? = nil
    private let filters = ["Todas", "Despesas", "Receitas", "Transferências"]

    private var filtered: [PBTx] {
        var txs = store.transactions
        if !query.isEmpty {
            let q = query.lowercased()
            txs = txs.filter { $0.title.lowercased().contains(q) || $0.account.lowercased().contains(q) }
        }
        switch filter {
        case "Despesas": txs = txs.filter { $0.amount < 0 && $0.cat != .transfer }
        case "Receitas": txs = txs.filter { $0.amount > 0 && $0.cat != .transfer }
        case "Transferências": txs = txs.filter { $0.cat == .transfer }
        default: break
        }
        return txs
    }

    private var grouped: [(label: String, items: [PBTx])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var groups: [String: [PBTx]] = [:]
        var order: [String] = []
        for tx in filtered {
            let label: String
            if let d = AppStore.parseDate(tx.date) {
                let start = cal.startOfDay(for: d)
                if start == today { label = "Hoje" }
                else if start == cal.date(byAdding: .day, value: -1, to: today) { label = "Ontem" }
                else if d > cal.date(byAdding: .day, value: -7, to: today)! { label = "Esta semana" }
                else { label = "Anteriores" }
            } else { label = "Anteriores" }
            if groups[label] == nil { order.append(label); groups[label] = [] }
            groups[label]?.append(tx)
        }
        return order.map { (label: $0, items: groups[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchBar
                filterChips
                ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.label.uppercased())
                            .font(.system(size: 12.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                            .padding(.top, 16)

                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, tx in
                                Button { editTx = tx } label: { TxListRow(tx: tx) }
                                    .buttonStyle(.plain)
                                if i < group.items.count - 1 { Divider().padding(.leading, 62) }
                            }
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }
                Spacer(minLength: 100)
            }
        }
        .background(PB.bg)
        .navigationTitle("Transações")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editTx) { tx in
            // See AccountScreen: without this the sheet reuses the previous
            // transaction's @State.
            TransactionEditSheet(tx: tx)
                .environment(store)
                .id(tx.txID)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Procurar", text: $query)
                .font(.system(size: 16))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemFill), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { filter = f }
                    } label: {
                        Text(f)
                            .font(.system(size: 13.5, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(filter == f ? PB.accent : Color(UIColor.systemFill),
                                        in: Capsule())
                            .foregroundStyle(filter == f ? .white : PB.text)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - MovimentosScreen (mantido para compatibilidade, redireciona)
struct MovimentosScreen: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        AccountsListScreen()
    }
}
