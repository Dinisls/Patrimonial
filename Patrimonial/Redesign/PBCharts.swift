// ───────────────────────────────────────────────────────────
// PBCharts.swift — Gráficos animados (Area, Donut, FlowBars, Spark, Bar) + count-up
// Reproduz charts.jsx: suavização Catmull-Rom, desenho animado da linha,
// fade do gradiente, ponto final, donut por segmentos, barras de fluxo.
// ───────────────────────────────────────────────────────────
import SwiftUI

// MARK: - Catmull-Rom → Path
enum Smooth {
    static func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[i == 0 ? i : i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[i + 2 < pts.count ? i + 2 : i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        return p
    }
}

// MARK: - Count-up (anima 0 → valor)
private struct CountUp: Animatable, View {
    var value: Double
    let format: (Double) -> String
    let font: Font
    let color: Color
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(format(value))
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

struct MoneyCountUp: View {
    let value: Double
    var format: (Double) -> String = { Fmt.eur($0) }
    var font: Font = PB.mono(38, .heavy)
    var color: Color = PB.text
    var duration: Double = 1.0
    @State private var shown: Double = 0
    var body: some View {
        CountUp(value: shown, format: format, font: font, color: color)
            .onAppear {
                shown = 0
                withAnimation(.easeOut(duration: duration)) { shown = value }
            }
            .onChange(of: value) { _, newVal in
                withAnimation(.easeOut(duration: duration)) { shown = newVal }
            }
    }
}

// MARK: - Area / line chart
struct AreaChartView: View {
    let data: [Double]
    var up: Bool = true
    var color: Color? = nil
    var height: CGFloat = 150
    var grid: Bool = false
    var yLabels: Bool = false
    var animKey: AnyHashable = 0
    var xLabels: [(at: Double, t: String)]? = nil
    var fill: Bool = true
    var lineWidth: CGFloat = 2.4
    var padT: CGFloat = 14
    var padB: CGFloat = 18
    var scrubValue: Binding<Double?>? = nil

    @State private var drawn = false
    @State private var scrubX: CGFloat? = nil

    private var stroke: Color { color ?? (up ? PB.pos : PB.neg) }

