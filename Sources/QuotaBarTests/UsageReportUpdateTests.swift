@testable import QuotaBarApp
import QuotaBarCore
import Combine
import Foundation

/// A scan start must not reread history merely because another provider already completed.
@MainActor
enum UsageReportUpdateTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { self.lock.withLock { self.count } }
        func read() -> UsageReportSnapshot {
            self.lock.withLock { self.count += 1 }
            return UsageReportSnapshot(days: [])
        }
    }

    static func run() async {
        await AppCheck.run("report uses its store database and preview uses sample usage") {
            let fixture = try RecordedUsageFixture()
            let suite = "QuotaBarReportIsolationTests"
            let defaults = EphemeralDefaults.make(suite)
            defer { EphemeralDefaults.clear(suite) }
            let store = UsageStore(
                settings: SettingsStore(defaults: defaults),
                costService: CostService(databaseURL: fixture.databaseURL, rateCard: RateCard()),
                recoveryDefaults: defaults
            )
            let report = UsageReportWindowController(store: store)
            let expected = try UsageReportReader.read(databaseURL: fixture.databaseURL, rateCard: RateCard.onDisk())
            try AppCheck.require(try report.debugReadSnapshot() == expected,
                                 "report did not read the store's isolated database")
            let preview = UsageReportWindowController(store: store, operations: UsageReportDumps.sampleOperations)
            let sample = try preview.debugReadSnapshot()
            try AppCheck.require(sample == UsageReportDumps.sampleSnapshot() && sample.hasRecordedUsage,
                                 "interface preview report did not use populated sample data")
        }
        await AppCheck.run("report reads follow scan completions and displays publish atomically") {
            let suite = "QuotaBarReportUpdateTests"
            let defaults = EphemeralDefaults.make(suite)
            defer { EphemeralDefaults.clear(suite) }
            let settings = SettingsStore(defaults: defaults)
            settings.menuBarProvider = .codex
            let snapshot = CostSnapshot(
                provider: .codex, days: [], todayCostUSD: 1, windowCostUSD: 1,
                latestTokens: 1, windowTokens: 1, topModel: nil,
                hasUnpricedTokens: false, scannedAt: Date(timeIntervalSince1970: 1)
            )
            var pending: CheckedContinuation<CostSnapshot?, Never>?
            let store = UsageStore(
                settings: settings, costService: CostService(rateCard: RateCard()),
                dateClock: { Date(timeIntervalSince1970: 1) },
                fetchCost: { provider in
                    if provider == .claude { return snapshot }
                    return await withCheckedContinuation { pending = $0 }
                },
                updateThirdPartyRates: { false }, recoveryDefaults: defaults
            )
            defer {
                pending?.resume(returning: nil)
                store.stop()
            }
            // Establish a completed provider before observing subsequent scan starts.
            store.refreshAllLocalUsage()
            try AppCheck.require(await AsyncWait.wait { store.finishedLocalScans == 1 && pending != nil },
                                 "initial scans did not start")
            let reads = Reads()
            let report = UsageReportWindowController(
                store: store, operations: .init(read: { reads.read() }, render: { _ in "" })
            )
            var emissions = 0
            var partialResult = false
            let observer = store.$displays.dropFirst().sink { displays in
                emissions += 1
                if displays[.codex]?.cost != nil, displays[.codex]?.localScanStatus == .scanning {
                    partialResult = true
                }
            }
            defer {
                report.windowWillClose(Notification(name: NSNotification.Name("test")))
                withExtendedLifetime(observer) {}
            }
            report.startLiveUpdates()
            try AppCheck.require(await AsyncWait.wait { reads.value >= 1 && store.finishedLocalScans == 2 },
                                 "opening read or second provider scan did not finish")
            // Drain the applied result and any coalesced follow-up, not just the read closure.
            await report.debugWaitForPendingReads()
            let before = reads.value
            let publications = emissions
            pending?.resume(returning: snapshot)
            pending = nil
            try AppCheck.require(await AsyncWait.wait { store.finishedLocalScans == 3 && reads.value > before },
                                 "a completed scan did not reread the report")
            await report.debugWaitForPendingReads()
            try AppCheck.require(!partialResult, "a completed scan published an intermediate display")
            try AppCheck.require(emissions == publications + 1, "completion published more than once")
            let after = reads.value
            store.retryLocalUsage()
            try AppCheck.require(await AsyncWait.wait { pending != nil }, "retry did not start")
            await report.debugWaitForPendingReads()
            try AppCheck.require(reads.value == after, "scan start reread history for an already completed provider")
            pending?.resume(returning: nil)
            pending = nil
            try AppCheck.require(await AsyncWait.wait { store.finishedLocalScans == 4 && reads.value > after },
                                 "failed scan completion did not settle the report")
            await report.debugWaitForPendingReads()
        }
    }
}
