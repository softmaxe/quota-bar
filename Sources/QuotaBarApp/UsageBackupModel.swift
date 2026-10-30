import QuotaBarCore
import Combine
import Foundation

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

    private let store: UsageStore
    private let fixture: SavedUsageSummary?

    /// `fixture` stands in for the saved usage, for dumps.
    init(store: UsageStore, fixture: SavedUsageSummary? = nil) {
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