    var body: some View {
        let pr: CGFloat = yLabels ? 38 : 0
        let pl: CGFloat = yLabels ? 6 : 0
        let minV = data.min() ?? 0
        let maxV = data.max() ?? 1
        let range = (maxV - minV) == 0 ? 1 : (maxV - minV)
        let headroom = range * 0.12
        let lo = minV - headroom
        let hi = maxV + headroom

        VStack(spacing: 0) {
            GeometryReader { geo in
                let W = geo.size.width
                let H = height
                let innerW = W - pl - pr
                let innerH = H - padT - padB
                let pts: [CGPoint] = data.enumerated().map { i, v in
                    CGPoint(
                        x: pl + (data.count == 1 ? 0 : CGFloat(i) / CGFloat(data.count - 1)) * innerW,
                        y: padT + (1 - CGFloat((v - lo) / (hi - lo))) * innerH
                    )
                }
                let line = Smooth.path(pts)
                let bottomY = padT + innerH
                let area = Self.areaPath(line: line, first: pts.first!, last: pts.last!, bottomY: bottomY)

                ZStack {
                    // Grid + Y labels
                    if grid || yLabels {
                        ForEach(0...4, id: \.self) { i in
                            let val = lo + (hi - lo) * (Double(i) / 4)
                            let y = padT + (1 - CGFloat(i) / 4) * innerH
                            if grid {
                                Path { p in
                                    p.move(to: CGPoint(x: pl, y: y))
                                    p.addLine(to: CGPoint(x: W - pr, y: y))
                                }
                                .stroke(PB.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            }
                            if yLabels {
                                Text(fmtK(val))
                                    .font(PB.mono(10.5, .regular))
                                    .foregroundStyle(PB.text3)
                                    .position(x: W - pr + 18, y: y)
                            }
                        }
                    }

                    // Fill
                    if fill {
                        area.fill(
                            LinearGradient(colors: [stroke.opacity(0.28), stroke.opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .opacity(drawn ? 1 : 0)
                        .animation(.easeIn(duration: 0.9).delay(0.2), value: drawn)
                    }

                    // Linha desenhada (trim)
                    line.trimmedPath(from: 0, to: drawn ? 1 : 0)
                        .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.0), value: drawn)

                    // Ponto final
                    Circle()
                        .fill(stroke)
                        .frame(width: 6.8, height: 6.8)
                        .position(pts.last!)
                        .opacity(drawn && scrubX == nil ? 1 : 0)
                        .animation(.easeIn(duration: 0.3).delay(1.0), value: drawn)

                    // Scrubber
                    if let sx = scrubX, !pts.isEmpty, innerW > 0 {
                        let clampedX = max(pl, min(pl + innerW, sx))
                        let frac = (clampedX - pl) / innerW
                        let idx = max(0, min(pts.count - 1, Int((frac * CGFloat(pts.count - 1)).rounded())))
                        let scrubPt = pts[idx]
                        Path { p in
                            p.move(to: CGPoint(x: clampedX, y: padT))
                            p.addLine(to: CGPoint(x: clampedX, y: padT + innerH))
                        }
                        .stroke(stroke.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        Circle()
                            .fill(stroke)
                            .frame(width: 12, height: 12)
                            .position(scrubPt)
                        Circle()
                            .fill(PB.bg)
                            .frame(width: 6, height: 6)
                            .position(scrubPt)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard !data.isEmpty, innerW > 0 else { return }
                            let x = max(pl, min(pl + innerW, v.location.x))
                            let frac = (x - pl) / innerW
                            let idx = max(0, min(data.count - 1, Int((frac * CGFloat(data.count - 1)).rounded())))
                            scrubX = x
                            scrubValue?.wrappedValue = data[idx]
                        }
                        .onEnded { _ in
                            scrubX = nil
                            scrubValue?.wrappedValue = nil
                        }
                )
            }
            .frame(height: height)

            // X labels
            if let xLabels {
                ZStack {
                    ForEach(Array(xLabels.enumerated()), id: \.offset) { idx, l in
                        GeometryReader { g in
                            Text(l.t)
                                .font(PB.sans(11))
                                .foregroundStyle(PB.text3)
                                .position(
                                    x: max(12, min(g.size.width - 12, CGFloat(l.at) * g.size.width)),
                                    y: 8
                                )
                        }
                    }
                }
                .frame(height: 16)
            }
        }
        .onAppear { trigger() }
        .onChange(of: animKey) { _, _ in trigger() }
    }

    private func trigger() {
        drawn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { drawn = true }
    }

    private static func areaPath(line: Path, first: CGPoint, last: CGPoint, bottomY: CGFloat) -> Path {
        var area = line
        area.addLine(to: CGPoint(x: last.x, y: bottomY))
        area.addLine(to: CGPoint(x: first.x, y: bottomY))
        area.closeSubpath()
        return area
    }

    private func fmtK(_ v: Double) -> String {
        if abs(v) >= 1000 {
            let k = v / 1000
            let s = String(format: k.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", k)
            return s.replacingOccurrences(of: ".", with: ",") + "K"
        }
        return String(Int(v.rounded()))
    }
}

// MARK: - Donut segmentado
struct DonutView: View {
    let segments: [(value: Double, color: Color)]
    var size: CGFloat = 200
    var thickness: CGFloat = 26
    var gapDeg: Double = 2.2
    var animKey: AnyHashable = 0

    @State private var drawn = false

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.value }
        ZStack {
            ForEach(Array(prefixSums(total).enumerated()), id: \.offset) { i, seg in
                DonutArc(startFrac: seg.start, endFrac: seg.end, gapDeg: gapDeg)
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(segments[i].color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                    .animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.7).delay(Double(i) * 0.055), value: drawn)
            }
        }
        .frame(width: size, height: size)
        .onAppear { trigger() }
        .onChange(of: animKey) { _, _ in trigger() }
    }

    private func prefixSums(_ total: Double) -> [(start: Double, end: Double)] {
        var acc = 0.0
        return segments.map { s in
            let frac = total > 0 ? s.value / total : 0
            let r = (start: acc, end: acc + frac)
            acc += frac
            return r
        }
    }
    private func trigger() {
        drawn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { drawn = true }
    }
}

private struct DonutArc: Shape {
    let startFrac: Double
    let endFrac: Double
    let gapDeg: Double
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2 - 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a0 = Angle(degrees: startFrac * 360 + gapDeg / 2 - 90)
        let a1 = Angle(degrees: endFrac * 360 - gapDeg / 2 - 90)
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        return p
    }
}

// MARK: - Barras de fluxo (receita acima / despesa abaixo)
struct FlowBarsView: View {
    let days: [(d: Int, inn: Double, out: Double)]
    var height: CGFloat = 170
    var animKey: AnyHashable = 0

