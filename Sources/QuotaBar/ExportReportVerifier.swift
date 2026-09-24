#if DEBUG
import AppKit
import Foundation
import QuotaBarCore
import SwiftUI

@MainActor
enum ExportReportVerifier {
    static func run() -> Never {
        Task {
            let failures = await Self.verify()
            VerifierReport.finish(failures, label: "report export", passed: "Report export saves HTML, handles errors and empty data, and rejects duplicate work")
        }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
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

    static func dump(directory: String) {
        let root = OffscreenCapture.directory(directory)
        let defaults = EphemeralDefaults.make("QuotaBarExportDump")
        defer { EphemeralDefaults.clear("QuotaBarExportDump") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let selection = SettingsSelection()
        selection.tab = .export
        let pricing = PricingEditorModel(costService: CostService(), fixtures: .init(usage: [:]))
        for (name, appearance) in [("export-settings-dark", NSAppearance.Name.darkAqua), ("export-settings-light", .aqua)] {
            let hosting = NSHostingView(rootView: SettingsView(settings: SettingsStore(defaults: defaults), pricing: pricing, selection: selection))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame.size = hosting.fittingSize
            _ = OffscreenCapture.writePNG(hosting, named: name, into: root, titled: true, settle: 0.3)
        }
    }

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
        Task {
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
        RunLoop.main.run()
        fatalError("export run loop stopped")
    }
}
#endif
