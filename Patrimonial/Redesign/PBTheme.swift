// ───────────────────────────────────────────────────────────
// PBTheme.swift — Design tokens iOS-native com accent vermelho
// ───────────────────────────────────────────────────────────
import SwiftUI

enum PB {
    // MARK: Accent
    static let accent = Color(hex: 0xEC3013)
    static let green  = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hex: 0x30D158) : UIColor(hex: 0x248A3D) })

    // MARK: Backgrounds (iOS system)
    static let bg      = Color(UIColor.systemGroupedBackground)
    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    static let surface2 = Color(UIColor.tertiarySystemGroupedBackground)
    static let surface3 = Color(UIColor.systemFill)

    // MARK: Texto (iOS system)
    static let text  = Color(UIColor.label)
    static let text2 = Color(UIColor.secondaryLabel)
    static let text3 = Color(UIColor.tertiaryLabel)

    // MARK: Separadores
    static let hairline  = Color(UIColor.separator)
    static let hairline2 = Color(UIColor.opaqueSeparator)

    // MARK: Semântico
    static let pos = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hex: 0x30D158) : UIColor(hex: 0x248A3D) })
    static let neg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hex: 0xFF453A) : UIColor(hex: 0xEC3013) })

    // MARK: Chrome (tab bar / navigation bar)
    static let chrome = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hex: 0x1C1C1E, alpha: 0.86)
        : UIColor(hex: 0xF9F9F9, alpha: 0.86) })

    static let fill = Color(UIColor.systemFill)

    // MARK: Paleta categórica
    static let cat: [Color] = [
        Color(hex: 0x4F86E0), Color(hex: 0x34B07A), Color(hex: 0xD8B24E),
        Color(hex: 0xE05A45), Color(hex: 0xB45CC9), Color(hex: 0x3FB8C9),
        Color(hex: 0xD38A3C), Color(hex: 0x8A6FD0), Color(hex: 0x7DB84A),
        Color(hex: 0xD45C92), Color(hex: 0x4F90C9), Color(hex: 0xAEB84A),
    ]

    // MARK: Tipografia
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let cardShadow1 = Color.black.opacity(0.08)
    static let cardShadow2 = Color.black.opacity(0.04)

    // MARK: Ícone de conta por tipo
    static let accentInk = Color.white
}

// MARK: - Color helpers
extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    func pbCardShadow() -> some View {
        self
            .shadow(color: PB.cardShadow1, radius: 1, x: 0, y: 1)
            .shadow(color: PB.cardShadow2, radius: 8, x: 0, y: 4)
    }
}

extension Color {
    func mix(with other: Color, by amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, bl1: CGFloat = 0, al1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, bl2: CGFloat = 0, al2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &bl1, alpha: &al1)
        b.getRed(&r2, green: &g2, blue: &bl2, alpha: &al2)
        let t = CGFloat(amount)
        return Color(.sRGB,
                     red: Double(r1 + (r2 - r1) * t),
                     green: Double(g1 + (g2 - g1) * t),
                     blue: Double(bl1 + (bl2 - bl1) * t),
                     opacity: 1)
    }
}
