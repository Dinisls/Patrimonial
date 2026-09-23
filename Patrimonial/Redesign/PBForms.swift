// ───────────────────────────────────────────────────────────
// PBForms.swift — Sheets para adicionar transações, transferências, contas
// ───────────────────────────────────────────────────────────
import SwiftUI

// Internal rather than fileprivate since the debt sheets were added: the
// chrome is what makes a sheet look like the app's other sheets, and a second
// copy of it in another file is a second thing to keep in step.
extension View {
    func pbFormChrome(_ title: String) -> some View {
        self.scrollContentBackground(.hidden)
            .background(PB.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// Shown when a mutation's write to disk failed. The sheet stays open on
    /// purpose — dismissing it would say "saved" when nothing was — so the
    /// message tells the user to try again, and the fields are still filled in.
    func pbSaveErrorAlert(_ isPresented: Binding<Bool>) -> some View {
        alert("Não foi possível guardar", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A alteração não foi gravada. Tenta novamente.")
        }
    }
}

private let weekdayNames: [String] = {
    var cal = Calendar.current
    cal.locale = Locale(identifier: "pt_PT")
    let symbols = cal.weekdaySymbols
    return symbols.map { $0.capitalized }
}()

// MARK: - Selector de categoria (chips horizontais)
struct CategoryChipPicker: View {
    @Environment(AppStore.self) private var store
    let isIncome: Bool
    @Binding var selection: CategorySelection
    @State private var showAddCat = false

    private var builtinCats: [TxCategory] {
        isIncome ? [.income, .work] : [.food, .transport, .work, .other]
    }
    private var customCats: [PBCustomCategory] {
        store.customCategories.filter { isIncome ? $0.isIncome : $0.isExpense }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(builtinCats, id: \.self) { cat in
                    chip(symbol: Icon.catSymbol(cat), name: builtinLabel(cat),
                         isSelected: selection == .builtin(cat), color: builtinColor(cat)) {
                        selection = .builtin(cat)
                    }
                }
                ForEach(customCats) { cat in
                    chip(symbol: cat.symbol, name: cat.name,
                         isSelected: selection == .custom(cat.id), color: cat.color) {
                        selection = .custom(cat.id)
                    }
                }
                Button { showAddCat = true } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(PB.text3)
                            .frame(width: 42, height: 42)
                            .background(PB.surface2, in: Circle())
                        Text("Nova")
                            .font(PB.sans(10, .medium))
                            .foregroundStyle(PB.text3)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showAddCat) {
            CategoryFormSheet(isIncome: isIncome) { newCat in
                selection = .custom(newCat.id)
            }
            .environment(store)
        }
        .onChange(of: isIncome) { _, _ in
            selection = isIncome ? .builtin(.income) : .builtin(.other)
        }
    }

    private func chip(symbol: String, name: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? color : PB.text3)
                    .frame(width: 42, height: 42)
                    .background(isSelected ? color.opacity(0.18) : PB.surface2, in: Circle())
                Text(name)
                    .font(PB.sans(10, .medium))
                    .foregroundStyle(isSelected ? color : PB.text3)
                    .lineLimit(1)
                    .frame(width: 56)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private func builtinLabel(_ c: TxCategory) -> String {
        switch c {
        case .food: "Alimentação"; case .transport: "Transportes"
        case .work: "Trabalho"; case .income: "Receita"; default: "Outras"
        }
    }
    private func builtinColor(_ c: TxCategory) -> Color {
        switch c {
        case .food: Color(hex: 0xD9A24A as UInt)
        case .transport: Color(hex: 0x3F7BE0 as UInt)
        case .work, .income: PB.pos
        default: PB.text3
        }
    }
}

// MARK: - Formulário de nova categoria personalizada
struct CategoryFormSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let initialIsIncome: Bool
    var onCreated: (PBCustomCategory) -> Void = { _ in }

    @State private var name = ""
    @State private var symbol = "tag"
    @State private var colorHex: UInt = 0x3F7BE0
    @State private var isExpense: Bool
    @State private var isIncome: Bool
    @State private var saveFailed = false

