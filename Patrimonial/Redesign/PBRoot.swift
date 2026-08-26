// ───────────────────────────────────────────────────────────
// PBRoot.swift — 5 tabs: Resumo, Contas, +, Transações, Investimentos
// ───────────────────────────────────────────────────────────
import SwiftUI
import SwiftData

struct PBRootView: View {
    @AppStorage("appTheme") private var appTheme = "system"
    @Environment(\.modelContext) private var modelContext
    @State private var store = AppStore()
    /// Owned here rather than by `PortfolioScreen`, which is where it used to
    /// live. Settings sits in a different tab and has to be able to clear the
    /// in-memory quotes as part of a data reset; a `@State` inside another tab
    /// is unreachable from there, and a reset that wipes the database while the
    /// old prices sit in memory puts them straight back on the next poll.
    @State private var priceStore = PriceStore()
    /// `PBDebug.initialTab` has been sitting unused since it was written. Wiring
    /// it costs nothing — it reads one environment variable and defaults to 0 —
    /// and it is the only way to get a screenshot of a tab other than Resumo
    /// without a UI-test runner.
    @State private var selectedTab = PBDebug.initialTab
    @State private var showQuickMenu = false
    @State private var showAddExpense = false
    @State private var showAddIncome = false
    @State private var showTransfer = false
    @State private var showNewAccount = false

    private var colorScheme: ColorScheme? {
        switch appTheme { case "light": .light; case "dark": .dark; default: nil }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("Resumo", systemImage: "house.fill", value: 0) {
                    NavigationStack { DashboardScreen(selectedTab: $selectedTab) }
                }
                Tab("Contas", systemImage: "creditcard.fill", value: 1) {
                    NavigationStack { AccountsListScreen() }
                }
                Tab("Novo", systemImage: "plus.circle.fill", value: 2) {
                    EmptyView()
                }
                Tab("Transações", systemImage: "list.bullet", value: 3) {
                    NavigationStack { TransactionsListScreen() }
                }
                Tab("Investimentos", systemImage: "chart.bar.fill", value: 4) {
                    NavigationStack { PortfolioScreen() }
                }
            }
            .onChange(of: selectedTab) { _, newVal in
                if newVal == 2 {
                    selectedTab = 0
                    showQuickMenu = true
                } else {
                    // Investment transactions are written by PortfolioViewModel
                    // through a separate context, so this store's caches go stale
                    // without a refresh on the way back.
                    store.reload()
                }
            }

            if showQuickMenu {
                QuickMenuOverlay(
                    isPresented: $showQuickMenu,
                    showAddExpense: $showAddExpense,
                    showAddIncome: $showAddIncome,
                    showTransfer: $showTransfer,
                    showNewAccount: $showNewAccount
                )
            }
        }
        .environment(store)
        .environment(priceStore)
        .preferredColorScheme(colorScheme)
        .tint(PB.accent)
        .onAppear {
            // Before anything reads a position, a price or a chart.
            //
            // Here rather than in `PortfolioScreen` because that screen is one
            // tab of five: a user who never opens Investimentos would keep
            // unattributed rows indefinitely, and every day that passes is a day
            // in which a second listing under the same ticker could arrive and
            // close the window on them for good. Idempotent and free after the
            // first run — see `ListingBackfill`.
            ListingBackfill.run(in: modelContext)
            ListingBackfill.normalizeCryptoMICs(in: modelContext)
            store.bind(modelContext)
        }
        .sheet(isPresented: $showAddExpense) {
            TransactionFormSheet(initialIsIncome: false).environment(store)
        }
        .sheet(isPresented: $showAddIncome) {
            TransactionFormSheet(initialIsIncome: true).environment(store)
        }
        .sheet(isPresented: $showTransfer) {
            TransferFormSheet().environment(store)
        }
        .sheet(isPresented: $showNewAccount) {
            AccountFormSheet().environment(store)
        }
    }
}

