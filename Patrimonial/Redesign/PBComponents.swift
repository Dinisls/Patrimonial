// ───────────────────────────────────────────────────────────
// PBComponents.swift — Átomos de UI reutilizáveis
// ───────────────────────────────────────────────────────────
import SwiftUI

// MARK: - Ícones
enum Icon {
    static func accountSymbol(_ kind: AccountKind) -> String { "creditcard" }
    static func catSymbol(_ cat: TxCategory) -> String {
        switch cat {
        case .food: "fork.knife"
        case .work: "briefcase"
        case .other: "ellipsis"
        case .income: "arrow.down"
        case .transport: "car"
        case .transfer: "arrow.left.arrow.right"
        case .investments: "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - Card
struct PBCard<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = 12
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground),
                         in: RoundedRectangle(cornerRadius: radius))
    }
}

struct TapScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.978 : 1)
            .animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.13), value: configuration.isPressed)
    }
}

// MARK: - Delta chip
struct DeltaChip: View {
    var pct: Double? = nil
    var eur: Double? = nil
    var up: Bool
    var soft: Bool = true
    var big: Bool = false

    private var text: String {
        if let pct { return Fmt.pct(pct) }
        if let eur { return Fmt.signedEur(eur) }
        return ""
    }
    var body: some View {
        let color = up ? PB.pos : PB.neg
        Text(text)
            .font(.system(size: big ? 15 : 12.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, soft ? (big ? 12 : 9) : 0)
            .padding(.vertical, soft ? (big ? 6 : 4) : 0)
            .background(
                soft ? AnyView(Capsule().fill(color.opacity(0.15))) : AnyView(Color.clear)
            )
    }
}

// MARK: - Tile
struct TileView: View {
    let color: Color
    let symbol: String
    var size: CGFloat = 46
    var radius: CGFloat = 13
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(color)
            )
    }
}

// MARK: - Avatar de categoria
struct CatAvatar: View {
    let cat: TxCategory
    let amount: Double
    var customSymbol: String? = nil
    var customColor: Color? = nil

    private var resolvedColor: Color {
        if let c = customColor { return c }
        if cat == .transfer { return PB.accent }
        if cat == .income || cat == .work { return PB.pos }
        return amount > 0 ? PB.pos : PB.neg
    }
    var body: some View {
        Circle()
            .fill(resolvedColor.opacity(0.16))
            .frame(width: 42, height: 42)
            .overlay(
                Image(systemName: customSymbol ?? Icon.catSymbol(cat))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(resolvedColor)
            )
    }
}

// MARK: - Section label
struct SectionLabel<Right: View>: View {
    let title: String
    @ViewBuilder var right: () -> Right
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            right()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}
extension SectionLabel where Right == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
    init(title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Range tabs
struct RangeTabs: View {
    let options: [String]
    @Binding var value: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == value
                Button { withAnimation(.easeInOut(duration: 0.2)) { value = o } } label: {
                    Text(o)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Color(UIColor.secondarySystemGroupedBackground) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .shadow(color: on ? .black.opacity(0.14) : .clear, radius: 3, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(UIColor.systemFill), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Segmented control
struct SegmentedControl: View {
    let options: [String]
    @Binding var value: String
    var body: some View {
        Picker("", selection: $value) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Glass icon button
struct GlassIconButton: View {
    let symbol: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Separador
struct Sep: View {
    var leading: CGFloat = 18
    var body: some View {
        Divider().padding(.leading, leading)
    }
}