    private let symbols = [
        "tag", "cart", "star", "heart", "house", "car", "airplane", "gift",
        "book", "music.note", "gamecontroller", "dumbbell", "scissors", "tshirt",
        "suitcase", "cup.and.saucer", "pills", "stethoscope", "banknote", "creditcard",
        "phone", "wifi", "bolt", "drop", "leaf", "pawprint", "bicycle", "bag"
    ]
    private let palette: [UInt] = [
        0xE0563C, 0xD9A24A, 0x2FA86E, 0x3F7BE0, 0x8A6FD0, 0xD45C92,
        0x2196F3, 0x00BCD4, 0xFF9800, 0x795548
    ]

    init(isIncome: Bool, onCreated: @escaping (PBCustomCategory) -> Void = { _ in }) {
        self.initialIsIncome = isIncome
        self.onCreated = onCreated
        _isExpense = State(initialValue: !isIncome)
        _isIncome = State(initialValue: isIncome)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (isExpense || isIncome)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Ex.: Viagens", text: $name)
                }
                Section("Ícone") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                        ForEach(symbols, id: \.self) { s in
                            Button { symbol = s } label: {
                                Image(systemName: s)
                                    .font(.system(size: 18))
                                    .foregroundStyle(symbol == s ? Color(hex: colorHex) : PB.text3)
                                    .frame(width: 42, height: 42)
                                    .background(symbol == s ? Color(hex: colorHex).opacity(0.16) : PB.surface2,
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Cor") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                        ForEach(palette, id: \.self) { c in
                            Button { colorHex = c } label: {
                                Circle()
                                    .fill(Color(hex: c))
                                    .frame(height: 36)
                                    .overlay(
                                        Circle().stroke(.white.opacity(0.9), lineWidth: colorHex == c ? 3 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Tipo") {
                    Toggle("Despesa", isOn: $isExpense)
                    Toggle("Receita", isOn: $isIncome)
                }
            }
            .pbFormChrome("Nova Categoria")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Criar") { save() }.disabled(!canSave).fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .pbSaveErrorAlert($saveFailed)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try store.addCustomCategory(name: trimmed, symbol: symbol, colorHex: colorHex,
                                        isExpense: isExpense, isIncome: isIncome)
            if let created = store.customCategories.last(where: { $0.name == trimmed }) {
                onCreated(created)
            }

            dismiss()
        } catch {

            saveFailed = true
        }
    }
}

// MARK: - Transação (receita / despesa)
struct TransactionFormSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var prefilledAccount: String? = nil

    @State private var isIncome: Bool
    @State private var title = ""
    @State private var amount = ""
    @State private var catSelection: CategorySelection = .builtin(.other)
    @State private var account = ""
    @State private var date = Date()
    @State private var recurrence: Recurrence = .none
    @State private var recurrenceDay: Int = 1
    @State private var recurrenceDay2: Int = 15
    @State private var saveFailed = false

    init(prefilledAccount: String? = nil, initialIsIncome: Bool = false) {
        self.prefilledAccount = prefilledAccount
        _isIncome = State(initialValue: initialIsIncome)
        _catSelection = State(initialValue: initialIsIncome ? .builtin(.income) : .builtin(.other))
    }