// MARK: - Quick action menu (+)
struct QuickMenuOverlay: View {
    @Binding var isPresented: Bool
    @Binding var showAddExpense: Bool
    @Binding var showAddIncome: Bool
    @Binding var showTransfer: Bool
    @Binding var showNewAccount: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 0) {
                    menuRow(label: "Nova despesa", icon: "minus.circle", color: PB.neg) {
                        isPresented = false
                        showAddExpense = true
                    }
                    Divider().padding(.leading, 16)
                    menuRow(label: "Nova receita", icon: "plus.circle", color: PB.pos) {
                        isPresented = false
                        showAddIncome = true
                    }
                    Divider().padding(.leading, 16)
                    menuRow(label: "Transferência", icon: "arrow.left.arrow.right", color: PB.accent) {
                        isPresented = false
                        showTransfer = true
                    }
                    Divider().padding(.leading, 16)
                    menuRow(label: "Nova conta", icon: "building.columns", color: PB.text2) {
                        isPresented = false
                        showNewAccount = true
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresented)
    }

    private func menuRow(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PB.text)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings
struct SettingsScreen: View {
    @AppStorage("appTheme") private var appTheme = "system"
    @Environment(AppStore.self) private var store
    @Environment(PriceStore.self) private var priceStore

    /// Two flags, two alerts, and no way to reach the second without having read
    /// the first. A single destructive tap on an irreversible action is not a
    /// confirmation, it is a trap — and the first alert is where the counts are,
    /// so skipping straight to "de certeza?" would mean confirming without ever
    /// being told what is about to go.
    @State private var showFirstConfirm = false
    @State private var showFinalConfirm = false
    /// Taken when the first alert opens and held for both, so the numbers the
    /// user reads are the numbers they agreed to and cannot shift underneath
    /// them between the two taps.
    @State private var pendingInventory: DataReset.Inventory?
    @State private var resetError: String?

    var body: some View {
        List {
            Section("Aparência") {
                Picker("Tema", selection: $appTheme) {
                    Text("Claro").tag("light")
                    Text("Escuro").tag("dark")
                    Text("Sistema").tag("system")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color(UIColor.secondarySystemGroupedBackground))
            }

            Section("Gestão") {
                NavigationLink {
                    CategoriesManagementScreen()
                } label: {
                    Label("Gerir Categorias", systemImage: "tag")
                }
            }

            Section("Dados") {
                LabeledContent("Contas") { Text("\(store.accounts.count)") }
                LabeledContent("Transações") { Text("\(store.transactions.count)") }
            }

            Section {
                Button {
                    pendingInventory = currentInventory()
                    showFirstConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Apagar todos os dados")
                            .foregroundStyle(PB.neg)
                        Spacer()
                    }
                }
            } footer: {
                Text("Apaga contas, transações, categorias, posições, cotações em cache e o histórico da carteira. As chaves de API não são afetadas.")
            }
        }
        .navigationTitle("Definições")
        .navigationBarTitleDisplayMode(.large)
        .alert(
            "Apagar todos os dados?",
            isPresented: $showFirstConfirm,
            presenting: pendingInventory
        ) { _ in
            Button("Continuar", role: .destructive) { showFinalConfirm = true }
            Button("Cancelar", role: .cancel) { pendingInventory = nil }
        } message: { inventory in
            Text(firstMessage(inventory))
        }
        // Presented off the same stored inventory, so the second alert repeats
        // the irreversible part rather than asking a question the user has
        // already answered.
        .alert(
            "De certeza?",
            isPresented: $showFinalConfirm,
            presenting: pendingInventory
        ) { _ in
            Button("Apagar tudo", role: .destructive) { performReset() }
            Button("Cancelar", role: .cancel) { pendingInventory = nil }
        } message: { inventory in
            Text(finalMessage(inventory))
        }
        .alert("Não foi possível apagar", isPresented: Binding(
            get: { resetError != nil },
            set: { if !$0 { resetError = nil } }
        )) {
            Button("OK", role: .cancel) { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
    }

    // MARK: - Reset

    private func currentInventory() -> DataReset.Inventory {
        guard let ctx = store.modelContext else {
            return DataReset.Inventory(
                accounts: 0, transactions: 0, positions: 0,
                customCategories: 0, portfolioSnapshots: 0, watchlisted: 0
            )
        }
        return DataReset.inventory(in: ctx)
    }

    /// Concrete numbers, not "todos os dados". The point of a confirmation on an
    /// irreversible action is to let the user recognise what they are about to
    /// destroy, and a count is the only part of that they can check against
    /// what they remember having.
    private func firstMessage(_ inventory: DataReset.Inventory) -> String {
        var lines = [
            "Vai apagar:",
            "• \(inventory.transactions) \(plural(inventory.transactions, "transação", "transações"))",
            "• \(inventory.positions) \(plural(inventory.positions, "posição", "posições"))",
            "• \(inventory.accounts) \(plural(inventory.accounts, "conta", "contas"))",
        ]
        if inventory.customCategories > 0 {
            lines.append("• \(inventory.customCategories) \(plural(inventory.customCategories, "categoria", "categorias")) personalizadas")
        }
        if inventory.watchlisted > 0 {
            lines.append("• \(inventory.watchlisted) \(plural(inventory.watchlisted, "título seguido", "títulos seguidos"))")
        }
        lines.append("• \(inventory.portfolioSnapshots) \(plural(inventory.portfolioSnapshots, "dia", "dias")) de histórico da carteira")
        lines.append("")
        lines.append("Também apaga as cotações e câmbios em cache. As chaves de API ficam intactas.")
        lines.append("")
        lines.append("Não pode ser anulado.")
        return lines.joined(separator: "\n")
    }

    /// The second alert says the one thing the first cannot say strongly
    /// enough. Positions and transactions can be typed in again from a broker
    /// statement; the snapshots are a daily recording of what the portfolio was
    /// worth on days that have already passed, and nothing re-creates those.
    private func finalMessage(_ inventory: DataReset.Inventory) -> String {
        let history = inventory.portfolioSnapshots
        let historyLine = history == 0
            ? "Ainda não há histórico da carteira gravado."
            : "Os \(history) \(plural(history, "dia", "dias")) de histórico da carteira são o único que não se recupera de forma nenhuma: as posições podes voltar a registar, os dias passados não."
        return "\(historyLine)\n\nApagar mesmo tudo?"
    }

    private func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }

