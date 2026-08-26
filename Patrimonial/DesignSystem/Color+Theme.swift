import SwiftUI

extension Color {

    // MARK: - Backgrounds

    static let screenBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 10/255, green: 14/255, blue: 12/255, alpha: 1)
            : UIColor(red: 244/255, green: 245/255, blue: 250/255, alpha: 1)
    })

    static let cardBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 22/255, green: 28/255, blue: 24/255, alpha: 1)
            : UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
    })

    static let tertiaryBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 30/255, green: 38/255, blue: 33/255, alpha: 1)
            : UIColor(red: 238/255, green: 240/255, blue: 247/255, alpha: 1)
    })

    static let separatorLine = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 42/255, green: 53/255, blue: 46/255, alpha: 1)
            : UIColor(red: 226/255, green: 229/255, blue: 238/255, alpha: 1)
    })

    // MARK: - Brand

    static let primaryAction = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 180/255, green: 164/255, blue: 72/255, alpha: 1)
            : UIColor(red: 160/255, green: 144/255, blue: 52/255, alpha: 1)
    })

    static let secondaryAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 43/255, green: 217/255, blue: 140/255, alpha: 1)
            : UIColor(red: 0/255, green: 191/255, blue: 166/255, alpha: 1)
    })

    static let sectionHeader = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 180/255, green: 164/255, blue: 72/255, alpha: 1)
            : UIColor(red: 120/255, green: 108/255, blue: 40/255, alpha: 1)
    })

    // MARK: - Semantic

    static let gainGreen = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 43/255, green: 217/255, blue: 140/255, alpha: 1)
            : UIColor(red: 0/255, green: 184/255, blue: 107/255, alpha: 1)
    })

    static let lossRed = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 255/255, green: 92/255, blue: 102/255, alpha: 1)
            : UIColor(red: 229/255, green: 72/255, blue: 77/255, alpha: 1)
    })

    // MARK: - Text

    static let textPrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 233/255, green: 234/255, blue: 232/255, alpha: 1)
            : UIColor(red: 27/255, green: 28/255, blue: 46/255, alpha: 1)
    })

    static let subtleText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 130/255, green: 140/255, blue: 135/255, alpha: 1)
            : UIColor(red: 106/255, green: 108/255, blue: 130/255, alpha: 1)
    })

    // MARK: - Percentage badge

    static let percentBadgeBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 20/255, green: 50/255, blue: 35/255, alpha: 1)
            : UIColor(red: 220/255, green: 245/255, blue: 230/255, alpha: 1)
    })

    static let percentBadgeBackgroundNegative = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 50/255, green: 20/255, blue: 22/255, alpha: 1)
            : UIColor(red: 255/255, green: 230/255, blue: 230/255, alpha: 1)
    })

    // MARK: - Tab bar

    static let tabBarBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 16/255, green: 20/255, blue: 18/255, alpha: 1)
            : UIColor(red: 248/255, green: 248/255, blue: 250/255, alpha: 1)
    })

    // MARK: - Brand gradient

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color.gainGreen.opacity(0.9), Color.gainGreen],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Helpers

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }

    static let accountColorOptions = [
        "E53E3E", "DD6B20", "38A169", "3182CE",
        "805AD5", "D53F8C", "00BFA6", "2B6CB0",
        "F7931A", "FFB347", "FF6B6B", "E5484D",
        "FF6F91", "4682B4", "6A5ACD", "2B2D42",
    ]
}

extension ShapeStyle where Self == Color {
    static var gainGreen: Color { .gainGreen }
    static var lossRed: Color { .lossRed }
}

