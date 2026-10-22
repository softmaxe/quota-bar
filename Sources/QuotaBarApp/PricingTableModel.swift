import QuotaBarCore
import Combine
import Foundation
import SwiftUI

enum PricingGroup: String, CaseIterable, Identifiable, Hashable {
    case claude = "Claude"
    case codex = "Codex"
    case others = "Others"

    var id: String { self.rawValue }

    /// Claude and Codex hold the models the price book lists for that provider; every other
    /// model, priced by models.dev or by nothing, is in Others.
    static func classify(model: String, provider: Provider, rateCard: RateCard) -> PricingGroup {
        guard rateCard.source(for: model, provider: provider) == .priceBook else { return .others }
        return provider == .claude ? .claude : .codex
    }
}

/// The settings pane lists the current API models whether or not they were used, and every other
/// model the local logs name.
enum PricingModelFilterPolicy {
    static func visibleModels(
        provider: Provider,
        usage: [ModelUsageTotal],
        rateCard: RateCard
    ) -> [String] {
        let settingsModels = rateCard.settingsModels(for: provider)
        let listed = Set(settingsModels)
        let seen = rateCard.modelUsage(usage, provider: provider).map(\.model)
            .filter { !listed.contains($0) }
        return settingsModels + seen.sorted()
    }
}

/// One row of the pricing table: a model, the rates in force for it today in USD per million
/// tokens, and where they come from.
struct PricingRow: Identifiable, Equatable {
    let group: PricingGroup
    let model: String
    /// True when the model appears in the local logs.
    var seenInLogs: Bool
    /// Total tokens seen in local logs. The settings list uses this to put active models first.
    var usageTokens: Int
    /// Position among the models the rate card lists for settings, which the default order keeps.
    var settingsRank: Int?
    /// nil when nothing prices the model today.
    let rates: ModelPricing?
    let source: RateCard.Source?

    /// A model in Others is one row whichever provider's logs named it, since its rates do not
    /// depend on the provider.
    var id: String { "\(self.group.rawValue)|\(self.model)" }

    var isPriced: Bool { self.rates != nil }

    var input: Double? { self.rates?.input }
    var output: Double? { self.rates?.output }
    var cacheWrite: Double? { self.rates?.cacheWrite }
    var cacheRead: Double? { self.rates?.cacheRead }

    /// Whether the model has a second price tier, which the row labels so it is clear there is
    /// more behind the disclosure than the four visible columns.
    var hasLongContextTier: Bool { self.rates?.thresholdTokens != nil }
}

/// Backs the pricing pane: the rates the rate card prices each model at today, beside how much
/// of each model the local logs recorded.
@MainActor
final class PricingTableModel: ObservableObject {
    @Published private(set) var rows: [PricingRow] = []
    @Published private(set) var isLoading = true
    @Published private(set) var usageReadError: String?
    @Published private(set) var hasLoadedUsage = false
    @Published private(set) var isReadingUsage = false
    @Published private(set) var scanStatusMessages: [String] = []
    /// When models.dev was last read, and whether pricing from it is on, for the footer.
    @Published private(set) var modelsDevFetchedAt: Date?
    @Published private(set) var modelsDevEnabled = true
    /// Rows whose one-hour and long-context rates are unfolded. Kept here rather than in the
    /// view so a headless dump can capture an expanded row.
    @Published var expandedRowIDs: Set<String> = []
    /// Which column the table is ordered by. Held here so the header arrows and the row order
    /// cannot disagree, and so the order survives a reload of the rates.
    @Published private(set) var sort: PricingSort = .default

    private let costService: CostService
    private var rateCard = RateCard()

    /// Supplies usage and rates for settings dumps and app-model verification. The optional
    /// read controls completion and failure without replacing the concrete SQLite adapter.
    struct PreviewFixtures {
        let usage: [Provider: [ModelUsageTotal]]
        let rateCard: RateCard
        let beforeCommit: (@MainActor () async -> Void)?
        let readUsage: (@MainActor () async throws -> [Provider: [ModelUsageTotal]])?

        init(
            usage: [Provider: [ModelUsageTotal]],
            rateCard: RateCard = RateCard(),
            beforeCommit: (@MainActor () async -> Void)? = nil,
            readUsage: (@MainActor () async throws -> [Provider: [ModelUsageTotal]])? = nil
        ) {
            self.usage = usage
            self.rateCard = rateCard
            self.beforeCommit = beforeCommit
            self.readUsage = readUsage
        }
    }

