import Foundation
@testable import QuotaBarCore

/// Differential checks retain the original Swift implementation as a test-only billing oracle.
enum RustPricingTests {
    private struct Sample {
        let pricing: ModelPricing
        let tokens: TokenTotals
        let longContext: Bool
    }

    private struct Generator {
        var state: UInt64 = 0x8f13_37a2_e9b0_c456
        mutating func next() -> UInt64 {
            self.state = self.state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return self.state
        }
    }

    static func run() {
        var samples: [Sample] = []
        let counts = [0, 1, 999_999, 1_000_000, 9_007_199_254_740_991,
                      9_007_199_254_740_992, 9_007_199_254_740_993, Int.max]
        // All optional masks include absent/present thresholds and both context tiers.
        for mask in 0..<512 {
            let rates = (0..<10).map { Double($0 + 1) / 8 }
            for longContext in [false, true] {
                var tokens = TokenTotals(input: counts[mask % counts.count], output: 17,
                    cacheWrite: counts[(mask + 1) % counts.count], cacheWrite1h: 1, cacheRead: 113)
                // Public mutable fields can exceed their initializer's one-hour clamp.
                if mask % 3 == 0 { tokens.cacheWrite1h = Int.max }
                samples.append(Sample(pricing: Self.pricing(rates, mask: mask, threshold: 200_000),
                                      tokens: tokens, longContext: longContext))
            }
        }
        let boundaries: [Double] = [0, -0.0, -1, .infinity, -.infinity, .nan,
            .leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
            Double.greatestFiniteMagnitude / 2, (Double.greatestFiniteMagnitude / 2).nextUp]
        for index in 0..<10 {
            for rate in boundaries {
                for mask in [0, 256, 511, 509, 447, 445] {
                    var rates = Array(repeating: 1.0, count: 10)
                    rates[index] = rate
                    for longContext in [false, true] {
                        samples.append(Sample(pricing: Self.pricing(rates, mask: mask, threshold: 200_000),
                            tokens: TokenTotals(input: Int.max, output: 3, cacheWrite: Int.max,
                                                cacheWrite1h: 123, cacheRead: 17), longContext: longContext))
                    }
                }
            }
        }
        for threshold in [Int.min, -1, 0, 1, 999_999_999_999, 1_000_000_000_000, Int.max] {
            samples.append(Sample(pricing: Self.pricing(Array(repeating: 1, count: 10),
                mask: 511, threshold: threshold), tokens: TokenTotals(input: 1), longContext: true))
        }
        for longContext in [false, true] {
            samples.append(Sample(pricing: Self.pricing(
                Array(repeating: Double.greatestFiniteMagnitude / 4, count: 10),
                mask: 511, threshold: 200_000),
                tokens: TokenTotals(input: 8, output: 8, cacheWrite: 8, cacheWrite1h: 4, cacheRead: 8),
                longContext: longContext))
        }
        for index in 0..<5 {
            var tokens = TokenTotals(input: 1, output: 1, cacheWrite: 1, cacheWrite1h: 1, cacheRead: 1)
            switch index {
            case 0: tokens.input = -1
            case 1: tokens.output = -1
            case 2: tokens.cacheWrite = -1
            case 3: tokens.cacheWrite1h = -1
            default: tokens.cacheRead = -1
            }
            samples.append(Sample(pricing: ModelPricing(input: 1, output: 1), tokens: tokens,
                                  longContext: false))
        }
        var generator = Generator()
        for index in 0..<4_096 {
            // Alternate unrestricted IEEE values with positive finite values, including subnormals.
            let rates = (0..<10).map { _ -> Double in
                let bits = generator.next()
                return Double(bitPattern: index % 2 == 0 ? bits : bits & 0x7fef_ffff_ffff_ffff)
            }
            let mask = Int(generator.next() % 512)
            let tokens = TokenTotals(input: Int(generator.next() & 0x7fff_ffff_ffff_ffff),
                output: Int(generator.next() % 1_000_000), cacheWrite: Int(generator.next() % 1_000_000),
                cacheWrite1h: Int(generator.next() % 1_000_000), cacheRead: Int(generator.next() % 1_000_000))
            samples.append(Sample(pricing: Self.pricing(rates, mask: mask, threshold: 200_000),
                                  tokens: tokens, longContext: index % 2 == 0))
        }
        var costMismatches = 0
        var rateMismatches = 0
        for sample in samples {
            let actual = sample.pricing.cost(for: sample.tokens, longContext: sample.longContext)
            let expected = Self.swiftCost(sample.pricing, for: sample.tokens, longContext: sample.longContext)
            if actual?.bitPattern != expected?.bitPattern { costMismatches += 1 }
            let actualRate = sample.pricing.cacheWrite1hRate(longContext: sample.longContext)
            let expectedRate = Self.swiftOneHour(sample.pricing, longContext: sample.longContext)
            if actualRate.bitPattern != expectedRate.bitPattern { rateMismatches += 1 }
        }
        Harness.expectEqual(costMismatches, 0, "Rust pricing matches Swift optional results and exact double bits across \(samples.count) cases")
        Harness.expectEqual(rateMismatches, 0, "Rust one-hour fallback matches Swift exact double bits across \(samples.count) cases")
        if ProcessInfo.processInfo.environment["QUOTABAR_BENCH_PRICING"] == "1" {
            Self.benchmark()
        }
    }

