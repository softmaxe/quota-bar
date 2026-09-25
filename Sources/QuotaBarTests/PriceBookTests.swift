import Foundation
import QuotaBarCore

/// The shipped price book is data, so these checks are what stop a malformed or incomplete edit
/// from reaching a release.
enum PriceBookTests {
    static func run() {
        Self.bundledBookIsComplete()
        Self.reportsStaleSources()
        Self.datedLookup()
        Self.publishedRates()
        Self.rejectsMalformedBooks()
    }

    /// Every model the shipped book lists, retired ones included, has to price today's usage.
    private static let today = DayKey.today()

    private static func bundledBookIsComplete() {
        let book = PriceBook.bundled
        for provider in Provider.allCases {
            let models = book.models(for: provider)
            // An invalid book loads as an empty one, so an empty provider means validation failed.
            Harness.expect(!models.isEmpty, "the bundled price book lists \(provider.rawValue) models")
            let listed = models.filter(\.showInSettings)
            Harness.expect(!listed.isEmpty, "\(provider.rawValue) lists models in the pricing settings")
            for model in listed {
                Harness.expect(!model.retired, "\(model.id) is listed in settings but marked retired")
            }
            for model in models {
                Harness.expect(
                    book.rates(for: model.id, provider: provider, day: Self.today) != nil,
                    "\(model.id) is priced today"
                )
                Harness.expectEqual(
                    RateCard().modelID(for: model.id, provider: provider),
                    model.id,
                    "\(model.id) is already a normalized name, so stored usage can find it"
                )
                for alias in model.aliases {
                    Harness.expectEqual(
                        RateCard().modelID(for: alias, provider: provider),
                        model.id,
                        "alias \(alias) resolves to \(model.id)"
                    )
                }
            }
        }
    }

    /// Never fails: an old check date is a reminder to compare the book against the published
    /// price lists, not a defect.
    private static func reportsStaleSources() {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let limit = 45
        for provider in Provider.allCases {
            guard let section = PriceBook.bundled.section(for: provider),
                  let checked = formatter.date(from: section.checkedAt),
                  let age = calendar.dateComponents([.day], from: checked, to: Date()).day,
                  age > limit else { continue }
            print("note: \(provider.rawValue) prices were last checked \(age) days ago against \(section.source)")
        }
    }

    private static func datedLookup() {
        let book: PriceBook
        do {
            book = try PriceBook(data: Data("""
                {
                  "schemaVersion": 1,
                  "providers": {
                    "codex": {
                      "source": "https://example.com", "checkedAt": "2026-09-01",
                      "models": [
                        {
                          "id": "dated-model",
                          "aliases": ["dated"],
                          "periods": [
                            { "rates": { "input": 4, "output": 20, "thresholdTokens": 100, "inputAbove": 8 }, "fastMultiplier": 2 },
                            { "from": "2026-11-22", "rates": { "input": 5, "output": 30 } }
                          ]
                        }
                      ]
                    }
                  }
                }
                """.utf8))
        } catch {
            Harness.expect(false, "dated fixture book threw: \(error)")
            return
        }
        Harness.expectEqual(
            book.rates(for: "dated-model", provider: .codex, day: "2020-01-01")?.input,
            4,
            "the opening period covers every day before the next one"
        )
        Harness.expectEqual(
            book.rates(for: "dated-model", provider: .codex, day: "2026-11-21")?.input,
            4,
            "the day before a new period keeps the old rates"
        )
        Harness.expectEqual(
            book.rates(for: "dated-model", provider: .codex, day: "2026-11-22")?.input,
            5,
            "a period applies from its first day"
        )
        Harness.expectEqual(
            book.rates(for: "dated-model", provider: .codex, day: "2026-11-21", fast: true),
            ModelPricing(input: 8, output: 40, thresholdTokens: 100, inputAbove: 16),
            "Fast multiplies every rate and keeps the threshold"
        )
        Harness.expect(
            book.rates(for: "dated-model", provider: .codex, day: "2026-11-22", fast: true) == nil,
            "a period without a Fast multiplier leaves Fast unpriced"
        )
        Harness.expect(
            book.rates(for: "dated-model", provider: .claude, day: "2026-11-22") == nil,
            "models are looked up within their own provider"
        )
        Harness.expectEqual(book.canonicalID(for: "dated", provider: .codex), "dated-model", "aliases resolve")
    }

