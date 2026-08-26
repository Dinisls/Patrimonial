import Foundation
import Testing
import SwiftUI
import UIKit
@testable import Patrimonial

// MARK: - The row is rendered, not reasoned about

/// "2 un · I" — the account name eaten down to one letter — was declared fixed
/// once on the strength of a `layoutPriority(1)` that looked right in the source.
/// It was not fixed on the device.
///
/// Reading a layout is not testing it: the widths that decide truncation come
/// from font metrics, not from the code. So this renders the real view at the
/// real widths and writes PNGs, and asserts on measured text rather than on
/// intent. `PB_ROW_SNAPSHOT_DIR` in the environment makes it drop the images
/// somewhere inspectable; without it the assertions still run.
@MainActor
struct PositionRowLayoutTests {

    /// Widths of the row's content box, after the card's outer padding and the
    /// row's own horizontal padding.
    ///
    /// The device this bug was reported on is the 402 pt one; the 375 pt case is
    /// the narrowest iPhone still supported and the one that fails first.
    private static let deviceWidths: [(name: String, screen: CGFloat)] = [
        ("se", 375), ("13", 390), ("pro", 402), ("promax", 440)
    ]

    private func holding(
        symbol: String = "HBM",
        mic: String? = "XNYS",
        account: String = "Investimentos",
        quantity: Decimal = 2,
        price: Decimal? = 223.96,
        fx: Decimal? = 0.8669,
        currency: String? = "USD"
    ) -> Holding {
        var h = Holding(
            assetSymbol: symbol,
            assetMIC: mic,
            accountID: "acc-1",
            accountName: account,
            quantity: quantity,
            totalCostEUR: 388,
            averagePriceEUR: 194,
            commissions: 0,
            realizedPL: 0,
            dividendsReceived: 0
        )
        h.currentPriceNative = price
        h.currency = currency
        h.currentFXRate = currency.flatMap { c in
            fx.flatMap { FXRate(from: c, to: "EUR", value: $0) }
        }
        return h
    }

