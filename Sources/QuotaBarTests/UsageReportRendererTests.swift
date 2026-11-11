import Foundation
import QuotaBarCore

func runUsageReportRendererTests() {
    do {
        let hostile = "</script><img src=x onerror=alert(1)> {{SCRIPT_BUNDLE}} & \"quoted\" \u{2028}"
        let snapshot = try rendererFixture(model: hostile, total: 1_000, unpriced: 100, cost: 9)
        let html = try UsageReportHTMLRenderer.render(snapshot)
        Harness.expect(html.contains("\\u003c/script>\\u003cimg"), "report JSON escapes markup before entering a script")
        Harness.expect(!html.contains("<img src=x"), "report never inserts raw model markup")
        Harness.expectEqual(html.components(separatedBy: "const REPORT=").count - 1, 1, "placeholder-shaped model text cannot insert another script")
        Harness.expect(!html.contains("src=\"http"), "report does not load external scripts")
        Harness.expect(!html.contains("href=\"http"), "report does not load remote fonts")
        Harness.expect(!html.contains("sourceMappingURL="), "embedded chart library has no external source map")

        guard let start = html.range(of: "const REPORT=")?.upperBound,
              let end = html.range(of: ";\n/* Report runtime */", range: start..<html.endIndex)?.lowerBound else {
            Harness.expect(false, "report embeds its snapshot between the REPORT marker and the runtime")
            return
        }
        let decoded = try JSONDecoder().decode(UsageReportSnapshot.self, from: Data(html[start..<end].utf8))
        Harness.expectEqual(decoded, snapshot, "script-safe encoding preserves the snapshot, hostile identifier included")
        Harness.expectEqual(String(html[start..<end]), try UsageReportHTMLRenderer.scriptLiteral(snapshot),
                            "the usage window's live updates carry the same script-safe JSON the page embeds")
    } catch {
        Harness.expect(false, "report rendering threw: \(error)")
    }
}

private func rendererFixture(model: String, total: Int, unpriced: Int, cost: Double) throws -> UsageReportSnapshot {
    let totals: [String: Any] = [
        "input": total / 10, "output": total / 5, "cacheRead": total * 7 / 10,
        "cacheWrite": 0, "cacheWrite1h": 0, "total": total,
        "unpricedTokens": unpriced, "cost": cost,
    ]
    let source = totals.merging(["name": "Codex", "source": "codex"]) { _, new in new }
    let named = totals.merging(["name": model, "source": "codex"]) { _, new in new }
    let breakdown: [String: Any] = ["input": 1, "output": 2, "cacheRead": 6, "cacheWrite": 0,
                                    "cacheSavings": 50, "fast": 0, "fastPremium": 0]
    let day = totals.merging(["day": "2026-09-15", "recorded": true, "sources": [source],
                              "models": [named], "costBreakdown": breakdown]) { _, new in new }
    let data: [String: Any] = ["days": [day], "history": [day]]
    return try JSONDecoder().decode(UsageReportSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
}