    private static func pricing(_ rates: [Double], mask: Int, threshold: Int) -> ModelPricing {
        func optional(_ bit: Int) -> Double? { mask & (1 << bit) != 0 ? rates[bit + 2] : nil }
        return ModelPricing(input: rates[0], output: rates[1], cacheWrite: optional(0),
            cacheWrite1h: optional(1), cacheRead: optional(2),
            thresholdTokens: mask & 256 != 0 ? threshold : nil,
            inputAbove: optional(3), outputAbove: optional(4), cacheWriteAbove: optional(5),
            cacheWrite1hAbove: optional(6), cacheReadAbove: optional(7))
    }

    private static func swiftOneHour(_ pricing: ModelPricing, longContext: Bool) -> Double {
        let inputRate = (longContext ? pricing.inputAbove : nil) ?? pricing.input
        if let stated = (longContext ? pricing.cacheWrite1hAbove : nil) ?? pricing.cacheWrite1h { return stated }
        return inputRate * ModelPricing.oneHourCacheWriteMultiplier
    }

    /// Original production validation and arithmetic, including the full RateRules dictionary path.
    @inline(never)
    private static func swiftCost(_ pricing: ModelPricing, for totals: TokenTotals, longContext: Bool) -> Double? {
        guard ModelPricing.violations(in: pricing.rateValues).isEmpty,
              [totals.input, totals.output, totals.cacheWrite, totals.cacheWrite1h, totals.cacheRead]
                .allSatisfy({ $0 >= 0 }) else { return nil }
        let million = 1_000_000.0
        let inputRate = (longContext ? pricing.inputAbove : nil) ?? pricing.input
        let outputRate = (longContext ? pricing.outputAbove : nil) ?? pricing.output
        // A model without its own cache rates bills cached tokens at the full input rate.
        let cacheWriteRate = (longContext ? pricing.cacheWriteAbove : nil) ?? pricing.cacheWrite ?? inputRate
        let cacheReadRate = (longContext ? pricing.cacheReadAbove : nil) ?? pricing.cacheRead ?? inputRate

        // Anthropic prices a one-hour cache write at twice the input rate, against 1.25x for the
        // five-minute default. The table's cache-write column is the five-minute rate, so unless
        // a one-hour rate is stated the longer TTL is derived the way Anthropic publishes it.
        let write1h = Double(min(totals.cacheWrite1h, totals.cacheWrite))
        let write5m = Double(totals.cacheWrite) - write1h

        let millionths = Double(totals.input) * inputRate
            + Double(totals.output) * outputRate
            + write5m * cacheWriteRate
            + write1h * Self.swiftOneHour(pricing, longContext: longContext)
            + Double(totals.cacheRead) * cacheReadRate
        if millionths.isFinite { return millionths / million }

        // Retry in USD when the intermediate amount in millionths overflowed.
        // This preserves the existing rounding for ordinary rates.
        let cost = Double(totals.input) * (inputRate / million)
            + Double(totals.output) * (outputRate / million)
            + write5m * (cacheWriteRate / million)
            + write1h * (Self.swiftOneHour(pricing, longContext: longContext) / million)
            + Double(totals.cacheRead) * (cacheReadRate / million)
        return cost.isFinite && cost >= 0 ? cost : nil
    }

    private static func benchmark() {
        let samples = (0..<1_024).map { index in
            Sample(pricing: Self.pricing((0..<10).map { Double($0 + 1) * 0.25 },
                                        mask: 256 | (index % 256), threshold: 200_000),
                   tokens: TokenTotals(input: index * 171, output: index * 31,
                                       cacheWrite: index * 83, cacheWrite1h: index * 41, cacheRead: index * 193),
                   longContext: index % 2 == 0)
        }
        @inline(never)
        func measure(rust: Bool) -> (Double, Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            var total = 0.0
            for _ in 0..<8 {
                for sample in samples {
                    let cost = rust
                        ? sample.pricing.cost(for: sample.tokens, longContext: sample.longContext)
                        : Self.swiftCost(sample.pricing, for: sample.tokens, longContext: sample.longContext)
                    total += cost ?? 0
                }
            }
            return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, total)
        }
        var swiftTimes: [Double] = []
        var rustTimes: [Double] = []
        for iteration in 0..<9 {
            let first = measure(rust: iteration % 2 == 0)
            let second = measure(rust: iteration % 2 != 0)
            Harness.expectEqual(first.1.bitPattern, second.1.bitPattern, "pricing benchmark preserves checksum")
            if iteration >= 2 {
                rustTimes.append(iteration % 2 == 0 ? first.0 : second.0)
                swiftTimes.append(iteration % 2 == 0 ? second.0 : first.0)
            }
        }
        print("pricing_benchmark calls_per_run=8192 swift_ms=\(swiftTimes) rust_ffi_ms=\(rustTimes)")
        print("pricing_benchmark swift_median_ms=\(swiftTimes.sorted()[3]) rust_ffi_median_ms=\(rustTimes.sorted()[3])")
    }
}
