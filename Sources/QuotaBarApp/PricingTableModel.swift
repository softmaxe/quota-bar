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

/// The blocks of the pricing list, one per place a price can come from.
enum PricingSection: String, CaseIterable, Identifiable, Hashable {
    case builtIn = "Built-in"
    case modelsDev = "models.dev"
    case unpriced = "Unpriced"

    var id: String { self.rawValue }

    init(source: RateCard.Source?) {
        switch source {
        case .priceBook?: self = .builtIn
        case .modelsDev?: self = .modelsDev
        case nil: self = .unpriced
        }
    }
}

/// Names the company behind a model. The price book's models are its two providers' own; for the
/// rest, models.dev says who makes most models, and the name tells for the others, including a
/// cache written before it kept makers and models nothing prices.
enum PricingVendor {
    static let other = "Other"

    /// A models.dev maker to the name shown, where a plain capitalized slug would misspell it.
    private static let displayNames = [
        "anthropic": "Anthropic",
        "bytedance-seed": "ByteDance",
        "deepseek": "DeepSeek",
        "minimax": "MiniMax",
        "moonshotai": "Moonshot AI",
        "nvidia": "NVIDIA",
        "openai": "OpenAI",
        "stepfun": "StepFun",
        "xai": "xAI",
        "zhipuai": "Zhipu AI",
    ]

    private static let makerPrefixes = [
        ("claude", "anthropic"),
        ("gpt-", "openai"),
        ("deepseek", "deepseek"),
        ("doubao", "bytedance-seed"),
        ("gemini", "google"),
        ("gemma", "google"),
        ("glm", "zhipuai"),
        ("grok", "xai"),
        ("hunyuan", "tencent"),
        ("kimi", "moonshotai"),
        ("llama", "meta"),
        ("mimo", "xiaomi"),
        ("minimax", "minimax"),
        ("mistral", "mistral"),
        ("muse", "meta"),
        ("qwen", "alibaba"),
    ]

    static func name(for model: String, group: PricingGroup, rateCard: RateCard) -> String {
        switch group {
        case .claude: return "Anthropic"
        case .codex: return "OpenAI"
        case .others:
            let key = model.lowercased()
            let maker = rateCard.thirdParty.maker(for: model)
                ?? Self.makerPrefixes.first { key.hasPrefix($0.0) }?.1
            return maker.map(Self.displayName) ?? Self.other
        }
    }

    private static func displayName(_ maker: String) -> String {
        Self.displayNames[maker] ?? maker.replacingOccurrences(of: "-", with: " ").capitalized
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
    /// The company behind the model, which the list groups by.
    let vendor: String
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

    var section: PricingSection { PricingSection(source: self.source) }
    var isPriced: Bool { self.rates != nil }

    var input: Double? { self.rates?.input }
    var output: Double? { self.rates?.output }
    var cacheWrite: Double? { self.rates?.cacheWrite }
    var cacheRead: Double? { self.rates?.cacheRead }
}

/// One vendor's models within a section of the pricing list.
struct PricingVendorGroup: Identifiable, Equatable {
    let section: PricingSection
    let vendor: String
    let rows: [PricingRow]

    var id: String { "\(self.section.rawValue)|\(self.vendor)" }
    var usageTokens: Int { self.rows.reduce(0) { $0 + $1.usageTokens } }
}

/// One source's block of the pricing list.
struct PricingSectionGroup: Identifiable, Equatable {
    let section: PricingSection
    let vendors: [PricingVendorGroup]

    var id: String { self.section.id }
}

/// The order of the pricing list: within a vendor, the models the local logs spend tokens on,
/// busiest first; then the rest in their provider's configured order.
enum PricingListPolicy {
    static func precedes(_ lhs: PricingRow, _ rhs: PricingRow) -> Bool {
        if lhs.usageTokens != rhs.usageTokens { return lhs.usageTokens > rhs.usageTokens }
        if lhs.seenInLogs != rhs.seenInLogs { return lhs.seenInLogs }

        let lhsGroup = PricingGroup.allCases.firstIndex(of: lhs.group) ?? .max
        let rhsGroup = PricingGroup.allCases.firstIndex(of: rhs.group) ?? .max
        if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }

        let lhsRank = lhs.settingsRank ?? .max
        let rhsRank = rhs.settingsRank ?? .max
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.model < rhs.model
    }

    /// Rows split by source, then by vendor: the busiest vendor first, Other last. Sources and
    /// vendors with no rows are left out, and each vendor keeps the rows in the order given.
    static func grouped(_ rows: [PricingRow]) -> [PricingSectionGroup] {
        PricingSection.allCases.compactMap { section in
            let sectionRows = rows.filter { $0.section == section }
            guard !sectionRows.isEmpty else { return nil }
            let vendors = Dictionary(grouping: sectionRows, by: \.vendor)
                .map { PricingVendorGroup(section: section, vendor: $0.key, rows: $0.value) }
                .sorted { lhs, rhs in
                    if (lhs.vendor == PricingVendor.other) != (rhs.vendor == PricingVendor.other) {
                        return rhs.vendor == PricingVendor.other
                    }
                    if lhs.usageTokens != rhs.usageTokens { return lhs.usageTokens > rhs.usageTokens }
                    return lhs.vendor < rhs.vendor
                }
            return PricingSectionGroup(section: section, vendors: vendors)
        }
    }

