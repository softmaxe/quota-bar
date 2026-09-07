import QuotaBarCore
import Combine
import Foundation
import SwiftUI

enum PricingGroup: String, CaseIterable, Identifiable, Hashable {
    case claude = "Claude"
    case codex = "Codex"
    case others = "Others"

    var id: String { self.rawValue }

    static func whitelist(for provider: Provider) -> [String] {
        switch provider {
        case .codex: ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "codex-mini-latest"]
        case .claude: [
                "claude-fable-5-1", "claude-fable-5", "claude-opus-5", "claude-sonnet-5",
                "claude-haiku-4-5", "claude-3-5-haiku",
            ]
        }
    }

    static func classify(model: String) -> PricingGroup {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.whitelist(for: .claude).contains(name) { return .claude }
        if self.whitelist(for: .codex).contains(name) { return .codex }
        return .others
    }
}

/// The settings pane keeps the current API models visible and only exposes an unpriced model
/// from the local logs when every pricing layer has failed to resolve it.
enum PricingModelFilterPolicy {
    static func visibleModels(
        provider: Provider,
        usage: [ModelUsageTotal],
        overlay: PricingOverlay
    ) -> [String] {
        let whitelist = PricingGroup.whitelist(for: provider)
        let seen = usage.map { CostPricing.normalize($0.model, provider: provider) }
        let seenSet = Set(seen.filter { !$0.isEmpty && $0 != CostPricing.unknownModel })
        let unpriced = seenSet.filter { name in
            !whitelist.contains(name)
                && CostPricing.pricing(for: name, provider: provider, overlay: overlay) == nil
        }
        return whitelist + unpriced.sorted()
    }
}

/// One editable row of the pricing table. Rates are USD per million tokens, matching how
/// providers publish them, and the fields cover every input the billing math actually reads:
/// the four base rates, the one-hour cache write, and the long-context tier.
struct PricingRow: Identifiable, Equatable {
    let provider: Provider
    let group: PricingGroup
    let model: String
    /// True when the model appears in the local logs, which is what makes a row worth editing.
    let seenInLogs: Bool
    /// True when the built-in table or the models.dev catalog already prices this model.
    let hasDefault: Bool
    /// Total tokens seen in local logs. The settings list uses this to put active models first.
    let usageTokens: Int

    var input: String
    var output: String
    /// Five-minute cache write, which is the TTL the published price tables quote.
    var cacheWrite: String
    /// One-hour cache write. Empty means "twice the input rate", the ratio Anthropic publishes.
    var cacheWrite1h: String
    var cacheRead: String

    /// Tokens in one request above which the long-context rates apply. Empty means no tier.
    var thresholdTokens: String
    var inputAbove: String
    var outputAbove: String
    var cacheWriteAbove: String
    var cacheWrite1hAbove: String
    var cacheReadAbove: String

    /// Every optional rate column, paired with the pricing field it mirrors. One list, so a new
    /// rate cannot reach the table without also reaching the reset that clears it.
    static let optionalRateColumns: [(
        column: WritableKeyPath<PricingRow, String>,
        rate: KeyPath<ModelPricing, Double?>
    )] = [
        (\.cacheWrite, \.cacheWrite),
        (\.cacheWrite1h, \.cacheWrite1h),
        (\.cacheRead, \.cacheRead),
        (\.inputAbove, \.inputAbove),
        (\.outputAbove, \.outputAbove),
        (\.cacheWriteAbove, \.cacheWriteAbove),
        (\.cacheWrite1hAbove, \.cacheWrite1hAbove),
        (\.cacheReadAbove, \.cacheReadAbove),
    ]

    var id: String { "\(self.provider.rawValue)|\(self.model)" }

    var isPriced: Bool {
        Double(self.input) != nil && Double(self.output) != nil
    }

