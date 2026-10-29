#if DEBUG
import Foundation

/// How a manual launch-flag check ends: name what passed and exit 0, or put the failure on
/// stderr and exit 1. The assertion suite itself runs in `QuotaBarTests`.
enum VerifierReport {
    /// Writes one failure line without ending the process, for a check with cleanup of its own
    /// to do first — `exit()` terminates without unwinding the stack, so `defer` never runs.
    static func report(_ message: String, label: String) {
        fputs("\(label) failed: \(message)\n", stderr)
    }
}

/// Polls from async code until `ready` holds. The deadline only turns a state that never arrives
/// into a failure instead of a hang.
@MainActor
enum AsyncWait {
    static func wait(until ready: () -> Bool, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return ready()
    }
}

/// A throwaway defaults domain, so a verifier never reads or writes the user's real preferences.
/// The suite name is fixed rather than PID-stamped: a run that dies before its cleanup leaves one
/// domain behind for the next run to clear, instead of one per crash.
enum EphemeralDefaults {
    /// An empty domain to run against. A suite that cannot be opened ends the run rather than
    /// falling back to `.standard`, which would write into the user's real preferences.
    static func make(_ suite: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite) else {
            fputs("could not open the \(suite) defaults suite\n", stderr)
            exit(2)
        }
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

#endif
