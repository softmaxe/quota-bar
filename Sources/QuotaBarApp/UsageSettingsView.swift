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
                    self.figures
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

    private var figures: some View {
        HStack(spacing: 16) {
            self.figure("Records", self.backup.summary.map { $0.records.formatted() } ?? "—")
            self.figure("Saved since", self.firstDay)
            self.figure("On disk", self.size)
        }
        .padding(.horizontal, 2)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            Button("Add host", systemImage: "plus") {
                self.configHosts = SSHConfigHosts.userHosts()
                self.isAddingHost = true
            }
            .labelStyle(.titleAndIcon)
            Button("Sync now") { self.remote.syncAll() }
                .disabled(self.settings.remoteHosts.isEmpty || self.remote.isSyncing)
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
                Divider()
                SettingsRow(title: "Sync automatically") {
                    Toggle("Sync automatically", isOn: self.$settings.remoteAutoSync)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
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
            detailColor: Self.isWarning(state, usage: usage) ? .orange : .secondary
        ) {
            if case .failed = state {
                Button("Retry") { self.remote.sync(host) }
                    .controlSize(.small)
            }
            if state == .syncing {
                ProgressView().controlSize(.small)
            }
            if let usage, usage.files > 0 {
                Text(Self.count(usage.records, "record"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(usage.records == 0 ? Color.orange : Color.primary)
                    .monospacedDigit()
                    .fixedSize()
                    .help("Usage records in this machine's logs. New counts those no other log recorded first.")
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
        .help(usage.map { "\(Self.count($0.files, "file")) · \(Self.size($0.bytes))" } ?? detail)
    }

    private var noHostsRow: some View {
        HStack(spacing: 12) {
            Text("Count usage from another machine over SSH.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Add host") {
                self.configHosts = SSHConfigHosts.userHosts()
                self.isAddingHost = true
            }
            .controlSize(.small)
        }
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
        case let .failed(reason): reason
        }
    }

    private static func joined(_ status: String, _ usage: RemoteHostUsage?) -> String {
        guard let usage, usage.files > 0 else { return status }
        guard usage.records > 0 else { return "\(status) · no usage in these logs" }
        return "\(status) · \(usage.newRecords.formatted()) new · \(self.size(usage.bytes))"
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
        SettingsSection("Backup") {
            Button("Import…") { Task { await self.chooseBackup() } }
                .disabled(self.backup.activity != nil)
            Button("Export…") { Task { await self.chooseExportDestination() } }
                .disabled(self.backup.activity != nil || self.backup.summary?.records == 0)
        } content: {
            self.backupStatus
                .font(.system(size: 11))
                .padding(.horizontal, 2)
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
    @State private var query = ""

    private static let listHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add host")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("SSH host or alias")
                    .font(.system(size: 12, weight: .medium))
                TextField("Search hosts or type devbox", text: self.$query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(self.addTyped)
            }
            if !self.matches.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(self.matches.enumerated()), id: \.element) { index, host in
                            if index > 0 { Divider() }
                            AddHostRow(host: host) { self.finish(host) }
                        }
                    }
                }
                .frame(maxHeight: Self.listHeight)
                .fixedSize(horizontal: false, vertical: true)
                .settingsGroup()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: self.addTyped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!RemoteLogMirror.isValidHost(self.typedHost))
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private var typedHost: String {
        self.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [String] {
        guard !self.typedHost.isEmpty else { return self.hosts }
        return self.hosts.filter { $0.localizedCaseInsensitiveContains(self.typedHost) }
    }

    private func addTyped() {
        guard RemoteLogMirror.isValidHost(self.typedHost) else { return }
        self.finish(self.typedHost)
    }

    private func finish(_ host: String) {
        self.add(host)
        self.dismiss()
    }
}

private struct AddHostRow: View {
    let host: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Text(self.host)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(self.isHovered ? 0.06 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: CardMotion.rowPressScale))
        .onHover { self.isHovered = $0 }
    }
}
