import SwiftUI
import SwiftData

private extension View {
    func pbFormChrome(_ title: String) -> some View {
        self.scrollContentBackground(.hidden)
            .background(PB.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddPositionSheet: View {
    /// Opens the sheet on a position the user is already looking at.
    ///
    /// The app knows the instrument, its venue, its currency, the account and
    /// the quantity held, so a quick action from the detail screen has no
    /// business asking for any of it again. The search step disappears and the
    /// asset is fixed — everything else, including the automatic FX lookup on
    /// the chosen date and the sale validation, behaves exactly as it does when
    /// the same asset is reached through search.
    struct Prefill: Equatable {
        let asset: AssetSearchResult
        /// Which account this action starts from. A ticker held in two
        /// brokerages is two positions, and a sale must come out of the one the
        /// user tapped — not the larger of the two, and not the sum.
        ///
        /// Nil when the action comes from the watchlist, where there is no
        /// position and so no account to inherit. The sheet then falls back to
        /// the usual default the way a fresh purchase does, and the user picks.
        let accountID: UUID?
        let type: TransactionType

        static func == (a: Prefill, b: Prefill) -> Bool {
            a.asset.id == b.asset.id && a.accountID == b.accountID && a.type == b.type
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PortfolioViewModel

    /// Non-nil in quick-action mode: the asset is fixed and cannot be changed.
    private let prefill: Prefill?

    init(viewModel: PortfolioViewModel, prefill: Prefill? = nil) {
        self.viewModel = viewModel
        self.prefill = prefill
        _txType = State(initialValue: prefill?.type ?? .assetPurchase)
        _selectedAsset = State(initialValue: prefill?.asset)
        _searchQuery = State(initialValue: prefill?.asset.symbol ?? "")
        _selectedAccountID = State(initialValue: prefill?.accountID)
    }

    /// True when the asset arrived with the sheet and must not be swapped.
    private var isAssetLocked: Bool { prefill != nil }

    @State private var txType: TransactionType = .assetPurchase
    @State private var searchQuery = ""
    @State private var selectedAsset: AssetSearchResult?
    @State private var quantityStr = ""
    @State private var unitPriceStr = ""
    @State private var fxRateStr = "1"
    @State private var fxIsAutomatic = true
    @State private var fxLoading = false
    @State private var commissionStr = "0"
    @State private var note = ""
    @State private var date = Date()
    @State private var selectedAccountID: UUID?
    @State private var error: String?
    @State private var showManualEntry = false

    @Query(sort: \Account.name) private var accounts: [Account]

    private var brokerageAccounts: [Account] {
        accounts.filter { $0.type == .brokerage }
    }
    private var allAccounts: [Account] { accounts }

    private var selectedAccount: Account? {
        let list = brokerageAccounts.isEmpty ? allAccounts : brokerageAccounts
        if let id = selectedAccountID { return list.first { $0.id == id } }
        return list.first
    }

    /// Only ever the symbol of a listing the user actually picked.
    ///
    /// It used to fall back to whatever was typed in the search box, which is
    /// how a position in "NVD" got saved instead of NVDA — and a symbol reached
    /// that way carries no venue and no currency, so the asset was stored
    /// unusable too. Free text now has one route in: the manual sheet, which
    /// demands both.
    private var resolvedSymbol: String {
        selectedAsset?.symbol ?? ""
    }

    /// The listing being traded — ticker *and* venue. What can be sold is a
    /// property of the listing: holding NVIDIA on XETRA does not let you sell
    /// the NASDAQ namesake, and asking by ticker said it did.
    private var resolvedListing: ListingID? {
        selectedAsset.map { ListingID(symbol: $0.symbol, mic: $0.mic ?? $0.exchange) }
    }

    /// The user typed a ticker and never picked a line from the results.
    private var hasUnconfirmedSearchText: Bool {
        selectedAsset == nil && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var quantity: Decimal? {
        Decimal(string: quantityStr.replacingOccurrences(of: ",", with: "."))
    }
    private var unitPrice: Decimal? {
        Decimal(string: unitPriceStr.replacingOccurrences(of: ",", with: "."))
    }
    private var fxRate: Decimal? {
        Decimal(string: fxRateStr.replacingOccurrences(of: ",", with: "."))
    }
    private var commission: Decimal {
        Decimal(string: commissionStr.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canSave: Bool {
        // No confirmed listing, no save. This is the guard that stops a
        // half-typed ticker becoming a position.
        guard selectedAsset != nil else { return false }

        guard let q = quantity, q > 0,
              let p = unitPrice, p > 0,
              let fx = fxRate, fx > 0,
              !resolvedSymbol.isEmpty,
              selectedAccount != nil,
              date <= Date()
        else { return false }

        if txType == .assetSale {
            guard let listing = resolvedListing else { return false }
            let available = viewModel.totalQuantity(listing: listing)
            return q <= available
        }
        return true
    }

    private var totalPreview: Decimal? {
        guard let q = quantity, let p = unitPrice, let fx = fxRate else { return nil }
        let base = q * p * fx
        switch txType {
        case .assetPurchase: return base + commission
        case .assetSale, .dividend: return base - commission
        default: return nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                tickerSection
                detailsSection
                fxSection
                accountSection
                previewSection

                if let error {
                    Section {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(PB.neg)
                    }
                }
            }
            .pbFormChrome(formTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .sheet(isPresented: $showManualEntry) {
            ManualAssetSheet { manual in
                selectAsset(manual)
            }
        }
        .onAppear {
            let list = brokerageAccounts.isEmpty ? allAccounts : brokerageAccounts
            if selectedAccountID == nil { selectedAccountID = list.first?.id }

            // Reached through search, the rate is fetched when a result is
            // picked. Nothing is picked here, so it has to happen on arrival —
            // otherwise a quick action would open with a rate of 1 and quietly
            // record a dollar cost as euros.
            if let prefill, prefill.asset.currency != "EUR" {
                fetchFXRate(currency: prefill.asset.currency)
            }
            if let prefill, prefill.asset.assetClass == .crypto,
               let cgID = prefill.asset.coingeckoID {
                viewModel.registerCryptoAsset(symbol: prefill.asset.symbol, coinGeckoID: cgID)
            }
        }
        .onChange(of: date) { _, _ in
            if let asset = selectedAsset, asset.currency != "EUR", fxIsAutomatic {
                fetchFXRate(currency: asset.currency)
            }
        }
    }

    private var formTitle: String {
        switch txType {
        case .assetPurchase: "Nova Compra"
        case .assetSale: "Nova Venda"
        case .dividend: "Novo Dividendo"
        default: "Nova Operação"
        }
    }

    // MARK: - Type

    private var typeSection: some View {
        Section {
            Picker("Tipo", selection: $txType) {
                Text("Compra").tag(TransactionType.assetPurchase)
                Text("Venda").tag(TransactionType.assetSale)
                Text("Dividendo").tag(TransactionType.dividend)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Ticker search with autocomplete

    private var tickerSection: some View {
        Section("Ativo") {
            if let asset = selectedAsset {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.symbol)
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(asset.name) · \(asset.exchange)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text(asset.currency)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(asset.assetClass.rawValue.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PB.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(PB.accent)
                    }
                }
                // In quick-action mode the asset is the whole point of having
                // arrived here, so there is nothing to change it to.
                if !isAssetLocked {
                    Button("Alterar ativo") {
                        selectedAsset = nil
                        searchQuery = ""
                        viewModel.clearSearch()
                        fxRateStr = "1"
                        fxIsAutomatic = true
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(PB.accent)
                }
            } else if !isAssetLocked {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Pesquisar ticker ou nome...", text: $searchQuery)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: searchQuery) { _, newVal in
                            viewModel.searchTicker(newVal)
                        }
                    if viewModel.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                // Saying plainly why "Guardar" is dead, instead of leaving the
                // user to guess that typing was not the same as choosing.
                if hasUnconfirmedSearchText && !viewModel.isSearching {
                    Label(
                        viewModel.searchResults.isEmpty
                        ? "Sem resultados para \"\(searchQuery.trimmingCharacters(in: .whitespaces))\". Escrever o símbolo não chega — escolhe um resultado ou introduz o ativo manualmente."
                        : "Escolhe um dos resultados abaixo. Escrever o símbolo não chega.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(PB.neg)
                }

                if !viewModel.searchResults.isEmpty {
                    ForEach(viewModel.visibleSearchResults) { result in
                        Button {
                            selectAsset(result)
                        } label: {
                            AssetSearchResultRow(
                                result: result,
                                quote: viewModel.searchQuote(for: result),
                                freshness: viewModel.searchFreshness(for: result),
                                isPricing: viewModel.isPricingSearch
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // The deep venues stay reachable, one tap away, rather than
                    // being scrolled past on the way to the obvious listing.
                    if !viewModel.showAllSearchResults, viewModel.hiddenSearchResultCount > 0 {
                        Button {
                            viewModel.showAllSearchResults = true
                        } label: {
                            Label(
                                "Ver mais \(viewModel.hiddenSearchResultCount) resultados",
                                systemImage: "chevron.down"
                            )
                            .font(.system(size: 13))
                        }
                        .foregroundStyle(PB.accent)
                    }
                }

                Button {
                    showManualEntry = true
                } label: {
                    Label("Introduzir ativo manualmente", systemImage: "square.and.pencil")
                        .font(.system(size: 14))
                }
                .foregroundStyle(PB.accent)
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Detalhes") {
            HStack {
                Text(txType == .dividend ? "Montante" : "Quantidade")
                Spacer()
                TextField("0", text: $quantityStr)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text(txType == .dividend ? "Preço/unidade" : "Preço unitário")
                Spacer()
                TextField("0,00", text: $unitPriceStr)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                if let asset = selectedAsset {
                    Text(asset.currency).foregroundStyle(PB.text3)
                }
            }
            HStack {
                Text("Comissão (€)")
                Spacer()
                TextField("0", text: $commissionStr)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            DatePicker("Data", selection: $date, in: ...Date(), displayedComponents: .date)
            TextField("Nota (opcional)", text: $note)

            if txType == .assetSale, let listing = resolvedListing {
                let available = viewModel.totalQuantity(listing: listing)
                if available > 0 {
                    LabeledContent("Disponível") {
                        Text(available.formatted(.number.precision(.fractionLength(0...8))))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - FX rate

    private var fxSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Taxa câmbio → EUR")
                    if fxIsAutomatic && selectedAsset != nil && selectedAsset?.currency != "EUR" {
                        Text("Automática")
                            .font(.system(size: 11))
                            .foregroundStyle(PB.pos)
                    }
                }
                Spacer()
                if fxLoading {
                    ProgressView().controlSize(.small)
                } else {
                    TextField("1", text: $fxRateStr)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: fxRateStr) { _, _ in
                            fxIsAutomatic = false
                        }
                }
            }
            if selectedAsset?.currency == "EUR" {
                Text("Ativo em EUR — taxa fixa em 1")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Câmbio")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Conta") {
            let list = brokerageAccounts.isEmpty ? allAccounts : brokerageAccounts
            if list.isEmpty {
                Text("Cria uma conta primeiro")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Conta", selection: $selectedAccountID) {
                    ForEach(list) { acc in
                        Text(acc.name).tag(Optional(acc.id))
                    }
                }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        if let total = totalPreview {
            Section("Resumo") {
                let label = txType == .assetPurchase ? "Custo total (EUR)" :
                            txType == .assetSale ? "Receita (EUR)" : "Valor líquido (EUR)"
                LabeledContent(label) {
                    Text(formatDecimalEUR(total))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Actions

    private func selectAsset(_ result: AssetSearchResult) {
        // Read the price before clearing the search, which discards it.
        //
        // Only fills an empty field: it is a reference for what the asset trades
        // at now, not a claim about what the user paid. Typing over it must
        // always win, and a price already entered is never overwritten.
        if unitPriceStr.isEmpty, let quote = viewModel.searchQuote(for: result) {
            unitPriceStr = Self.editableDecimal(quote.price)
        }

        selectedAsset = result
        searchQuery = result.symbol
        viewModel.clearSearch()

        if result.assetClass == .crypto, let cgID = result.coingeckoID {
            viewModel.registerCryptoAsset(symbol: result.symbol, coinGeckoID: cgID)
            fxRateStr = "1"
            fxIsAutomatic = true
        } else {
            fetchFXRate(currency: result.currency)
        }
    }

    private func fetchFXRate(currency: String) {
        // Unknown currency: leave the rate to the user rather than inventing one.
        guard !currency.isEmpty else {
            fxRateStr = ""
            fxIsAutomatic = false
            return
        }
        if currency == "EUR" {
            fxRateStr = "1"
            fxIsAutomatic = true
            return
        }
        fxLoading = true
        fxIsAutomatic = true
        Task {
            if let rate = await viewModel.lookupFXRate(currency: currency, on: date) {
                fxRateStr = Self.editableDecimal(rate.value)
                fxIsAutomatic = true
            } else {
                fxRateStr = ""
                fxIsAutomatic = false
            }
            fxLoading = false
        }
    }

    private func save() {
        guard let q = quantity, let p = unitPrice, let fx = fxRate,
              let account = selectedAccount else { return }

        do {
            try viewModel.addInvestment(
                type: txType,
                symbol: resolvedSymbol,
                quantity: q,
                unitPrice: p,
                fxRate: fx,
                commission: commission,
                account: account,
                date: date,
                note: note,
                asset: selectedAsset
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A decimal the user can keep typing into: comma separator to match the
    /// keyboard, no grouping separators, no currency symbol.
    static func editableDecimal(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 8
        return f.string(from: value as NSDecimalNumber) ?? ""
    }

    private func formatDecimalEUR(_ value: Decimal) -> String {
        let ns = value as NSDecimalNumber
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: ns) ?? "—"
    }
}
