import SwiftUI

/// Card motion adopted from the Claude desktop app's component system: content that reveals,
/// values that roll, work that pulses, and confirmations that resolve. Every effect is short,
/// stays off layout, and turns into a cut under Reduce Motion or in the offscreen card dump.
enum CardMotion {
    // MARK: - Reveal

    /// Disclosure content rises this far while it fades in. The height itself still cuts.
    static let revealOffset: CGFloat = 4
    static let revealDuration: TimeInterval = 0.2
    static var revealCurve: Animation {
        .timingCurve(0.165, 0.84, 0.44, 1, duration: Self.revealDuration)
    }

    /// Fresh local usage replacing its placeholder fades in over this long.
    static let placeholderRevealDuration: TimeInterval = 0.15

    // MARK: - Roll

    /// A changed value leaves and the new one rolls in from the direction it moved.
    static let rollDuration: TimeInterval = 0.12
    static var rollCurve: Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: Self.rollDuration)
    }

    // MARK: - Provider switch

    /// The new provider's content enters from the side its tab sits on.
    static let slideDistance: CGFloat = 12
    static var slideCurve: Animation { Self.revealCurve }

    // MARK: - Press

    /// Compact controls squish further than full-width rows, which read as cards.
    static let pressScale: CGFloat = 0.975
    static let rowPressScale: CGFloat = 0.99
    static var pressCurve: Animation { .easeOut(duration: 0.06) }
    /// Release overshoots slightly, close to the CDS button spring's 9% peak.
    static var releaseSpring: Animation { .spring(duration: 0.45, bounce: 0.4) }

    // MARK: - Working dots

    static let dotPeriod: TimeInterval = 1.8
    static let dotStep: TimeInterval = 0.2
    static let dotRestingOpacity = 0.2857

    /// One dot's opacity: rests dim, brightens quickly, holds, then fades back.
    static func dotOpacity(at time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: Self.dotPeriod)
        let progress = (phase < 0 ? phase + Self.dotPeriod : phase) / Self.dotPeriod
        let low = Self.dotRestingOpacity
        switch progress {
        case ..<0.05: return low
        case ..<0.15: return low + (1 - low) * (progress - 0.05) / 0.10
        case ..<0.25: return 1
        case ..<0.65: return 1 - (1 - low) * (progress - 0.25) / 0.40
        default: return low
        }
    }

    // MARK: - Skeleton

    /// A scan that finishes sooner never shows a placeholder at all.
    static let skeletonHold: TimeInterval = 0.5
    static let breathePeriod: TimeInterval = 2
    static let breatheWave: TimeInterval = 0.09

    static func breatheOpacity(at time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: Self.breathePeriod) / Self.breathePeriod
        return 0.8 + 0.2 * cos(2 * .pi * phase)
    }

    // MARK: - Resolve

    static let resolveDuration: TimeInterval = 0.45
    /// How long a confirmation stays before the control returns to its resting label.
    static let confirmationHold: TimeInterval = 1.6
}

private struct CardMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False for offscreen captures, which need every view at rest on their only frame.
    var cardMotionEnabled: Bool {
        get { self[CardMotionEnabledKey.self] }
        set { self[CardMotionEnabledKey.self] = newValue }
    }
}

/// Reads both switches that turn card motion into a cut.
private struct CardMotionGate: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cardMotionEnabled) private var enabled

    var animates: Bool { self.enabled && !self.reduceMotion }
}

// MARK: - Reveal

/// Content that arrives inside a card that is already open: it rises a few points and fades in.
/// `active` is read when the content first appears, so a card that opens with the content
/// already there shows it at rest.
private struct RevealOnAppear: ViewModifier {
    let active: Bool
    let offset: CGFloat
    let animation: Animation
    private let gate = CardMotionGate()
    @State private var revealed = false

    func body(content: Content) -> some View {
        let settled = self.revealed || !self.active || !self.gate.animates
        content
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : self.offset)
            .onAppear {
                withAnimation(self.animation) { self.revealed = true }
            }
    }
}

extension View {
    /// Disclosure and sign-in content: a 4 pt rise with a fade.
    func cardReveal(active: Bool = true) -> some View {
        self.modifier(RevealOnAppear(active: active, offset: CardMotion.revealOffset, animation: CardMotion.revealCurve))
    }

    /// Fresh local usage replacing its placeholder: a fade only.
    func placeholderReveal(active: Bool) -> some View {
        self.modifier(RevealOnAppear(
            active: active,
            offset: 0,
            animation: .easeOut(duration: CardMotion.placeholderRevealDuration)
        ))
    }
}

// MARK: - Roll

