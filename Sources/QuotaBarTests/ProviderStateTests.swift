@testable import QuotaBarApp
import QuotaBarCore
import AppKit
import Foundation
import SwiftUI

/// Exercises quota and local-scan state without reading credentials, logs, or the network.
@MainActor
enum ProviderStateTests {
    /// Main-actor isolated because the checks read and clear these fields while a fetch writes
    /// them. A nonisolated async method runs off the main actor and would race them.
    @MainActor
    private final class Fetches {
        var quotaCalls = 0
        var costCalls = 0
        var quota: CheckedContinuation<ProviderState, Never>?
        var cost: CheckedContinuation<CostSnapshot?, Never>?

        func fetchQuota() async -> ProviderState {
            self.quotaCalls += 1
            return await withCheckedContinuation { self.quota = $0 }
        }

        func fetchCost() async -> CostSnapshot? {
            self.costCalls += 1
            return await withCheckedContinuation { self.cost = $0 }
        }

        static func snapshot(at date: Date) -> CostSnapshot {
            CostSnapshot(
                provider: .codex, days: [], todayCostUSD: 0, windowCostUSD: 0,
                latestTokens: 0, windowTokens: 0, topModel: nil,
                hasUnpricedTokens: false, scannedAt: date
            )
        }
    }

    private static let suite = "QuotaBarProviderStateTests"

