#if DEBUG
import Foundation
import Metal

/// Command Line Tools ship no XCTest, so the suite is a set of launch flags and every `--verify-*`
/// run ends the same way: name what passed and exit 0, or put each failure on stderr and exit 1.
/// `VerifierReport` owns that ending, which leaves each verifier holding only its own checks.
enum VerifierReport {
    /// Ends a run that collects its failures and reports them together. `label` names the check in
    /// the failure lines; `passed` is the one-line summary printed when there are none.
    static func finish(_ failures: [String], label: String, passed: String) -> Never {
        guard failures.isEmpty else {
            for failure in failures {
                fputs("\(label) failed: \(failure)\n", stderr)
            }
            exit(1)
        }
        print(passed)
        exit(0)
    }

    /// Ends a run that cannot usefully continue past its first failure.
    static func fail(_ message: String, label: String) -> Never {
        Self.report(message, label: label)
        exit(1)
    }

    /// Fails the run unless `condition` holds, for a verifier that checks one thing at a time.
    static func require(_ condition: @autoclosure () -> Bool, _ message: String, label: String) {
        guard condition() else { Self.fail(message, label: label) }
    }

    /// Writes one failure line without ending the process, for a verifier with cleanup of its own
    /// to do first — `exit()` terminates without unwinding the stack, so `defer` never runs.
    static func report(_ message: String, label: String) {
        fputs("\(label) failed: \(message)\n", stderr)
    }
}

/// A throwaway defaults domain, so a verifier never reads or writes the user's real preferences.
/// The suite name is fixed rather than PID-stamped: a run that dies before its cleanup leaves one
/// domain behind for the next run to clear, instead of one per crash.
enum EphemeralDefaults {
    /// An empty domain to run against. Falls back to `.standard` only when the suite cannot be
    /// opened at all, which on a developer machine means the check runs rather than vanishing.
    static func make(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static func clear(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

/// Turns the main run loop for a fixed slice, for a check that has to let scheduled work land
/// before it looks at the result.
enum RunLoopDrain {
    static func run(for duration: TimeInterval = 0.05, mode: RunLoop.Mode = .default) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: deadline)
        }
    }
}

/// Whether a pixel-level check can run here. `ImageRenderer` and `NSHostingView` need Metal, and a
/// headless Intel runner without it aborts inside MTLLoader, so those checks stand down and the
/// policy assertions around them carry the run.
enum GPURenderCheck {
    static var skipReason: String? {
        if ProcessInfo.processInfo.environment["QUOTA_BAR_SKIP_GPU_RENDER_CHECK"] == "1" {
            return "requested by the test environment"
        }
        if MTLCreateSystemDefaultDevice() == nil {
            return "no Metal device is available on this headless verifier"
        }
        return nil
    }
}

#endif
