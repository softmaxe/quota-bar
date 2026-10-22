#if DEBUG
import AppKit
import Foundation
import QuotaBarCore

/// Writes the usage report without the export pane: a sample for the README, or the saved usage.
@MainActor
enum UsageReportDumps {
    /// Builds documentation data without reading credentials, logs, or the usage database.
    static func dumpSampleReport(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let series = [24, 31, 18, 27, 49, 38, 32, 14, 42, 55, 47, 36, 58, 70, 52,
                      43, 61, 79, 50, 36, 64, 82, 74, 59, 87, 66, 80, 93, 72, 68]
        func usage(_ value: Int, cost: Double) -> UsageReportTotals {
            UsageReportTotals(input: value * 1_200, output: value * 600,
                              cacheRead: value * 7_600, cacheWrite: value * 600,
                              cacheWrite1h: value * 200, cost: cost)
        }
        func sum(_ rows: [UsageReportTotals]) -> UsageReportTotals {
            UsageReportTotals(input: rows.reduce(0) { $0 + $1.input },
                              output: rows.reduce(0) { $0 + $1.output },
                              cacheRead: rows.reduce(0) { $0 + $1.cacheRead },
                              cacheWrite: rows.reduce(0) { $0 + $1.cacheWrite },
                              cacheWrite1h: rows.reduce(0) { $0 + $1.cacheWrite1h },
                              cost: rows.reduce(0) { $0 + $1.cost })
        }
        func breakdown(_ cost: Double, fast: Double) -> UsageReportCostBreakdown {
            UsageReportCostBreakdown(input: cost * 0.1, output: cost * 0.2, cacheRead: cost * 0.55,
                                     cacheWrite: cost * 0.15, cacheSavings: cost * 4.9,
                                     fast: fast, fastPremium: fast / 2)
        }
        // Each day splits between Codex, on two models, and Claude, on one.
        var modelTotals: [String: [UsageReportTotals]] = [:]
        var sourceTotals: [String: [UsageReportTotals]] = [:]
        var fastTotal = 0.0
        let days = series.enumerated().map { index, value in
            let codexShare = 0.55 + 0.25 * sin(Double(index) / 4)
            let codex = Int(Double(value) * codexShare), claude = value - codex
            let astra = codex * 7 / 10
            let parts = [("gpt-6-astra", "codex", astra, 0.9), ("gpt-5.6-sol", "codex", codex - astra, 0.7),
                         ("claude-opus-5", "claude", claude, 0.95)]
            let rows = parts.map { name, source, tokens, rate in (name, source, usage(tokens, cost: Double(tokens) * rate)) }
            let models = rows.map { UsageReportNamedUsage(name: $0.0, source: $0.1, totals: $0.2) }
            let codexUsage = sum(rows.filter { $0.1 == "codex" }.map(\.2))
            let claudeUsage = sum(rows.filter { $0.1 == "claude" }.map(\.2))
            for row in rows { modelTotals[row.0, default: []].append(row.2) }
            sourceTotals["codex", default: []].append(codexUsage)
            sourceTotals["claude", default: []].append(claudeUsage)
            let total = sum([codexUsage, claudeUsage])
            let fast = index.isMultiple(of: 3) ? codexUsage.cost * 0.4 : 0
            fastTotal += fast
            return UsageReportDay(
                day: String(format: "2026-09-%02d", index + 1), recorded: true, totals: total,
                sources: [UsageReportNamedUsage(name: "Codex", source: "codex", totals: codexUsage),
                          UsageReportNamedUsage(name: "Claude", source: "claude", totals: claudeUsage)],
                models: models.sorted { $0.cost > $1.cost },
                costBreakdown: breakdown(total.cost, fast: fast)
            )
        }
        let models = modelTotals.map { name, rows in
            UsageReportNamedUsage(name: name, source: name.hasPrefix("claude") ? "claude" : "codex", totals: sum(rows))
        }.sorted { $0.cost > $1.cost }
        let codexTotals = sum(sourceTotals["codex", default: []])
        let claudeTotals = sum(sourceTotals["claude", default: []])
        let sources = [
            UsageReportNamedUsage(name: "Codex", source: "codex", totals: codexTotals),
            UsageReportNamedUsage(name: "Claude", source: "claude", totals: claudeTotals),
        ]
        let totals = sum([codexTotals, claudeTotals])
        let snapshot = UsageReportSnapshot(period: "2026-09-01 至 2026-09-30", capturedAt: "2026-09-30T18:00:00Z",
                                           timezone: "UTC", totals: totals,
                                           costBreakdown: breakdown(totals.cost, fast: fastTotal), days: days,
                                           models: models, sources: sources, weekdays: [])
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let html = try UsageReportHTMLRenderer.render(snapshot)
            try Data(html.utf8).write(to: root.appendingPathComponent("usage-report.html"), options: .atomic)
        } catch {
            fputs("Sample report generation failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func exportLive(to path: String) -> Never {
        VerifierReport.runAsync {
            let destination = URL(fileURLWithPath: path)
            let model = ExportSettingsModel()
            model.openAfterExport = false
            if await model.export(to: destination) {
                print("Exported saved usage to \(destination.path)")
                exit(0)
            }
            fputs("Report export failed: \(model.status)\n", stderr)
            exit(1)
        }
    }
}
#endif
