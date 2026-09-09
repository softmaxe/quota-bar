#if DEBUG
import QuotaBarCore
import AppKit
import SwiftUI

/// `QuotaBar --dump-card <dir>` renders the menu card off screen to PNGs and exits.
/// Lets the card layout be checked without opening the real menu.
@MainActor
enum CardDump {
    /// Renders the settings window's content off screen too, so its layout can be checked
    /// without opening a real window.
    static func dumpSettings(directory: String) {
        let root = OffscreenCapture.directory(directory)

        // A throwaway defaults domain keeps the dump from touching real preferences, and the
        // fixtures keep the machine's own logs and saved rates out of the render.
        let defaults = EphemeralDefaults.make("QuotaBarSettingsDump")
        let settings = SettingsStore(defaults: defaults)
        let pricing = PricingEditorModel(
            costService: CostService(databaseURL: root.appendingPathComponent("unused.sqlite")),
            fixtures: Self.pricingFixtures
        )

        Self.captureSettings(
            AnyView(SettingsView(settings: settings, pricing: pricing)),
            named: "settings",
            into: root
        )
        // The pricing pane again on its own, with the top row unfolded, so the one-hour and
        // long-context fields are in the dump rather than a click away. The rows only load when
        // the pane appears, and the first capture never selects that tab, so load them here.
        let loading = Task {
            await pricing.load()
            // The first row the table draws is the first API model, not the busiest one, so pick
            // the busiest explicitly: an unfolded row with real numbers above it reads better
            // than one captioned "Not used locally".
            let row = pricing.rows.max { $0.usageTokens < $1.usageTokens } ?? pricing.rows.first
            if let row { pricing.expandedRowIDs = [row.id] }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        _ = loading
        Self.captureSettings(
            AnyView(PricingSettingsView(model: pricing)),
            named: "settings-pricing-expanded",
            into: root
        )
    }

    /// The settings window is a tab bar over a 620x460 pane and the pricing pane is that pane on
    /// its own, so the height comes from the view rather than from a constant here. The pane loads
    /// its rows asynchronously, so the capture lets the run loop turn first.
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
    /// wrote, since a layout regression usually shows up there first; frame dumps that print their
    /// own count pass `reporting: false`.
    private static func capture(
        _ view: some View,
        named name: String,
        into root: URL,
        appearance: NSAppearance? = nil,
        titled: Bool = false,
        settle: TimeInterval = 0,
        reporting: Bool = true
    ) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let outcome = OffscreenCapture.writePNG(
            hosting,
            named: name,
            into: root,
            titled: titled,
            settle: settle
        )
        guard reporting else { return }
        switch outcome {
        case let .written(url):
            print("wrote \(url.path) (\(Int(hosting.frame.width))x\(Int(hosting.frame.height)))")
        case let .failed(reason):
            print(reason)
        }
    }