    private var amountValue: Double { Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && amountValue > 0 && !account.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tipo", selection: $isIncome) {
                        Text("Despesa").tag(false)
                        Text("Receita").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Detalhes") {
                    TextField("Descrição", text: $title)
                    HStack {
                        Text("Valor")
                        Spacer()
                        TextField("0,00", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(PB.text3)
                    }
                    Picker("Conta", selection: $account) {
                        ForEach(store.accounts) { a in Text(a.name).tag(a.name) }
                    }
                    DatePicker("Data", selection: $date, displayedComponents: .date)
                }
                Section("Repetição") {
                    Picker("Repetir", selection: $recurrence) {
                        Text("Nunca").tag(Recurrence.none)
                        Text("Semanalmente").tag(Recurrence.weekly)
                        Text("2x por mês").tag(Recurrence.bimonthly)
                        Text("Mensalmente").tag(Recurrence.monthly)
                    }
                    if recurrence == .weekly {
                        Picker("Dia da semana", selection: $recurrenceDay) {
                            ForEach(Array(weekdayNames.enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i + 1)
                            }
                        }
                    }
                    if recurrence == .monthly {
                        Picker("Dia do mês", selection: $recurrenceDay) {
                            ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                        }
                    }
                    if recurrence == .bimonthly {
                        Picker("Primeiro dia", selection: $recurrenceDay) {
                            ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                        }
                        Picker("Segundo dia", selection: $recurrenceDay2) {
                            ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                        }
                    }
                }
                Section("Categoria") {
                    CategoryChipPicker(isIncome: isIncome, selection: $catSelection)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
            .pbFormChrome(isIncome ? "Nova Receita" : "Nova Despesa")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }.disabled(!canSave).fontWeight(.semibold)
                }
            }
            .onChange(of: date) { _, newDate in
                if recurrence == .weekly {
                    recurrenceDay = Calendar.current.component(.weekday, from: newDate)
                } else if recurrence == .monthly || recurrence == .bimonthly {
                    recurrenceDay = Calendar.current.component(.day, from: newDate)
                }
            }
            .onChange(of: recurrence) { _, newVal in
                if newVal == .weekly {
                    recurrenceDay = Calendar.current.component(.weekday, from: date)
                } else if newVal == .monthly {
                    recurrenceDay = Calendar.current.component(.day, from: date)
                } else if newVal == .bimonthly {
                    recurrenceDay = Calendar.current.component(.day, from: date)
                    recurrenceDay2 = min(recurrenceDay + 14, 28)
                }
            }
        }
        .tint(PB.accent)
        .pbSaveErrorAlert($saveFailed)
        .onAppear { if account.isEmpty { account = prefilledAccount ?? store.accounts.first?.name ?? "" } }
    }

    private func save() {
        let (cat, customID) = resolvedCategory()
        do {
            try store.addTransaction(
                title: title.trimmingCharacters(in: .whitespaces),
                amount: amountValue, isIncome: isIncome,
                category: cat, customCatID: customID,
                account: account, date: dateString(date),
                recurrence: recurrence,
                recurrenceDay: recurrence != .none ? recurrenceDay : nil,
                recurrenceDay2: recurrence == .bimonthly ? recurrenceDay2 : nil
            )

            dismiss()
        } catch {

            saveFailed = true
        }
    }
    private func resolvedCategory() -> (TxCategory, String?) {
        switch catSelection {
        case .builtin(let c): return (isIncome ? .income : c, nil)
        case .custom(let id): return (isIncome ? .income : .other, id)
        }
    }
    private func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_PT"); f.dateFormat = "d/M/yyyy"
        return f.string(from: d)
    }
}

