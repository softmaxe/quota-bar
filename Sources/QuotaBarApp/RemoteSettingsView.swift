import QuotaBarCore
import SwiftUI

/// The SSH hosts whose logs count toward this Mac's usage, each with how its last sync went.
struct RemoteSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var remote: RemoteSyncModel

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
    }

    private func hostRow(_ host: String) -> some View {
        let state = self.remote.state(of: host)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host)
                    .font(.system(size: 13))
                Text(Self.detail(of: state))
                    .font(.system(size: 11))
                    .foregroundStyle(Self.isFailure(state) ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .help(Self.detail(of: state))
            }
            Spacer(minLength: 8)
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

    private static func detail(of state: RemoteHostSyncState) -> String {
        switch state {
        case .idle: "Waiting for the next sync"
        case .syncing: "Syncing…"
        case let .synced(date): "Synced \(Formatters.relativeAge(since: date))"
        case let .failed(reason): reason
        }
    }

    private static func isFailure(_ state: RemoteHostSyncState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
