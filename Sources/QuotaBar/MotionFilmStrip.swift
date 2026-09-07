#if DEBUG
import QuotaBarCore
import AppKit
import SwiftUI

/// Frame dumps of the controls whose motion lives in SwiftUI state rather than in a clock the app
/// can hand a time to. The reset animation can be rendered from the shipped views because
/// `QuotaCelebration` is a function of elapsed seconds; a pill driven by two `@State` edges and a
/// `withAnimation` cannot be posed at t = 0.14s from outside.
///
/// So the layouts here are stand-ins. The timing is not: every duration, curve, spring and stagger
/// is read from the same `TabSwitchMotion`, `DisclosureMotion` and `CostChartHoverMotion` the real
/// controls animate on, and the curve sampler solves the same cubic Bézier the verifier walks.
/// Change a constant in one of those and these strips change with it. Change the shipped layout and
/// they will not, which is the cost of doing it this way.
@MainActor
enum MotionFilmStrip {
    /// 25 frames a second, which is 40ms per frame. A GIF stores its delay in hundredths, so this
    /// is a whole number of them and the export plays at the speed the app runs at rather than at
    /// whatever the rounding produced.
    private static let step: TimeInterval = 1.0 / 25

    // MARK: - Curve sampling

    /// The `.timingCurve(0.16, 1, 0.3, 1, …)` both `DisclosureMotion.openCurve` and the tab pill
    /// run on, solved for a moment in time. `TabSwitchMotion` already owns the solver.
    static func curve(_ time: TimeInterval, duration: TimeInterval) -> Double {
        TabSwitchMotion.progress(at: time, duration: duration)
    }

    /// `.easeOut`, the unit cubic Bézier through (0, 0) and (0.58, 1), which is what the label's
    /// unit swap runs on. `TabSwitchMotion` solves its own control points and only its own, so
    /// this one solves these.
    static func easeOut(_ time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let x = min(max(time / duration, 0), 1)
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<20 {
            let current = 3 * (1 - t) * t * t * 0.58 + t * t * t
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return 3 * (1 - t) * t * t * 1.0 + t * t * t
    }

    /// SwiftUI's `.spring(response:dampingFraction:)` is a damped harmonic oscillator with
    /// ω₀ = 2π / response and ζ = dampingFraction, released from rest. This is that solution.
    static func spring(_ time: TimeInterval, response: TimeInterval, damping: Double) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / max(response, 0.0001)
        let zeta = max(0, damping)
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let envelope = exp(-zeta * omega * time)
            return 1 - envelope * (cos(damped * time) + (zeta * omega / damped) * sin(damped * time))
        }
        // Critically damped, which is what the chart uses when clearing hover.
        return 1 - exp(-omega * time) * (1 + omega * time)
    }

    // MARK: - Shared

    private static func write(
        _ view: some View,
        frame index: Int,
        into root: URL
    ) {
        OffscreenCapture.renderPNG(
            view.environment(\.colorScheme, .dark),
            named: String(format: "frame-%04d", index),
            into: root
        )
    }

    /// Every film strip is the same loop: walk a list of states, sample each one every `step`
    /// until its span runs out, and number the frames continuously across all of them.
    private static func strip<State, Frame: View>(
        _ states: [State],
        into root: URL,
        named name: String,
        span: (State) -> TimeInterval,
        frame: (State, TimeInterval) -> Frame
    ) {
        var index = 0
        for state in states {
            let duration = span(state)
            var time: TimeInterval = 0
            while time < duration {
                Self.write(frame(state, time), frame: index, into: root)
                time += Self.step
                index += 1
            }
        }
        print("wrote \(index) \(name) frames to \(root.path)")
    }

    // MARK: - Settings tab pill

    /// `--dump-tab-switch <dir>`: General to Pricing and back, on the two edge durations the real
    /// pill uses. The whole point is the gap between them, so the hold at each end is short.
    static func dumpTabSwitch(directory: String) {
        let root = OffscreenCapture.directory(directory)
        let travel = max(TabSwitchMotion.leadDuration, TabSwitchMotion.trailDuration)
        let hold: TimeInterval = 0.55

        Self.strip([true, false], into: root, named: "tab switch") { _ in travel + hold } frame: {
            TabPillFrame(elapsed: min($1, travel), movingRight: $0)
        }
    }

    // MARK: - Pricing disclosure

    /// `--dump-disclosure <dir>`: a group unfolding four rows on the open curve, one stagger beat
    /// apart, with the control taking the press spring on the way in.
    static func dumpDisclosure(directory: String) {
        let root = OffscreenCapture.directory(directory)
        let rows = 4
        let opening = DisclosureMotion.openDuration + DisclosureMotion.rowDelay(index: rows - 1)
        let hold: TimeInterval = 0.7

        Self.strip([true, false], into: root, named: "disclosure") { _ in opening + hold } frame: {
            DisclosureFrame(elapsed: $1, isOpening: $0, rows: rows)
        }
    }

    // MARK: - Cost chart highlight

    /// `--dump-chart-motion <dir>`: the highlight moving between bars. The last move samples the
    /// critically damped timing used when the app clears hover.
    static func dumpChartMotion(directory: String) {
        let root = OffscreenCapture.directory(directory)
        // The last move uses the clear-hover timing so the film strip includes both curves.
        let moves: [(from: Int, to: Int?, response: Double, damping: Double)] = [
            (7, 1, CostChartHoverMotion.hoverResponse, CostChartHoverMotion.hoverDamping),
            (1, 2, CostChartHoverMotion.hoverResponse, CostChartHoverMotion.hoverDamping),
            (2, 5, CostChartHoverMotion.hoverResponse, CostChartHoverMotion.hoverDamping),
            (5, nil, CostChartHoverMotion.clearResponse, CostChartHoverMotion.clearDamping),
        ]

        // Each move runs long enough for the envelope to be invisible: e^(-ζω₀t) under a thousandth.
        Self.strip(moves, into: root, named: "chart motion") { $0.response * 1.6 } frame: { move, time in
            ChartHighlightFrame(
                from: Double(move.from),
                to: move.to.map(Double.init),
                progress: Self.spring(time, response: move.response, damping: move.damping)
            )
        }
    }

    // MARK: - Cost chart label

    /// `--dump-label-toggle <dir>`: a click on the highlighted bar swapping its label between
    /// tokens and cost, twice, on the shipped blur-and-resolve. The click changes the chart's
    /// height metric as well as the reading, so the bars rescale under the label on the same
    /// curve.
    static func dumpLabelToggle(directory: String) {
        let root = OffscreenCapture.directory(directory)
        let hold: TimeInterval = 0.9

        Self.strip([CostChartLabelMode.cost, .tokens], into: root, named: "label toggle") { _ in
            CostChartHoverMotion.swapDuration + hold
        } frame: { mode, time in
            ChartLabelSwapFrame(
                mode: mode,
                progress: Self.easeOut(time, duration: CostChartHoverMotion.swapDuration)
            )
        }
    }
}