    /// Made-up token totals and the built-in rate table, so the pricing pane renders the same
    /// on any machine and carries nobody's account in it.
    private static let pricingFixtures = PricingEditorModel.PreviewFixtures(
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
            ],
        ],
        overlay: PricingOverlay()
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
                    tokens: TokenTotals(input: Int(total * share * 1_000_000)),
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

    /// `--dump-breakdown-toggle <dir> <provider>` holds the three faces of the line that closes a
    /// busy day's model list: at rest, under the pointer, and opened. Off screen there is no
    /// pointer, so the hover is seeded rather than performed.
    static func dumpBreakdownToggle(directory: String, provider: Provider) {
        let root = OffscreenCapture.directory(directory)
        let cost = Self.busyCost(provider)
        guard let today = cost.days.last else { return }

        let states: [(name: String, expanded: Bool, toggleHovered: Bool)] = [
            ("collapsed", false, false),
            ("hovered", false, true),
            ("expanded", true, true),
        ]
        for state in states {
            Self.capture(
                CostSectionView(
                    snapshot: cost,
                    previewHoveredDayKey: today.dayKey,
                    previewTodayDayKey: today.dayKey,
                    isBreakdownExpanded: state.expanded,
                    previewToggleHovered: state.toggleHovered
                ).padding(14).frame(width: 280),
                named: state.name,
                into: root
            )
        }
    }

    /// `--dump-chart-hover <dir> <provider>` walks the highlight across every bar of the cost
    /// chart, one PNG per day. The frames carry the breakdown each bar opens, not the spring that
    /// carries the highlight between them — a still cannot hold a spring.
    static func dumpChartHover(directory: String, provider: Provider) {
        let root = OffscreenCapture.directory(directory)
        let cost = Self.sampleCost(provider)
        guard let today = cost.days.last else { return }

        for (index, day) in cost.days.enumerated() {
            Self.capture(
                CostSectionView(
                    snapshot: cost,
                    previewHoveredDayKey: day.dayKey,
                    previewTodayDayKey: today.dayKey
                ).padding(14).frame(width: 280),
                named: String(format: "frame-%04d", index),
                into: root,
                reporting: false
            )
        }
        print("wrote \(cost.days.count) chart hover frames to \(root.path)")
    }

    /// `--dump-reset-toggle <dir> <provider>` plays the reset label as the switch it is: the
    /// pointer arrives on the session line, one click trades the countdown for the clock time it
    /// was counting down to, a second click trades it back. Both windows change together, because
    /// the choice belongs to the card rather than to the row that was clicked.
    ///
    /// The swap is a cut in the app too, so the frames hold each face instead of crossing between
    /// them. What the dump has to supply is the hover: off screen there is no pointer, and the
    /// lift on the label is the only thing that says where the click goes.
    static func dumpResetToggle(directory: String, provider: Provider) {
        let root = OffscreenCapture.directory(directory)
        let display = ProviderDisplay(
            snapshot: Self.loadedSnapshot(provider),
            cost: Self.sampleCost(provider)
        )
        // Nothing moves inside a beat, so the frames are held rather than sampled, and the beat
        // is counted in frames rather than in seconds. The export plays them back at ten a
        // second, which is a whole number of GIF delay units, so a count here is tenths.
        let beats: [(mode: QuotaResetDisplayMode, hovered: Bool, frames: Int)] = [
            (.countdown, false, 9),
            (.countdown, true, 4),
            (.clock, true, 15),
            (.countdown, true, 11),
            (.countdown, false, 5),
        ]

        var index = 0
        for beat in beats {
            let view = MenuCardView(
                provider: provider,
                display: display,
                isRefreshing: false,
                animatesFill: false,
                quotaResetDisplayMode: beat.mode,
                hoveredResetLabelWindow: beat.hovered ? .session : nil
            )
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            // The card is laid out once per beat and captured once per frame it is held for.
            for _ in 0..<beat.frames {
                _ = OffscreenCapture.writePNG(
                    hosting,
                    named: String(format: "frame-%04d", index),
                    into: root
                )
                index += 1
            }
        }
        print("wrote \(index) reset toggle frames to \(root.path)")
    }

    /// The loaded card each provider is drawn from, shared with the reset toggle dump so both
    /// carry the same account.
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = values.enumerated().map { index, value in
            let date = calendar.date(byAdding: .day, value: index - (values.count - 1), to: today) ?? today
            return CostDay(
                dayKey: Formatters.dayKey(for: date),
                byModel: Dictionary(uniqueKeysWithValues: mix.map { source, model, share in
                    (ModelUsageKey(source: source, model: model), ModelDayUsage(
                        tokens: TokenTotals(input: Int(value * share * 1_000_000)),
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

        // Capture both the idle and hovered states, since the dump has no pointer.
        for (provider, cost) in costs {
            guard let today = cost.days.last,
                  let hovered = cost.days.max(by: { ($0.costUSD ?? 0) < ($1.costUSD ?? 0) }) else { continue }
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
