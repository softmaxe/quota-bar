import AppKit
import Combine
import Foundation
import QuotaBarCore
import UniformTypeIdentifiers

enum ExportPeriod: Int, CaseIterable, Identifiable {
    case last7Days = 7
    case last30Days = 30

    var id: Int { self.rawValue }

    var title: String {
        switch self {
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        }
    }
}

enum ExportStatus: Equatable {
    case idle
    case exporting
    case choosingDestination
    case saved(URL)
    case cancelled
    case noRecordedUsage
    case failed(String)
}

/// Reads saved usage and writes one self-contained report without blocking the settings window.
@MainActor
final class ExportSettingsModel: ObservableObject {
    @Published var period: ExportPeriod = .last30Days {
        didSet {
            if !self.isExporting, self.period != oldValue {
                self.status = .idle
            }
        }
    }
    @Published var openAfterExport = true
    @Published private(set) var status: ExportStatus = .idle
    /// Covers the initial database read, the Save panel, rendering, and the atomic write. Keeping
    /// this true for the whole flow prevents a second export while the sheet is open.
    @Published private(set) var isExporting = false

    struct Operations: Sendable {
        let read: @Sendable (Int) throws -> UsageReportSnapshot
        let render: @Sendable (UsageReportSnapshot) throws -> String
        let write: @Sendable (String, URL) throws -> Void

        static let live = Operations(
            read: { try UsageReportReader.read(windowDays: $0, rateCard: RateCard.onDisk()) },
            render: { try UsageReportHTMLRenderer.render($0) },
            write: { html, url in
                try Data(html.utf8).write(to: url, options: .atomic)
            }
        )
    }

    private let operations: Operations

    init(operations: Operations = .live) {
        self.operations = operations
    }

    /// Runs the complete user flow. The data check comes first so an empty period does not ask for
    /// a filename and then produce a misleading report.
    func export() async {
        guard self.beginExport() else { return }
        defer { self.isExporting = false }

        let selectedPeriod = self.period
        let snapshot: UsageReportSnapshot
        do {
            snapshot = try await Self.readSnapshot(
                days: selectedPeriod.rawValue,
                using: self.operations
            )
        } catch {
            self.status = .failed(error.localizedDescription)
            return
        }

        guard snapshot.hasRecordedUsage else {
            self.status = .noRecordedUsage
            return
        }

        self.status = .choosingDestination
        guard let destination = await Self.chooseDestination(
            defaultFilename: snapshot.defaultFilename
        ) else {
            self.status = .cancelled
            return
        }

        self.status = .exporting
        await self.finishExport(snapshot: snapshot, to: destination)
    }

    /// Test and automation entry point that skips the Save panel while exercising the same
    /// background read, render, and atomic-write path.
    @discardableResult
    func export(to destination: URL) async -> Bool {
        guard self.beginExport() else { return false }
        defer { self.isExporting = false }

        let snapshot: UsageReportSnapshot
        do {
            snapshot = try await Self.readSnapshot(
                days: self.period.rawValue,
                using: self.operations
            )
        } catch {
            self.status = .failed(error.localizedDescription)
            return false
        }

        guard snapshot.hasRecordedUsage else {
            self.status = .noRecordedUsage
            return false
        }

        return await self.finishExport(snapshot: snapshot, to: destination)
    }

    func openReport() {
        guard case let .saved(url) = self.status else { return }
        NSWorkspace.shared.open(url)
    }

    func showInFinder() {
        guard case let .saved(url) = self.status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func beginExport() -> Bool {
        guard !self.isExporting else { return false }
        self.isExporting = true
        self.status = .exporting
        return true
    }

    @discardableResult
    private func finishExport(snapshot: UsageReportSnapshot, to destination: URL) async -> Bool {
        let operations = self.operations
        do {
            try await Task.detached(priority: .userInitiated) {
                let html = try operations.render(snapshot)
                try operations.write(html, destination)
            }.value
            self.status = .saved(destination)
            if self.openAfterExport {
                NSWorkspace.shared.open(destination)
            }
            return true
        } catch {
            self.status = .failed(error.localizedDescription)
            return false
        }
    }

    private nonisolated static func readSnapshot(
        days: Int,
        using operations: Operations
    ) async throws -> UsageReportSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try operations.read(days)
        }.value
    }

    private static func chooseDestination(defaultFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Usage Report"
        panel.message = "Save an offline HTML report with usage from all stored sources."
        panel.prompt = "Export"
        panel.nameFieldStringValue = defaultFilename
        panel.allowedContentTypes = [.html]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        return await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
}