// MARK: - Frames

/// The two edges of the selection pill, each on its own duration. Segment widths are fixed here
/// rather than measured from the labels, which is the one thing the real control does differently.
private struct TabPillFrame: View {
    let elapsed: TimeInterval
    let movingRight: Bool

    private static let segments: [(title: String, width: CGFloat)] = [
        ("General", 92), ("Pricing", 88),
    ]
    private static let gap: CGFloat = 2
    private static let height: CGFloat = 28

    private var bounds: [(minX: CGFloat, maxX: CGFloat)] {
        var x: CGFloat = 0
        return Self.segments.map { segment in
            let rect = (minX: x, maxX: x + segment.width)
            x += segment.width + Self.gap
            return rect
        }
    }

    private var pill: (minX: CGFloat, maxX: CGFloat) {
        let source = self.bounds[self.movingRight ? 0 : 1]
        let destination = self.bounds[self.movingRight ? 1 : 0]
        let durations = TabSwitchMotion.edgeDurations(movingRight: self.movingRight)
        let minX = MotionFilmStrip.curve(self.elapsed, duration: durations.minX)
        let maxX = MotionFilmStrip.curve(self.elapsed, duration: durations.maxX)
        return (
            minX: source.minX + (destination.minX - source.minX) * minX,
            maxX: source.maxX + (destination.maxX - source.maxX) * maxX
        )
    }

    /// The label weights trade places on the open curve, the way the real segments cross-fade a
    /// semibold copy over a regular one.
    private func selectedness(_ index: Int) -> Double {
        let arriving = MotionFilmStrip.curve(self.elapsed, duration: DisclosureMotion.openDuration)
        let destination = self.movingRight ? 1 : 0
        return index == destination ? arriving : 1 - arriving
    }

    var body: some View {
        let pill = self.pill
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: pill.maxX - pill.minX, height: Self.height)
                .offset(x: pill.minX)

            HStack(spacing: Self.gap) {
                ForEach(Array(Self.segments.enumerated()), id: \.offset) { index, segment in
                    ZStack {
                        Text(segment.title).font(.system(size: 13, weight: .semibold))
                            .opacity(self.selectedness(index))
                        Text(segment.title).font(.system(size: 13, weight: .regular))
                            .opacity(1 - self.selectedness(index))
                    }
                    .foregroundStyle(Color.white.opacity(0.55 + 0.45 * self.selectedness(index)))
                    .frame(width: segment.width, height: Self.height)
                }
            }
        }
        .frame(width: 320, height: 76)
        .background(OffscreenCapture.groundColor)
    }
}

