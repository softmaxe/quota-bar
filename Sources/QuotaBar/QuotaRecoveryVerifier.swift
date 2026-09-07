#if DEBUG
import QuotaBarCore
import AppKit
import Foundation
import SwiftUI

/// No XCTest without Xcode, so reset detection, persistence, and animation curves are asserted
/// from a launch flag the way the fill policy and chart highlighting are.
enum QuotaRecoveryVerifier {
    @MainActor
    static func run() -> Never {
        var failures: [String] = []
        failures += Self.trackerFailures()
        failures += Self.choreographyFailures()
        failures += Self.relayFailures()
        return VerifierReport.finish(
            failures,
            label: "quota recovery verification",
            passed: "quota reset detection, five-hour/weekly hand-off, persistence, and shared animation passed"
        )
    }

    // MARK: - Tracker

    @MainActor
    private static func trackerFailures() -> [String] {
        var failures: [String] = []
        let suite = "QuotaBarQuotaRecoveryVerifier"
        let defaults = EphemeralDefaults.make(suite)
        defer { EphemeralDefaults.clear(suite) }

        let tracker = QuotaRecoveryTracker(defaults: defaults)
        let epoch = Date(timeIntervalSince1970: 2_000_000_000)
        let first = Self.snapshot(
            provider: .claude,
            sessionRemaining: 37,
            sessionReset: epoch.addingTimeInterval(5 * 3600),
            weeklyRemaining: 62,
            weeklyReset: epoch.addingTimeInterval(7 * 24 * 3600)
        )
        tracker.observe(snapshot: first)
        if !tracker.pendingRecoveries(for: .claude).isEmpty {
            failures.append("the first reading was mistaken for a reset")
        }

        let spent = Self.snapshot(
            provider: .claude,
            sessionRemaining: 23,
            sessionReset: epoch.addingTimeInterval(5 * 3600),
            weeklyRemaining: 51,
            weeklyReset: epoch.addingTimeInterval(7 * 24 * 3600)
        )
        tracker.observe(snapshot: spent)
        if !tracker.pendingRecoveries(for: .claude).isEmpty {
            failures.append("ordinary spending with the same reset identity queued an animation")
        }

        let reset = Self.snapshot(
            provider: .claude,
            sessionRemaining: 100,
            sessionReset: epoch.addingTimeInterval(10 * 3600),
            weeklyRemaining: 100,
            weeklyReset: epoch.addingTimeInterval(14 * 24 * 3600)
        )
        tracker.observe(snapshot: reset)
        let expected: [QuotaWindowKind: QuotaRecoveryEvent] = [
            .session: QuotaRecoveryEvent(fromRemainingPercent: 23),
            .weekly: QuotaRecoveryEvent(fromRemainingPercent: 51),
        ]
        if tracker.pendingRecoveries(for: .claude) != expected {
            failures.append("five-hour and weekly resets did not independently preserve their starting values")
        }
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("one provider's reset leaked into the other")
        }