    private let fixtures: PreviewFixtures?

    init(costService: CostService, fixtures: PreviewFixtures? = nil) {
        self.costService = costService
        self.fixtures = fixtures
    }

    /// Fills the table from the price book, the third-party rates, and the local scan cache.
    func load() async {
        if let fixtures = self.fixtures {
            self.rateCard = fixtures.rateCard
            self.modelsDevFetchedAt = fixtures.rateCard.thirdParty.fetchedAt
            await self.readUsage()
            return
        }

        let modelsDev = ModelsDevPricing.live
        self.rateCard = RateCard.onDisk(modelsDev: modelsDev)
        self.modelsDevEnabled = modelsDev.enabled
        self.modelsDevFetchedAt = modelsDev.cached().fetchedAt
        await self.readUsage()
        self.scanStatusMessages = await self.costService.currentScanStatuses().compactMap {
            $0.status.message(agent: $0.source.displayName)
        }
    }

    /// Reads usage again, keeping the rates the table was loaded with.
    func retryUsage() async {
        await self.readUsage()
    }

    private func readUsage() async {
        guard !self.isReadingUsage else { return }
        self.isReadingUsage = true
        self.isLoading = self.rows.isEmpty
        defer {
            self.isReadingUsage = false
            self.isLoading = false
        }
        do {
            let usageByProvider: [Provider: [ModelUsageTotal]]
            if let fixtures = self.fixtures {
                usageByProvider = try await fixtures.readUsage?() ?? fixtures.usage
            } else {
                let databaseURL = self.costService.databaseURL
                usageByProvider = try await Task.detached {
                    var usage: [Provider: [ModelUsageTotal]] = [:]
                    for provider in Provider.allCases {
                        usage[provider] = try CostUsageReader.knownModelUsage(
                            provider: provider, databaseURL: databaseURL
                        )
                    }
                    return usage
                }.value
            }
            if let beforeCommit = self.fixtures?.beforeCommit { await beforeCommit() }
            self.rows = Self.buildRows(usage: usageByProvider, rateCard: self.rateCard)
            self.hasLoadedUsage = true
            self.usageReadError = nil
        } catch {
            // A failed refresh keeps the last successful counts; with none, the rates still show.
            if self.rows.isEmpty {
                self.rows = Self.buildRows(usage: [:], rateCard: self.rateCard)
            }
            self.usageReadError = error.localizedDescription
        }
    }

    static func buildRows(
        usage usageByProvider: [Provider: [ModelUsageTotal]],
        rateCard: RateCard,
        day: String = DayKey.today()
    ) -> [PricingRow] {
        var rows: [String: PricingRow] = [:]
        for provider in Provider.allCases {
            let usage = usageByProvider[provider] ?? []
            let resolved = rateCard.modelUsage(usage, provider: provider)
            let usageTokens = Dictionary(uniqueKeysWithValues: resolved.map { ($0.model, $0.tokens) })
            let settingsModels = rateCard.settingsModels(for: provider)

            for name in PricingModelFilterPolicy.visibleModels(provider: provider, usage: usage, rateCard: rateCard) {
                let tokens = usageTokens[name] ?? 0
                let row = PricingRow(
                    group: PricingGroup.classify(model: name, provider: provider, rateCard: rateCard),
                    model: name,
                    seenInLogs: usageTokens[name] != nil,
                    usageTokens: tokens,
                    settingsRank: settingsModels.firstIndex(of: name),
                    rates: rateCard.rates(for: name, provider: provider, day: day),
                    source: rateCard.source(for: name, provider: provider)
                )
                if var existing = rows[row.id] {
                    existing.usageTokens += tokens
                    existing.seenInLogs = existing.seenInLogs || row.seenInLogs
                    rows[row.id] = existing
                } else {
                    rows[row.id] = row
                }
            }
        }
        // Provider sections stay stable; active models rise within their section by actual usage.
        return rows.values.sorted(by: PricingSortPolicy.defaultOrder)
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
        self.rows = rows.sorted(by: PricingSortPolicy.defaultOrder)
        self.isLoading = false
        self.hasLoadedUsage = true
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

    static func text(_ value: Double?) -> String {
        guard let value else { return "—" }
        // Rates go to four decimals: cache reads run as low as $0.005 per million.
        return value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%g", value)
    }
}