/// A pricing group unrolling its rows. Row height, stagger and the chevron's quarter turn are the
/// shipped numbers; the row contents are a sketch of the real table.
private struct DisclosureFrame: View {
    let elapsed: TimeInterval
    let isOpening: Bool
    let rows: Int

    private static let names = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5"]
    private static let rates = [("5", "25"), ("2", "10"), ("0.5", "2.5"), ("10", "50")]
    private static let rowHeight: CGFloat = 34

    /// How far a row has arrived, 0...1. Closing runs the same curve backwards, and without the
    /// stagger: a group folding away is one movement, not four.
    private func arrival(_ index: Int) -> Double {
        guard self.isOpening else {
            return 1 - MotionFilmStrip.curve(self.elapsed, duration: DisclosureMotion.openDuration)
        }
        let delay = DisclosureMotion.rowDelay(index: index)
        return MotionFilmStrip.curve(self.elapsed - delay, duration: DisclosureMotion.openDuration)
    }

    private var openness: Double {
        self.isOpening
            ? MotionFilmStrip.curve(self.elapsed, duration: DisclosureMotion.openDuration)
            : 1 - MotionFilmStrip.curve(self.elapsed, duration: DisclosureMotion.openDuration)
    }

    /// The control dips under the pointer and comes back on the settle spring. Only the control:
    /// a table that overshoots its own height pushes every row below it.
    private var pressScale: Double {
        let press = MotionFilmStrip.spring(
            self.elapsed,
            response: DisclosureMotion.pressResponse,
            damping: DisclosureMotion.pressDamping
        )
        return 0.94 + 0.06 * press
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(90 * self.openness))
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Text("\(self.rows)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
                Spacer(minLength: 0)
            }
            .scaleEffect(self.pressScale, anchor: .leading)
            .frame(height: 30)

            ForEach(0..<self.rows, id: \.self) { index in
                let arrival = self.arrival(index)
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(Self.names[index]).font(.system(size: 12))
                    Spacer(minLength: 0)
                    ForEach([Self.rates[index].0, Self.rates[index].1], id: \.self) { rate in
                        Text(rate)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 54, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                }
                .padding(.leading, 14)
                .frame(height: Self.rowHeight * arrival)
                .opacity(arrival)
                .clipped()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 420, height: 200, alignment: .top)
        .background(OffscreenCapture.groundColor)
    }
}

/// The chart's highlight between two bars. Tone and the mark under the baseline cross over
/// together, because the highlight is meant to read as one shape moving rather than as one bar
/// dimming and another brightening. Only the mark moves: the bars keep the heights they are being
/// compared on.
private struct ChartHighlightFrame: View {
    let from: Double
    let to: Double?
    let progress: Double

    private static let values: [Double] = [62, 90, 48, 71, 9, 88, 41, 37]
    private static let days = ["Aug 17", "Aug 18", "Aug 19", "Aug 20", "Aug 21", "Aug 22", "Aug 23", "Aug 24"]
    private static let barWidth: CGFloat = 30
    private static let maxHeight: CGFloat = 84

    private var position: Double {
        guard let to = self.to else { return self.from }
        return self.from + (to - self.from) * self.progress
    }

    private var clearShare: Double {
        min(1, max(0, 1 - self.progress))
    }

    /// How highlighted one bar is: 1 when the moving position is on it, 0 a whole bar away.
    private func share(_ index: Int) -> Double {
        if self.to == nil {
            return index == Int(self.from.rounded()) ? self.clearShare : 0
        }
        return max(0, 1 - abs(self.position - Double(index)))
    }

    /// The label belongs to whichever bar the highlight is closest to, so it never reads out a
    /// day the highlight has already left.
    private var label: String {
        let index = min(Self.values.count - 1, max(0, Int(self.position.rounded())))
        return "\(Self.days[index]) · $\(Int(Self.values[index])).00 · \(Int(Self.values[index]))M tokens"
    }

    var body: some View {
        let tint = Theme.accent(for: .claude)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(Self.values.enumerated()), id: \.offset) { index, value in
                    let share = self.share(index)
                    VStack(spacing: CostChartHoverMotion.markerGap) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(tint.opacity(
                                CostChartHighlightPolicy.restingOpacity
                                    + (1 - CostChartHighlightPolicy.restingOpacity) * share
                            ))
                            .frame(width: Self.barWidth, height: Self.maxHeight * value / 90)
                        Capsule(style: .continuous)
                            .fill(tint)
                            .frame(width: Self.barWidth, height: CostChartHoverMotion.markerHeight)
                            .scaleEffect(x: CostChartHoverMotion.markerWidth(share: share), y: 1)
                            .opacity(share)
                    }
                }
            }
            Text(self.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .opacity(0.9 * (self.to == nil ? self.clearShare : 1))
        }
        .padding(18)
        .frame(width: 340, height: 160, alignment: .bottomLeading)
        .background(OffscreenCapture.groundColor)
    }
}

