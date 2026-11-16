import CQuotaBarRust
import Foundation
@testable import QuotaBarCore

/// The same Swift day dictionary feeds both folds so cross-day floating-point order is identical.
enum RustAggregationTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)
    private static let today = "2026-11-30"

    static func run() {
        Harness.expectEqual(MemoryLayout<QBAggregateTokens>.size, 40, "aggregation token ABI size")
        Harness.expectEqual(MemoryLayout<QBAggregateRow>.size, 88, "aggregation row ABI size")
        Harness.expectEqual(MemoryLayout<QBAggregateGroup>.size, 72, "aggregation group ABI size")
        Harness.expectEqual(MemoryLayout<QBAggregateDay>.size, 64, "aggregation day ABI size")
        Harness.expectEqual(MemoryLayout<QBAggregateModel>.size, 24, "aggregation model ABI size")
        Harness.expectEqual(MemoryLayout<QBAggregateRow>.alignment, 8, "aggregation row ABI alignment")
        Harness.expectEqual(MemoryLayout<QBAggregateGroup>.alignment, 8, "aggregation group ABI alignment")
        Harness.expectEqual(MemoryLayout<QBAggregateDay>.alignment, 8, "aggregation day ABI alignment")
        Harness.expectEqual(MemoryLayout<QBAggregateModel>.alignment, 8, "aggregation model ABI alignment")
        var failures: [String] = []
        var cases = 0
        func check(_ rows: [PricedUsage], _ name: String, tab: UsageTab = .pi,
                   allowedTies: Set<String>? = nil) {
            cases += 1
            let grouped = Dictionary(grouping: rows, by: \.day)
            let swift = Result { try SwiftCostAggregator.aggregate(groupedRows: grouped, tab: tab,
                                                                  todayKey: Self.today, now: Self.now) }
            let rust = Result { try CostAggregator.aggregate(groupedRows: grouped, tab: tab,
                                                             todayKey: Self.today, now: Self.now) }
            switch (swift, rust) {
            case let (.success(expected), .success(actual)):
                if !Self.equal(actual, expected, allowedTies: allowedTies) { failures.append(name) }
            case let (.failure(expected), .failure(actual)):
                if expected.localizedDescription != actual.localizedDescription { failures.append(name + " error text") }
            default: failures.append(name + " success/error")
            }
        }
        check([], "empty")
        check([Self.row()], "single")
        check([Self.row(model: "unknown"), Self.row(model: "")], "unknown names")
        check([Self.row(cost: nil)], "unpriced")
        check([Self.row(cost: 0), Self.row(model: "other", cost: nil)], "nil versus zero", allowedTies: ["model", "other"])
        check([Self.row(cost: -0.0)], "signed zero")
        check([Self.row(cost: nil, unpriced: 1), Self.row(cost: 0, fallback: true)], "partial fallback")
        check([Self.row(unpriced: -1)], "nonpositive unpriced is ignored")
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        for _ in 0..<16 {
            check([Self.row(day: "2026-11-01", model: composed, cost: nil),
                   Self.row(day: "2026-11-02", model: decomposed)], "Unicode model spelling per day and top model")
            check([Self.row(model: composed, cost: nil), Self.row(model: decomposed)],
                  "first token key differs from first cost key")
            check([Self.row(model: decomposed, cost: nil), Self.row(model: composed)],
                  "reversed first token and cost spellings")
            check([Self.row(day: "2026-11-01", upstream: composed),
                   Self.row(day: "2026-11-02", upstream: decomposed)], "Unicode upstream spelling per day")
        }
        for tab in UsageTab.allCases {
            for count in [1, 7, 30] {
                check(Self.fixture(days: count, models: 7), "mixed sources and tiers \(tab) \(count)", tab: tab)
            }
        }
        for index in 0..<64 {
            // Non-dyadic and extreme finite costs exercise exact accumulation bits and overflow.
            let exponent = index % 4 == 0 ? 900 : (index % 4 == 1 ? -1_020 : 0)
            let cost = Double(sign: .plus, exponent: exponent, significand: Double(index + 1) / 7)
            check((0..<12).map { row in
                Self.row(day: "2026-11-\(row % 3 + 10)", model: "model-\(row % 4)",
                         tokens: TokenTotals(input: (index + 1) * (row + 1)),
                         cost: cost * Double(row + 1) / 3)
            }, "floating order \(index)")
        }
        for index in 0..<6 {
            var tokens = TokenTotals(input: 1, output: 1, cacheWrite: 1, cacheWrite1h: 1, cacheRead: 1)
            switch index {
            case 0: tokens.input = -1
            case 1: tokens.output = -1
            case 2: tokens.cacheWrite = -1
            case 3: tokens.cacheWrite1h = -1
            case 4: tokens.cacheRead = -1
            default: tokens.cacheWrite1h = 2
            }
            check([Self.row(tokens: tokens)], "invalid count \(index)")
        }
        check([Self.row(tokens: TokenTotals(input: Int.max, output: 1))], "invalid source total")
        check([Self.row(tokens: TokenTotals(input: Int.max)), Self.row(tokens: TokenTotals(input: 1))],
              "same-bucket token overflow")
        check([Self.row(tokens: TokenTotals(input: Int.max)), Self.row(tokens: TokenTotals(output: 1))],
              "cross-bucket total overflow")
        check([Self.row(tokens: TokenTotals(input: Int.max)), Self.row(model: "other", tokens: TokenTotals(output: 1))],
              "day cross-model total overflow")
        check([Self.row(day: "2026-11-01", tokens: TokenTotals(input: Int.max)),
               Self.row(day: "2026-11-02", tokens: TokenTotals(input: 1))], "model window overflow")
        check([Self.row(day: "2026-11-01", tokens: TokenTotals(input: Int.max)),
               Self.row(day: "2026-11-02", model: "other", tokens: TokenTotals(input: 1))], "window total overflow")
        check([Self.row(unpriced: Int.max), Self.row(unpriced: 1)], "unpriced total overflow")
        for cost in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            check([Self.row(cost: cost)], "invalid cost \(cost)")
        }
        check([Self.row(cost: .greatestFiniteMagnitude), Self.row(cost: .greatestFiniteMagnitude)], "day cost overflow")
        check([Self.row(day: "2026-11-01", cost: .greatestFiniteMagnitude),
               Self.row(day: "2026-11-02", cost: .greatestFiniteMagnitude)], "model cost overflow")
        check([Self.row(day: "2026-11-01", model: "a", cost: .greatestFiniteMagnitude),
               Self.row(day: "2026-11-02", model: "b", cost: .greatestFiniteMagnitude)], "window cost overflow")
        // The original Set.max comparator deliberately has no tertiary ordering for exact ties.
        for _ in 0..<32 {
            check([Self.row(model: "a"), Self.row(model: "b")], "top cost/token tie", allowedTies: ["a", "b"])
            check([Self.row(model: "a", cost: nil), Self.row(model: "b", cost: nil)],
                  "top unpriced tie", allowedTies: ["a", "b"])
        }
        check([Self.row(model: "a", tokens: TokenTotals(input: 1)),
               Self.row(model: "b", tokens: TokenTotals(input: 2))], "top cost tie breaks by tokens")
        Harness.expectEqual(failures.count, 0, "Rust aggregation preserves snapshots, double bits and error text across \(cases) cases: \(failures.prefix(5))")
        if ProcessInfo.processInfo.environment["QUOTABAR_BENCH_AGGREGATION"] == "1" { Self.benchmark() }
    }

    private static func row(day: String = today, model: String = "model", source: CostUsageSource = .piAgent,
                            fast: Bool = false, long: Bool = false, upstream: String? = nil,
                            tokens: TokenTotals = TokenTotals(input: 1), cost: Double? = 1,
                            unpriced: Int = 0, fallback: Bool = false) -> PricedUsage {
        PricedUsage(key: .init(day: day, source: source, model: model, longContext: long, isFast: fast,
                              upstreamProvider: upstream, pricingProvider: .codex),
                    tokens: tokens, cost: cost, unpricedTokens: unpriced, usesLoggedCostFallback: fallback)
    }

    private static func fixture(days: Int, models: Int) -> [PricedUsage] {
        var rows: [PricedUsage] = []
        for day in 1...days {
            for model in 0..<models {
                for long in [false, true] {
                    for fast in [false, true] {
                        let count = (model + 1) * day * 73 + (long ? 234 : 0) + (fast ? 129 : 0)
                        let tokens = TokenTotals(input: count, output: count / 8, cacheWrite: count / 5,
                                                cacheWrite1h: count / 9, cacheRead: count / 3)
                        let unpriced = model % 7 == 6
                        rows.append(Self.row(day: String(format: "2026-11-%02d", day),
                            model: String(format: "synthetic-model-%03d", model),
                            source: [.codex, .claude, .openCode, .piAgent][model % 4], fast: fast, long: long,
                            upstream: model % 3 == 0 ? nil : "provider-\(model % 3)", tokens: tokens,
                            cost: unpriced ? nil : Double(count) / 1_000_000,
                            unpriced: unpriced ? tokens.total : (model % 5 == 4 ? 1 : 0), fallback: model % 5 == 4))
                    }
                }
            }
        }
        return rows
    }

    private static func equal(_ actual: CostSnapshot, _ expected: CostSnapshot, allowedTies: Set<String>?) -> Bool {
        let normalized = CostSnapshot(tab: actual.tab, days: actual.days, todayCostUSD: actual.todayCostUSD,
            windowCostUSD: actual.windowCostUSD, latestTokens: actual.latestTokens, windowTokens: actual.windowTokens,
            topModel: expected.topModel, hasUnpricedTokens: actual.hasUnpricedTokens, scannedAt: actual.scannedAt)
        guard normalized == expected,
              actual.todayCostUSD.bitPattern == expected.todayCostUSD.bitPattern,
              actual.windowCostUSD.bitPattern == expected.windowCostUSD.bitPattern else { return false }
        if let allowedTies {
            guard let actualTop = actual.topModel, let expectedTop = expected.topModel,
                  allowedTies.contains(actualTop), allowedTies.contains(expectedTop) else { return false }
        } else if actual.topModel.map({ Array($0.utf8) }) != expected.topModel.map({ Array($0.utf8) }) { return false }
        for (a, b) in zip(actual.days, expected.days) {
            guard a.costUSD?.bitPattern == b.costUSD?.bitPattern,
                  Array(a.dayKey.utf8) == Array(b.dayKey.utf8) else { return false }
            for (key, usage) in a.byModel {
                guard usage.costUSD?.bitPattern == b.byModel[key]?.costUSD?.bitPattern,
                      let expectedKey = b.byModel.keys.first(where: { $0 == key }),
                      Array(key.model.utf8) == Array(expectedKey.model.utf8),
                      key.upstreamProvider.map({ Array($0.utf8) }) == expectedKey.upstreamProvider.map({ Array($0.utf8) })
                else { return false }
            }
        }
        return true
    }

    private static func benchmark() {
        @inline(never)
        func measure(_ rows: [PricedUsage], rust: Bool, repeats: Int) throws -> (Double, Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            var checksum = 0.0
            for _ in 0..<repeats {
                let grouped = Dictionary(grouping: rows, by: \.day)
                let result = rust
                    ? try CostAggregator.aggregate(groupedRows: grouped, tab: .pi, todayKey: Self.today, now: Self.now)
                    : try SwiftCostAggregator.aggregate(groupedRows: grouped, tab: .pi, todayKey: Self.today, now: Self.now)
                checksum += result.windowCostUSD + Double(result.windowTokens)
                checksum += Double(result.days.reduce(0) { $0 + $1.byModel.count })
            }
            return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(repeats), checksum)
        }
        do {
            for (days, models, repeats) in [(10, 3, 100), (30, 7, 50), (30, 40, 10)] {
                let rows = Self.fixture(days: days, models: models)
                var swift: [Double] = [], rust: [Double] = []
                for run in 0..<9 {
                    let first = try measure(rows, rust: run % 2 == 0, repeats: repeats)
                    let second = try measure(rows, rust: run % 2 != 0, repeats: repeats)
                    Harness.expectEqual(first.1.bitPattern, second.1.bitPattern, "aggregation benchmark checksum")
                    if run >= 2 {
                        rust.append(run % 2 == 0 ? first.0 : second.0)
                        swift.append(run % 2 == 0 ? second.0 : first.0)
                    }
                }
                print("aggregation_benchmark rows=\(rows.count) swift_ms=\(swift) rust_ffi_ms=\(rust)")
                print("aggregation_benchmark rows=\(rows.count) swift_median_ms=\(swift.sorted()[3]) rust_ffi_median_ms=\(rust.sorted()[3])")
            }
        } catch { Harness.expect(false, "aggregation benchmark failed: \(error)") }
    }
}
