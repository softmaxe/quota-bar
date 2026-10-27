import AppKit
import Combine
import QuotaBarCore
import SwiftUI
import WebKit

/// The usage report, kept current from the cost database while the window is open. New usage
/// replaces the page's data in place, so the period, metric, breakdown, and language the user
/// picked stay as they are.
@MainActor
final class UsageReportWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    struct Operations: Sendable {
        let read: @Sendable () throws -> UsageReportSnapshot
        let render: @Sendable (UsageReportSnapshot) throws -> String

        static let live = Operations(
            // The window opens on 30 days unless the page remembers another choice.
            read: { try UsageReportReader.read(windowDays: 30, rateCard: RateCard.onDisk()) },
            render: { try UsageReportHTMLRenderer.render($0) }
        )
    }

    /// How often an open window rescans local logs. Scans are incremental, so after the first
    /// pass each one only reads what the sources appended since.
    static let rescanInterval: TimeInterval = 60

    private let operations: Operations
    private let store: UsageStore?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var emptyView: NSView?
    private var scanObserver: AnyCancellable?
    private var timer: Timer?

    /// The page has run its script and can take `updateReport`.
    private var isPageReady = false
    private var isPageRequested = false
    private var readTask: Task<Void, Never>?
    private var needsAnotherRead = false
    /// What the page shows, so an unchanged read leaves it alone.
    private var shownSnapshot: UsageReportSnapshot?
    /// Arrived while the page was still loading.
    private var pendingSnapshot: UsageReportSnapshot?

    /// The page keeps its view choices in local storage under this path, so they survive
    /// relaunches. Nothing is written there; the page is loaded from memory.
    private static let pageURL = AppSupport.directory.appendingPathComponent("usage-report.html")

    init(store: UsageStore?, operations: Operations = .live) {
        self.store = store
        self.operations = operations
    }

    var isVisible: Bool { self.window?.isVisible ?? false }

    func show() {
        let window = self.window ?? self.makeWindow()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.startLiveUpdates()
    }

    // MARK: Live updates

    private func startLiveUpdates() {
        // Reading the database is quick; show what is saved now, then again after the scans.
        self.reload()
        self.store?.refreshAllLocalUsage()
        guard self.timer == nil else { return }

        // Any scan that finishes, whichever path started it, may have saved new usage.
        self.scanObserver = self.store?.$displays
            .map { displays in Provider.allCases.map { displays[$0]?.localScanStatus } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] statuses in
                guard statuses.contains(where: { if case .completed = $0 { true } else { false } }) else { return }
                self?.reload()
            }
        let timer = Timer(timeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Without a store this still rereads, which also moves the page past midnight.
                if let store = self.store { store.refreshAllLocalUsage() } else { self.reload() }
            }
        }
        timer.tolerance = Self.rescanInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopLiveUpdates() {
        self.timer?.invalidate()
        self.timer = nil
        self.scanObserver = nil
    }

    /// Rereads the database off the main thread. Requests made during a read coalesce into one
    /// more read after it.
    func reload() {
        guard self.readTask == nil else {
            self.needsAnotherRead = true
            return
        }
        let read = self.operations.read
        self.readTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try read() }
            }.value
            guard let self else { return }
            self.readTask = nil
            self.apply(result)
            if self.needsAnotherRead {
                self.needsAnotherRead = false
                self.reload()
            }
        }
    }

    private func apply(_ result: Result<UsageReportSnapshot, Error>) {
        switch result {
        case let .failure(error):
            // A failed read leaves a page that already shows usage as it is.
            Log.ui.error("Usage report read failed: \(error.localizedDescription, privacy: .public)")
            if self.shownSnapshot == nil { self.showEmpty(message: error.localizedDescription) }
        case let .success(snapshot):
            guard snapshot.hasRecordedUsage else {
                self.showEmpty(message: nil)
                return
            }
            self.show(snapshot)
        }
    }

    private func show(_ snapshot: UsageReportSnapshot) {
        guard let webView = self.webView else { return }
        self.emptyView?.isHidden = true
        guard self.isPageRequested else {
            do {
                let html = try self.operations.render(snapshot)
                self.isPageRequested = true
                self.shownSnapshot = snapshot
                webView.loadHTMLString(html, baseURL: Self.pageURL)
            } catch {
                self.showEmpty(message: error.localizedDescription)
            }
            return
        }
        guard self.isPageReady else {
            self.pendingSnapshot = snapshot
            return
        }
        guard snapshot != self.shownSnapshot else { return }
        do {
            let literal = try UsageReportHTMLRenderer.scriptLiteral(snapshot)
            self.shownSnapshot = snapshot
            webView.evaluateJavaScript("window.updateReport(\(literal));void 0") { _, error in
                if let error {
                    Log.ui.error("Usage report update failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Log.ui.error("Usage report encoding failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func showEmpty(message: String?) {
        guard let window = self.window else { return }
        self.emptyView?.removeFromSuperview()
        let empty = NSHostingView(rootView: UsageReportEmptyView(failure: message))
        empty.frame = window.contentView?.bounds ?? .zero
        empty.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(empty)
        self.emptyView = empty
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780), configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        // Hidden until the page has drawn, so a dark window never flashes white.
        webView.isHidden = true
        self.webView = webView

        let container = NSView(frame: webView.frame)
        container.addSubview(webView)
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Usage"
        window.contentView = container
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("QuotaBarUsageReport")
        self.window = window
        return window
    }

    func windowWillClose(_: Notification) {
        // The page stays loaded, so reopening keeps its scroll position and choices.
        self.stopLiveUpdates()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        self.isPageReady = true
        webView.isHidden = false
        if let pending = self.pendingSnapshot {
            self.pendingSnapshot = nil
            self.show(pending)
        }
    }

    /// The page is self-contained. Nothing it does may navigate the window away.
    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(self.isPageReady || action.navigationType != .other ? .cancel : .allow)
    }

#if DEBUG
    /// The loaded page, for the preview dump.
    var debugWebView: WKWebView? { self.isPageReady ? self.webView : nil }
#endif
}

private struct UsageReportEmptyView: View {
    let failure: String?

    var body: some View {
        if let failure {
            ContentUnavailableView {
                Label("Usage could not be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            }
        } else {
            ContentUnavailableView {
                Label("No saved usage yet", systemImage: "tray")
            } description: {
                Text("Usage appears here once QuotaBar has scanned local sessions from Codex, Claude Code, OpenCode, or Pi Agent.")
            }
        }
    }
}
