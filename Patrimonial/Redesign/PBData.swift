// ───────────────────────────────────────────────────────────
// PBData.swift — Dados de exemplo + formatadores pt-PT + geradores de séries
// ───────────────────────────────────────────────────────────
import SwiftUI

// MARK: - Formatação pt-PT
enum Fmt {
    private static let eurFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
    private static func plain(_ minF: Int, _ maxF: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_PT")
        f.minimumFractionDigits = minF
        f.maximumFractionDigits = maxF
        return f
    }

    static func eur(_ v: Double) -> String {
        eurFmt.string(from: v as NSNumber) ?? "\(v)"
    }
    static func signedEur(_ v: Double) -> String {
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
        return sign + eur(abs(v))
    }
    static func pct(_ v: Double, dp: Int = 2) -> String {
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
        let s = String(format: "%.\(dp)f", abs(v)).replacingOccurrences(of: ".", with: ",")
        return sign + s + "%"
    }
    static func num(_ v: Double, dp: Int = 2) -> String {
        plain(dp, dp).string(from: v as NSNumber) ?? "\(v)"
    }
}

// MARK: - Tipos
enum AccountKind { case cash }
enum TxCategory: String { case food, work, other, income, transport, transfer, investments }

struct PBAccount: Identifiable {
    let id: String
    var name: String
    var sub: String
    var balance: Double
    var colorHex: UInt
    var kind: AccountKind
    var change: Double
    var color: Color { Color(hex: colorHex) }
}

struct PBTx: Identifiable {
    let id: Int
    var txID: UUID? = nil
    let title: String
    var sub: String? = nil
    let cat: TxCategory
    let account: String
    let date: String
    let amount: Double
    var customCatID: String? = nil
    var customCatName: String? = nil
    var customCatSymbol: String? = nil
    var customCatColorHex: UInt? = nil
    var recurrence: Recurrence = .none
    var recurrenceDay: Int? = nil
    var recurrenceDay2: Int? = nil

    // Investment fields, nil for ordinary transactions. Carried into the PB
    // layer so the generic editor can recognise what it must not touch: it has
    // no inputs for any of these, and saving through it rewrote the type to
    // .expense while leaving them behind — the position vanished from the
    // portfolio and the row became neither an expense nor a holding.
    var assetSymbol: String? = nil
    var assetQuantity: Decimal? = nil
    var assetUnitPrice: Decimal? = nil
    var assetFXRate: Decimal? = nil
    var assetCommission: Decimal? = nil
    var assetCurrency: String? = nil

    var isInvestment: Bool { assetSymbol != nil }
}

struct PBCategoryTotal: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let colorHex: UInt
    let total: Double
    let count: Int
    var fraction: Double = 0
    var color: Color { Color(hex: colorHex) }
}

func txCatLabel(_ cat: TxCategory) -> String {
    switch cat {
    case .food: "Alimentação"
    case .transport: "Transportes"
    case .work, .income: "Trabalho"
    case .other: "Outras"
    case .transfer: "Transferência"
    case .investments: "Investimentos"
    }
}
func txCatColorHex(_ cat: TxCategory) -> UInt {
    switch cat {
    case .food: 0xD9A24A
    case .transport: 0x3F7BE0
    case .work, .income: 0x2FA86E
    case .investments: 0x7A5AF8
    default: 0x8A8A8E
    }
}

struct PBCustomCategory: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let colorHex: UInt
    var isExpense: Bool
    var isIncome: Bool
    var color: Color { Color(hex: colorHex) }
}

enum CategorySelection: Equatable {
    case builtin(TxCategory)
    case custom(String)
}

// MARK: - Etiquetas dinâmicas do eixo X
func chartXLabels(range: String) -> [(Double, String)] {
    let cal = Calendar.current
    let today = Date()
    let dayFmt = DateFormatter()
    dayFmt.locale = Locale(identifier: "pt_PT")
    dayFmt.dateFormat = "d/MM"
    let monFmt = DateFormatter()
    monFmt.locale = Locale(identifier: "pt_PT")
    monFmt.dateFormat = "MMM"

    func day(_ offset: Int) -> String {
        dayFmt.string(from: cal.date(byAdding: .day, value: offset, to: today) ?? today)
    }
    func mon(_ offset: Int) -> String {
        monFmt.string(from: cal.date(byAdding: .month, value: offset, to: today) ?? today).capitalized
    }

    switch range {
    case "7 dias":
        return [(0, day(-7)), (0.5, day(-4)), (1, day(0))]
    case "30 dias":
        return [(0, day(-30)), (0.5, day(-15)), (1, day(0))]
    case "3 meses":
        return [(0, mon(-3)), (0.5, mon(-1)), (1, day(0))]
    case "6 meses":
        return [(0, mon(-6)), (0.5, mon(-3)), (1, day(0))]
    default:
        return [(0, day(-30)), (0.5, day(-15)), (1, day(0))]
    }
}