    static func run() async {
        await AppCheck.run("signed-out cards keep saved usage") {
            if let failure = Self.verifySignedOutCards() { throw CheckFailure(description: failure) }
        }
        await AppCheck.run("provider states preserve reasons, readings, scan progress, and retry eligibility") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            try await Self.walkThrough(defaults: defaults)
        }
        await AppCheck.run("the menu reads recorded usage independently of quota") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            if let failure = try await Self.verifyMenuReadsRecordedUsage(defaults: defaults) {
                throw CheckFailure(description: failure)
            }
        }
    }

    private static func walkThrough(defaults: UserDefaults) async throws {
        var uptime: TimeInterval = 1_000
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = SettingsStore(defaults: defaults)
        // This walk-through follows Codex; pin it rather than rely on the fresh-install default.
        settings.menuBarProvider = .codex
        let fetches = Fetches()
        let store = UsageStore(
            settings: settings,
            costService: CostService(rateCard: RateCard()),
            clock: { uptime },
            dateClock: { origin.addingTimeInterval(uptime - 1_000) },
            fetchState: { _, _ in await fetches.fetchQuota() },
            fetchCost: { _ in await fetches.fetchCost() },
            historyStore: UsageHistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            recoveryDefaults: defaults
        )

        store.refresh()
        try AppCheck.require(await AsyncWait.wait(until: { fetches.quota != nil && fetches.cost != nil }), "initial work did not start")
        try AppCheck.require(store.isRefreshing(.codex) &&
              store.displays[.codex]?.localScanStatus == .scanning, "quota and local scan did not start independently")
        store.refresh()
        try AppCheck.require(fetches.quotaCalls == 1 && fetches.costCalls == 1, "a second request was not coalesced")

        fetches.quota?.resume(returning: .signedOut("Run codex login to sign in."))
        fetches.quota = nil
        try AppCheck.require(await AsyncWait.wait(until: { store.displays[.codex]?.isSignedOut == true }), "signed-out state was not applied")
        try AppCheck.require(store.displays[.codex]?.signedOutReason == "Run codex login to sign in." &&
              store.displays[.codex]?.localScanStatus == .scanning, "signed-out reason or independent scan state was lost")

        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        try AppCheck.require(await AsyncWait.wait(until: {
            if case .some(.failed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }), "local scan failure was not exposed")
        try AppCheck.require(store.displays[.codex]?.error == nil, "local scan failure was mislabeled a quota failure")

        store.retryLocalUsage()
        try AppCheck.require(await AsyncWait.wait(until: { fetches.costCalls == 2 && fetches.cost != nil }), "local usage retry did not start")
        try AppCheck.require(fetches.quotaCalls == 1 &&
              store.displays[.codex]?.localScanStatus == .scanning, "local usage retry changed quota state or skipped progress")
        store.retryLocalUsage()
        try AppCheck.require(fetches.costCalls == 2, "repeated local usage retry started a duplicate scan")
        fetches.cost?.resume(returning: Fetches.snapshot(at: origin))
        fetches.cost = nil
        try AppCheck.require(await AsyncWait.wait(until: {
            if case .some(.completed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }), "local usage retry did not report completion")
        try AppCheck.require(fetches.quotaCalls == 1 &&
              store.displays[.codex]?.isSignedOut == true &&
              store.displays[.codex]?.snapshot == nil &&
              store.displays[.codex]?.cost == Fetches.snapshot(at: origin), "local usage retry changed sign-in state or lost its result")

        uptime = 1_059
        try AppCheck.require(store.canRefresh(.codex), "local cooldown did not expire")
        store.refresh()
        try AppCheck.require(await AsyncWait.wait(until: { fetches.quota != nil && fetches.cost != nil }), "second refresh did not start")
        let snapshot = UsageSnapshot(
            provider: .codex, session: nil, weekly: nil, planLabel: nil,
            credits: nil, fetchedAt: origin.addingTimeInterval(59)
        )
        fetches.quota?.resume(returning: .loaded(snapshot))
        fetches.quota = nil
        try AppCheck.require(await AsyncWait.wait(until: { store.displays[.codex]?.snapshot == snapshot }), "quota success did not apply")
        try AppCheck.require(store.displays[.codex]?.failure == nil &&
              store.displays[.codex]?.signedOutReason == nil, "quota success left an old warning")
        fetches.cost?.resume(returning: Fetches.snapshot(at: origin.addingTimeInterval(59)))
        fetches.cost = nil
        try AppCheck.require(await AsyncWait.wait(until: {
            if case .some(.completed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }), "second local scan did not report completion")
        try AppCheck.require(store.displays[.codex]?.cost == Fetches.snapshot(at: origin.addingTimeInterval(59)), "local scan completion did not apply usage")

        uptime = 1_118
        let deadline = origin.addingTimeInterval(118 + 300)
        store.refresh()
        try AppCheck.require(await AsyncWait.wait(until: { fetches.quota != nil && fetches.cost != nil }), "rate-limit fixture did not start")
        fetches.quota?.resume(returning: .rateLimited(reason: "API limited", retryAfter: deadline))
        fetches.quota = nil
        try AppCheck.require(await AsyncWait.wait(until: { store.displays[.codex]?.retryDeadline == deadline }), "server retry deadline was not kept")
        try AppCheck.require(store.displays[.codex]?.snapshot == snapshot &&
              store.displays[.codex]?.failure?.kind == .rateLimited &&
              abs(store.cooldownRemaining(for: .codex) - 300) < 0.01 &&
              store.retryEligibleAt(for: .codex) == deadline &&
              !store.canRefresh(.codex), "cached quota or effective server retry state is wrong")
        store.refresh(trigger: .user)
        try AppCheck.require(fetches.quotaCalls == 3, "a force request bypassed the server retry deadline")
        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        try AppCheck.require(await AsyncWait.wait(until: {
            if case .some(.failed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }), "rate-limit fixture's local scan did not finish")

        uptime = 1_418
        try AppCheck.require(store.canRefresh(.codex), "server deadline did not expire")
        store.refresh()
        try AppCheck.require(await AsyncWait.wait(until: { fetches.quota != nil && fetches.cost != nil }), "post-limit refresh did not start")
        fetches.quota?.resume(returning: .loaded(snapshot))
        fetches.quota = nil
        try AppCheck.require(await AsyncWait.wait(until: { store.displays[.codex]?.failure == nil }), "successful retry did not clear the warning")
        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        try AppCheck.require(await AsyncWait.wait(until: {
            if case .some(.failed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }), "post-limit local scan did not finish")

        let savedCost = store.displays[.codex]?.cost
        uptime = 1_477
        store.refresh()
        try AppCheck.require(await AsyncWait.wait(until: { fetches.quota != nil && fetches.cost != nil }), "sign-out refresh did not start")
        fetches.quota?.resume(returning: .signedOut("Run codex login to sign in."))
        fetches.quota = nil
        try AppCheck.require(await AsyncWait.wait(until: { store.displays[.codex]?.isSignedOut == true }), "sign-out after a successful login did not apply")
        try AppCheck.require(savedCost != nil &&
              store.displays[.codex]?.snapshot == nil &&
              store.displays[.codex]?.cost == savedCost &&
              store.displays[.codex]?.localScanStatus == .scanning, "sign-out did not clear quota independently of saved local usage")
        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        try AppCheck.require(await AsyncWait.wait(until: {
            if case .some(.failed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }) && store.displays[.codex]?.cost == savedCost, "a failed signed-out scan discarded saved local usage")
        store.stop()
    }

    /// The only check that leaves the store on its default cost fetch, so it is what proves the
    /// menu reads the service's recorded usage at all.
    private static func verifyMenuReadsRecordedUsage(defaults: UserDefaults) async throws -> String? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-bar-menu-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeHome = directory.appendingPathComponent("claude")
        let transcript = claudeHome.appendingPathComponent("projects/app/session.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req","message":{"id":"msg","model":"fixture-model","usage":{"input_tokens":1,"output_tokens":0}}}"#
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let service = CostService(
            databaseURL: directory.appendingPathComponent("usage.sqlite"),
            env: ["CLAUDE_CONFIG_DIR": claudeHome.path],
            rateCard: RateCard()
        )
        let settings = SettingsStore(defaults: defaults)
        settings.menuBarProvider = .claude
        var quotaCalls = 0
        let store = UsageStore(
            settings: settings, costService: service,
            fetchState: { _, _ in
                quotaCalls += 1
                return .failed("No quota request expected")
            },
            historyStore: UsageHistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            recoveryDefaults: defaults
        )
        defer { store.stop() }
        store.retryLocalUsage()
        guard await AsyncWait.wait(until: { store.displays[.claude]?.cost?.windowTokens == 1 }), quotaCalls == 0 else {
            return "the menu did not load recorded usage independently of quota"
        }
        return nil
    }

    /// Compare actual hosted content rather than a policy flag: the regression kept the data
    /// in the store but omitted its entire view whenever credentials were missing.
    private static func verifySignedOutCards() -> String? {
        for provider in Provider.allCases {
            let cost = CardDump.busyCost(provider)
            for mode in [CostChartLabelMode.tokens, .cost] {
                func height(_ display: ProviderDisplay, expanded: Bool = false) -> CGFloat {
                    NSHostingView(rootView: MenuCardView(
                        provider: provider, display: display, isRefreshing: false,
                        animatesFill: false, costChartLabelMode: mode,
                        isCostBreakdownExpanded: expanded,
                        expandedCostBreakdownDayKey: cost.days.last?.dayKey
                    )).fittingSize.height
                }
                var display = ProviderDisplay(isSignedOut: true)
                let signInHeight = height(display)
                display.cost = cost
                let usageHeight = height(display)
                guard usageHeight > signInHeight else {
                    return "\(provider) signed-out card hides saved \(mode) usage"
                }
                guard height(display, expanded: true) > usageHeight else {
                    return "\(provider) signed-out card hides the expanded model breakdown"
                }
                for status in [LocalScanStatus.scanning, .failed("Local scan failed.")] {
                    display.localScanStatus = status
                    let savedUsageHeight = height(display)
                    display.cost = nil
                    let statusOnlyHeight = height(display)
                    guard statusOnlyHeight > signInHeight, savedUsageHeight > statusOnlyHeight else {
                        return "\(provider) signed-out card hides local scan status or saved usage"
                    }
                    display.cost = cost
                }
            }
        }
        return nil
    }
}
