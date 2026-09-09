#if DEBUG
import QuotaBarCore
import AppKit
import SwiftUI

/// Opening a day's model list sweeps the card's height while the rows fade in under it, because a
/// menu has no animation of its own — `StatusItemController` steps the hosting view's frame and
/// AppKit re-lays the menu out around each step.
///
/// Everything above the breakdown has to hold still through that. It does only because the card is
/// laid out at the height its own contents want and hangs from the top of the hosting view, so a
/// sweep uncovers it; drop that and every step re-proposes a height to the whole card, and the
/// chart and the lines above it shuffle their way through an animation happening beneath them.
/// This renders the opened card at three points of the sweep and compares the pixels above the
/// breakdown, which is that property and nothing else.
@MainActor
enum BreakdownSweepVerifier {
    private static let label = "breakdown sweep verification"
    /// Down to the last bar of the chart. Below this line the breakdown itself is drawing, which
    /// is what the sweep is there to uncover.
    private static let stillRegionHeight: CGFloat = 230
    private static let cardWidth: CGFloat = 280

    static func run() -> Never {
        let provider = Provider.codex
        let display = ProviderDisplay(
            snapshot: CardDump.loadedSnapshot(provider),
            cost: CardDump.busyCost(provider)
        )
        let collapsed = Self.height(of: Self.card(provider: provider, display: display, openness: 0))
        let open = Self.height(of: Self.card(provider: provider, display: display, openness: 1))

        var failures: [String] = []
        if open <= collapsed {
            failures.append("opening the breakdown expected a taller card, got \(open) from \(collapsed)")
        }

        // A selected day with one hidden model must only open one row, even when another chart
        // day contains many more models. This is the layout reached after the chart label switches
        // between tokens and cost; reserving the other day's rows leaves a blank block below
        // "Show less".
        let unevenDisplay = ProviderDisplay(
            snapshot: CardDump.loadedSnapshot(provider),
            cost: Self.unevenCost(provider)
        )
        let layout = CostSectionView.breakdownLayout
        let rowStripHeight = layout.rowsHeight(rows: 1)
        let selectedDayKey = unevenDisplay.cost?.days.first?.dayKey
        if let cost = unevenDisplay.cost, let selectedDayKey {
            let expandedSection = CostSectionView(
                snapshot: cost,
                previewTodayDayKey: cost.days.last?.dayKey,
                isBreakdownExpanded: true,
                breakdownOpenness: 1,
                expandedBreakdownDayKey: selectedDayKey,
                previewToggleHovered: true
            )
            if let highlightedDayKey = expandedSection.debugSelectedDayKey {
                failures.append(
                    "opening the breakdown off-bar expected no chart selection, got \(highlightedDayKey)"
                )
            }
        }
        for mode in [CostChartLabelMode.tokens, .cost] {
            let closedHeight = Self.height(of: Self.card(
                provider: provider,
                display: unevenDisplay,
                openness: 0,
                labelMode: mode
            ))
            let openHeight = Self.height(of: Self.card(
                provider: provider,
                display: unevenDisplay,
                openness: 1,
                labelMode: mode,
                expandedDayKey: selectedDayKey
            ))
            let growth = openHeight - closedHeight
            if abs(growth - rowStripHeight) > 0.5 {
                failures.append(
                    "opening a five-model day in \(mode.rawValue) mode expected \(rowStripHeight)pt of growth, got \(growth)pt"
                )
            }

            // A provider switch can invalidate the held day key while the menu stays open. The
            // expanded card must fall back to a visible day so the detail and "Show less" remain.
            let fallbackHeight = Self.height(of: Self.card(
                provider: provider,
                display: unevenDisplay,
                openness: 1,
                labelMode: mode,
                expandedDayKey: "missing-day"
            ))
            let fallbackGrowth = fallbackHeight - closedHeight
            let expectedFallbackGrowth = layout.rowsHeight(rows: 8)
            if abs(fallbackGrowth - expectedFallbackGrowth) > 0.5 {
                failures.append(
                    "an unavailable expanded day in \(mode.rawValue) mode expected a visible-day fallback with \(expectedFallbackGrowth)pt of growth, got \(fallbackGrowth)pt"
                )
            }
        }

        var reference: Data?
        for progress in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
            // Exactly what one step of the sweep hands the card: the height it is drawn in and how
            // far open the rows are, off the same reading.
            let height = CostChartHoverMotion.breakdownHeight(
                start: collapsed,
                target: open,
                progress: progress
            )
            let openness = CostChartHoverMotion.breakdownEase(progress)
            if height != height.rounded() {
                failures.append("the sweep expected whole points, got \(height)")
            }
            guard let strip = Self.stillRegion(
                of: Self.card(provider: provider, display: display, openness: openness),
                at: height
            ) else {
                VerifierReport.fail("failed to render the card at \(height)pt", label: Self.label)
            }
            if let reference, strip != reference {
                failures.append(
                    "the card moved above the breakdown \(Int(progress * 100))% through the sweep"
                )
            }
            reference = reference ?? strip
        }

