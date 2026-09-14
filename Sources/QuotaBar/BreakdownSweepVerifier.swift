#if DEBUG
import QuotaBarCore
import AppKit
import SwiftUI

/// Opening the entire model list sweeps the card's height while the rows fade in under it.
///
/// Everything above the breakdown has to hold still through that. It does only because the card is
/// laid out at the height its own contents want and hangs from the top of the hosting view, so a
/// sweep uncovers it; drop that and every step re-proposes a height to the whole card, and the
/// chart and the lines above it shuffle their way through an animation happening beneath them.
/// This checks the natural height of both the section and card, then compares the pixels above the
/// breakdown through six steps of the sweep.
@MainActor
enum BreakdownSweepVerifier {
    private static let label = "breakdown sweep verification"
    /// The provider header and quota rows must not move as model rows appear below.
    private static let stillRegionHeight: CGFloat = 230
    private static let cardWidth: CGFloat = 280

    static func run() -> Never {
        let provider = Provider.codex
        let cost = CardDump.busyCost(provider)
        let display = ProviderDisplay(
            snapshot: CardDump.loadedSnapshot(provider),
            cost: cost
        )
        let collapsed = Self.height(of: Self.card(provider: provider, display: display, openness: 0))
        let open = Self.height(of: Self.card(provider: provider, display: display, openness: 1))

        var failures: [String] = []
        if open <= collapsed {
            failures.append("opening the breakdown expected a taller card, got \(open) from \(collapsed)")
        }

        for testedCost in [cost, Self.partiallyPricedCost(cost)] {
            let testedDisplay = ProviderDisplay(snapshot: display.snapshot, cost: testedCost)
            for openness in [0.0, 1.0] {
                let tokenSection = Self.sectionHeight(of: Self.section(
                    cost: testedCost, openness: openness, labelMode: .tokens
                ))
                let costSection = Self.sectionHeight(of: Self.section(
                    cost: testedCost, openness: openness, labelMode: .cost
                ))
                if abs(tokenSection - costSection) > 0.5 {
                    failures.append(
                        "switching usage units at \(openness) openness moved the section height "
                            + "from \(tokenSection)pt to \(costSection)pt"
                    )
                }
                let tokenCard = Self.height(of: Self.card(
                    provider: provider, display: testedDisplay, openness: openness, labelMode: .tokens
                ))
                let costCard = Self.height(of: Self.card(
                    provider: provider, display: testedDisplay, openness: openness, labelMode: .cost
                ))
                if abs(tokenCard - costCard) > 0.5 {
                    failures.append(
                        "switching usage units at \(openness) openness moved the card height "
                            + "from \(tokenCard)pt to \(costCard)pt"
                    )
                }
            }
        }

        let partialCost = Self.partiallyPricedCost(cost)
        if let pricedDay = partialCost.days.first?.dayKey,
           let partialDay = partialCost.days.last?.dayKey,
           let zeroDay = CostChartHighlightPolicy.visibleDays(
                from: partialCost.days, todayDayKey: partialDay, maxBars: 10
           ).first?.dayKey {
            for mode in [CostChartLabelMode.tokens, .cost] {
                let selectedHeights = [pricedDay, zeroDay, partialDay].map { dayKey in
                    Self.sectionHeight(of: Self.section(
                        cost: partialCost, openness: 0, labelMode: mode,
                        hoveredDayKey: dayKey
                    ))
                }
                if let firstHeight = selectedHeights.first,
                   selectedHeights.contains(where: { abs($0 - firstHeight) > 0.5 }) {
                    failures.append("hovering priced, empty, and partially priced days in \(mode.rawValue) mode "
                        + "moved the section heights to \(selectedHeights)")
                }
            }
        }

        // A selected five-model day opens exactly five rows, even when the latest day contains
        // twelve models. The collapsed state shows no model rows.
        let unevenDisplay = ProviderDisplay(
            snapshot: CardDump.loadedSnapshot(provider),
            cost: Self.unevenCost(provider)
        )
        let layout = CostSectionView.breakdownLayout
        let rowStripHeight = layout.rowsHeight(rows: 5)
        let selectedDayKey = unevenDisplay.cost?.days.first?.dayKey
        for mode in [CostChartLabelMode.tokens, .cost] {
            if let cost = unevenDisplay.cost, let selectedDayKey {
                let closedSectionHeight = Self.sectionHeight(of: Self.section(
                    cost: cost, openness: 0, labelMode: mode
                ))
                let openSectionHeight = Self.sectionHeight(of: Self.section(
                    cost: cost,
                    openness: 1,
                    labelMode: mode,
                    expandedDayKey: selectedDayKey
                ))
                if abs(openSectionHeight - closedSectionHeight - rowStripHeight) > 0.5 {
                    failures.append(
                        "the \(mode.rawValue) section expected all five rows and no clipped content; "
                            + "height grew \(openSectionHeight - closedSectionHeight)pt instead of \(rowStripHeight)pt"
                    )
                }
            }
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
                    "opening the five-model day in \(mode.rawValue) mode expected \(rowStripHeight)pt of growth, got \(growth)pt"
                )
            }

