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
/// unless automatic sync is off, and whenever the user asks. Mirroring has its own schedule
/// because it costs network time the local scan does not, and a machine that is off must not
/// hold the menu up. Each sync that succeeds asks for a scan, which records the new logs.
@MainActor
final class RemoteSyncModel: ObservableObject {
    @Published private(set) var states: [String: RemoteHostSyncState] = [:]
    /// What each host's mirror holds, as of the last read.
    @Published private(set) var usage: [String: RemoteHostUsage] = [:]

    private static let interval: TimeInterval = 15 * 60

    private let settings: SettingsStore
    private let mirror: RemoteLogMirror
    private let syncAndRecord: (@Sendable (String) async throws -> Void)?
    private let didSync: @MainActor () -> Void
    private let readUsage: @Sendable ([String]) -> [String: RemoteHostUsage]?
    private var timer: Timer?
    private var taskIDs: [String: UUID] = [:]
    private var generations: [String: UUID] = [:]
    @Published private var tasks: [String: Task<Void, Never>] = [:]

    /// `readUsage` runs off the main actor and returns nil when the usage cannot be read.
    init(
        settings: SettingsStore,
        mirror: RemoteLogMirror,
        didSync: @escaping @MainActor () -> Void,
        syncAndRecord: (@Sendable (String) async throws -> Void)? = nil,
        readUsage: @escaping @Sendable ([String]) -> [String: RemoteHostUsage]? = { _ in nil }
    ) {
        self.settings = settings
        self.mirror = mirror
        self.syncAndRecord = syncAndRecord
        self.didSync = didSync
        self.readUsage = readUsage
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
        self.generations = [:]
    }

    func state(of host: String) -> RemoteHostSyncState {
        self.states[host] ?? .idle
    }

    var isSyncing: Bool { !self.tasks.isEmpty }

    /// Rereads what the mirrors hold. A failed read keeps the figures already shown.
    func loadUsage() async {
        let hosts = self.settings.remoteHosts
        let read = self.readUsage
        let usage = await Task.detached(priority: .utility) { read(hosts) }.value
        guard !Task.isCancelled, let usage else { return }
        self.usage = usage.filter { self.settings.remoteHosts.contains($0.key) }
    }

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
        self.generations[host] = nil
        self.states[host] = nil
        self.usage[host] = nil
    }

    func syncAll() {
        self.syncAll(isAutomatic: false)
    }

    private func syncAll(isAutomatic: Bool) {
        if isAutomatic, !self.settings.remoteAutoSync { return }
        for host in self.settings.remoteHosts { self.sync(host) }
    }

    /// A sync already running for this host covers this request too.
    func sync(_ host: String) {
        guard self.settings.remoteHosts.contains(host), self.generations[host] == nil else { return }
        let previous = self.tasks[host]
        let generation = UUID()
        self.generations[host] = generation
        self.taskIDs[host] = generation
        self.states[host] = .syncing
        self.tasks[host] = Task(priority: .utility) { [weak self, mirror] in
            // A removed host may still be winding down its command. Never overlap its writes.
            await previous?.value
            let outcome: Result<Void, Error>
            do {
                try Task.checkCancellation()
                if let syncAndRecord = self?.syncAndRecord {
                    try await syncAndRecord(host)
                } else {
                    try await mirror.sync(host: host)
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                guard let self else { return }
                guard self.generations[host] == generation else {
                    if self.taskIDs[host] == generation {
                        self.tasks[host] = nil
                        self.taskIDs[host] = nil
                    }
                    return
                }
                self.generations[host] = nil
                self.taskIDs[host] = nil
                guard !Task.isCancelled else {
                    self.tasks[host] = nil
                    return
                }
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

    func debugSetUsage(_ usage: RemoteHostUsage, for host: String) {
        self.usage[host] = usage
    }
#endif
}