        VerifierReport.finish(
            failures,
            label: Self.label,
            passed: "the card grew for the breakdown and held everything above it still while it did"
        )
    }

    private static func card(
        provider: Provider,
        display: ProviderDisplay,
        openness: Double,
        labelMode: CostChartLabelMode = .tokens,
        expandedDayKey: String? = nil
    ) -> MenuCardView {
        MenuCardView(
            provider: provider,
            display: display,
            isRefreshing: false,
            animatesFill: false,
            costChartLabelMode: labelMode,
            isCostBreakdownExpanded: openness > 0,
            costBreakdownOpenness: openness,
            expandedCostBreakdownDayKey: expandedDayKey
        )
    }

    /// The selected first day has five models, while the latest visible day has twelve. Closed
    /// cards may reserve a stable four-row block across hover changes; opened cards must fit the
    /// selected day's full list rather than the busiest day's list.
    private static func unevenCost(_ provider: Provider) -> CostSnapshot {
        let sample = CardDump.busyCost(provider)
        guard let first = sample.days.first, let last = sample.days.last else { return sample }

        func day(from source: CostDay, modelCount: Int) -> CostDay {
            let byModel = Dictionary(uniqueKeysWithValues: (0..<modelCount).map { index in
                let key = ModelUsageKey(
                    source: provider == .codex ? .codex : .claude,
                    model: "fixture-model-\(index)"
                )
                return (key, ModelDayUsage(
                    tokens: TokenTotals(input: (modelCount - index) * 1_000_000),
                    costUSD: Double(index + 1)
                ))
            })
            return CostDay(
                dayKey: source.dayKey,
                byModel: byModel,
                costUSD: source.costUSD,
                unpricedTokens: 0
            )
        }

        var days = sample.days
        days[days.startIndex] = day(from: first, modelCount: 5)
        days[days.index(before: days.endIndex)] = day(from: last, modelCount: 12)
        return CostSnapshot(
            provider: sample.provider,
            days: days,
            todayCostUSD: sample.todayCostUSD,
            windowCostUSD: sample.windowCostUSD,
            latestTokens: sample.latestTokens,
            windowTokens: sample.windowTokens,
            topModel: sample.topModel,
            hasUnpricedTokens: sample.hasUnpricedTokens,
            scannedAt: sample.scannedAt
        )
    }

    private static func height(of card: MenuCardView) -> CGFloat {
        NSHostingView(rootView: card).fittingSize.height
    }

    /// The card drawn into a hosting view of `height` — one step of the sweep — as the raw pixels
    /// of the region that has to be identical in every step.
    private static func stillRegion(of card: MenuCardView, at height: CGFloat) -> Data? {
        let hosting = NSHostingView(rootView: card)
        // The same clip the menu's own card has: what the sweep has not uncovered yet is cut off
        // rather than drawn past the bottom edge.
        hosting.clipsToBounds = true
        hosting.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: height)
        guard let rep = OffscreenCapture.render(hosting), let pixels = rep.bitmapData else {
            return nil
        }
        // Renders come back at the screen's backing scale, so the row count is read off the
        // bitmap rather than assumed.
        let scale = CGFloat(rep.pixelsHigh) / height
        let rows = min(rep.pixelsHigh, Int((Self.stillRegionHeight * scale).rounded()))
        return Data(bytes: pixels, count: rows * rep.bytesPerRow)
    }
}
#endif