    /// The published rates in force on a fixed day. A price change adds a period instead of
    /// editing these, so a failure here means an old period was edited or a rate was mistyped.
    private static func publishedRates() {
        let book = PriceBook.bundled
        func rates(_ id: String, _ provider: Provider, fast: Bool = false) -> ModelPricing? {
            book.rates(for: id, provider: provider, day: "2026-09-25", fast: fast)
        }

        let codex: [(id: String, fast: Bool, rates: ModelPricing)] = [
            ("gpt-6-astra", false, ModelPricing(
                input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1,
                thresholdTokens: 272_000,
                inputAbove: 20, outputAbove: 75, cacheWriteAbove: 25, cacheReadAbove: 2
            )),
            ("gpt-6-astra", true, ModelPricing(
                input: 20, output: 100, cacheWrite: 25, cacheRead: 2,
                thresholdTokens: 272_000,
                inputAbove: 40, outputAbove: 150, cacheWriteAbove: 50, cacheReadAbove: 4
            )),
            ("gpt-5.6-sol", false, ModelPricing(
                input: 4, output: 20, cacheWrite: 5, cacheRead: 0.4,
                thresholdTokens: 272_000,
                inputAbove: 8, outputAbove: 30, cacheWriteAbove: 10, cacheReadAbove: 0.8
            )),
            ("gpt-5.6-sol", true, ModelPricing(
                input: 8, output: 40, cacheWrite: 10, cacheRead: 0.8,
                thresholdTokens: 272_000,
                inputAbove: 16, outputAbove: 60, cacheWriteAbove: 20, cacheReadAbove: 1.6
            )),
            ("gpt-5.6-terra", true, ModelPricing(
                input: 4, output: 24, cacheWrite: 5, cacheRead: 0.4,
                thresholdTokens: 272_000,
                inputAbove: 8, outputAbove: 36, cacheWriteAbove: 10, cacheReadAbove: 0.8
            )),
            ("gpt-5.6-luna", true, ModelPricing(
                input: 0.4, output: 2.4, cacheWrite: 0.5, cacheRead: 0.04,
                thresholdTokens: 272_000,
                inputAbove: 0.8, outputAbove: 3.6, cacheWriteAbove: 1, cacheReadAbove: 0.08
            )),
            ("gpt-5.3-codex", true, ModelPricing(input: 3.5, output: 28, cacheRead: 0.35)),
            ("codex-mini-latest", false, ModelPricing(input: 1.5, output: 6, cacheRead: 0.375)),
        ]
        for entry in codex {
            Harness.expectEqual(
                rates(entry.id, .codex, fast: entry.fast),
                entry.rates,
                "\(entry.id) \(entry.fast ? "Fast" : "Standard") rates match the published table"
            )
        }
        for id in ["gpt-5.6-cyber", "codex-mini-latest"] {
            Harness.expect(rates(id, .codex, fast: true) == nil, "\(id) has no Fast price")
        }

        Harness.expectEqual(
            rates("claude-opus-5", .claude),
            ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
            "claude-opus-5 rates match the published table"
        )
        let haiku = rates("claude-3-5-haiku", .claude)
        Harness.expectClose(haiku?.input, 0.8, "claude-3-5-haiku input rate")
        Harness.expectClose(haiku?.output, 4, "claude-3-5-haiku output rate")
        Harness.expectClose(haiku?.cacheWrite, 1, "claude-3-5-haiku five-minute cache-write rate")
        Harness.expectClose(haiku?.cacheRead, 0.08, "claude-3-5-haiku cache-read rate")
        Harness.expectClose(haiku?.cacheWrite1hRate(longContext: false), 1.6, "claude-3-5-haiku one-hour cache-write rate is derived")

        // The 5.1 pair is the one Anthropic family that breaks the 0.1x cache-read ratio, so
        // its read rate is worth pinning rather than left to look like a typo.
        let fable = rates("claude-fable-5-1", .claude)
        Harness.expectClose(fable?.input, 10, "claude-fable-5-1 input rate")
        Harness.expectClose(fable?.output, 50, "claude-fable-5-1 output rate")
        Harness.expectClose(fable?.cacheWrite, 12.5, "claude-fable-5-1 five-minute cache-write rate")
        Harness.expectClose(fable?.cacheRead, 0.25, "claude-fable-5-1 cache-read rate is 0.025x input")
        Harness.expectClose(fable?.cacheWrite1hRate(longContext: false), 20, "claude-fable-5-1 one-hour cache-write rate is derived")
        Harness.expectClose(rates("claude-mythos-5-1", .claude)?.cacheRead, 0.25, "claude-mythos-5-1 shares the 5.1 cache-read rate")
        Harness.expectClose(rates("claude-fable-5", .claude)?.cacheRead, 1, "claude-fable-5 keeps the standard 0.1x cache-read rate")

        // Opus 5.5 is the other break from 0.1x: its cache read is 0.05x input.
        let opus55 = rates("claude-opus-5-5", .claude)
        Harness.expectClose(opus55?.input, 4, "claude-opus-5-5 input rate")
        Harness.expectClose(opus55?.output, 20, "claude-opus-5-5 output rate")
        Harness.expectClose(opus55?.cacheWrite, 5, "claude-opus-5-5 five-minute cache-write rate")
        Harness.expectClose(opus55?.cacheRead, 0.2, "claude-opus-5-5 cache-read rate is 0.05x input")
        Harness.expectClose(opus55?.cacheWrite1hRate(longContext: false), 8, "claude-opus-5-5 one-hour cache-write rate is derived")
    }

