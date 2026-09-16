import Foundation

/// A column the pricing table can be ordered by. `.usage` is the order the pane loads in —
/// the models the local logs actually spend tokens on, first — and the one the header's
/// reset control comes back to.
enum PricingSortField: String, CaseIterable, Hashable {
    case usage
    case model
    case input
    case output
    case cacheWrite
    case cacheRead

    /// The rate a column reads off a row. `.usage` and `.model` are not rates.
    var rateKeyPath: KeyPath<PricingRow, String>? {
        switch self {
        case .usage, .model: return nil
        case .input: return \.input
        case .output: return \.output
        case .cacheWrite: return \.cacheWrite
        case .cacheRead: return \.cacheRead
        }
    }

    /// Where a fresh click on the column starts. A name reads naturally A→Z; a price column is
    /// asked about because something looks expensive, so it opens on the expensive end.
    var opensAscending: Bool {
        self == .model
    }
}

struct PricingSort: Equatable {
    var field: PricingSortField
    var ascending: Bool

    /// Whitelist models keep their configured order; Others are most-used first.
    static let `default` = PricingSort(field: .usage, ascending: false)

    var isDefault: Bool { self == .default }
}

/// Ordering for the pricing table. Kept out of the view so the header's arrows, the row order,
/// and the reset control all read the same rules, and so a headless run can check them.
enum PricingSortPolicy {
    /// Clicking the column already sorted flips it; clicking another column starts that column
    /// at its natural end rather than inheriting the previous column's direction.
    static func next(after current: PricingSort, tapping field: PricingSortField) -> PricingSort {
        guard current.field == field else {
            return PricingSort(field: field, ascending: field.opensAscending)
        }
        return PricingSort(field: field, ascending: !current.ascending)
    }

    static func sorted(_ rows: [PricingRow], by sort: PricingSort) -> [PricingRow] {
        switch sort.field {
        case .usage:
            let ordered = rows.sorted(by: Self.defaultOrder)
            return sort.ascending ? ordered.reversed() : ordered
        case .model:
            return rows.sorted { lhs, rhs in
                let comparison = lhs.model.localizedStandardCompare(rhs.model)
                guard comparison != .orderedSame else { return false }
                return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        default:
            guard let keyPath = sort.field.rateKeyPath else { return rows }
            return rows.sorted { lhs, rhs in
                Self.precedes(lhs, rhs, rate: keyPath, ascending: sort.ascending)
            }
        }
    }

    /// The order the list is built in: provider sections stay put, API whitelist models keep
    /// their configured order, and Others with local usage rise above the remaining rows.
    static func defaultOrder(_ lhs: PricingRow, _ rhs: PricingRow) -> Bool {
        let lhsGroup = PricingGroup.allCases.firstIndex(of: lhs.group) ?? .max
        let rhsGroup = PricingGroup.allCases.firstIndex(of: rhs.group) ?? .max
        if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }

        if lhs.group != .others {
            let whitelist = PricingGroup.whitelist(for: lhs.provider)
            let lhsWhitelistIndex = whitelist.firstIndex(of: lhs.model) ?? Int.max
            let rhsWhitelistIndex = whitelist.firstIndex(of: rhs.model) ?? Int.max
            if lhsWhitelistIndex != rhsWhitelistIndex {
                return lhsWhitelistIndex < rhsWhitelistIndex
            }
        }

        if lhs.usageTokens != rhs.usageTokens { return lhs.usageTokens > rhs.usageTokens }
        if lhs.seenInLogs != rhs.seenInLogs { return lhs.seenInLogs }
        if lhs.seenInLogs, lhs.isPriced != rhs.isPriced { return !lhs.isPriced }
        return lhs.model < rhs.model
    }

    /// A blank rate is not a zero: an unpriced model would otherwise fill the top of every
    /// ascending sort. Blanks sink to the bottom whichever way the column points, and equal
    /// rates fall back to the model name so the order never shuffles between renders.
    private static func precedes(
        _ lhs: PricingRow,
        _ rhs: PricingRow,
        rate keyPath: KeyPath<PricingRow, String>,
        ascending: Bool
    ) -> Bool {
        let lhsRate = Self.rate(lhs[keyPath: keyPath])
        let rhsRate = Self.rate(rhs[keyPath: keyPath])
        switch (lhsRate, rhsRate) {
        case let (lhsValue?, rhsValue?):
            if lhsValue != rhsValue { return ascending ? lhsValue < rhsValue : lhsValue > rhsValue }
            return lhs.model < rhs.model
        case (nil, .some): return false
        case (.some, nil): return true
        case (nil, nil): return lhs.model < rhs.model
        }
    }

    static func rate(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }
}