/// The highlighted bar's label changing unit, and the whole chart rescaling under it. The layout
/// is the stand-in; the readings and the heights are not. The text comes from
/// `CostChartHighlightPolicy`, the two readings are drawn through the same `LabelResolve` the
/// shipped transition ends on, and every bar is scaled by `CostChartHighlightPolicy.value` against
/// that metric's own maximum, which is the height the shipped chart animates to on the same click.
private struct ChartLabelSwapFrame: View {
    /// The unit arriving. The one leaving is the other one; there are only two.
    let mode: CostChartLabelMode
    let progress: Double

    /// A week the two metrics disagree about, because a cheap model spends tokens a dear one does
    /// not: the tallest token day is the second, the tallest cost day is the third. A fixture that
    /// read the same in both units would hold the chart still and show half of what the click does.
    /// The selected day is the one place they agree, at 37M tokens and $37, so the two readings are
    /// the same length and the swap is worth watching rather than a change of width.
    private static let fixture: [(tokensM: Double, costUSD: Double)] = [
        (62, 18), (90, 24), (48, 40), (71, 30), (9, 7), (88, 22), (41, 35), (37, 37),
    ]
    private static let chartHeight: CGFloat = 56
    private static let spacing: CGFloat = 4
    private static let chartWidth: CGFloat = 252

    private static let days: [CostDay] = Self.fixture.enumerated().map { index, day in
        CostDay(
            dayKey: String(format: "2026-08-%02d", 17 + index),
            byModel: [
                ModelUsageKey(source: .claude, model: "opus-5"): ModelDayUsage(
                    tokens: TokenTotals(input: Int(day.tokensM * 1_000_000)),
                    costUSD: day.costUSD
                ),
            ],
            costUSD: day.costUSD,
            unpricedTokens: 0
        )
    }

    private func text(for mode: CostChartLabelMode) -> some View {
        let day = Self.days[Self.days.count - 1]
        return Text(CostChartHighlightPolicy.labelText(
            selectedMode: mode,
            tokens: day.tokens.total,
            costUSD: day.costUSD
        ))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.primary)
        .fixedSize()
    }

    private var label: some View {
        ZStack {
            self.text(for: self.mode == .tokens ? .cost : .tokens)
                .modifier(LabelResolve(progress: self.progress))
            self.text(for: self.mode)
                .modifier(LabelResolve(progress: 1 - self.progress))
        }
    }

    /// Height as a share of the chart, interpolated on the swap's own progress. The shipped bars
    /// get there the same way: the mode flips inside `withAnimation`, so SwiftUI runs the frame
    /// from the old metric's ratio to the new one over the curve the label resolves on.
    private func ratio(for day: CostDay) -> Double {
        let leaving = self.mode == .tokens ? CostChartLabelMode.cost : .tokens
        return Self.ratio(for: day, mode: leaving)
            + (Self.ratio(for: day, mode: self.mode) - Self.ratio(for: day, mode: leaving))
            * self.progress
    }

    private static func ratio(for day: CostDay, mode: CostChartLabelMode) -> Double {
        let maxValue = CostChartHighlightPolicy.maxValue(for: Self.days, mode: mode)
        guard maxValue > 0 else { return 0 }
        return CostChartHighlightPolicy.value(for: day, mode: mode) / maxValue
    }

    var body: some View {
        let tint = Theme.accent(for: .claude)
        return HStack(alignment: .bottom, spacing: Self.spacing) {
            ForEach(Array(Self.days.enumerated()), id: \.offset) { index, day in
                let isSelected = index == Self.days.count - 1
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .opacity(isSelected ? 1 : CostChartHighlightPolicy.restingOpacity)
                    .frame(height: max(4, Self.chartHeight * self.ratio(for: day)))
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(tint)
                                .frame(height: CostChartHoverMotion.markerHeight)
                                .offset(y: CostChartHoverMotion.markerBand)
                        }
                    }
                    .overlay(alignment: .top) {
                        if isSelected { self.label.offset(y: -14) }
                    }
            }
        }
        .frame(width: Self.chartWidth, height: Self.chartHeight)
        // Room for the label above and the mark below, the way the card reserves them.
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 12 + CostChartHoverMotion.markerBand)
        .frame(width: 280, alignment: .bottom)
        .background(OffscreenCapture.groundColor)
    }
}
#endif