    /// Whether the model has a second price tier, which the row labels so it is clear there is
    /// more behind the disclosure than the four visible columns.
    var hasLongContextTier: Bool {
        !self.thresholdTokens.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What an empty one-hour field bills at, so the placeholder shows the real number.
    var derivedCacheWrite1h: Double? {
        Double(self.input.trimmingCharacters(in: .whitespaces))
            .map { $0 * ModelPricing.oneHourCacheWriteMultiplier }
    }

    var derivedCacheWrite1hAbove: Double? {
        Double(self.inputAbove.trimmingCharacters(in: .whitespaces))
            .map { $0 * ModelPricing.oneHourCacheWriteMultiplier }
    }
}

/// Backs the pricing pane: loads the effective rates, tracks edits, and writes the override file.
@MainActor
final class PricingEditorModel: ObservableObject {
    @Published private(set) var rows: [PricingRow] = []
    @Published private(set) var isLoading = true
    @Published private(set) var saveError: String?
    @Published private(set) var externalScanStatuses: [String] = []
    @Published private(set) var hasUnsavedChanges = false
    /// Set after a save so the pane can say what the new rates do and do not touch.
    @Published private(set) var lastSavedAt: Date?
    /// Rows whose one-hour and long-context fields are unfolded. Kept here rather than in the
    /// view so a headless dump can capture an expanded row.
    @Published var expandedRowIDs: Set<String> = []
    /// Which column the table is ordered by. Held here so the header arrows and the row order
    /// cannot disagree, and so the order survives a reload of the rates.
    @Published private(set) var sort: PricingSort = .default

    private var originalRows: [String: PricingRow] = [:]
    /// Position of each row in `rows`, so a field can reach its row without a linear scan.
    private var indexByID: [String: Int] = [:]
    /// Rates from the built-in table plus models.dev, i.e. what a row falls back to.
    private var defaults: [String: ModelPricing] = [:]
    /// User overrides loaded with the current overlay, including models hidden from the table.
    private var loadedUserOverrides: [String: ModelPricing] = [:]
    private let costService: CostService
    /// Called after a successful save so the cards can re-price without waiting for a poll.
    var onSaved: (() -> Void)?

    /// Stands in for the two things `load()` reads off the machine it is running on: the local
    /// scan cache and the price layers on disk. Only `--dump-settings` passes one, so the pane
    /// it renders shows made-up models at the built-in rates rather than whoever ran it.
    struct PreviewFixtures {
        let usage: [Provider: [ModelUsageTotal]]
        let overlay: PricingOverlay
    }

    private let fixtures: PreviewFixtures?

    init(costService: CostService, fixtures: PreviewFixtures? = nil) {
        self.costService = costService
        self.fixtures = fixtures
    }

    /// Fills the table from disk and only then goes looking for a newer models.dev catalog.
    ///
    /// Both halves used to be one blocking step in front of the table, so the pane sat on a
    /// spinner for the length of a network round trip — and for the full request timeout on a
    /// host that cannot reach models.dev, on every single open, because a failed fetch writes
    /// no cache and so never stops looking stale.
    func load() async {
        // Reopening the pane must not throw away rates the user is part-way through typing.
        guard !self.hasUnsavedChanges else { return }

        if let fixtures = self.fixtures {
            await self.rebuild(overlay: fixtures.overlay)
            return
        }

        await self.rebuild(overlay: PricingOverlayStore.loadFromDisk())
        self.externalScanStatuses = await [
            self.costService.currentOpenCodeScanStatus().message(agent: "OpenCode"),
            self.costService.currentPiAgentScanStatus().message(agent: "Pi Agent"),
        ].compactMap { $0 }

        // The table is on screen by now, so the catalog refresh costs the user nothing. It
        // only redraws when models.dev actually moved.
        if let refreshed = await self.costService.refreshPricingCatalog(), !self.hasUnsavedChanges {
            await self.rebuild(overlay: refreshed)
        }
    }

