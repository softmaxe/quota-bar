import Foundation
import SwiftUI

/// Popover disclosures resize once, keeping text fixed while the chevron acknowledges the click.
struct PopoverDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withTransaction(Transaction(animation: nil)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(isOpen: configuration.isExpanded, reduceMotion: self.reduceMotion)
                        .frame(width: 10, height: 12)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
#if DEBUG
            .background { QuotaLayoutProbe(identifier: "pace-disclosure") }
#endif
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Collapse details" : "Expand details")

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How the pricing table's disclosures open. Both curves are readings of what the reset
/// choreography already does — `QuotaCelebration` charges the fill on an exponential decay and
/// settles its landing on a damped sine — shortened from a celebration to the length of a click.
enum DisclosureMotion {
    /// The fill's easing as a timing curve: most of the distance early, and the last of it
    /// arriving without a stop.
    static let openDuration: TimeInterval = 0.28
    /// The landing's damped sine as a spring. Only the control under the pointer takes it: a
    /// table that overshoots its own height pushes every row below it, which reads as a layout
    /// bug rather than as a beat.
    static let pressResponse: TimeInterval = 0.34
    static let pressDamping: Double = 0.62
    /// How far apart consecutive rows arrive, so a group unrolls from under its header instead of
    /// appearing all at once.
    static let rowStagger: TimeInterval = 0.035
    /// Past this many rows the stagger stops growing. A 14-model group would otherwise still be
    /// arriving half a second after the click, and the rows that late are below the fold anyway.
    static let maxStaggeredRows = 6
    /// The provider-group header acknowledges a press without moving the table's contents.
    static let providerGroupPressScale: CGFloat = 0.985
    static let providerGroupPressDuration: TimeInterval = 0.10

    static var openCurve: Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: Self.openDuration)
    }

    static var pressCurve: Animation {
        .spring(response: Self.pressResponse, dampingFraction: Self.pressDamping)
    }

    /// The provider-group header settles with a short ease-out and no overshoot.
    static var providerGroupPressCurve: Animation {
        .easeOut(duration: Self.providerGroupPressDuration)
    }

    /// Seconds a row waits before it arrives, counted from the top of its group.
    static func rowDelay(index: Int) -> TimeInterval {
        Self.rowStagger * Double(min(max(0, index), Self.maxStaggeredRows))
    }

    /// The curve a row arrives on: the group's own easing, one beat later per row.
    static func rowArrival(index: Int) -> Animation {
        Self.openCurve.delay(Self.rowDelay(index: index))
    }

    /// Nil rather than a curve under Reduce Motion, which turns every change back into a cut.
    static func open(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Self.openCurve
    }
}

/// The disclosure control itself: one glyph taking a quarter turn, rather than two glyphs
/// swapping places. Callers set the color, because the group header and the rows inside it are
/// deliberately not the same weight.
struct DisclosureChevron: View {
    let isOpen: Bool
    var size: CGFloat = 9
    var reduceMotion = false

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: self.size, weight: .semibold))
            .rotationEffect(.degrees(self.isOpen ? 90 : 0))
            .animation(DisclosureMotion.open(reduceMotion: self.reduceMotion), value: self.isOpen)
    }
}

/// Borderless, and with a weight of its own: the control dips while the mouse is down and comes
/// back on the settle spring, so the click reads as a press rather than as the only thing that
/// happened being somewhere else on screen.
struct DisclosurePressStyle: ButtonStyle {
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!self.reduceMotion && configuration.isPressed ? 0.86 : 1)
            .animation(
                self.reduceMotion ? nil : DisclosureMotion.pressCurve,
                value: configuration.isPressed
            )
    }
}

/// A restrained press for provider-group headers. Unlike the model-row disclosure, it does not
/// use the spring that can overshoot.
struct ProviderGroupHeaderPressStyle: ButtonStyle {
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                !self.reduceMotion && configuration.isPressed
                    ? DisclosureMotion.providerGroupPressScale
                    : 1
            )
            .animation(
                self.reduceMotion ? nil : DisclosureMotion.providerGroupPressCurve,
                value: configuration.isPressed
            )
    }
}
