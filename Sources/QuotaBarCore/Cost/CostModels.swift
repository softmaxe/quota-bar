import Foundation

/// Token counts for one model on one day. The four buckets are disjoint and priced separately.
public struct TokenTotals: Sendable, Equatable {
    /// Fresh input tokens (Codex: `input_tokens` minus `cached_input_tokens`).
    public var input: Int
    public var output: Int
    /// Tokens written into the prompt cache, both TTLs together.
    public var cacheWrite: Int
    /// The subset of `cacheWrite` written with a one-hour TTL, which Anthropic prices higher.
    /// Always zero for Codex, which offers no choice of cache lifetime.
    public var cacheWrite1h: Int
    /// Tokens served from the prompt cache.
    public var cacheRead: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = min(cacheWrite1h, cacheWrite)
        self.cacheRead = cacheRead
    }

    /// `cacheWrite1h` is a subset of `cacheWrite`, so counting it here would double it.
    public var total: Int { self.input + self.output + self.cacheWrite + self.cacheRead }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// The local tool that produced a usage record.
public enum CostUsageSource: String, Sendable, Hashable {
    case codex
    case openCode
    case piAgent
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .piAgent: "Pi Agent"
        case .claude: "Claude"
        }
    }
}

/// Keeps same-model usage from different local tools separate in the daily breakdown.
public struct ModelUsageKey: Sendable, Hashable {
    public let source: CostUsageSource
    public let model: String
    public let isFast: Bool

    public init(source: CostUsageSource, model: String, isFast: Bool = false) {
        self.source = source
        self.model = model
        self.isFast = isFast
    }
}

/// What one model from one local tool did on one day.
public struct ModelDayUsage: Sendable, Equatable {
    public let tokens: TokenTotals
    /// nil when the model has no price, so its tokens count but its cost does not.
    public let costUSD: Double?

    public init(tokens: TokenTotals, costUSD: Double?) {
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

/// One local-calendar day of usage, already split by source and model.
public struct CostDay: Sendable, Equatable {
    /// `yyyy-MM-dd` in the local time zone, matching how the chart buckets days.
    public let dayKey: String
    public let byModel: [ModelUsageKey: ModelDayUsage]
    public let costUSD: Double?
    /// Tokens whose model had no price, so they count toward totals but not toward cost.
    public let unpricedTokens: Int

    public init(
        dayKey: String,
        byModel: [ModelUsageKey: ModelDayUsage],
        costUSD: Double?,
        unpricedTokens: Int
    ) {
        self.dayKey = dayKey
        self.byModel = byModel
        self.costUSD = costUSD
        self.unpricedTokens = unpricedTokens
    }

    public var tokens: TokenTotals {
        self.byModel.values.reduce(into: TokenTotals()) { $0 += $1.tokens }
    }

    /// A nil price means usage is unpriced, while an empty day is a known zero.
    public var costAvailability: CostAvailability {
        CostAvailability(
            knownUSD: self.costUSD,
            totalTokens: self.tokens.total,
            unpricedTokens: self.unpricedTokens
        )
    }

    /// Source/model/tier rows that ran that day. Unpriced rows sort by token count behind every
    /// priced one.
    public var rankedModels: [(key: ModelUsageKey, model: String, usage: ModelDayUsage)] {
        self.rankedModels(by: .cost)
    }

    /// Ranks the daily breakdown by the metric selected for the chart.
    public func rankedModels(
        by mode: CostChartLabelMode
    ) -> [(key: ModelUsageKey, model: String, usage: ModelDayUsage)] {
        self.byModel
            .map { (key: $0.key, model: $0.key.model, usage: $0.value) }
            .sorted { lhs, rhs in
                let lhsTokens = lhs.usage.tokens.total
                let rhsTokens = rhs.usage.tokens.total
                let lhsCost = lhs.usage.costUSD ?? -1
                let rhsCost = rhs.usage.costUSD ?? -1
                switch mode {
                case .tokens:
                    if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                    if lhsCost != rhsCost { return lhsCost > rhsCost }
                case .cost:
                    if lhsCost != rhsCost { return lhsCost > rhsCost }
                    if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                }
                if lhs.model != rhs.model { return lhs.model < rhs.model }
                if lhs.key.source != rhs.key.source {
                    return lhs.key.source.rawValue < rhs.key.source.rawValue
                }
                return !lhs.key.isFast && rhs.key.isFast
            }
    }
}

/// What the popover's cost section shows for one provider.
public struct CostSnapshot: Sendable, Equatable {
    public let provider: Provider
    /// Ascending by day; only days with activity appear, which is why the chart's bar count varies.
    public let days: [CostDay]
    public let todayCostUSD: Double
    public let windowCostUSD: Double
    /// Tokens on the most recent day that had any activity, which is not always today.
    public let latestTokens: Int
    public let windowTokens: Int
    /// Model with the highest cost in the window, falling back to token count when nothing is priced.
    public let topModel: String?
    /// True when at least one model in the window had no price entry.
    public let hasUnpricedTokens: Bool
    public let scannedAt: Date

    public init(
        provider: Provider,
        days: [CostDay],
        todayCostUSD: Double,
        windowCostUSD: Double,
        latestTokens: Int,
        windowTokens: Int,
        topModel: String?,
        hasUnpricedTokens: Bool,
        scannedAt: Date
    ) {
        self.provider = provider
        self.days = days
        self.todayCostUSD = todayCostUSD
        self.windowCostUSD = windowCostUSD
        self.latestTokens = latestTokens
        self.windowTokens = windowTokens
        self.topModel = topModel
        self.hasUnpricedTokens = hasUnpricedTokens
        self.scannedAt = scannedAt
    }

    public var windowCostAvailability: CostAvailability {
        CostAvailability(
            knownUSD: self.windowCostUSD,
            totalTokens: self.windowTokens,
            unpricedTokens: self.days.reduce(0) { $0 + $1.unpricedTokens }
        )
    }

    public func costAvailability(forDayKey dayKey: String) -> CostAvailability {
        self.days.first(where: { $0.dayKey == dayKey })?.costAvailability ?? .zero
    }
}

/// Distinguishes a known zero, a partial estimate, and usage with no known price.
public struct CostAvailability: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case priced
        case partial
        case unpriced
    }

    public let state: State
    public let knownUSD: Double?
    public let unpricedTokens: Int

    public init(knownUSD: Double?, totalTokens: Int, unpricedTokens: Int) {
        self.unpricedTokens = max(0, unpricedTokens)
        if totalTokens <= 0 {
            self.state = .priced
            self.knownUSD = 0
        } else if knownUSD == nil {
            self.state = .unpriced
            self.knownUSD = nil
        } else if self.unpricedTokens <= 0 {
            self.state = .priced
            self.knownUSD = knownUSD
        } else if self.unpricedTokens >= totalTokens {
            self.state = .unpriced
            self.knownUSD = nil
        } else {
            self.state = .partial
            self.knownUSD = knownUSD
        }
    }

    public static let zero = CostAvailability(knownUSD: 0, totalTokens: 0, unpricedTokens: 0)
}

package enum DayKey {
    /// Days bucket by the local calendar, so "today" matches what the user's clock says.
    package static func make(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    package static func today(calendar: Calendar = .current, now: Date = Date()) -> String {
        self.make(from: now, calendar: calendar)
    }
}
