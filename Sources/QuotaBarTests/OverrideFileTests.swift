import Foundation
import QuotaBarCore

/// The hand-edited override file: which entries it accepts, and how it reaches and leaves disk.
enum OverrideFileTests {
    static func run() {
        self.parsing()
        self.disk()
    }

    private static func disk() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-override-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = OverrideFile(url: directory.appendingPathComponent("pricing-overrides.json"))

        Harness.expect(file.load().isEmpty, "a missing file overrides nothing")

        // Saving refuses a rate set the book's rules reject, and leaves the file as it was.
        do {
            try file.save(["kept": ModelPricing(input: 1, output: 2)])
        } catch {
            Harness.expect(false, "saving a valid override threw: \(error)")
        }
        Harness.expectThrows("saving a zero threshold") {
            try file.save(["broken": ModelPricing(input: 1, output: 2, thresholdTokens: 0)])
        }
        Harness.expectThrows("saving a negative rate") {
            try file.save(["broken": ModelPricing(input: -1, output: 2)])
        }
        Harness.expectEqual(Set(file.load().keys), ["kept"], "a refused save writes nothing")

        // A hand edit that breaks one entry costs only that entry.
        try? Data("""
        { "kept": { "input": 1, "output": 2 }, "broken": { "input": 1, "output": 2, "thresholdTokens": 0 } }
        """.utf8).write(to: file.url)
        Harness.expectEqual(Set(file.load().keys), ["kept"], "loading drops only the broken entry")

        // Every rate the billing math reads survives the trip, so an override cannot drop a tier.
        let full = ModelPricing(
            input: 2, output: 12, cacheWrite: 2.5, cacheWrite1h: 3.5, cacheRead: 0.2,
            thresholdTokens: 200_000,
            inputAbove: 4, outputAbove: 18, cacheWriteAbove: 5,
            cacheWrite1hAbove: 7, cacheReadAbove: 0.4
        )
        do {
            try file.save(["full": full])
        } catch {
            Harness.expect(false, "saving a full rate set threw: \(error)")
        }
        Harness.expectEqual(file.load()["full"], full, "the full rate set round-trips")

        // Saving nothing removes the file, handing every model back to the price book.
        try? file.save([:])
        Harness.expect(!FileManager.default.fileExists(atPath: file.url.path), "an empty override set deletes the file")
    }

    /// An override follows the same rules as the price book's own rates. An entry that breaks one
    /// is dropped on its own, so the book prices that model while every other override still holds.
    private static func parsing() {
        let parsed = OverrideFile.parse(Data("""
        {
          "valid": { "input": 1, "output": 2, "cacheRead": 0.1 },
          "quoted": { "input": "1.5", "output": "6" },
          "Mixed-Case": { "input": 3, "output": 4 },
          "negative": { "input": -1, "output": 2 },
          "zero-threshold": { "input": 1, "output": 2, "thresholdTokens": 0 },
          "fractional-threshold": { "input": 1, "output": 2, "thresholdTokens": 1.5 },
          "orphan-above": { "input": 1, "output": 2, "inputAbove": 4 },
          "misspelt": { "input": 1, "output": 2, "cacheread": 0.1 },
          "no-output": { "input": 1 },
          "boolean": { "input": true, "output": 2 },
          "not-a-number": { "input": "cheap", "output": 2 },
          "not-an-object": 5
        }
        """.utf8))

        Harness.expectEqual(
            Set(parsed.overrides.keys),
            ["valid", "quoted", "mixed-case"],
            "only entries that follow the price book's rules are kept"
        )
        Harness.expectEqual(parsed.overrides["valid"]?.cacheRead, 0.1, "a kept entry keeps its optional rates")
        Harness.expectEqual(parsed.overrides["quoted"]?.input, 1.5, "a rate written as a numeric string still reads")
        Harness.expectEqual(
            Set(parsed.ignored.keys),
            [
                "negative", "zero-threshold", "fractional-threshold", "orphan-above", "misspelt",
                "no-output", "boolean", "not-a-number", "not-an-object",
            ],
            "every rejected entry is reported"
        )
        Harness.expect(
            parsed.ignored["zero-threshold"]?.contains("thresholdTokens") == true,
            "the reason names the rate that broke the rule"
        )

        let garbage = OverrideFile.parse(Data("not json".utf8))
        Harness.expect(garbage.overrides.isEmpty, "an unreadable file overrides nothing")
    }
}