// MARK: - Editar transação existente
struct TransactionEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let tx: PBTx

    @State private var isIncome: Bool
    @State private var title: String
    @State private var amount: String
    @State private var catSelection: CategorySelection
    @State private var account: String
    @State private var date: Date
    @State private var recurrence: Recurrence
    @State private var recurrenceDay: Int
    @State private var recurrenceDay2: Int
    @State private var showDeleteConfirm = false
    @State private var saveFailed = false

    private var amountValue: Double { Self.parseAmountField(amount) ?? 0 }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && amountValue > 0 && !account.isEmpty }

    init(tx: PBTx) {
        self.tx = tx
        _isIncome = State(initialValue: tx.amount > 0)
        _title = State(initialValue: tx.title)
        _amount = State(initialValue: Self.amountFieldText(for: tx.amount))
        if let customID = tx.customCatID {
            _catSelection = State(initialValue: .custom(customID))
        } else {
            let defaultCat: TxCategory = tx.amount > 0 ? .income : (tx.cat == .other ? .other : tx.cat)
            _catSelection = State(initialValue: .builtin(defaultCat))
        }
        _account = State(initialValue: tx.account)
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "d/M/yyyy"
        let parsedDate = f.date(from: tx.date) ?? Date()
        _date = State(initialValue: parsedDate)
        _recurrence = State(initialValue: tx.recurrence)
        _recurrenceDay = State(initialValue: tx.recurrenceDay ?? Calendar.current.component(.day, from: parsedDate))
        _recurrenceDay2 = State(initialValue: tx.recurrenceDay2 ?? 15)
    }

    var body: some View {
        NavigationStack {
            Form {
                if tx.isInvestment {
                    investmentSections
                } else if tx.cat == .transfer {
                    Section("Transferência") {
                        LabeledContent("Valor") { Text(Fmt.eur(abs(tx.amount))).foregroundStyle(PB.text2) }
                        if let sub = tx.sub { LabeledContent("Direção") { Text(sub).foregroundStyle(PB.text2) } }
                        DatePicker("Data", selection: $date, displayedComponents: .date)
                    }
                } else {
                    Section {
                        Picker("Tipo", selection: $isIncome) {
                            Text("Despesa").tag(false)
                            Text("Receita").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Detalhes") {
                        TextField("Descrição", text: $title)
                        HStack {
                            Text("Valor")
                            Spacer()
                            TextField("0,00", text: $amount)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("€").foregroundStyle(PB.text3)
                        }
                        Picker("Conta", selection: $account) {
                            ForEach(store.accounts) { a in Text(a.name).tag(a.name) }
                        }
                        DatePicker("Data", selection: $date, displayedComponents: .date)
                    }
                    Section("Repetição") {
                        Picker("Repetir", selection: $recurrence) {
                            Text("Nunca").tag(Recurrence.none)
                            Text("Semanalmente").tag(Recurrence.weekly)
                            Text("2x por mês").tag(Recurrence.bimonthly)
                            Text("Mensalmente").tag(Recurrence.monthly)
                        }
                        if recurrence == .weekly {
                            Picker("Dia da semana", selection: $recurrenceDay) {
                                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { i, name in
                                    Text(name).tag(i + 1)
                                }
                            }
                        }
                        if recurrence == .monthly {
                            Picker("Dia do mês", selection: $recurrenceDay) {
                                ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                            }
                        }
                        if recurrence == .bimonthly {
                            Picker("Primeiro dia", selection: $recurrenceDay) {
                                ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                            }
                            Picker("Segundo dia", selection: $recurrenceDay2) {
                                ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                            }
                        }
                    }
                    Section("Categoria") {
                        CategoryChipPicker(isIncome: isIncome, selection: $catSelection)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        HStack { Spacer(); Text("Apagar Transação"); Spacer() }
                    }
                }
            }
            .pbFormChrome(formTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tx.isInvestment ? "Fechar" : "Cancelar") { dismiss() }
                }
                // No save button at all for an investment: there is nothing on
                // this screen that may legitimately be written back.
                if !tx.isInvestment {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") { save() }
                            .disabled(!canSave)
                            .fontWeight(.semibold)
                    }
                }
            }
            .onChange(of: recurrence) { _, newVal in
                if newVal == .weekly {
                    recurrenceDay = Calendar.current.component(.weekday, from: date)
                } else if newVal == .monthly {
                    recurrenceDay = Calendar.current.component(.day, from: date)
                } else if newVal == .bimonthly {
                    recurrenceDay = Calendar.current.component(.day, from: date)
                    recurrenceDay2 = min(recurrenceDay + 14, 28)
                }
            }
        }
        .tint(PB.accent)
        .pbSaveErrorAlert($saveFailed)
        .confirmationDialog("Apagar esta transação?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                guard let id = tx.txID else { dismiss(); return }
                do {
                    try store.deleteTransaction(id: id)

                    dismiss()
                } catch {
        
                    saveFailed = true
                }
            }
        }
    }

    private var formTitle: String {
        if tx.isInvestment { return "Investimento" }
        return tx.cat == .transfer ? "Transferência" : "Editar Transação"
    }

    /// Read-only. An investment carries a symbol, quantity, unit price, FX rate
    /// and commission that this editor has no inputs for — and the portfolio is
    /// computed from exactly those. Showing them and refusing to write is the
    /// honest option; the alternative was a form that quietly turned a purchase
    /// into an expense.
    @ViewBuilder
    private var investmentSections: some View {
        Section("Operação") {
            LabeledContent("Tipo") { Text(tx.title).foregroundStyle(PB.text2) }
            if let symbol = tx.assetSymbol {
                LabeledContent("Ativo") { Text(symbol).foregroundStyle(PB.text2) }
            }
            if let qty = tx.assetQuantity {
                LabeledContent("Quantidade") { Text(Self.qtyText(qty)).foregroundStyle(PB.text2) }
            }
            if let price = tx.assetUnitPrice {
                LabeledContent("Preço unitário") {
                    Text(Self.decimalText(price) + (tx.assetCurrency.map { " \($0)" } ?? ""))
                        .foregroundStyle(PB.text2)
                }
            }
            if let fx = tx.assetFXRate {
                LabeledContent("Câmbio → EUR") { Text(Self.decimalText(fx, dp: 6)).foregroundStyle(PB.text2) }
            }
            if let commission = tx.assetCommission, commission != 0 {
                LabeledContent("Comissão") { Text(Fmt.eur(Double(truncating: commission as NSNumber))).foregroundStyle(PB.text2) }
            }
            LabeledContent("Total") { Text(Fmt.eur(abs(tx.amount))).foregroundStyle(PB.text2) }
            LabeledContent("Conta") { Text(tx.account).foregroundStyle(PB.text2) }
            LabeledContent("Data") { Text(tx.date).foregroundStyle(PB.text2) }
        }
        Section {
            Text("As operações de investimento editam-se no separador Investimentos. Aqui só podem ser consultadas ou apagadas — este ecrã não tem campos para símbolo, quantidade, preço ou câmbio, e gravar por aqui apagaria a posição.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private static func qtyText(_ v: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 8
        return f.string(from: v as NSDecimalNumber) ?? "\(v)"
    }

    private static func decimalText(_ v: Decimal, dp: Int = 2) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = dp
        return f.string(from: v as NSDecimalNumber) ?? "\(v)"
    }

    /// The exact text the amount field starts with. Extracted so the value
    /// pipeline — stored Decimal → PBTx Double → editable string → parsed back —
    /// can be tested for fidelity instead of only eyeballed.
    static func amountFieldText(for amount: Double) -> String {
        String(format: "%.2f", abs(amount)).replacingOccurrences(of: ".", with: ",")
    }

    static func parseAmountField(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func save() {
        guard let id = tx.txID else { dismiss(); return }
        // Belt and braces: the button does not exist for investments.
        if tx.isInvestment { dismiss(); return }
        do {
            if tx.cat == .transfer {
                try store.updateTransactionMeta(id: id, account: account, date: dateString(date))
            } else {
                let (cat, customID) = resolvedCategory()
                try store.updateTransaction(
                    id: id,
                    title: title.trimmingCharacters(in: .whitespaces),
                    amount: amountValue, isIncome: isIncome,
                    category: cat, customCatID: customID,
                    account: account, date: dateString(date),
                    recurrence: recurrence,
                    recurrenceDay: recurrence != .none ? recurrenceDay : nil,
                    recurrenceDay2: recurrence == .bimonthly ? recurrenceDay2 : nil
                )
            }

            dismiss()
        } catch {

            saveFailed = true
        }
    }

    private func resolvedCategory() -> (TxCategory, String?) {
        switch catSelection {
        case .builtin(let c): return (isIncome ? .income : c, nil)
        case .custom(let id): return (isIncome ? .income : .other, id)
        }
    }
    private func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_PT"); f.dateFormat = "d/M/yyyy"
        return f.string(from: d)
    }
}

