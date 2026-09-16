#if DEBUG
import Foundation

/// Proves disclosure timing is brief and respects Reduce Motion.
enum DisclosureMotionVerifier {
    private static let budget: TimeInterval = 0.2

    static func run() -> Never {
        Self.require(
            DisclosureMotion.openDuration > 0,
            "the opening retains a visible state change"
        )
        Self.require(
            DisclosureMotion.openDuration < Self.budget,
            "the disclosure settles in \(DisclosureMotion.openDuration)s, past the "
                + "\(Self.budget)s budget"
        )

        Self.require(
            DisclosureMotion.open(reduceMotion: true) == nil,
            "Reduce Motion turns the disclosure back into a cut"
        )
        Self.require(
            DisclosureMotion.open(reduceMotion: false) != nil,
            "the disclosure animates when motion is not reduced"
        )

        print("disclosure motion verification passed")
        exit(0)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        VerifierReport.require(condition(), message, label: "disclosure-motion verification")
    }
}
#endif