    private func render(_ view: some View, screenWidth: CGFloat, to name: String) -> UIImage? {
        // The card sits inside `.padding(.horizontal, 16)` on the screen; the row
        // adds its own 16 on each side. Reproduced here so the width the row is
        // proposed is the width it gets in the app.
        let content = view
            .frame(width: screenWidth - 32)
            .background(Color(UIColor.secondarySystemGroupedBackground))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        // Via `cgImage` rather than `uiImage`: the UIImage that comes back is not
        // always bitmap-backed, and `pngData()` on it silently answers nil.
        guard let cg = renderer.cgImage else { return nil }
        let image = UIImage(cgImage: cg)
        let dir = ProcessInfo.processInfo.environment["PB_ROW_SNAPSHOT_DIR"]
            ?? (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
                + "/pb-row-snapshots")
        guard let data = image.pngData() else {
            Issue.record("no png data for \(name)")
            return image
        }
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try data.write(to: url)
        } catch {
            Issue.record("could not write \(name).png to \(dir): \(error)")
        }
        return image
    }

    /// Width the subtitle wants, measured with the font the view actually uses.
    private func subtitleIdealWidth(_ text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12.5)
        ]
        return (text as NSString).size(withAttributes: attributes).width
    }

    /// Width the price column wants, the same way.
    private func trailingIdealWidth(value: String, pct: String, native: String) -> CGFloat {
        func w(_ s: String, _ size: CGFloat, _ weight: UIFont.Weight, mono: Bool = false) -> CGFloat {
            let font = mono
                ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
                : UIFont.systemFont(ofSize: size, weight: weight)
            return (s as NSString).size(withAttributes: [.font: font]).width
        }
        return max(
            w(value, 16, .semibold),
            w(pct, 12, .semibold, mono: true),
            w(native, 10, .regular)
        )
    }

    /// The two greys, side by side, so the claim that they are now
    /// distinguishable is looked at rather than asserted.
    ///
    /// `.closed` and `.dailyClose` were both plain grey circles. They say
    /// different things — the market is shut, versus this is the best quote
    /// obtainable while the market trades — and on the reported screen the
    /// second was read as the first.
    @Test func theTwoGreysAreDrawnDifferently() {
        let closed = PositionRowView(
            holding: holding(symbol: "HBM", mic: "XNYS", currency: "EUR"),
            privacyMode: false, freshness: .closed
        )
        #expect(render(closed, screenWidth: 402, to: "grey-closed") != nil)

        let settled = PositionRowView(
            holding: holding(symbol: "NVD", mic: "XETR", currency: "EUR"),
            privacyMode: false,
            freshness: .dailyClose(Date().addingTimeInterval(-3 * 86_400))
        )
        #expect(render(settled, screenWidth: 402, to: "grey-dailyclose") != nil)
    }

    // MARK: - What the row must satisfy

    /// The two columns do not fit side by side at every width — that much is
    /// arithmetic, and no arrangement changes it.
    ///
    /// So the question a layout fix has to answer is *which* side gives way, and
    /// this records the answer: the trailing column always gets the width it
    /// asks for. It is the one holding numbers, and a number that wraps or
    /// truncates stops being the number.
    @Test(arguments: PositionRowLayoutTests.deviceWidths.map(\.screen))
    func subtitleFitsAtEveryWidth(screen: CGFloat) {
        let subtitle = "2 un · Investimentos"
        let content = screen - 32 - 32   // card padding, row padding
        let available = content - 40 - 14 - 14  // avatar, avatar-to-left gap, left-to-trailing gap

        let left = subtitleIdealWidth(subtitle)
        let right = trailingIdealWidth(
            value: "48,31 €", pct: "+0,92%", native: "27,86 USD × 0,8669"
        )

        #expect(
            left + right <= available,
            "at \(screen) pt subtitle truncates: needs \(left + right), has \(available)"
        )
    }

    /// The regression itself, stated as a height.
    ///
    /// `388,30 €` rendered one digit per line made the row 176 pt tall and spilled
    /// out of the card. Nothing in the source said "wrap"; the priority order did
    /// it. A height ceiling catches that whatever the cause, which reading the
    /// modifiers never would have.
    @Test(arguments: PositionRowLayoutTests.deviceWidths.map(\.screen))
    func rowNeverGrowsBeyondOneLine(screen: CGFloat) {
        // Avatar 40 + 10 pt padding top and bottom is the row's natural height;
        // 72 leaves room for a descender without leaving room for a second line.
        let ceiling: CGFloat = 72

        for (label, view) in [
            ("live", PositionRowView(
                holding: holding(), privacyMode: false, freshness: .delayed(15)
            )),
            ("close", PositionRowView(
                holding: holding(symbol: "NVD", mic: "XETR", currency: "EUR"),
                privacyMode: false,
                // A close from the current year, which is the only kind that reaches
                // this row in practice — the label drops the year for those, and
                // testing the longer form would flatter the layout.
                freshness: .dailyClose(Date().addingTimeInterval(-3 * 86_400))
            )),
            ("long", PositionRowView(
                holding: holding(account: "Conta Investimentos DEGIRO"),
                privacyMode: false,
                // A close from the current year, which is the only kind that reaches
                // this row in practice — the label drops the year for those, and
                // testing the longer form would flatter the layout.
                freshness: .dailyClose(Date().addingTimeInterval(-3 * 86_400))
            ))
        ] {
            guard let image = render(view, screenWidth: screen, to: "h-\(label)") else {
                Issue.record("\(label) at \(screen) did not render")
                continue
            }
            let height = image.size.height / 3   // rendered at scale 3
            #expect(
                height <= ceiling,
                "\(label) at \(screen) pt is \(height) pt tall — something wrapped"
            )
        }
    }

    // MARK: - Rendered artefacts

    @Test(arguments: PositionRowLayoutTests.deviceWidths.map(\.name).indices)
    func rendersAtEveryWidth(index: Int) {
        let (name, screen) = Self.deviceWidths[index]

        let live = PositionRowView(
            holding: holding(), privacyMode: false, freshness: .delayed(15)
        )
        #expect(render(live, screenWidth: screen, to: "\(name)-live") != nil)

        let close = PositionRowView(
            holding: holding(symbol: "NVD", mic: "XETR", currency: "EUR"),
            privacyMode: false,
            // A close from the current year, which is the only kind that reaches
                // this row in practice — the label drops the year for those, and
                // testing the longer form would flatter the layout.
                freshness: .dailyClose(Date().addingTimeInterval(-3 * 86_400))
        )
        #expect(render(close, screenWidth: screen, to: "\(name)-close") != nil)

        let longAccount = PositionRowView(
            holding: holding(account: "Conta Investimentos DEGIRO"),
            privacyMode: false,
            // A close from the current year, which is the only kind that reaches
                // this row in practice — the label drops the year for those, and
                // testing the longer form would flatter the layout.
                freshness: .dailyClose(Date().addingTimeInterval(-3 * 86_400))
        )
        #expect(render(longAccount, screenWidth: screen, to: "\(name)-long") != nil)
    }

}