    private static func rejectsMalformedBooks() {
        func book(models: String, schemaVersion: Int = 1) -> String {
            """
            {
              "schemaVersion": \(schemaVersion),
              "providers": {
                "codex": { "source": "https://example.com", "checkedAt": "2026-09-01", "models": [\(models)] }
              }
            }
            """
        }
        let valid = #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2 } } ] }"#
        do {
            _ = try PriceBook(data: Data(book(models: valid).utf8))
        } catch {
            Harness.expect(false, "the minimal valid book was rejected: \(error)")
        }

        let cases: [(String, String)] = [
            ("a misspelt rate key", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2, "cachRead": 1 } } ] }"#),
            ("a missing output rate", #"{ "id": "m", "periods": [ { "rates": { "input": 1 } } ] }"#),
            ("a negative rate", #"{ "id": "m", "periods": [ { "rates": { "input": -1, "output": 2 } } ] }"#),
            ("a boolean rate", #"{ "id": "m", "periods": [ { "rates": { "input": true, "output": 2 } } ] }"#),
            ("no periods", #"{ "id": "m", "periods": [] }"#),
            ("a dated opening period", #"{ "id": "m", "periods": [ { "from": "2026-01-01", "rates": { "input": 1, "output": 2 } } ] }"#),
            ("an undated later period", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2 } }, { "rates": { "input": 1, "output": 2 } } ] }"#),
            ("periods out of order", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2 } }, { "from": "2026-02-01", "rates": { "input": 1, "output": 2 } }, { "from": "2026-01-01", "rates": { "input": 1, "output": 2 } } ] }"#),
            ("a malformed day", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2 } }, { "from": "2026-1-1", "rates": { "input": 1, "output": 2 } } ] }"#),
            ("long-context rates without a threshold", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2, "inputAbove": 2 } } ] }"#),
            ("a fractional threshold", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2, "thresholdTokens": 1.5 } } ] }"#),
            ("a zero Fast multiplier", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2 }, "fastMultiplier": 0 } ] }"#),
            ("an uppercase id", #"{ "id": "M", "periods": [ { "rates": { "input": 1, "output": 2 } } ] }"#),
            ("a duplicate id", valid + "," + valid),
            ("an alias shadowing an id", #"{ "id": "m", "periods": [ { "rates": { "input": 1, "output": 2 } } ] }, { "id": "n", "aliases": ["m"], "periods": [ { "rates": { "input": 1, "output": 2 } } ] }"#),
            ("an unknown model key", #"{ "id": "m", "retird": true, "periods": [ { "rates": { "input": 1, "output": 2 } } ] }"#),
        ]
        for (label, models) in cases {
            Harness.expectThrows(label) { _ = try PriceBook(data: Data(book(models: models).utf8)) }
        }
        Harness.expectThrows("an unsupported schema version") {
            _ = try PriceBook(data: Data(book(models: valid, schemaVersion: 2).utf8))
        }
        Harness.expectThrows("an unknown provider") {
            _ = try PriceBook(data: Data("""
                { "schemaVersion": 1, "providers": { "gemini": { "source": "x", "checkedAt": "2026-09-01", "models": [\(valid)] } } }
                """.utf8))
        }
    }
}
