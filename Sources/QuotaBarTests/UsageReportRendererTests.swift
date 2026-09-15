import Foundation
import QuotaBarCore

func runUsageReportRendererTests() {
    do {
        let hostile = "</script><img src=x onerror=alert(1)> {{SCRIPT_BUNDLE}} & \"quoted\" \u{2028}"
        let snapshot = try rendererFixture(model: hostile, total: 1_000, unpriced: 100, cost: 9)
        let html = try UsageReportHTMLRenderer.render(snapshot)
        Harness.expect(html.contains("\\u003c/script>\\u003cimg"), "report JSON escapes markup before entering a script")
        Harness.expect(!html.contains("<img src=x"), "report never inserts raw model markup")
        Harness.expectEqual(html.components(separatedBy: "<script>").count - 1, 4, "report has only its four trusted script blocks")
        Harness.expectEqual(html.components(separatedBy: "const REPORT=").count - 1, 1, "placeholder-shaped model text cannot insert another script")
        Harness.expect(!html.contains("src=\"http"), "report does not load external scripts")
        Harness.expect(!html.contains("href=\"http"), "report does not load remote fonts")
        Harness.expect(!html.contains("sourceMappingURL="), "embedded chart library has no external source map")
        Harness.expectEqual(html.components(separatedBy: "data-chart=").count - 1, 3, "approved trend report retains three chart slots")
        Harness.expect(html.contains("data-language=\"zh\"") && html.contains("data-language=\"en\""), "export retains both language controls")
        Harness.expect(html.contains("id=\"daily-table\"") && html.contains("id=\"model-table\""), "exact values remain available through semantic tables")
        Harness.expect(html.contains("Chart.js v4.5.1"), "chart library ships inside the offline report")

        let start = html.range(of: "const REPORT=")!.upperBound
        let end = html.range(of: ";\n/* Report runtime */", range: start..<html.endIndex)!.lowerBound
        let decoded = try JSONDecoder().decode(UsageReportSnapshot.self, from: Data(html[start..<end].utf8))
        Harness.expectEqual(decoded.models.first?.name, hostile, "script-safe encoding preserves the original identifier")
        Harness.expectEqual(decoded.totals.total, 1_000, "embedded snapshot matches displayed metrics")
        Harness.expectEqual(decoded.totals.cost, 9, "frozen partial costs are not recomputed")
        Harness.expectEqual(decoded.totals.unpricedTokens, 100, "unpriced usage reaches the bilingual runtime")
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
    let day = totals.merging(["day": "2026-09-15", "recorded": true]) { _, new in new }
    let named = totals.merging(["name": model]) { _, new in new }
    let source = totals.merging(["name": "Codex"]) { _, new in new }
    let data: [String: Any] = [
        "period": "2026-09-15 至 2026-09-15", "capturedAt": "2026-09-15T12:00:00Z",
        "timezone": "Asia/Shanghai", "totals": totals, "days": [day],
        "models": [named], "sources": [source], "weekdays": [["name": "周二", "total": total]],
    ]
    return try JSONDecoder().decode(UsageReportSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
}
