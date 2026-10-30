#if DEBUG
import QuotaBarCore
import AppKit
import SwiftUI

/// `QuotaBar --dump-card <dir>` renders the menu card off screen to PNGs and exits.
/// Lets the card layout be checked without opening the real menu.
@MainActor
enum CardDump {
    /// Additional review states use the real views with disposable fixtures.
    static func dumpInteractionStates(directory: String) {
        let root = OffscreenCapture.directory(directory)
        let now = Date()
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            Self.capture(
                MenuCardView(provider: .codex,
                             display: ProviderDisplay(snapshot: Self.loadedSnapshot(.codex), cost: Self.sampleCost(.codex)),
                             isRefreshing: false, animatesFill: false),
                named: appearance == .aqua ? "main-light" : "main-dark", into: root,
                appearance: NSAppearance(named: appearance)
            )
        }
        let signedOut = ProviderDisplay(
            cost: Self.sampleCost(.codex),
            signedOutReason: "Sign in with the CLI to check quota. Local usage is available below.",
            isSignedOut: true
        )
        Self.capture(
            MenuCardView(provider: .codex, display: signedOut, isRefreshing: false, animatesFill: false),
            named: "sign-in", into: root
        )
        let failed = ProviderDisplay(
            snapshot: Self.loadedSnapshot(.claude), cost: Self.sampleCost(.claude),
            error: "The service is rate-limiting quota requests.",
            failure: ProviderFailure(kind: .rateLimited, reason: "Rate limited", serverRetryAfter: now.addingTimeInterval(90))
        )
        Self.capture(
            MenuCardView(provider: .claude, display: failed, isRefreshing: false, animatesFill: false)
                .environment(\.menuRefreshState, RefreshEligibility.Row(title: "Refresh", trailingText: "90s", isEnabled: false)),
            named: "refresh-failed", into: root
        )
    }

    /// Renders the settings window's content off screen too, so its layout can be checked
    /// without opening a real window.
    static func dumpSettings(directory: String) {
        let root = OffscreenCapture.directory(directory)

        // A throwaway defaults domain keeps the dump from touching real preferences, and the
        // fixtures keep the machine's own logs and cached rates out of the render.
        let defaults = EphemeralDefaults.make("QuotaBarSettingsDump")
        let settings = SettingsStore(defaults: defaults)
        let costService = CostService(databaseURL: root.appendingPathComponent("unused.sqlite"))
        let pricing = PricingTableModel(costService: costService, fixtures: Self.pricingFixtures)
        // General draws each provider's live quota, so the store carries the sample snapshots.
        let store = UsageStore(
            settings: settings,
            costService: costService,
            historyStore: UsageHistoryStore(fileURL: root.appendingPathComponent("unused-history.json")),
            recoveryDefaults: defaults
        )
        for provider in Provider.allCases {
            store.debugSetDisplay(ProviderDisplay(snapshot: Self.loadedSnapshot(provider)), for: provider)
        }

        // The data pane shows the size of what is saved, which the throwaway database does not have.
        let backup = UsageBackupModel(
            settings: settings,
            store: store,
            fixture: SavedUsageSummary(records: 56_412, firstDay: "2025-11-03", bytes: 27_400_000)
        )
        settings.lastUsageExport = Date().addingTimeInterval(-3 * 86_400)

        Self.captureSettings(
            AnyView(SettingsView(settings: settings, pricing: pricing, store: store, backup: backup)),
            named: "settings",
            into: root
        )
        Self.captureSettings(
            AnyView(DataSettingsView(model: backup, settings: settings)),
            named: "settings-data",
            into: root
        )
        // The pricing pane again on its own. The rows only load when the pane appears, and the
        // first capture never selects that tab, so load them here. A model with a long-context
        // tier is picked when there is one, so the dump shows every line the detail side has.
        let loading = Task {
            await pricing.load()
            let row = pricing.listRows.first { $0.rates?.thresholdTokens != nil && $0.usageTokens > 0 }
                ?? pricing.listRows.first
            pricing.selectedRowID = row?.id
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        _ = loading
        Self.captureSettings(
            AnyView(PricingSettingsView(model: pricing)),
            named: "settings-pricing",
            into: root
        )

        settings.remoteHosts = ["ubuntu-tailscale", "build-server", "old-laptop"]
        store.remoteSync.debugSetState(.synced(Date().addingTimeInterval(-240)), for: "ubuntu-tailscale")
        store.remoteSync.debugSetState(.syncing, for: "build-server")
        store.remoteSync.debugSetState(
            .failed("ssh: connect to host old-laptop port 22: Operation timed out"),
            for: "old-laptop"
        )
        Self.captureSettings(
            AnyView(RemoteSettingsView(settings: settings, remote: store.remoteSync)),
            named: "settings-remote",
            into: root
        )
    }

    /// The settings window is a sidebar beside a pane and the pricing pane is that pane on its
    /// own, so the size comes from the view rather than from a constant here. The pane loads its
    /// rows asynchronously, so the capture lets the run loop turn first.
    private static func captureSettings(_ view: AnyView, named name: String, into root: URL) {
        Self.capture(
            view,
            named: name,
            into: root,
            appearance: NSAppearance(named: .darkAqua),
            titled: true,
            settle: 3
        )
    }

    /// Lays a view out at its natural size and writes one PNG of it. The dumps name the size they
    /// wrote, since a layout regression usually shows up there first.
    private static func capture(
        _ view: some View,
        named name: String,
        into root: URL,
        appearance: NSAppearance? = nil,
        titled: Bool = false,
        settle: TimeInterval = 0
    ) {
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .active))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let outcome = OffscreenCapture.writePNG(
            hosting,
            named: name,
            into: root,
            titled: titled,
            settle: settle
        )
        switch outcome {
        case let .written(url):
            print("wrote \(url.path) (\(Int(hosting.frame.width))x\(Int(hosting.frame.height)))")
        case let .failed(reason):
            print(reason)
        }
    }

    /// Made-up token totals, the built-in rate table, and two made-up models.dev rates, so the pricing pane renders the same
    /// on any machine and carries nobody's account in it.
    static let pricingFixtures = PricingTableModel.PreviewFixtures(
        usage: [
            .claude: [
                ModelUsageTotal(model: "claude-opus-5", tokens: 412_000_000),
                ModelUsageTotal(model: "claude-sonnet-5", tokens: 168_000_000),
                ModelUsageTotal(model: "claude-fable-5", tokens: 38_400_000),
                ModelUsageTotal(model: "claude-haiku-4-5", tokens: 24_600_000),
            ],
            .codex: [
                ModelUsageTotal(model: "gpt-5.6-sol", tokens: 236_000_000),
                ModelUsageTotal(model: "gpt-5.6-terra", tokens: 91_000_000),
                ModelUsageTotal(model: "gpt-5.6-luna", tokens: 12_400_000),
                ModelUsageTotal(model: "deepseek-v4.1-flash", tokens: 48_000_000),
                ModelUsageTotal(model: "glm-5.3", tokens: 6_200_000),
                ModelUsageTotal(model: "qwen3.8-27b:latest", tokens: 2_100_000),
            ],
        ],
        rateCard: RateCard(thirdParty: ThirdPartyRates(
            current: [
                "deepseek-v4.1-flash": ModelPricing(input: 0.15, output: 0.6, cacheRead: 0.003),
                "glm-5.3": ModelPricing(input: 1.4, output: 4.4, cacheWrite: 0, cacheRead: 0.26),
            ],
            fetchedAt: Date(timeIntervalSinceNow: -3 * 3_600)
        ))
    )

    /// `sampleCost` mixes three models into a day, which is the normal day and fits the block
    /// under the chart. This is the other kind: enough models on the day being read that the list
    /// has to be opened before all of it can be seen.
    static func busyCost(_ provider: Provider) -> CostSnapshot {
        let sample = Self.sampleCost(provider)
        guard let last = sample.days.last else { return sample }
        let models: [(CostUsageSource, String)] = provider == .codex
            ? [
                (.piAgent, "gpt-5.6-sol"),
                (.codex, "gpt-5.6-sol"),
                (.codex, "gpt-5.6-luna"),
                (.piAgent, "gpt-5.6-luna"),
                (.openCode, "gpt-5.6-terra"),
                (.codex, "gpt-5.6-terra"),
            ]
            : [
                (.claude, "claude-opus-5"),
                (.claude, "claude-sonnet-5"),
                (.claude, "claude-fable-5"),
                (.claude, "claude-haiku-4-5"),
                (.claude, "claude-opus-4-1"),
                (.claude, "claude-sonnet-4-5"),
            ]
        let shares = [0.47, 0.24, 0.13, 0.08, 0.05, 0.03]
        let total = last.costUSD ?? 0
        let busy = CostDay(
            dayKey: last.dayKey,
            byModel: Dictionary(uniqueKeysWithValues: zip(models, shares).map { entry, share in
                (ModelUsageKey(source: entry.0, model: entry.1), ModelDayUsage(
                    tokens: Self.mixedTokens(Int(total * share * 1_000_000), cacheHitRate: 0.95 - share / 2),
                    costUSD: total * share
                ))
            }),
            costUSD: total,
            unpricedTokens: 0
        )
        return CostSnapshot(
            provider: sample.provider,
            days: sample.days.dropLast() + [busy],
            todayCostUSD: sample.todayCostUSD,
            windowCostUSD: sample.windowCostUSD,
            latestTokens: sample.latestTokens,
            windowTokens: sample.windowTokens,
            topModel: sample.topModel,
            hasUnpricedTokens: sample.hasUnpricedTokens,
            scannedAt: sample.scannedAt
        )
    }

    /// Splits a model's tokens the way an agent session does: most input comes back from the
    /// cache, and the rest is cache writes, fresh input, and output.
    private static func mixedTokens(_ total: Int, cacheHitRate: Double) -> TokenTotals {
        let output = total / 25
        let input = total - output
        let cacheRead = Int(Double(input) * cacheHitRate)
        let cacheWrite = (input - cacheRead) * 3 / 4
        return TokenTotals(
            input: input - cacheRead - cacheWrite,
            output: output,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead
        )
    }

    /// The loaded card each provider is drawn from, shared with the preview and verifiers so
    /// they all carry the same account.
    static func loadedSnapshot(_ provider: Provider) -> UsageSnapshot {
        let now = Date().addingTimeInterval(-5 * 60)
        switch provider {
        case .codex:
            return UsageSnapshot(
                provider: .codex,
                session: UsageWindow(usedPercent: 12, resetsAt: Date().addingTimeInterval(3 * 3600), windowSeconds: 18_000),
                // Two days into the week with 14% gone is a reserve; the tip renders green.
                weekly: UsageWindow(usedPercent: 14, resetsAt: Date().addingTimeInterval(5 * 86_400), windowSeconds: 604_800),
                planLabel: "Plus",
                credits: CreditsSnapshot(hasCredits: true, unlimited: false, balance: 640),
                fetchedAt: now
            )
        case .claude:
            return UsageSnapshot(
                provider: .claude,
                // Most of the session window spent with a third of it left: a deficit, tip in red.
                session: UsageWindow(usedPercent: 71, resetsAt: Date().addingTimeInterval(1 * 3600), windowSeconds: nil),
                weekly: UsageWindow(usedPercent: 55, resetsAt: Date().addingTimeInterval(2 * 86_400), windowSeconds: nil),
                planLabel: "Pro",
                credits: nil,
                fetchedAt: now
            )
        }
    }

    /// The synthetic day-by-day history every card dump draws from. A realistic day mixes models,
    /// which is what the hover breakdown is for. The run ends on today, because the chart marks
    /// today from the clock rather than from the snapshot — a fixture stuck in a fixed week draws
    /// an extra empty bar next to it.
    private static func sampleCost(_ provider: Provider) -> CostSnapshot {
        let now = Date().addingTimeInterval(-5 * 60)
        let (values, top) = provider == .codex
            ? ([18.0, 22, 12, 20, 24, 176], "gpt-5.6-sol")
            : ([62.0, 90, 48, 71, 9, 88, 41, 37], "claude-opus-5")
        let mix: [(CostUsageSource, String, Double)] = provider == .codex
            ? [(.codex, top, 0.72), (.openCode, "gpt-5.6-terra", 0.2), (.piAgent, "gpt-5.6-luna", 0.08)]
            : [(.claude, top, 0.8), (.claude, "claude-sonnet-5", 0.15), (.claude, "claude-haiku-4-5", 0.05)]
        let hitRates = [0.91, 0.88, 0.93, 0.9, 0.84, 0.92, 0.95, 0.94]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = values.enumerated().map { index, value in
            let date = calendar.date(byAdding: .day, value: index - (values.count - 1), to: today) ?? today
            return CostDay(
                dayKey: DayKey.make(from: date),
                byModel: Dictionary(uniqueKeysWithValues: mix.map { source, model, share in
                    (ModelUsageKey(source: source, model: model), ModelDayUsage(
                        tokens: Self.mixedTokens(
                            Int(value * share * 1_000_000),
                            cacheHitRate: hitRates[index % hitRates.count]
                        ),
                        costUSD: value * share
                    ))
                }),
                costUSD: value,
                unpricedTokens: 0
            )
        }
        return CostSnapshot(
            provider: provider,
            days: days,
            todayCostUSD: values.last ?? 0,
            windowCostUSD: values.reduce(0, +),
            latestTokens: 67_000_000,
            windowTokens: 637_000_000,
            topModel: top,
            hasUnpricedTokens: false,
            scannedAt: now
        )
    }

    static func run(directory: String) {
        let root = OffscreenCapture.directory(directory)

        let now = Date().addingTimeInterval(-5 * 60)

        let costs: [Provider: CostSnapshot] = [
            .claude: Self.sampleCost(.claude),
            .codex: Self.sampleCost(.codex),
        ]

        let cases: [(String, Provider, UsageSnapshot?)] = [
            ("codex-loaded", .codex, Self.loadedSnapshot(.codex)),
            ("claude-loaded", .claude, Self.loadedSnapshot(.claude)),
            // A plan without the five-hour cap keeps the session row, drawn as unlimited.
            ("codex-unlimited-session", .codex, UsageSnapshot(
                provider: .codex,
                session: nil,
                // Burning faster than the week allows, so the tip below the unlimited row is red.
                weekly: UsageWindow(usedPercent: 52, resetsAt: Date().addingTimeInterval(4 * 86_400 + 12 * 3600), windowSeconds: 604_800),
                planLabel: "Pro",
                credits: nil,
                fetchedAt: now,
                sessionIsUnlimited: true
            )),
            // An empty session has no pace, so its status fills the line beside the reset label.
            ("claude-session-exhausted", .claude, UsageSnapshot(
                provider: .claude,
                session: UsageWindow(usedPercent: 100, resetsAt: Date().addingTimeInterval(3 * 3600 + 43 * 60), windowSeconds: 18_000),
                weekly: UsageWindow(usedPercent: 35, resetsAt: Date().addingTimeInterval(6 * 86_400 + 7 * 3600), windowSeconds: 604_800),
                planLabel: "Pro",
                credits: nil,
                fetchedAt: now
            )),
            // A rate-limited refresh keeps the numbers on screen and appends the error.
            ("claude-rate-limited", .claude, (UsageSnapshot(
                provider: .claude,
                session: UsageWindow(usedPercent: 65, resetsAt: Date().addingTimeInterval(3 * 3600 + 51 * 60), windowSeconds: nil),
                weekly: UsageWindow(usedPercent: 7, resetsAt: Date().addingTimeInterval(6 * 86_400 + 9 * 3600), windowSeconds: nil),
                planLabel: "Pro",
                credits: nil,
                fetchedAt: now
            ))),
        ]
        let errors = ["claude-rate-limited": "Claude usage API rate-limited. Try again after 4:24 PM."]

        // Capture both the idle and hovered states, since the dump has no pointer. The hovered day
        // is an earlier one, so the left figure shows it in place of Today.
        for (provider, cost) in costs {
            guard let today = cost.days.last,
                  let hovered = cost.days.dropLast().max(by: { ($0.costUSD ?? 0) < ($1.costUSD ?? 0) })
            else { continue }
            for (name, hoveredDayKey) in [("idle", nil), ("hover", hovered.dayKey)] {
                for mode in [CostChartLabelMode.tokens, .cost] {
                    let suffix = mode == .tokens ? "" : "-cost"
                    Self.capture(
                        CostSectionView(
                            snapshot: cost,
                            previewHoveredDayKey: hoveredDayKey,
                            previewTodayDayKey: today.dayKey,
                            labelMode: mode
                        ).padding(14).frame(width: 280),
                        named: "\(provider.rawValue)-\(name)\(suffix)",
                        into: root
                    )
                }
            }
        }

        // The breakdown open on a busy day, in both units, since the share bars follow the unit.
        for provider in [Provider.codex, .claude] {
            let busy = Self.busyCost(provider)
            guard let today = busy.days.last else { continue }
            for mode in [CostChartLabelMode.tokens, .cost] {
                let suffix = mode == .tokens ? "" : "-cost"
                Self.capture(
                    CostSectionView(
                        snapshot: busy,
                        previewTodayDayKey: today.dayKey,
                        labelMode: mode,
                        isBreakdownExpanded: true,
                        expandedBreakdownDayKey: today.dayKey
                    )
                    .environment(\.cardMotionEnabled, false)
                    .padding(14).frame(width: 280),
                    named: "\(provider.rawValue)-breakdown\(suffix)",
                    into: root
                )
            }
        }

        // Both faces of the reset label: the clock one is the longer string, and it is the one
        // that would crowd the headline out of a 280pt card if it ever got too long.
        let resetModes: [(String, QuotaResetDisplayMode)] = [("", .countdown), ("-reset-clock", .clock)]
        for (baseName, provider, snapshot) in cases {
            for (suffix, resetMode) in resetModes {
                let name = baseName + suffix
                Self.capture(
                    MenuCardView(
                        provider: provider,
                        display: ProviderDisplay(
                            snapshot: snapshot,
                            cost: costs[provider],
                            error: errors[baseName]
                        ),
                        isRefreshing: false,
                        animatesFill: false,
                        quotaResetDisplayMode: resetMode
                    ),
                    named: name,
                    into: root
                )
            }
        }
    }
}

#endif
