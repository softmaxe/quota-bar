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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Remote machines")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Sync now") { self.remote.syncAll() }
                    .controlSize(.small)
                    .disabled(self.settings.remoteHosts.isEmpty || self.remote.isSyncing)
            }
            .padding(.leading, 2)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if !self.settings.remoteHosts.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(self.settings.remoteHosts.enumerated()), id: \.element) { index, host in
                            if index > 0 { Divider().padding(.leading, 12) }
                            self.hostRow(host)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .settingsGroup()
                .padding(.bottom, 10)
            }

            self.addRow

            Text(
                "Sessions on these machines count toward this Mac's usage, without counting twice. "
                    + "QuotaBar connects with your SSH config every 15 minutes, or only when you "
                    + "press Sync now if refreshing is Manual. Hosts need key sign-in, and rsync "
                    + "on the machine."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.leading, 2)

            Text(
                "Claude Code and Codex logs are copied whole to this Mac and may include "
                    + "prompts and responses. OpenCode and Pi Agent are not included."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(width: SettingsView.paneWidth, height: SettingsView.paneHeight, alignment: .top)
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
