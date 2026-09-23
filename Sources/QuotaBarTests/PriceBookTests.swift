import Foundation
import QuotaBarCore

/// The shipped price book is data, so these checks are what stop a malformed or incomplete edit
/// from reaching a release.
enum PriceBookTests {
    static func run() {
        Self.bundledBookIsComplete()
        Self.reportsStaleSources()
        Self.datedLookup()
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
                    CostPricing.normalize(model.id, provider: provider),
                    model.id,
                    "\(model.id) is already a normalized name, so stored usage can find it"
                )
                for alias in model.aliases {
                    Harness.expectEqual(
                        CostPricing.normalize(alias, provider: provider),
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
        Harness.expectEqual(
            CostPricing.cost(
                totals: TokenTotals(input: 1_000_000),
                model: "dated-model",
                provider: .codex,
                longContext: false,
                day: "2026-12-01",
                book: book
            ),
            5,
            "cost uses the period in force on the usage day"
        )
        Harness.expectEqual(
            CostPricing.cost(
                totals: TokenTotals(input: 1_000_000),
                model: "dated-model",
                provider: .codex,
                longContext: false,
                day: "2026-12-01",
                overlay: PricingOverlay(userOverrides: ["dated-model": ModelPricing(input: 1, output: 1)]),
                book: book
            ),
            1,
            "a user override applies on every day"
        )
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
