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
        let names = ["gpt-6-astra", "claude-opus-5", "gpt-5.6-sol", "gpt-5.6-luna"]
        let entries = series.map { value in
            UsageReportTotals(input: value * 1_200, output: value * 600,
                              cacheRead: value * 7_600, cacheWrite: value * 600,
                              cacheWrite1h: value * 200, cost: Double(value) * 0.85)
        }
        func sum(_ rows: [UsageReportTotals]) -> UsageReportTotals {
            UsageReportTotals(input: rows.reduce(0) { $0 + $1.input },
                              output: rows.reduce(0) { $0 + $1.output },
                              cacheRead: rows.reduce(0) { $0 + $1.cacheRead },
                              cacheWrite: rows.reduce(0) { $0 + $1.cacheWrite },
                              cacheWrite1h: rows.reduce(0) { $0 + $1.cacheWrite1h },
                              cost: rows.reduce(0) { $0 + $1.cost })
        }
        let days = entries.enumerated().map { index, totals in
            UsageReportDay(day: String(format: "2026-09-%02d", index + 1), recorded: true, totals: totals)
        }
        let models = names.enumerated().map { index, name in
            UsageReportNamedUsage(name: name, totals: sum(entries.enumerated().compactMap { $0.offset % 4 == index ? $0.element : nil }))
        }
        let sources = [
            UsageReportNamedUsage(name: "Codex", totals: sum(entries.enumerated().compactMap { $0.offset % 4 != 1 ? $0.element : nil })),
            UsageReportNamedUsage(name: "Claude", totals: sum(entries.enumerated().compactMap { $0.offset % 4 == 1 ? $0.element : nil })),
        ]
        let snapshot = UsageReportSnapshot(period: "2026-09-01 至 2026-09-30", capturedAt: "2026-09-30T18:00:00Z",
                                           timezone: "UTC", totals: sum(entries), days: days,
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