// MARK: - Transferência entre contas
struct TransferFormSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var prefilledFromAccount: String? = nil

    @State private var fromAccount = ""
    @State private var toAccount = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var saveFailed = false

    private func d(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var destAccounts: [PBAccount] { store.accounts.filter { $0.name != fromAccount } }
    private var canSave: Bool { d(amount) > 0 && !fromAccount.isEmpty && !toAccount.isEmpty && fromAccount != toAccount }

    var body: some View {
        NavigationStack {
            Form {
                Section("De / Para") {
                    Picker("De", selection: $fromAccount) {
                        ForEach(store.accounts) { a in Text(a.name).tag(a.name) }
                    }
                    .onChange(of: fromAccount) { _, _ in
                        if toAccount == fromAccount { toAccount = destAccounts.first?.name ?? "" }
                    }
                    Picker("Para", selection: $toAccount) {
                        ForEach(destAccounts) { a in Text(a.name).tag(a.name) }
                    }
                }
                Section("Detalhes") {
                    HStack {
                        Text("Valor")
                        Spacer()
                        TextField("0,00", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(PB.text3)
                    }
                    TextField("Nota (opcional)", text: $note)
                    DatePicker("Data", selection: $date, displayedComponents: .date)
                }
            }
            .pbFormChrome("Transferência")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }.disabled(!canSave).fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .pbSaveErrorAlert($saveFailed)
        .onAppear {
            fromAccount = prefilledFromAccount ?? store.accounts.first?.name ?? ""
            toAccount = destAccounts.first?.name ?? ""
        }
    }

    private func save() {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_PT"); f.dateFormat = "d/M/yyyy"
        do {
            try store.addTransfer(fromAccount: fromAccount, toAccount: toAccount,
                                  amount: d(amount), note: note, date: f.string(from: date))

            dismiss()
        } catch {

            saveFailed = true
        }
    }
}

// MARK: - Nova conta
struct AccountFormSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sub = ""
    @State private var balance = ""
    @State private var colorHex: UInt = 0x3F7BE0
    @State private var saveFailed = false

    private let palette: [UInt] = [0xE0563C, 0xD9A24A, 0x2FA86E, 0x3F7BE0, 0x8A6FD0, 0xD45C92]
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Detalhes") {
                    TextField("Nome", text: $name)
                    TextField("Subtipo (ex.: Conta à Ordem)", text: $sub)
                    HStack {
                        Text("Saldo inicial"); Spacer()
                        TextField("0,00", text: $balance).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(PB.text3)
                    }
                }
                Section("Cor") {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { c in
                            Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(PB.text, lineWidth: colorHex == c ? 2 : 0))
                                .onTapGesture { colorHex = c }
                        }
                    }
                }
            }
            .pbFormChrome("Nova Conta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        do {
                            try store.addAccount(name: name.trimmingCharacters(in: .whitespaces),
                                                 sub: sub.isEmpty ? "Conta" : sub,
                                                 kind: .cash, colorHex: colorHex,
                                                 initialBalance: Double(balance.replacingOccurrences(of: ",", with: ".")) ?? 0)
                
                            dismiss()
                        } catch {
                
                            saveFailed = true
                        }
                    }.disabled(!canSave).fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .pbSaveErrorAlert($saveFailed)
    }
}

