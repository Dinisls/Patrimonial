import SwiftUI

/// The one sanctioned way to register an asset the search does not find.
///
/// It exists because the alternative — letting the search box double as free
/// text — silently produced assets with a made-up symbol, no venue and no
/// currency. Every field here is mandatory for that reason: an `Asset` without
/// a venue cannot tell IWDA on XAMS from IWDA on XLON, and one without a
/// currency gets the wrong FX rate applied to its cost.
struct ManualAssetSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onConfirm: (AssetSearchResult) -> Void

    @State private var symbol = ""
    @State private var name = ""
    @State private var venue = Venue.lisbon
    @State private var customVenue = ""
    @State private var currency = Currency.eur
    @State private var customCurrency = ""
    @State private var assetClass: AssetClass = .stock

    /// MIC codes, because that is what `upsertAsset` stores and what
    /// disambiguates a ticker listed on more than one exchange.
    enum Venue: String, CaseIterable, Identifiable {
        case lisbon = "XLIS"
        case amsterdam = "XAMS"
        case paris = "XPAR"
        case xetra = "XETR"
        case nyse = "XNYS"
        case nasdaq = "XNAS"
        case other = "OUTRA"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lisbon: "Euronext Lisboa (XLIS)"
            case .amsterdam: "Euronext Amesterdão (XAMS)"
            case .paris: "Euronext Paris (XPAR)"
            case .xetra: "XETRA (XETR)"
            case .nyse: "NYSE (XNYS)"
            case .nasdaq: "NASDAQ (XNAS)"
            case .other: "Outra…"
            }
        }
    }

    enum Currency: String, CaseIterable, Identifiable {
        case eur = "EUR"
        case usd = "USD"
        case gbp = "GBP"
        case chf = "CHF"
        case other = "OUTRA"

        var id: String { rawValue }

        var label: String { self == .other ? "Outra…" : rawValue }
    }

    // MARK: - Draft

    /// The five fields and the rule that all of them are required, kept out of
    /// the view so the rule can be tested rather than only tapped through.
    struct Draft {
        var symbol: String
        var name: String
        var venue: String
        var currency: String
        var assetClass: AssetClass

        var resolvedSymbol: String { symbol.uppercased().trimmingCharacters(in: .whitespaces) }
        var resolvedName: String { name.trimmingCharacters(in: .whitespaces) }
        var resolvedVenue: String { venue.uppercased().trimmingCharacters(in: .whitespaces) }
        var resolvedCurrency: String { currency.uppercased().trimmingCharacters(in: .whitespaces) }

        /// All five, no exceptions — that is the whole point of this sheet. The
        /// currency is held to three letters so a typo cannot become an ISO code
        /// nothing will ever match.
        var isComplete: Bool {
            !resolvedSymbol.isEmpty
            && !resolvedName.isEmpty
            && !resolvedVenue.isEmpty
            && resolvedCurrency.count == 3
            && resolvedCurrency.allSatisfy(\.isLetter)
        }

        /// Nil for an incomplete draft, so there is no path that yields an asset
        /// without a venue and a currency.
        func result() -> AssetSearchResult? {
            guard isComplete else { return nil }
            return AssetSearchResult(
                symbol: resolvedSymbol,
                name: resolvedName,
                exchange: resolvedVenue,
                assetClass: assetClass,
                currency: resolvedCurrency,
                mic: resolvedVenue,
                // No CoinGecko id is knowable from typing, so a manually entered
                // crypto gets no price rather than a wrong one.
                coingeckoID: nil
            )
        }
    }

    private var draft: Draft {
        Draft(
            symbol: symbol,
            name: name,
            venue: venue == .other ? customVenue : venue.rawValue,
            currency: currency == .other ? customCurrency : currency.rawValue,
            assetClass: assetClass
        )
    }

    private var canConfirm: Bool { draft.isComplete }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Símbolo") {
                        TextField("Ex.: GALP.LS", text: $symbol)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Nome") {
                        TextField("Ex.: Galp Energia", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Identificação")
                } footer: {
                    Text("Usa o símbolo tal como a bolsa o publica, com sufixo (.LS, .AS, .PA, .DE). Um símbolo errado nunca terá cotação.")
                }

                Section("Bolsa") {
                    Picker("Bolsa", selection: $venue) {
                        ForEach(Venue.allCases) { v in
                            Text(v.label).tag(v)
                        }
                    }
                    if venue == .other {
                        LabeledContent("Código MIC") {
                            TextField("Ex.: XLON", text: $customVenue)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Moeda") {
                    Picker("Moeda", selection: $currency) {
                        ForEach(Currency.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    if currency == .other {
                        LabeledContent("Código ISO") {
                            TextField("Ex.: SEK", text: $customCurrency)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Classe") {
                    Picker("Classe", selection: $assetClass) {
                        Text("Ação").tag(AssetClass.stock)
                        Text("ETF").tag(AssetClass.etf)
                        Text("Obrigação").tag(AssetClass.bond)
                        Text("Cripto").tag(AssetClass.crypto)
                    }
                    .pickerStyle(.segmented)
                }

                if !canConfirm {
                    Section {
                        Text("Todos os campos são obrigatórios. Sem bolsa e moeda o ativo não pode ser guardado.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PB.bg.ignoresSafeArea())
            .navigationTitle("Ativo manual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirmar") { confirm() }
                        .disabled(!canConfirm)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(PB.accent)
    }

    private func confirm() {
        guard let result = draft.result() else { return }
        onConfirm(result)
        dismiss()
    }
}
