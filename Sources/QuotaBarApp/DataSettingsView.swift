import QuotaBarCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Backing up and restoring saved usage. Saved usage outlives the session logs it came from, so
/// a backup is the only copy of it once this Mac's QuotaBar data is gone.
@MainActor
final class UsageBackupModel: ObservableObject {
    enum Activity {
        case exporting
        case importing
    }

    enum Outcome: Equatable {
        case exported(fileName: String)
        case imported(UsageImportResult)
        case failed(String)
    }

    /// nil until read, and when the database cannot be read.
    @Published private(set) var summary: SavedUsageSummary?
    @Published private(set) var activity: Activity?
    @Published private(set) var outcome: Outcome?

    private let settings: SettingsStore
    private let store: UsageStore
    private let fixture: SavedUsageSummary?

    /// `fixture` stands in for the saved usage, for dumps.
    init(settings: SettingsStore, store: UsageStore, fixture: SavedUsageSummary? = nil) {
        self.settings = settings
        self.store = store
        self.fixture = fixture
        self.summary = fixture
    }

    func loadSummary() async {
        guard self.fixture == nil else { return }
        let databaseURL = self.store.costService.databaseURL
        self.summary = await Task.detached(priority: .utility) {
            try? CostUsageReader.savedUsage(databaseURL: databaseURL)
        }.value
    }

    func exportBackup(to url: URL) async {
        self.activity = .exporting
        defer { self.activity = nil }
        do {
            try await self.store.costService.exportBackup(to: url)
            self.settings.lastUsageExport = Date()
            self.outcome = .exported(fileName: url.lastPathComponent)
        } catch {
            self.outcome = .failed(error.localizedDescription)
        }
    }

    func importBackup(from url: URL) async {
        self.activity = .importing
        defer { self.activity = nil }
        do {
            self.outcome = .imported(try await self.store.costService.importBackup(from: url))
            self.store.refreshAllLocalUsageAfterChange()
            await self.loadSummary()
        } catch {
            self.outcome = .failed(error.localizedDescription)
        }
    }
}

/// How much usage is saved, and the two ways to move it. Importing only ever adds, so neither
/// action asks for confirmation.
struct DataSettingsView: View {
    @ObservedObject var model: UsageBackupModel
    @ObservedObject var settings: SettingsStore
    /// Zero while the pane is out of view; any other change rereads what is saved.
    var reload = 0

    var body: some View {
        SettingsPane("Data") {
            HStack(spacing: 0) {
                self.figure("Records", self.model.summary.map { $0.records.formatted() } ?? "—")
                Divider()
                self.figure("Saved since", self.firstDay)
                Divider()
                self.figure("On disk", self.size)
            }
            .fixedSize(horizontal: false, vertical: true)
            .settingsGroup()

            SettingsSectionTitle("Backup")
            VStack(spacing: 0) {
                SettingsRow(
                    symbol: "square.and.arrow.up",
                    title: "Export a backup",
                    detail: self.exportDetail
                ) {
                    Button("Export…") { Task { await self.chooseExportDestination() } }
                        .disabled(self.model.activity != nil || self.model.summary?.records == 0)
                }
                Divider().padding(.leading, 50)
                SettingsRow(
                    symbol: "square.and.arrow.down",
                    title: "Import a backup",
                    detail: "Adds what this Mac is missing. Removes nothing."
                ) {
                    Button("Import…") { Task { await self.chooseBackup() } }
                        .disabled(self.model.activity != nil)
                }
            }
            .controlSize(.small)
            .settingsGroup()

            self.status
                .padding(.top, 10)
                .padding(.leading, 2)
        }
        .task(id: self.reload) {
            guard self.reload != 0 else { return }
            await self.model.loadSummary()
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if let activity = self.model.activity {
                ProgressView().controlSize(.small)
                Text(activity == .exporting ? "Exporting…" : "Importing…")
            } else if let outcome = self.model.outcome {
                switch outcome {
                case let .exported(fileName):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(fileName).")
                case let .imported(result):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(Self.summary(of: result))
                case let .failed(reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(reason)
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(2)
        .frame(minHeight: 18, alignment: .leading)
    }

    private static func summary(of result: UsageImportResult) -> String {
        let records = result.added == 1 ? "1 record" : "\(result.added.formatted()) records"
        switch (result.added, result.updated) {
        case (0, 0): return "Nothing to add. This Mac already has everything in that backup."
        case (_, 0): return "Added \(records)."
        case (0, _): return "Updated \(result.updated.formatted()) from the backup."
        default: return "Added \(records) and updated \(result.updated.formatted())."
        }
    }

    private var firstDay: String {
        guard let day = self.model.summary?.firstDay else { return "—" }
        return "\(Formatters.dayLabel(day)), \(day.prefix(4))"
    }

    private var size: String {
        guard let bytes = self.model.summary?.bytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var exportDetail: String {
        guard let exported = self.settings.lastUsageExport else {
            return "Not exported yet"
        }
        return "Last exported \(Formatters.relativeAge(since: exported))"
    }

    private func chooseExportDestination() async {
        let panel = NSSavePanel()
        panel.title = "Export Usage Backup"
        panel.allowedContentTypes = Self.backupTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "QuotaBar-Backup-\(DayKey.make(from: Date())).sqlite"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await self.model.exportBackup(to: url)
    }

    private func chooseBackup() async {
        let panel = NSOpenPanel()
        panel.title = "Import Usage Backup"
        panel.prompt = "Import"
        panel.allowedContentTypes = Self.backupTypes
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await self.model.importBackup(from: url)
    }

    private static var backupTypes: [UTType] {
        [UTType(filenameExtension: "sqlite") ?? .data]
    }
}
