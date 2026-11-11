import QuotaBarCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What usage is saved, where it comes from, and how to keep a copy: this Mac, the SSH hosts whose
/// logs count toward it, and backups. Importing only ever adds, so neither backup action asks for
/// confirmation.
struct UsageSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore
    @ObservedObject var remote: RemoteSyncModel
    @ObservedObject var backup: UsageBackupModel
    /// Zero while the pane is out of view; any other change rereads what is saved and what the
    /// mirrors hold.
    var reload = 0

    @State private var isAddingHost = false
    /// Read when the sheet opens, so a host added to the config meanwhile shows up.
    @State private var configHosts: [String] = []

    var body: some View {
        SettingsPane("Usage") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    self.sources
                    self.backupSection
                }
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: self.$isAddingHost) {
            AddHostSheet(hosts: self.suggestedHosts) { self.remote.add($0) }
        }
        .task(id: self.reload) {
            guard self.reload != 0 else { return }
            await self.remote.loadUsage()
            await self.backup.loadSummary()
        }
    }

    // MARK: - Saved usage

    /// "56,412 records since Nov 3, 2025 · 27.4 MB", or what is known of it so far.
    private var savedSummary: String {
        guard let summary = self.backup.summary else { return "Reading what is saved…" }
        let records = summary.records == 1 ? "1 record" : "\(summary.records.formatted()) records"
        let since = summary.firstDay == nil ? records : "\(records) since \(self.firstDay)"
        return summary.bytes > 0 ? "\(since) · \(self.size)" : since
    }

    private var firstDay: String {
        guard let day = self.backup.summary?.firstDay else { return "—" }
        return "\(Formatters.dayLabel(day)), \(day.prefix(4))"
    }

    private var size: String {
        guard let bytes = self.backup.summary?.bytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Sources

    private var sources: some View {
        SettingsSection("Sources") {
            if !self.settings.remoteHosts.isEmpty {
                Button("Sync now", systemImage: "arrow.clockwise") { self.remote.syncAll() }
                    .labelStyle(.titleAndIcon)
                    .disabled(self.remote.isSyncing)
            }
            Button("Add host", systemImage: "plus") {
                self.configHosts = SSHConfigHosts.userHosts()
                self.isAddingHost = true
            }
            .labelStyle(.titleAndIcon)
        } content: {
            VStack(spacing: 0) {
                SettingsRow(symbol: "laptopcomputer", title: "This Mac", detail: self.thisMacDetail) {
                    EmptyView()
                }
                ForEach(self.settings.remoteHosts, id: \.self) { host in
                    Divider()
                    self.hostRow(host)
                }
                if self.settings.remoteHosts.isEmpty {
                    Divider()
                    self.noHostsRow
                }
                // Only with a host to sync does the switch have anything to act on.
                if !self.settings.remoteHosts.isEmpty {
                    Divider()
                    SettingsRow(title: "Sync automatically") {
                        Toggle("Sync automatically", isOn: self.$settings.remoteAutoSync)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
            }
            .settingsGroup()
        }
    }

    /// The freshest of the providers' local scans, or what one still running or failed has to say.
    private var thisMacDetail: String {
        let statuses = self.store.displays.values.map(\.localScanStatus)
        if statuses.contains(.scanning) { return "Scanning…" }
        let scans = statuses.compactMap { status -> Date? in
            if case let .completed(date) = status { date } else { nil }
        }
        if let latest = scans.max() { return "Scanned \(Formatters.relativeAge(since: latest))" }
        for case let .failed(reason) in statuses { return reason }
        return "Waiting for the first scan"
    }

    private func hostRow(_ host: String) -> some View {
        let state = self.remote.state(of: host)
        let usage = self.remote.usage[host]
        let detail = Self.detail(of: state, usage: usage)
        return SettingsRow(
            symbol: "server.rack",
            title: host,
            detail: detail,
            detailColor: Self.detailColor(state, usage: usage)
        ) {
            if case .failed = state {
                Button("Retry", systemImage: "arrow.clockwise") { self.remote.sync(host) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.trailing, 6)
            }
            if state == .syncing {
                ProgressView().controlSize(.small)
            }
            if let usage, usage.records > 0 || usage.files > 0 {
                Text(Self.count(usage.records, "record"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(usage.records == 0 ? Color.orange : Color.primary)
                    .monospacedDigit()
                    .fixedSize()
                    .help("Recorded usage from this host. Unique records were first recorded from this host.")
            }
            Menu {
                Button("Sync this host") { self.remote.sync(host) }
                    .disabled(state == .syncing)
                Button("Stop syncing") { self.remote.remove(host) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(host)")
            .help("Stop syncing keeps the usage already recorded.")
        }
        .help(Self.tooltip(state: state, usage: usage, detail: detail))
    }

    private var noHostsRow: some View {
        Text("Add a host to count usage from another machine over SSH.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    private var suggestedHosts: [String] {
        self.configHosts.filter { !self.settings.remoteHosts.contains($0) }
    }

    private static func detail(of state: RemoteHostSyncState, usage: RemoteHostUsage?) -> String {
        switch state {
        case .idle: self.joined("Waiting for the next sync", usage)
        case .syncing: "Syncing…"
        case let .synced(date): self.joined("Synced \(Formatters.relativeAge(since: date))", usage)
        case let .failed(reason): self.failureSummary(reason)
        }
    }

    /// A short line for the row; the raw message stays in the row's tooltip.
    private static func failureSummary(_ reason: String) -> String {
        let lowered = reason.lowercased()
        if lowered.contains("timed out") || lowered.contains("connect to host")
            || lowered.contains("could not resolve") || lowered.contains("no route") {
            return "Couldn't reach this host"
        }
        if lowered.contains("permission denied") { return "SSH sign-in was refused" }
        return "Sync failed"
    }

    private static func tooltip(state: RemoteHostSyncState, usage: RemoteHostUsage?, detail: String) -> String {
        if case let .failed(reason) = state { return reason }
        return usage.map { "\(Self.count($0.files, "cached file")) · \(Self.size($0.bytes)) cached locally" } ?? detail
    }

    private static func joined(_ status: String, _ usage: RemoteHostUsage?) -> String {
        guard let usage, usage.records > 0 || usage.files > 0 else { return status }
        guard usage.records > 0 else { return "\(status) · no usage in these logs" }
        return "\(status) · \(usage.newRecords.formatted()) unique · \(self.size(usage.bytes)) cached"
    }

    /// Red for a failed sync, orange for logs that arrived holding nothing to count.
    private static func detailColor(_ state: RemoteHostSyncState, usage: RemoteHostUsage?) -> Color {
        if case .failed = state { return .red }
        return self.isWarning(state, usage: usage) ? .orange : .secondary
    }

    /// A failed sync, or logs that arrived holding nothing to count.
    private static func isWarning(_ state: RemoteHostSyncState, usage: RemoteHostUsage?) -> Bool {
        switch state {
        case .failed: true
        case .syncing: false
        case .idle, .synced: usage.map { $0.files > 0 && $0.records == 0 } ?? false
        }
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Backup

    private var backupSection: some View {
        SettingsSection("Saved usage") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage database")
                            .font(.system(size: 13, weight: .medium))
                        // What is saved, in one line; importing only ever adds to it.
                        Text(self.savedSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help("Export writes a copy. Import merges one back in and only adds.")
                    }
                    Spacer(minLength: 8)
                    Button("Import…") { Task { await self.chooseBackup() } }
                        .disabled(self.backup.activity != nil)
                    Button("Export…") { Task { await self.chooseExportDestination() } }
                        .disabled(self.backup.activity != nil || self.backup.summary?.records == 0)
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                if self.backup.activity != nil || self.backup.outcome != nil {
                    Divider()
                    self.backupStatus
                        .font(.system(size: 11))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .settingsGroup()
        }
    }

    private var backupStatus: some View {
        HStack(spacing: 6) {
            if let activity = self.backup.activity {
                ProgressView().controlSize(.small)
                Text(activity == .exporting ? "Exporting…" : "Importing…")
            } else if let outcome = self.backup.outcome {
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

    private func chooseExportDestination() async {
        let panel = NSSavePanel()
        panel.title = "Export Usage Backup"
        panel.allowedContentTypes = Self.backupTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "QuotaBar-Backup-\(DayKey.make(from: Date())).sqlite"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await self.backup.exportBackup(to: url)
    }

    private func chooseBackup() async {
        let panel = NSOpenPanel()
        panel.title = "Import Usage Backup"
        panel.prompt = "Import"
        panel.allowedContentTypes = Self.backupTypes
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await self.backup.importBackup(from: url)
    }

    private static var backupTypes: [UTType] {
        [UTType(filenameExtension: "sqlite") ?? .data]
    }
}

/// One field for both ways to name a host: typing filters the hosts in the SSH config, and a name
/// the config does not list can still be added as typed.
struct AddHostSheet: View {
    let hosts: [String]
    let add: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State var query = ""
    @State private var selectedHost: String?

    private static let listHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add host")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("SSH host or alias")
                    .font(.system(size: 12, weight: .medium))
                HostSearchField(text: self.$query, submit: self.addSelected, move: self.moveSelection)
                    .frame(height: 22)
            }
            if !self.choices.hosts.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(self.choices.hosts.enumerated()), id: \.element) { index, host in
                                if index > 0 { Divider() }
                                AddHostRow(
                                    host: host,
                                    isTyped: host == self.choices.typedOption,
                                    isSelected: host == self.resolvedHost
                                ) { self.finish(host) }
                                .id(host)
                            }
                        }
                    }
                    .onChange(of: self.resolvedHost) { _, host in
                        if let host { proxy.scrollTo(host) }
                    }
                }
                .frame(maxHeight: Self.listHeight)
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .settingsGroup()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: self.addSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.resolvedHost == nil)
            }
        }
        .padding(18)
        .frame(width: 400)
        .onChange(of: self.query) { self.selectedHost = nil }
    }

    private var choices: AddHostChoices { AddHostChoices(query: self.query, hosts: self.hosts) }

    private var resolvedHost: String? { self.choices.resolve(selection: self.selectedHost) }

    private func moveSelection(_ offset: Int) {
        self.selectedHost = self.choices.moved(selection: self.selectedHost, by: offset)
    }

    private func addSelected() {
        guard let host = self.resolvedHost else { return }
        self.finish(host)
    }

    private func finish(_ host: String) {
        self.add(host)
        self.dismiss()
    }
}

private struct AddHostRow: View {
    let host: String
    let isTyped: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Text(self.isTyped ? "Add \"\(self.host)\" as typed" : self.host)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(self.isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(self.isHovered ? 0.06 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: CardMotion.rowPressScale))
        .onHover { self.isHovered = $0 }
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }
}
