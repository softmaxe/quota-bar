import Foundation

/// Command Line Tools ship neither XCTest nor swift-testing, so the suite is a plain
/// executable with a few assertions. `make test` runs it; a failure exits non-zero.
enum Harness {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var checks = 0

    static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        self.checks += 1
        guard !condition else { return }
        let name = URL(fileURLWithPath: "\(file)").lastPathComponent
        self.failures.append("\(name):\(line)  \(message())")
    }

    static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        self.expect(
            actual == expected,
            "\(label): expected \(expected), got \(actual)",
            file: file,
            line: line
        )
    }

    /// Costs are sums of per-million rates, so exact equality is the wrong test.
    static func expectClose(
        _ actual: Double?,
        _ expected: Double,
        _ label: String,
        tolerance: Double = 1e-9,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let actual else {
            self.expect(false, "\(label): expected \(expected), got nil", file: file, line: line)
            return
        }
        self.expect(
            abs(actual - expected) <= tolerance,
            "\(label): expected \(expected), got \(actual)",
            file: file,
            line: line
        )
    }

    static func expectThrows(
        _ label: String,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            self.expect(false, "\(label): expected a throw, none happened", file: file, line: line)
        } catch {
            self.checks += 1
        }
    }

    static func finish() -> Never {
        if self.failures.isEmpty {
            print("\(self.checks) checks passed")
            exit(0)
        }
        print("\(self.failures.count) of \(self.checks) checks failed:")
        for failure in self.failures {
            print("  \(failure)")
        }
        exit(1)
    }
}