    private func performReset() {
        pendingInventory = nil
        guard let ctx = store.modelContext else {
            resetError = "A base de dados não está disponível."
            return
        }
        do {
            try DataReset.eraseEverything(in: ctx, priceStore: priceStore, appStore: store)
            // The store's own caches are cleared by the erase; this rebuilds
            // them from an empty database so the screens behind this sheet are
            // already empty when it closes, without a relaunch.
            store.reload()
        } catch {
            resetError = error.localizedDescription
        }
    }
}

// MARK: - Gestão de categorias
struct CategoriesManagementScreen: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false

    var body: some View {
        List {
            if store.customCategories.isEmpty {
                ContentUnavailableView("Sem categorias", systemImage: "tag.slash",
                                       description: Text("Toca em + para criar a primeira."))
            } else {
                ForEach(store.customCategories) { cat in
                    HStack(spacing: 14) {
                        Image(systemName: cat.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(cat.color)
                            .frame(width: 34, height: 34)
                            .background(cat.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.name).font(.system(size: 16, weight: .medium))
                            Text(cat.isExpense && cat.isIncome ? "Despesa & Receita" : cat.isExpense ? "Despesa" : "Receita")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { store.deleteCustomCategory(id: store.customCategories[i].id) }
                }
            }
        }
        .navigationTitle("Categorias")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            CategoryFormSheet(isIncome: false).environment(store)
        }
    }
}

// MARK: - Debug hooks
enum PBDebug {
    static var initialTab: Int {
        Int(ProcessInfo.processInfo.environment["PB_TAB"] ?? "") ?? 0
    }
    static var sheet: String? {
        let s = ProcessInfo.processInfo.environment["PB_SHEET"] ?? ""
        return s.isEmpty ? nil : s
    }
    static var initialPaths: [Int: [PBRoute]] {
        guard let s = ProcessInfo.processInfo.environment["PB_PUSH"], !s.isEmpty,
              let route = parse(s) else { return [:] }
        return [initialTab: [route]]
    }
    private static func parse(_ s: String) -> PBRoute? {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "cashflow":   return .cashflow
        case "account":    return parts.count > 1 ? .account(parts[1]) : nil
        default:           return nil
        }
    }
}
