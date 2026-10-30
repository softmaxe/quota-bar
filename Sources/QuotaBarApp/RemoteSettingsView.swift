import QuotaBarCore
import SwiftUI

/// The SSH hosts whose logs count toward this Mac's usage, each with how its last sync went and
/// how much usage its logs hold.
struct RemoteSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var remote: RemoteSyncModel
    /// Zero while the pane is out of view; any other change rereads what the mirrors hold.
    var reload = 0

    @State private var newHost = ""
    /// Read when the pane appears, so a host added to the config meanwhile shows up.
    @State private var configHosts: [String] = []

    var body: some View {
        SettingsPane("Remote") {
            Button("Sync now") { self.remote.syncAll() }
                .controlSize(.small)
                .disabled(self.settings.remoteHosts.isEmpty || self.remote.isSyncing)
        } content: {
            if !self.settings.remoteHosts.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(self.settings.remoteHosts.enumerated()), id: \.element) { index, host in
                            if index > 0 { Divider().padding(.leading, 12) }
                            self.hostRow(host)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .settingsGroup()
                .padding(.bottom, 10)
            }

            self.addRow

            SettingsRow(
                symbol: "clock.arrow.circlepath",
                title: "Sync automatically",
                detail: self.settings.remoteAutoSync
                    ? "Every 15 minutes and when QuotaBar starts"
                    : "Only when you press Sync now"
            ) {
                Toggle("Sync automatically", isOn: self.$settings.remoteAutoSync)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .settingsGroup()
            .padding(.top, 12)
        }
        .onAppear { self.configHosts = SSHConfigHosts.userHosts() }
        .task(id: self.reload) {
            guard self.reload != 0 else { return }
            await self.remote.loadUsage()
        }
    }

    private func hostRow(_ host: String) -> some View {
        let state = self.remote.state(of: host)
        let usage = self.remote.usage[host]
        let detail = Self.detail(of: state, usage: usage)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.isWarning(state, usage: usage) ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .help(detail)
            }
            Spacer(minLength: 12)
            if let usage, usage.files > 0 {
                self.usageSummary(usage)
            }
            if state == .syncing {
                ProgressView().controlSize(.small)
            }
            Button {
                self.remote.remove(host)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop syncing \(host)")
            .help("Stop syncing. Usage already recorded stays.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func usageSummary(_ usage: RemoteHostUsage) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Self.count(usage.records, "record"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(usage.records == 0 ? Color.orange : Color.primary)
            Text("\(Self.count(usage.files, "file")) · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .combine)
        .help("Usage records in this machine's logs. New counts those no other log recorded first.")
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("SSH host", text: self.$newHost)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(self.addTypedHost)
            if !self.suggestedHosts.isEmpty {
                Menu("From SSH config") {
                    ForEach(self.suggestedHosts, id: \.self) { host in
                        Button(host) { self.remote.add(host) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Button("Add", action: self.addTypedHost)
                .controlSize(.small)
                .disabled(!RemoteLogMirror.isValidHost(self.typedHost))
        }
    }

    private var typedHost: String {
        self.newHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestedHosts: [String] {
        self.configHosts.filter { !self.settings.remoteHosts.contains($0) }
    }

    private func addTypedHost() {
        guard RemoteLogMirror.isValidHost(self.typedHost) else { return }
        self.remote.add(self.typedHost)
        self.newHost = ""
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
        return "\(status) · \(usage.records == 0 ? "no usage in these logs" : "\(usage.newRecords.formatted()) new")"
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
}
