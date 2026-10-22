#if DEBUG
import AppKit
import Foundation
import QuotaBarCore

@MainActor
enum ExportReportVerifier {
    static func run() -> Never {
        VerifierReport.runAsync {
            let failures = await Self.verify()
            VerifierReport.finish(failures, label: "report export", passed: "Report export saves HTML, handles errors and empty data, and rejects duplicate work")
        }
    }

    private static func verify() async -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBarExportVerifier-\(UUID().uuidString)")
        var failures: [String] = []
        func expect(_ condition: Bool, _ description: String) {
            if !condition { failures.append(description) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = Self.fixture()
            let destination = directory.appendingPathComponent("usage.html")
            let operations = ExportSettingsModel.Operations(
                read: { days in
                    guard !Thread.isMainThread, days == 7 else { throw CheckError.wrongExecution }
                    return fixture
                },
                render: { try UsageReportHTMLRenderer.render($0) },
                write: ExportSettingsModel.Operations.live.write
            )
            let model = ExportSettingsModel(operations: operations)
            model.openAfterExport = false
            model.period = .last7Days
            let saved = await model.export(to: destination)
            expect(saved && model.status == .saved(destination), "successful export should identify its saved file")
            expect(!model.isExporting, "successful export should release its busy state")
            let html = try String(contentsOf: destination, encoding: .utf8)
            expect(html.contains("const REPORT=") && html.contains("data-chart=\"daily\""), "saved HTML should contain the real report and data")
            expect(!html.contains("{{HEAD_BUNDLE}}"), "saved HTML should resolve the bundled template")

            let blocked = directory.appendingPathComponent("missing/usage.html")
            expect(!(await model.export(to: blocked)), "write to a missing parent should fail")
            if case .failed = model.status {} else { failures.append("write error should be visible") }
            expect(!model.isExporting, "write error should release its busy state")
            expect(try String(contentsOf: destination, encoding: .utf8) == html, "failed save should preserve the previous report")
            expect(await model.export(to: destination), "a failed export should be retryable")

            let empty = ExportSettingsModel(operations: .init(
                read: { _ in Self.emptyFixture },
                render: { _ in throw CheckError.unexpectedWrite },
                write: { _, _ in throw CheckError.unexpectedWrite }
            ))
            empty.openAfterExport = false
            let emptyURL = directory.appendingPathComponent("empty.html")
            expect(!(await empty.export(to: emptyURL)), "empty data should not export a report")
            expect(empty.status == .noRecordedUsage && !FileManager.default.fileExists(atPath: emptyURL.path), "empty data should explain the missing records without writing a file")

            let failure = ExportSettingsModel(operations: .init(
                read: { _ in throw CheckError.unavailable },
                render: { try UsageReportHTMLRenderer.render($0) },
                write: ExportSettingsModel.Operations.live.write
            ))
            failure.openAfterExport = false
            expect(!(await failure.export(to: emptyURL)), "read failure should not report success")
            expect(failure.status == .failed(CheckError.unavailable.localizedDescription), "read failure should expose its actionable reason")
            expect(!failure.isExporting && !FileManager.default.fileExists(atPath: emptyURL.path),
                   "read failure should release its busy state without creating a destination")
            expect(!(await failure.export(to: destination)), "retrying a failed read should still report failure")
            expect(try String(contentsOf: destination, encoding: .utf8) == html,
                   "read failure should preserve an existing destination unchanged")

            let gate = DispatchSemaphore(value: 0)
            let duplicate = ExportSettingsModel(operations: .init(
                read: { _ in
                    guard gate.wait(timeout: .now() + 5) == .success else { throw CheckError.unavailable }
                    return fixture
                },
                render: { try UsageReportHTMLRenderer.render($0) },
                write: ExportSettingsModel.Operations.live.write
            ))
            duplicate.openAfterExport = false
            let first = Task { await duplicate.export(to: destination) }
            while !duplicate.isExporting { await Task.yield() }
            expect(!(await duplicate.export(to: emptyURL)), "second export should be rejected while the first is reading")
            gate.signal()
            expect(await first.value, "first export should complete after the blocked read")
            expect(!FileManager.default.fileExists(atPath: emptyURL.path), "duplicate request should never write a second file")
        } catch {
            failures.append(error.localizedDescription)
        }
        return failures
    }

    private enum CheckError: LocalizedError {
        case unavailable, unexpectedWrite, wrongExecution
        var errorDescription: String? {
            switch self {
            case .unavailable: "The saved usage database is unavailable."
            case .unexpectedWrite: "An empty report should never be written."
            case .wrongExecution: "The reader must use the selected period on a background thread."
            }
        }
    }

    private nonisolated static var emptyFixture: UsageReportSnapshot {
        UsageReportSnapshot(period: "2026-09-09 至 2026-09-15", capturedAt: "2026-09-15T12:00:00Z", timezone: "Asia/Shanghai",
                            totals: UsageReportTotals(), days: [UsageReportDay(day: "2026-09-15", recorded: false)],
                            models: [], sources: [], weekdays: [])
    }

    private nonisolated static func fixture() -> UsageReportSnapshot {
        let totals = UsageReportTotals(input: 10_000, output: 2_000, cacheRead: 100_000, cost: 1.5)
        return UsageReportSnapshot(
            period: "2026-09-09 至 2026-09-15", capturedAt: "2026-09-15T12:00:00Z", timezone: "Asia/Shanghai",
            totals: totals, days: [UsageReportDay(day: "2026-09-15", recorded: true, totals: totals)],
            models: [UsageReportNamedUsage(name: "gpt-6-astra", totals: totals)],
            sources: [UsageReportNamedUsage(name: "Codex", totals: totals)],
            weekdays: [UsageReportWeekday(name: "周二", total: totals.total)]
        )
    }

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
