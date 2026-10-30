import QuotaBarCore
import Combine
import Foundation

/// How a remote host's last sync went, for its row in Settings.
enum RemoteHostSyncState: Equatable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)
}

/// Keeps the SSH hosts in Settings mirrored: once when the app starts and every fifteen minutes,
/// unless refreshing is set to Manual, and whenever the user asks. Mirroring has its own schedule
/// because it costs network time the local scan does not, and a machine that is off must not
/// hold the menu up. Each sync that succeeds asks for a scan, which records the new logs.
@MainActor
final class RemoteSyncModel: ObservableObject {
    @Published private(set) var states: [String: RemoteHostSyncState] = [:]

    private static let interval: TimeInterval = 15 * 60

    private let settings: SettingsStore
    private let mirror: RemoteLogMirror
    private let didSync: @MainActor () -> Void
    private var timer: Timer?
    private var tasks: [String: Task<Void, Never>] = [:]

    init(settings: SettingsStore, mirror: RemoteLogMirror, didSync: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.mirror = mirror
        self.didSync = didSync
    }

    func start() {
        self.syncAll(isAutomatic: true)
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncAll(isAutomatic: true) }
        }
        timer.tolerance = Self.interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        for task in self.tasks.values { task.cancel() }
        self.tasks = [:]
    }

    func state(of host: String) -> RemoteHostSyncState {
        self.states[host] ?? .idle
    }

    var isSyncing: Bool { !self.tasks.isEmpty }

    /// Adds a host and mirrors it at once, so a wrong name or a missing key shows up right away.
    func add(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteLogMirror.isValidHost(host), !self.settings.remoteHosts.contains(host) else { return }
        self.settings.remoteHosts.append(host)
        self.sync(host)
    }

    /// Stops mirroring a host. What it already contributed stays recorded and its mirror stays
    /// on disk, because recorded usage never depends on the source logs still being there.
    func remove(_ host: String) {
        self.settings.remoteHosts.removeAll { $0 == host }
        self.tasks[host]?.cancel()
        self.tasks[host] = nil
        self.states[host] = nil
    }

    func syncAll() {
        self.syncAll(isAutomatic: false)
    }

    private func syncAll(isAutomatic: Bool) {
        if isAutomatic, self.settings.refreshFrequency == .manual { return }
        for host in self.settings.remoteHosts { self.sync(host) }
    }

    /// A sync already running for this host covers this request too.
    private func sync(_ host: String) {
        guard self.tasks[host] == nil else { return }
        self.states[host] = .syncing
        self.tasks[host] = Task(priority: .utility) { [weak self, mirror] in
            let outcome: Result<Void, Error>
            do {
                try await mirror.sync(host: host)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.tasks[host] = nil
                switch outcome {
                case .success:
                    self.states[host] = .synced(Date())
                    self.didSync()
                case let .failure(error):
                    Log.ui.error("Remote sync of \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    self.states[host] = .failed(error.localizedDescription)
                }
            }
        }
    }

#if DEBUG
    func debugSetState(_ state: RemoteHostSyncState, for host: String) {
        self.states[host] = state
    }
#endif
}