private struct RollingValue<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let direction: Double?
    private let gate = CardMotionGate()

    func body(content: Content) -> some View {
        content
            .contentTransition(self.transition)
            .animation(self.gate.animates ? CardMotion.rollCurve : nil, value: self.trigger)
    }

    private var transition: ContentTransition {
        guard self.gate.animates else { return .identity }
        return self.direction.map { .numericText(value: $0) } ?? .numericText()
    }
}

extension View {
    /// Rolls a text's glyphs when `trigger` changes. `direction` decides whether they roll up
    /// (an increase) or down; without one they roll up.
    func rollingValue(_ trigger: some Equatable, direction: Double? = nil) -> some View {
        self.modifier(RollingValue(trigger: trigger, direction: direction))
    }
}

// MARK: - Provider switch

extension AnyTransition {
    /// The new provider's content enters from its tab's side; the old one leaves at once, so the
    /// card never shows both.
    static func providerSlide(fromTrailing: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .offset(x: fromTrailing ? CardMotion.slideDistance : -CardMotion.slideDistance)
                .combined(with: .opacity)
                .animation(CardMotion.slideCurve),
            removal: .identity
        )
    }
}

// MARK: - Working dots

/// Three dots pulsing in sequence while a request is in flight.
struct WorkingDots: View {
    private let gate = CardMotionGate()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !self.gate.animates)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 3, height: 3)
                        .opacity(self.gate.animates
                            ? CardMotion.dotOpacity(at: time - Double(index) * CardMotion.dotStep)
                            : 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A progress label: the title without its ellipsis, followed by the dots.
struct WorkingLabel: View {
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            Text(self.title.hasSuffix("…") ? String(self.title.dropLast()) : self.title)
            WorkingDots()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.title)
    }
}

// MARK: - Resolve check

/// A confirmation glyph: a rounded square draws itself, fills, and its tick turns white.
struct ResolveCheck: View {
    let tint: Color
    var size: CGFloat = 11
    private let gate = CardMotionGate()
    @State private var progress = 0.0

    var body: some View {
        ResolveGlyph(progress: self.gate.animates ? self.progress : 1, tint: self.tint)
            .frame(width: self.size, height: self.size)
            .onAppear {
                withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: CardMotion.resolveDuration)) {
                    self.progress = 1
                }
            }
            .accessibilityHidden(true)
    }
}

private struct ResolveGlyph: View, Animatable {
    var progress: Double
    let tint: Color

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    var body: some View {
        let outline = min(1, self.progress * 2)
        let fill = max(0, self.progress * 2 - 1)
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.fill(self.tint.opacity(fill))
            shape.trim(from: 0, to: outline).stroke(self.tint, lineWidth: 1.2)
            ResolveTick()
                .stroke(
                    self.progress >= 0.75 ? Color.white : self.tint,
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )
        }
    }
}

private struct ResolveTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.36))
        return path
    }
}

// MARK: - Skeleton

/// The local usage section before its first scan finishes. Nothing is drawn for the first half
/// second, so a quick scan goes straight from nothing to numbers; a slower one fades in shapes
/// where the numbers will be, breathing in a wave across the chart.
struct LocalUsageSkeleton: View {
    private let gate = CardMotionGate()
    @State private var visible = false

    private static let barHeights: [CGFloat] = [8, 8, 8, 8, 14, 18, 11, 16, 17, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local usage")
                .font(.system(size: 13, weight: .semibold))
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !self.gate.animates || !self.visible)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 16) {
                        self.kpi("Today", time: time)
                        self.kpi("Last 30 days", time: time)
                    }
                    Text("Last 10 calendar days")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { index, height in
                            self.block(height: height, time: time - Double(index) * CardMotion.breatheWave)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 61, alignment: .bottom)
                    self.block(width: 140, height: 18, time: time)
                }
            }
            .opacity(self.visible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            try? await Task.sleep(for: .seconds(CardMotion.skeletonHold))
            guard !Task.isCancelled else { return }
            withAnimation(self.gate.animates ? .easeOut(duration: CardMotion.placeholderRevealDuration) : nil) {
                self.visible = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scanning local usage")
    }

    private func kpi(_ label: String, time: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            self.block(width: 56, height: 16, time: time)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func block(width: CGFloat? = nil, height: CGFloat, time: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.progressTrack)
            .frame(width: width, height: height)
            .opacity(self.gate.animates ? CardMotion.breatheOpacity(at: time) : 1)
    }
}

// MARK: - Scroll edges

/// Fades the scroll view's edges by how far its content continues past them.
struct ScrollEdgeFadeMask: View {
    let top: CGFloat
    let bottom: CGFloat

    static let maximum: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: min(Self.maximum, max(0, self.top)))
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: min(Self.maximum, max(0, self.bottom)))
        }
    }
}
