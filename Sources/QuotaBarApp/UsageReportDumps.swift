#if DEBUG
import AppKit
import Foundation
import QuotaBarCore

/// Renders the usage report on sample data, for the README image and for checking the usage window.
@MainActor
enum UsageReportDumps {
    /// The interface preview shares the report fixtures without ever reading the live database.
    static var sampleOperations: UsageReportWindowController.Operations {
        let snapshot = Self.sampleSnapshot()
        return .init(read: { snapshot }, render: { try UsageReportHTMLRenderer.render($0) })
    }

    /// Builds documentation data without reading credentials, logs, or the usage database.
    static func dumpSampleReport(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let html = try UsageReportHTMLRenderer.render(Self.sampleSnapshot())
            try Data(html.utf8).write(to: root.appendingPathComponent("usage-report.html"), options: .atomic)
        } catch {
            fputs("Sample report generation failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Thirty days of synthetic Codex and Claude usage, ending on 2026-09-30, or on an earlier
    /// day when `days` is shorter.
    static func sampleSnapshot(days dayCount: Int = 30) -> UsageReportSnapshot {
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
        let days = series.prefix(dayCount).enumerated().map { index, value in
            let codexShare = 0.55 + 0.25 * sin(Double(index) / 4)
            let codex = Int(Double(value) * codexShare), claude = value - codex
            let astra = codex * 7 / 10
            let parts = [("gpt-6-astra", "codex", astra, 0.9), ("gpt-5.6-sol", "codex", codex - astra, 0.7),
                         ("claude-opus-5", "claude", claude, 0.95)]
            let rows = parts.map { name, source, tokens, rate in (name, source, usage(tokens, cost: Double(tokens) * rate)) }
            let models = rows.map { UsageReportNamedUsage(name: $0.0, source: $0.1, totals: $0.2) }
            let codexUsage = sum(rows.filter { $0.1 == "codex" }.map(\.2))
            let claudeUsage = sum(rows.filter { $0.1 == "claude" }.map(\.2))
            let total = sum([codexUsage, claudeUsage])
            let fast = index.isMultiple(of: 3) ? codexUsage.cost * 0.4 : 0
            return UsageReportDay(
                day: String(format: "2026-09-%02d", index + 1), recorded: true, totals: total,
                sources: [UsageReportNamedUsage(name: "Codex", source: "codex", totals: codexUsage),
                          UsageReportNamedUsage(name: "Claude", source: "claude", totals: claudeUsage)],
                models: models.sorted { $0.cost > $1.cost },
                costBreakdown: breakdown(total.cost, fast: fast)
            )
        }
        return UsageReportSnapshot(days: days)
    }

    /// Opens the usage window on 29 sample days, then hands it the thirtieth as a live update
    /// and writes what the page shows to `<directory>/usage-window.png`.
    static func dumpUsageWindow(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let snapshots = UsageSnapshots(first: Self.sampleSnapshot(days: 29), second: Self.sampleSnapshot())
        let controller = UsageReportWindowController(store: nil, operations: .init(
            read: { snapshots.next() },
            render: { try UsageReportHTMLRenderer.render($0) }
        ))
        NSApplication.shared.setActivationPolicy(.accessory)
        controller.show()
        func spin(until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }
        guard spin(until: { controller.debugWebView != nil }), let webView = controller.debugWebView else {
            fputs("Usage window never loaded\n", stderr)
            exit(1)
        }
        controller.reload()
        var lastDay: String?
        _ = spin(until: {
            webView.evaluateJavaScript("document.querySelector('[data-range-to]').max") { value, _ in
                lastDay = value as? String
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return lastDay == "2026-09-30"
        })
        guard lastDay == "2026-09-30" else {
            fputs("Usage window kept \(lastDay ?? "nothing") after the live update\n", stderr)
            exit(1)
        }
        func evaluate(_ script: String) -> Any? {
            var finished = false
            var result: Any?
            var failure: Error?
            webView.evaluateJavaScript(script) { value, error in
                result = value
                failure = error
                finished = true
            }
            guard spin(until: { finished }), failure == nil else {
                fputs("Usage window script failed: \(failure?.localizedDescription ?? "timed out")\n", stderr)
                exit(1)
            }
            return result
        }
        func settle() {
            // An occluded WKWebView may suspend animation frames, so wait on the native run loop.
            webView.layoutSubtreeIfNeeded()
            _ = evaluate("document.getAnimations().forEach(animation=>animation.finish());document.documentElement.getBoundingClientRect().height")
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        func capture(_ name: String) {
            settle()
            var image: NSImage?
            webView.takeSnapshot(with: nil) { snapshot, _ in image = snapshot }
            guard spin(until: { image != nil }), let tiff = image?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                fputs("Usage window snapshot failed\n", stderr)
                exit(1)
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let url = root.appendingPathComponent(name)
                try png.write(to: url)
                print("Wrote \(url.path)")
            } catch {
                fputs("Usage window snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
        // Additional states must not replace the view the user had saved before the dump.
        _ = evaluate("window.__usageDumpStoredState=localStorage.getItem('quotabar-report:'+location.pathname);true;")
        capture("usage-window.png")
        for (name, language, metric, period, appearance, breakdown) in [
            ("en-cost-30-dark.png", "en", "cost", "30", NSAppearance.Name.darkAqua, "model"),
            ("en-tokens-7-dark.png", "en", "tokens", "7", .darkAqua, "model"),
            ("zh-cost-30-light.png", "zh", "cost", "30", .aqua, "model"),
            ("en-tokens-7-light.png", "en", "tokens", "7", .aqua, "model"),
            ("en-cost-30-day-dark.png", "en", "cost", "30", .darkAqua, "day"),
        ] {
            webView.window?.appearance = NSAppearance(named: appearance)
            _ = evaluate("""
                document.querySelector('[data-language="\(language)"]').click();
                document.querySelector('[data-metric="\(metric)"]').click();
                document.querySelector('[data-period="\(period)"]').click();
                document.querySelector('[data-breakdown="\(breakdown)"]').click();
                window.scrollTo(0,0);
                true;
                """)
            if breakdown == "day" {
                _ = evaluate("window.scrollTo(0,document.querySelector('.breakdown').offsetTop-68);true;")
            }
            capture(name)
        }
        _ = evaluate("""
            if(window.__usageDumpStoredState===null)localStorage.removeItem('quotabar-report:'+location.pathname);
            else localStorage.setItem('quotabar-report:'+location.pathname,window.__usageDumpStoredState);
            true;
            """)
    }

    /// Opens only the usage window, on the saved usage, beside an installed QuotaBar that keeps
    /// scanning. Without a store the window rereads the database every minute instead.
    static func previewLiveWindow() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = UsageReportWindowController(store: nil)
        controller.show()
        Self.previewWindow = controller
        // Closing the window ends the preview, which has no menu bar item to quit from.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static var previewWindow: UsageReportWindowController?
}

/// Hands out the first snapshot once, then the second: one load and one live update.
private final class UsageSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let first: UsageReportSnapshot
    private let second: UsageReportSnapshot

    init(first: UsageReportSnapshot, second: UsageReportSnapshot) {
        self.first = first
        self.second = second
    }

    func next() -> UsageReportSnapshot {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.reads += 1
        return self.reads == 1 ? self.first : self.second
    }
}
#endif