    private func rebuild(overlay: PricingOverlay) async {
        // A reload behind an already-drawn table replaces it in place; only a first fill has
        // nothing to show meanwhile.
        self.isLoading = self.rows.isEmpty

        self.loadedUserOverrides = overlay.userOverrides
        // The overlay minus the user layer is what a row would fall back to if its override
        // were removed, which is what the Reset button has to restore.
        let fallback = PricingOverlay(userOverrides: [:], modelsDev: overlay.modelsDev)

        // Read on a connection of its own rather than through the service's actor, which a log
        // scan can hold for seconds at a time.
        let databaseURL = self.costService.databaseURL
        let usageByProvider: [Provider: [ModelUsageTotal]]
        if let fixtures = self.fixtures {
            usageByProvider = fixtures.usage
        } else {
            usageByProvider = await Task.detached {
                var usage: [Provider: [ModelUsageTotal]] = [:]
                for provider in Provider.allCases {
                    usage[provider] = CostUsageReader.knownModelUsage(
                        provider: provider,
                        databaseURL: databaseURL
                    )
                }
                return usage
            }.value
        }

        var built: [PricingRow] = []
        var defaults: [String: ModelPricing] = [:]

        for provider in Provider.allCases {
            let usage = usageByProvider[provider] ?? []
            let seen = usage.map(\.model)
            let names = PricingModelFilterPolicy.visibleModels(
                provider: provider,
                usage: usage,
                overlay: overlay
            )

            let seenSet = Set(seen.map { CostPricing.normalize($0, provider: provider) })
            let usageTokens = Dictionary(uniqueKeysWithValues: usage.map {
                (CostPricing.normalize($0.model, provider: provider), $0.tokens)
            })

            for name in names {
                let fallbackPricing = CostPricing.pricing(for: name, provider: provider, overlay: fallback)
                let effective = CostPricing.pricing(for: name, provider: provider, overlay: overlay)
                let row = PricingRow(
                    provider: provider,
                    group: PricingGroup.classify(model: name),
                    model: name,
                    seenInLogs: seenSet.contains(name),
                    hasDefault: fallbackPricing != nil,
                    usageTokens: usageTokens[name] ?? 0,
                    input: Self.text(effective?.input),
                    output: Self.text(effective?.output),
                    cacheWrite: Self.text(effective?.cacheWrite),
                    cacheWrite1h: Self.text(effective?.cacheWrite1h),
                    cacheRead: Self.text(effective?.cacheRead),
                    thresholdTokens: Self.integerText(effective?.thresholdTokens),
                    inputAbove: Self.text(effective?.inputAbove),
                    outputAbove: Self.text(effective?.outputAbove),
                    cacheWriteAbove: Self.text(effective?.cacheWriteAbove),
                    cacheWrite1hAbove: Self.text(effective?.cacheWrite1hAbove),
                    cacheReadAbove: Self.text(effective?.cacheReadAbove)
                )
                defaults[row.id] = fallbackPricing
                built.append(row)
            }
        }

        // Provider sections stay stable; active models rise within their section by actual usage.
        built.sort(by: PricingSortPolicy.defaultOrder)

        self.defaults = defaults
        self.setRows(built)
        self.originalRows = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        self.hasUnsavedChanges = false
        self.isLoading = false
    }