struct AccountEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let account: PBAccount
    @State private var name: String
    @State private var sub: String
    @State private var balance: String
    @State private var colorHex: UInt
    @State private var saveFailed = false

    private let palette: [UInt] = [0xE0563C, 0xD9A24A, 0x2FA86E, 0x3F7BE0, 0x8A6FD0, 0xD45C92]
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    init(account: PBAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _sub = State(initialValue: account.sub)
        _balance = State(initialValue: String(format: "%.2f", account.balance).replacingOccurrences(of: ".", with: ","))
        _colorHex = State(initialValue: account.colorHex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Detalhes") {
                    TextField("Nome", text: $name)
                    TextField("Subtipo (ex.: Conta à Ordem)", text: $sub)
                    HStack {
                        Text("Saldo"); Spacer()
                        TextField("0,00", text: $balance).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(PB.text3)
                    }
                }
                Section("Cor") {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { c in
                            Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(PB.text, lineWidth: colorHex == c ? 2 : 0))
                                .onTapGesture { colorHex = c }
                        }
                    }
                }
            }
            .pbFormChrome("Editar Conta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        do {
                            try store.updateAccount(
                                id: account.id,
                                name: name.trimmingCharacters(in: .whitespaces),
                                sub: sub,
                                colorHex: colorHex,
                                balance: Double(balance.replacingOccurrences(of: ",", with: ".")) ?? account.balance
                            )
                
                            dismiss()
                        } catch {
                
                            saveFailed = true
                        }
                    }.disabled(!canSave).fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
        .pbSaveErrorAlert($saveFailed)
    }
}