    /// The rows a search keeps, in list order. Matching ignores case, so "GLM" finds "glm-5.3".
    static func filtered(_ rows: [PricingRow], matching query: String) -> [PricingRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = rows.sorted(by: Self.precedes)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.model.localizedCaseInsensitiveContains(query) }
    }
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
    /// When models.dev was last read, and whether pricing from it is on, for its section heading.
    @Published private(set) var modelsDevFetchedAt: Date?
    @Published private(set) var modelsDevEnabled = true
    /// How many models each source prices, for the section headings. The models.dev count is the
    /// cached catalog's, so it still reads while that source is switched off.
    @Published private(set) var priceBookModelCount = 0
    @Published private(set) var modelsDevModelCount = 0
    /// The row open in the table, nil when none is. Kept here rather than in the view so it
    /// survives a reload of the rates and a headless dump can pick one.
    @Published var selectedRowID: String?
    /// Narrows the list by model name.
    @Published var searchText = ""
    /// The vendors opened, by `PricingVendorGroup.id`. Every vendor starts folded.
    @Published private(set) var openVendorIDs: Set<String> = []

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
        self.loadSources()
        await self.readUsage()
        guard self.fixtures == nil else { return }
        self.scanStatusMessages = await self.costService.currentScanStatuses().compactMap {
            $0.status.message(agent: $0.source.displayName)
        }
    }

    /// Rereads the rates and what each source covers.
    private func loadSources() {
        let cached: ThirdPartyRates
        if let fixtures = self.fixtures {
            self.rateCard = fixtures.rateCard
            cached = fixtures.rateCard.thirdParty
        } else {
            let modelsDev = ModelsDevPricing.live
            cached = modelsDev.cached()
            self.rateCard = RateCard(thirdParty: modelsDev.enabled ? cached : .empty)
            self.modelsDevEnabled = modelsDev.enabled
        }
        self.modelsDevFetchedAt = cached.fetchedAt
        self.modelsDevModelCount = cached.models.count
        self.priceBookModelCount = Provider.allCases.reduce(0) {
            $0 + self.rateCard.settingsModels(for: $1).count
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
                let group = PricingGroup.classify(model: name, provider: provider, rateCard: rateCard)
                let row = PricingRow(
                    group: group,
                    model: name,
                    vendor: PricingVendor.name(for: name, group: group, rateCard: rateCard),
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
        return rows.values.sorted(by: PricingListPolicy.precedes)
    }

    /// The list as the search leaves it, split by source and vendor.
    var listSections: [PricingSectionGroup] {
        PricingListPolicy.grouped(PricingListPolicy.filtered(self.rows, matching: self.searchText))
    }

    /// Every row the search keeps, top to bottom.
    var listRows: [PricingRow] {
        self.listSections.flatMap { $0.vendors.flatMap(\.rows) }
    }

    /// The rows on screen, which the arrow keys move through.
    var visibleRows: [PricingRow] {
        self.listSections.flatMap { $0.vendors.filter(self.isOpen).flatMap(\.rows) }
    }

    var isSearching: Bool {
        !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A search opens every vendor, so a match is never folded away.
    func isOpen(_ vendor: PricingVendorGroup) -> Bool {
        self.isSearching || self.openVendorIDs.contains(vendor.id)
    }

    func toggle(_ vendor: PricingVendorGroup) {
        if self.openVendorIDs.insert(vendor.id).inserted { return }
        self.openVendorIDs.remove(vendor.id)
        if vendor.rows.contains(where: { $0.id == self.selectedRowID }) { self.selectedRowID = nil }
    }

    /// Folds every vendor, which is how the pane opens.
    func foldAll() {
        self.openVendorIDs = []
        self.selectedRowID = nil
    }

    /// The row the detail side shows: the one picked, or the top of the list until one is, or
    /// when the search hides the one picked.
    var selectedRow: PricingRow? {
        let rows = self.listRows
        return rows.first { $0.id == self.selectedRowID } ?? rows.first
    }

#if DEBUG
    /// Lets a headless run drive the table without reading the pricing files on disk.
    func debugSetRows(_ rows: [PricingRow]) {
        self.rows = rows.sorted(by: PricingListPolicy.precedes)
        self.isLoading = false
        self.hasLoadedUsage = true
    }
#endif

    static func text(_ value: Double?) -> String {
        guard let value else { return "—" }
        // Rates go to four decimals: cache reads run as low as $0.005 per million.
        return value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%g", value)
    }
}
