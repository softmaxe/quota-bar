import Foundation

/// The failure that stopped an app check.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// App checks drive real stores and controllers, where a broken step usually leaves nothing
/// sensible to look at after it, so they stop at their first failure instead of collecting them.
enum AppCheck {
    /// Stops the check with `message` unless `condition` holds.
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw CheckFailure(description: message()) }
    }

    /// Turns the main run loop in menu-tracking mode until `ready` holds, so a timer that only
    /// fires while a menu is open gets its chance. Checks run inside a main-actor job, so the
    /// run loop cannot drain main-actor work itself; each turn also suspends to let a timer's hop
    /// to the main actor land.
    @MainActor
    @discardableResult
    static func waitDuringMenuTracking(until ready: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready(), Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
            try? await Task.sleep(for: .milliseconds(1))
        }
        return ready()
    }

    /// Runs one check and records it under `label`: as passed, or with whatever stopped it.
    @MainActor
    static func run(
        _ label: String,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Harness.expect(true, label, file: file, line: line)
        } catch {
            Harness.expect(false, "\(label): \(error)", file: file, line: line)
        }
    }
}