        // Later polls must update the baseline without discarding a reset the card has not shown.
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 98,
            resetsAt: epoch.addingTimeInterval(10 * 3600)
        )
        if tracker.pendingRecoveries(for: .claude) != expected {
            failures.append("a later poll dropped a queued reset animation")
        }

        // Both the baseline and pending payload survive a process restart.
        let restarted = QuotaRecoveryTracker(defaults: defaults)
        if restarted.pendingRecoveries(for: .claude) != expected {
            failures.append("pending reset animations did not survive a restart")
        }
        if restarted.consumePending(for: .claude) != expected {
            failures.append("the card was not handed both reset windows with their starting values")
        }
        if !restarted.consumePending(for: .claude).isEmpty {
            failures.append("a reset animation was handed out twice")
        }

        // A large percentage jump alone is not a reset; the provider's reset identity is.
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 12,
            resetsAt: epoch.addingTimeInterval(5 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(5 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("a percentage jump with an unchanged reset identity was treated as a reset")
        }

        // A reset identity moving forward is not enough on its own. Codex can report a later
        // identity while the remaining quota has fallen, which must stay on the ordinary glide
        // path instead of playing a celebration backwards from 100% to the current reading.
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(10 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 62,
            resetsAt: epoch.addingTimeInterval(15 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("a forward reset identity with quota falling from 100 to 62 queued an animation")
            _ = tracker.consumePending(for: .codex)
        }

        // Claude reports the five-hour deadline it has already passed until real usage opens the
        // next window, so the quota returns to 100 several polls before the identity moves. The
        // recovery has to be caught at that reading, and must survive the identity catching up.
        let lagging = epoch.addingTimeInterval(20 * 3600)
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 3,
            resetsAt: lagging,
            now: lagging.addingTimeInterval(-600)
        )
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 100,
            resetsAt: lagging,
            now: lagging.addingTimeInterval(140)
        )
        let laggingExpected: [QuotaWindowKind: QuotaRecoveryEvent] = [
            .session: QuotaRecoveryEvent(fromRemainingPercent: 3),
        ]
        if tracker.pendingRecoveries(for: .claude) != laggingExpected {
            failures.append("a five-hour window recovering past its own deadline queued no animation")
        }
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 94,
            resetsAt: lagging.addingTimeInterval(5 * 3600),
            now: lagging.addingTimeInterval(900)
        )
        if tracker.pendingRecoveries(for: .claude) != laggingExpected {
            failures.append("the identity catching up to a recovery already seen dropped its animation")
        }
        _ = tracker.consumePending(for: .claude)

        // Two rollovers with the first one never shown: the unobserved second window supersedes
        // the stale event instead of animating from a window that is two resets old.
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 8,
            resetsAt: epoch.addingTimeInterval(30 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(35 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(40 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 71,
            resetsAt: epoch.addingTimeInterval(45 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("an event two rollovers old was still queued")
            _ = tracker.consumePending(for: .codex)
        }

        // An older response must not move the identity backwards and manufacture a future reset.
        tracker.observe(
            provider: .codex,
            kind: .weekly,
            remainingPercent: 44,
            resetsAt: epoch.addingTimeInterval(14 * 24 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .weekly,
            remainingPercent: 80,
            resetsAt: epoch.addingTimeInterval(7 * 24 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .weekly,
            remainingPercent: 43,
            resetsAt: epoch.addingTimeInterval(14 * 24 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("a stale response manufactured a weekly reset")
        }

        return failures
    }

    private static func snapshot(
        provider: Provider,
        sessionRemaining: Double,
        sessionReset: Date,
        weeklyRemaining: Double,
        weeklyReset: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            session: UsageWindow(
                usedPercent: 100 - sessionRemaining,
                resetsAt: sessionReset,
                windowSeconds: 5 * 3600
            ),
            weekly: UsageWindow(
                usedPercent: 100 - weeklyRemaining,
                resetsAt: weeklyReset,
                windowSeconds: 7 * 24 * 3600
            ),
            planLabel: nil,
            credits: nil,
            fetchedAt: Date()
        )
    }

    // MARK: - Choreography

    private static func choreographyFailures() -> [String] {
        Self.fillFailures() + Self.landingFailures() + Self.replayFailures() + Self.headlineFailures()
    }

    /// What the headline above the bar owes the same timeline: the digits are the fill's own
    /// easing, the blur belongs to the charge and nothing else, and every landing effect is over
    /// when the clock stops.
    private static func headlineFailures() -> [String] {
        var failures: [String] = []
        let landing = QuotaCelebration.landing
        let duration = QuotaCelebration.duration

        if QuotaNumberMotion.speed(at: 0) != 1 {
            failures.append("the headline blur did not peak at the start of the charge")
        }
        if QuotaNumberMotion.speed(at: landing * 0.5) >= QuotaNumberMotion.speed(at: landing * 0.1) {
            failures.append("the headline blur did not decay with the count")
        }
        if QuotaNumberMotion.speed(at: landing) != 0 || QuotaNumberMotion.speed(at: duration) != 0 {
            failures.append("the headline was still blurred once the count had landed")
        }

        if QuotaNumberMotion.flash(at: landing - 0.01) != 0 {
            failures.append("the headline washed warm before the landing")
        }
        if QuotaNumberMotion.flash(at: landing) <= 0 {
            failures.append("the headline did not take the landing beat")
        }
        if QuotaNumberMotion.glow(at: landing - 0.01) != nil {
            failures.append("the headline bloom rose before the landing")
        }
        if QuotaNumberMotion.glow(at: landing + 0.05) == nil {
            failures.append("the headline bloom did not rise on the landing")
        }

        if QuotaNumberMotion.scale(at: landing) != 1 {
            failures.append("the headline pop did not start from rest on the landing")
        }
        if QuotaNumberMotion.scale(at: landing + 0.1) <= 1 {
            failures.append("the headline did not overshoot after the landing")
        }
        if QuotaNumberMotion.scale(at: duration) != 1
            || QuotaNumberMotion.flash(at: duration) != 0
            || QuotaNumberMotion.glow(at: duration) != nil {
            failures.append("the headline was still animating when the clock stopped")
        }

        return failures
    }

    private static func fillFailures() -> [String] {
        var failures: [String] = []
        let start = 37.0

        if QuotaCelebration.fillPercent(at: 0, from: start, to: 100) != start {
            failures.append("the reset animation did not start at the pre-reset reading")
        }
        if QuotaCelebration.fillPercent(at: QuotaCelebration.landing, from: start, to: 100) != 100 {
            failures.append("the reset animation did not finish at 100")
        }

        var previousValue = start
        var previousStep = Double.infinity
        for step in 1...200 {
            let value = QuotaCelebration.fillPercent(
                at: QuotaCelebration.landing * Double(step) / 200,
                from: start,
                to: 100
            )
            if value < previousValue - 1e-9 {
                failures.append("the reset fill went backwards at \(step)/200")
                break
            }
            let delta = value - previousValue
            if delta > previousStep + 1e-8 {
                failures.append("the reset fill sped up instead of continuously slowing at \(step)/200")
                break
            }
            previousValue = value
            previousStep = delta
        }
        if QuotaCelebration.fillFraction(at: QuotaCelebration.landing * 0.2) < 0.6 {
            failures.append("the continuous curve did not start fast enough")
        }
        return failures
    }

    /// The bar is 252 pt wide inside a 280 pt card, so it has 14 pt of margin on each side.
    private static let barWidth: CGFloat = 252
    private static let cardMargin: CGFloat = 14

    /// What the landing owes the card: nothing before the head arrives, the pop, flash and glow
    /// all on the beat it does, nothing left when the clock stops, and a glow already invisible
    /// where the card cuts it off.
    private static func landingFailures() -> [String] {
        var failures: [String] = []
        let landing = QuotaCelebration.landing
        let beat = landing + 0.02

        if QuotaCelebration.flashOpacity(at: beat) <= 0 {
            failures.append("the landing flash did not share the final beat")
        }
        if QuotaCelebration.barScale(at: beat).height <= 1 {
            failures.append("the bar did not start enlarging on the final beat")
        }
        if QuotaCelebration.glows(at: beat, barWidth: Self.barWidth).count < 2 {
            failures.append("both glows did not rise on the beat the head arrived")
        }
        if !QuotaCelebration.glows(at: landing - 0.01, barWidth: Self.barWidth).isEmpty {
            failures.append("the glow appeared before the head reached 100%")
        }
        if QuotaCelebration.head(at: landing) != nil {
            failures.append("the charging head outlived the sweep that carried it")
        }
        if QuotaCelebration.head(at: landing - 0.01)?.coreOpacity ?? 1 > 0.1 {
            failures.append("the charging head switched off instead of fading into the landing")
        }

        let duration = QuotaCelebration.duration
        if !QuotaCelebration.glows(at: duration, barWidth: Self.barWidth).isEmpty
            || QuotaCelebration.flashOpacity(at: duration) > 0
            || QuotaCelebration.barScale(at: duration) != CGSize(width: 1, height: 1) {
            failures.append("the landing was still on screen when the clock stopped")
        }

        // A glow has no edge, so what matters is that it is already invisible where the card
        // stops rather than that it fits inside it.
        var time = landing
        while time <= duration {
            for glow in QuotaCelebration.glows(at: time, barWidth: Self.barWidth) {
                for edge in [-Double(Self.cardMargin), Double(Self.barWidth + Self.cardMargin)] {
                    let distance = abs(edge - Double(glow.centre.x))
                    let alpha = glow.opacity * max(0, 1 - distance / Double(glow.radiusX))
                    if alpha > 0.05 {
                        failures.append("a glow was still visible where the card cuts it off")
                    }
                }
            }
            time += 0.01
        }
        return Array(Set(failures)).sorted()
    }

    private static func replayFailures() -> [String] {
        var failures: [String] = []
        let start = 37.0

        if QuotaCelebrationReplay.fillPercent(at: 0, from: start, to: start) != start {
            failures.append("the five-click replay did not start at the live reading")
        }
        if QuotaCelebrationReplay.fillPercent(
            at: QuotaCelebration.duration,
            from: start,
            to: start
        ) != 100 {
            failures.append("the five-click replay did not finish the real reset animation")
        }
        if QuotaCelebrationReplay.fillPercent(
            at: QuotaCelebrationReplay.duration,
            from: start,
            to: start
        ) != start {
            failures.append("the five-click replay did not return to the live reading")
        }

        var previousReturnValue = 100.0
        for step in 1...100 {
            let time = QuotaCelebration.duration
                + QuotaCelebrationReplay.returnDuration * Double(step) / 100
            let value = QuotaCelebrationReplay.fillPercent(at: time, from: start, to: start)
            if value > previousReturnValue + 1e-9 {
                failures.append("the five-click replay reversed direction during its return")
                break
            }
            previousReturnValue = value
        }

        let returnMiddle = QuotaCelebration.duration + QuotaCelebrationReplay.returnDuration / 2
        if QuotaCelebrationReplay.opacity(at: QuotaCelebration.duration) != 1
            || QuotaCelebrationReplay.opacity(at: returnMiddle) >= 1
            || QuotaCelebrationReplay.opacity(at: QuotaCelebrationReplay.duration) != 1 {
            failures.append("the five-click replay did not fade out and back in during its return")
        }

        return failures
    }

    // MARK: - Relay

    /// The headline renders from frames the bar publishes, so the wiring between them is worth an
    /// assertion of its own: the maths above all still pass if nothing is ever handed over.
    @MainActor
    private static func relayFailures() -> [String] {
        // Reduce Motion turns the celebration off entirely, and with it the frames this checks for.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return [] }

        var failures: [String] = []
        let relay = QuotaCelebrationRelay()
        let start = 20.0
        let hosting = NSHostingView(rootView: UsageProgressBar(
            percent: 100,
            tint: .orange,
            celebrationToken: 1,
            celebrationStartPercent: start,
            celebrationRelay: relay
        ).frame(width: Self.barWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.barWidth, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        guard let frame = relay.frame else {
            window.orderOut(nil)
            return ["the bar published no frame for the headline to render"]
        }
        if frame.elapsed <= 0 {
            failures.append("the published frame never advanced past the first instant")
        }
        if frame.percent <= start || frame.percent > 100 {
            failures.append("the published frame carried \(frame.percent), outside the charge")
        }
        if frame.isReplay {
            failures.append("a real reset was published as a five-click replay")
        }
        if abs(frame.percent - QuotaCelebration.fillPercent(at: frame.elapsed, from: start, to: 100)) > 1e-9 {
            failures.append("the published percentage was not the percentage the fill was drawing")
        }

        // Closing the card has to end the sequence for the headline too, or the number would be
        // left mid-count the next time the menu opens.
        window.contentView = nil
        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if relay.frame != nil {
            failures.append("the headline was left mid-animation after the bar went away")
        }
        return failures
    }
}
#endif