            // A refresh can invalidate the selected date. The expanded card falls back to the
            // latest visible day, whose complete twelve-row list must fit.
            let fallbackHeight = Self.height(of: Self.card(
                provider: provider,
                display: unevenDisplay,
                openness: 1,
                labelMode: mode,
                expandedDayKey: "missing-day"
            ))
            let fallbackGrowth = fallbackHeight - closedHeight
            let expectedFallbackGrowth = layout.rowsHeight(rows: 12)
            if abs(fallbackGrowth - expectedFallbackGrowth) > 0.5 {
                failures.append(
                    "an unavailable expanded day in \(mode.rawValue) mode expected the latest twelve rows "
                        + "and \(expectedFallbackGrowth)pt of growth, got \(fallbackGrowth)pt"
                )
            }
            if let cost = unevenDisplay.cost {
                let fallbackSectionGrowth = Self.sectionHeight(of: Self.section(
                    cost: cost,
                    openness: 1,
                    labelMode: mode,
                    expandedDayKey: "missing-day"
                )) - Self.sectionHeight(of: Self.section(
                    cost: cost, openness: 0, labelMode: mode
                ))
                if abs(fallbackSectionGrowth - expectedFallbackGrowth) > 0.5 {
                    failures.append(
                        "the \(mode.rawValue) section expected all twelve fallback rows without clipping; "
                            + "height grew \(fallbackSectionGrowth)pt"
                    )
                }
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
            passed: "the entire model list fits when opened and the card remains stable above it"
        )
    }

    private static func section(
        cost: CostSnapshot,
        openness: Double,
        labelMode: CostChartLabelMode,
        expandedDayKey: String? = nil,
        hoveredDayKey: String? = nil
    ) -> some View {
        CostSectionView(
            snapshot: cost,
            previewHoveredDayKey: hoveredDayKey,
            previewTodayDayKey: cost.days.last?.dayKey,
            labelMode: labelMode,
            isBreakdownExpanded: openness > 0,
            breakdownOpenness: openness,
            expandedBreakdownDayKey: expandedDayKey
        )
        .frame(width: Self.cardWidth - 28)
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

    /// The selected first day has five models, while the latest visible day has twelve.
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

    private static func partiallyPricedCost(_ sample: CostSnapshot) -> CostSnapshot {
        guard let last = sample.days.last else { return sample }
        let missingTokens = 1_000
        var byModel = last.byModel
        byModel[ModelUsageKey(source: .codex, model: "fixture-unpriced")] = ModelDayUsage(
            tokens: TokenTotals(input: missingTokens), costUSD: nil
        )
        var days = sample.days
        days[days.index(before: days.endIndex)] = CostDay(
            dayKey: last.dayKey,
            byModel: byModel,
            costUSD: last.costUSD,
            unpricedTokens: missingTokens
        )
        return CostSnapshot(
            provider: sample.provider,
            days: days,
            todayCostUSD: sample.todayCostUSD,
            windowCostUSD: sample.windowCostUSD,
            latestTokens: sample.latestTokens + missingTokens,
            windowTokens: sample.windowTokens + missingTokens,
            topModel: sample.topModel,
            hasUnpricedTokens: true,
            scannedAt: sample.scannedAt
        )
    }

    private static func height(of card: MenuCardView) -> CGFloat {
        NSHostingView(rootView: card).fittingSize.height
    }

    private static func sectionHeight(of section: some View) -> CGFloat {
        NSHostingView(rootView: section).fittingSize.height
    }

    /// The card drawn into a hosting view of `height` — one step of the sweep — as the raw pixels
    /// of the region that has to be identical in every step.
    private static func stillRegion(of card: MenuCardView, at height: CGFloat) -> Data? {
        let hosting = NSHostingView(rootView: card)
        // The card's visible frame clips rows that the sweep has not revealed yet.
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
