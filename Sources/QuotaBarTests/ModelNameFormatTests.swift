@testable import QuotaBarApp

/// The short model names the breakdown rows show.
enum ModelNameFormatTests {
    static func run() {
        let cases: [(String, String)] = [
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-haiku-4-5", "Haiku 4.5"),
            ("claude-sonnet-5", "Sonnet 5"),
            ("claude-fable", "Fable"),
            // Older Claude IDs put the version first; they are not rewritten.
            ("claude-3-5-sonnet", "claude-3-5-sonnet"),
            ("claude-opus-4-1-preview", "claude-opus-4-1-preview"),
            ("gpt-5.6-sol", "GPT-5.6 Sol"),
            ("gpt-5", "GPT-5"),
            ("gpt-4o-mini", "GPT-4o Mini"),
            ("deepseek-v4.1-flash", "deepseek-v4.1-flash"),
        ]
        for (model, expected) in cases {
            Harness.expectEqual(Formatters.modelName(model), expected, "short name for \(model)")
        }
    }
}