    /// Rows and the id lookup move together: the table asks for a row by id once per field, so
    /// scanning the array for each one made a redraw quadratic in the number of models.
    private func setRows(_ rows: [PricingRow]) {
        self.rows = rows
        self.indexByID = Dictionary(
            uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    func rows(in group: PricingGroup) -> [PricingRow] {
        PricingSortPolicy.sorted(self.rows.filter { $0.group == group }, by: self.sort)
    }

    /// Header click: flips the column that is already sorted, otherwise switches to the tapped one.
    func toggleSort(_ field: PricingSortField) {
        self.sort = PricingSortPolicy.next(after: self.sort, tapping: field)
    }

    /// Back to the order the pane loads in, most-used first.
    func resetSort() {
        self.sort = .default
    }

#if DEBUG
    /// Lets a headless run drive the table without reading the pricing files on disk.
    func debugSetRows(_ rows: [PricingRow]) {
        self.setRows(rows.sorted(by: PricingSortPolicy.defaultOrder))
        self.isLoading = false
    }
#endif

    func isExpanded(_ id: String) -> Bool {
        self.expandedRowIDs.contains(id)
    }

    func toggleExpanded(_ id: String) {
        if self.expandedRowIDs.contains(id) {
            self.expandedRowIDs.remove(id)
        } else {
            self.expandedRowIDs.insert(id)
        }
    }

    func binding(for id: String, keyPath: WritableKeyPath<PricingRow, String>) -> Binding<String> {
        Binding(
            get: { self.indexByID[id].map { self.rows[$0][keyPath: keyPath] } ?? "" },
            set: { newValue in
                guard let index = self.indexByID[id] else { return }
                self.rows[index][keyPath: keyPath] = newValue
                self.recomputeUnsavedChanges()
            }
        )
    }

    /// Restores a row to what it would be with no override.
    func reset(id: String) {
        guard let index = self.indexByID[id] else { return }
        self.applyFallback(at: index)
        self.recomputeUnsavedChanges()
    }

    func resetAll() {
        for index in self.rows.indices { self.applyFallback(at: index) }
        // One scan after the whole table, rather than one per row reset.
        self.recomputeUnsavedChanges()
    }

    private func applyFallback(at index: Int) {
        let fallback = self.defaults[self.rows[index].id] ?? nil
        self.rows[index].input = Self.text(fallback?.input)
        self.rows[index].output = Self.text(fallback?.output)
        self.rows[index].thresholdTokens = Self.integerText(fallback?.thresholdTokens)
        for field in PricingRow.optionalRateColumns {
            self.rows[index][keyPath: field.column] = Self.text(
                fallback.flatMap { $0[keyPath: field.rate] }
            )
        }
    }

    private func recomputeUnsavedChanges() {
        self.hasUnsavedChanges = self.rows.contains { self.originalRows[$0.id] != $0 }
    }

    /// Writes only the rows that differ from their fallback, so the override file stays small
    /// and future built-in updates still reach the untouched models.
    ///
    /// Rows hidden by the settings filter are kept in the file. A visible row is the only row
    /// allowed to update or remove its own override.
    ///
    /// Usage already recorded keeps the cost it was scanned with: the service prices everything
    /// on disk at the old rates first, and the new rates only reach what is logged afterwards.
    func save() async {
        let overrides = Self.mergedUserOverrides(
            existing: self.loadedUserOverrides,
            rows: self.rows,
            defaults: self.defaults
        )

        do {
            try await self.costService.freezeCurrentPrices()
            try PricingOverlayStore.saveUserOverrides(overrides)
            await self.costService.invalidatePricing()
            self.saveError = nil
            self.hasUnsavedChanges = false
            self.lastSavedAt = Date()
            self.loadedUserOverrides = overrides
            self.originalRows = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0) })
            self.onSaved?()
        } catch {
            self.saveError = error.localizedDescription
        }
    }

    /// Merges visible edits into the loaded user layer without deleting overrides for hidden rows.
    /// A missing row price or a value equal to its fallback removes that row's override.
    static func mergedUserOverrides(
        existing: [String: ModelPricing],
        rows: [PricingRow],
        defaults: [String: ModelPricing]
    ) -> [String: ModelPricing] {
        var overrides = existing
        for row in rows {
            guard let pricing = Self.pricing(from: row) else {
                overrides.removeValue(forKey: row.model)
                continue
            }
            if let fallback = defaults[row.id], pricing == fallback {
                overrides.removeValue(forKey: row.model)
            } else {
                overrides[row.model] = pricing
            }
        }
        return overrides
    }

    /// A row with no base rates is not priced at all, which is how a model gets removed from the
    /// override file. Everything else round-trips, including the tier the billing math reads.
    static func pricing(from row: PricingRow) -> ModelPricing? {
        guard let input = Self.number(row.input), let output = Self.number(row.output) else {
            return nil
        }
        return ModelPricing(
            input: input,
            output: output,
            cacheWrite: Self.number(row.cacheWrite),
            cacheWrite1h: Self.number(row.cacheWrite1h),
            cacheRead: Self.number(row.cacheRead),
            thresholdTokens: Self.number(row.thresholdTokens).map { Int($0) },
            inputAbove: Self.number(row.inputAbove),
            outputAbove: Self.number(row.outputAbove),
            cacheWriteAbove: Self.number(row.cacheWriteAbove),
            cacheWrite1hAbove: Self.number(row.cacheWrite1hAbove),
            cacheReadAbove: Self.number(row.cacheReadAbove)
        )
    }

    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Thousands separators are natural to type into a token threshold.
        return Double(trimmed.replacingOccurrences(of: ",", with: ""))
    }

    static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        // Rates go to four decimals: cache reads run as low as $0.005 per million.
        return value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%g", value)
    }

    private static func integerText(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}