    @State private var drawn = false

    var body: some View {
        let maxIn = max(days.map(\.inn).max() ?? 1, 1)
        let maxOut = max(days.map(\.out).max() ?? 1, 1)
        let maxV = max(maxIn, maxOut)
        let padT: CGFloat = 10, padB: CGFloat = 22

        GeometryReader { geo in
            let W = geo.size.width
            let innerH = height - padT - padB
            let zeroY = padT + innerH * CGFloat(maxIn / (maxIn + maxOut * 0.6))
            let n = days.count
            let bw = min(26, (W / CGFloat(n)) * 0.5)

            ZStack(alignment: .topLeading) {
                // linha zero
                Path { p in
                    p.move(to: CGPoint(x: 0, y: zeroY))
                    p.addLine(to: CGPoint(x: W, y: zeroY))
                }.stroke(PB.hairline, lineWidth: 1)

                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let x = (CGFloat(i) + 0.5) / CGFloat(n) * W - bw / 2
                    let upH = CGFloat(d.inn / maxV) * (zeroY - padT)
                    let dnH = CGFloat(d.out / maxV) * (height - padB - zeroY)
                    let delay = Double(i) * 0.035

                    if d.inn > 0 {
                        let h = max(upH, 3)
                        RoundedRectangle(cornerRadius: min(4, bw / 2))
                            .fill(PB.pos)
                            .frame(width: bw, height: drawn ? h : 0)
                            .position(x: x + bw / 2, y: zeroY - (drawn ? h : 0) / 2)
                            .animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.7).delay(delay), value: drawn)
                    }
                    if d.out > 0 {
                        let h = max(dnH, 3)
                        RoundedRectangle(cornerRadius: min(4, bw / 2))
                            .fill(PB.neg)
                            .frame(width: bw, height: drawn ? h : 0)
                            .position(x: x + bw / 2, y: zeroY + (drawn ? h : 0) / 2)
                            .animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.7).delay(delay), value: drawn)
                    }
                    if d.d % 2 == 1 {
                        Text("\(d.d)")
                            .font(PB.sans(11))
                            .foregroundStyle(PB.text3)
                            .position(x: (CGFloat(i) + 0.5) / CGFloat(n) * W, y: height - 8)
                    }
                }
            }
        }
        .frame(height: height)
        .onAppear { trigger() }
        .onChange(of: animKey) { _, _ in trigger() }
    }
    private func trigger() {
        drawn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { drawn = true }
    }
}

// MARK: - Sparkline (estático)
struct SparkView: View {
    let data: [Double]
    var up: Bool = true
    var width: CGFloat = 64
    var height: CGFloat = 22
    var body: some View {
        let minV = data.min() ?? 0
        let maxV = data.max() ?? 1
        let range = (maxV - minV) == 0 ? 1 : (maxV - minV)
        Canvas { ctx, size in
            let pts = data.enumerated().map { i, v in
                CGPoint(
                    x: (data.count == 1 ? 0 : CGFloat(i) / CGFloat(data.count - 1)) * size.width,
                    y: size.height - 2 - CGFloat((v - minV) / range) * (size.height - 4)
                )
            }
            ctx.stroke(Smooth.path(pts),
                       with: .color(up ? PB.pos : PB.neg),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Barra de progresso animada
struct ProgressBarView: View {
    let frac: Double
    var color: Color = PB.pos
    var track: Color = PB.surface3
    var height: CGFloat = 9
    var delay: Double = 0
    @State private var shown: Double = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(1, shown))
            }
        }
        .frame(height: height)
        .onAppear {
            shown = 0
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.9).delay(delay)) {
                shown = max(0, min(1, frac))
            }
        }
    }
}
