#if DEBUG
import Foundation

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

    /// Runs an async check on the main run loop. `body` owns the process: it must end it with
    /// `finish`, `fail`, or `exit`.
    @MainActor
    static func runAsync(_ body: @escaping @MainActor () async -> Void) -> Never {
        Task { await body() }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
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

    /// Turns the main run loop until `ready` holds. How long scheduled work takes to land belongs
    /// to the machine, so the deadline only turns a state that never arrives into a failure
    /// instead of a hang.
    @discardableResult
    static func run(
        until ready: () -> Bool,
        timeout: TimeInterval = 5,
        mode: RunLoop.Mode = .default
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready(), Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }
        return ready()
    }
}

#endif
