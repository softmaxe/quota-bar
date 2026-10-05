import Foundation

/// The environment every `CostService` in these checks scans with. A source whose variable is
/// unset falls back to the developer's home directory, so each one resolves under `root`, and a
/// check names only the roots its fixture populates in `overrides`.
func isolatedEnvironment(root: URL, overriding overrides: [String: String] = [:]) -> [String: String] {
    [
        "HOME": root.path,
        "CODEX_HOME": root.appendingPathComponent("codex").path,
        "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
        "OPENCODE_DATA_HOME": root.appendingPathComponent("opencode").path,
        "PI_CODING_AGENT_DIR": root.appendingPathComponent("pi").path,
    ].merging(overrides) { $1 }
}
