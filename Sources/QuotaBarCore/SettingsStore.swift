// Refresh cadence options mirror CodexBar's (MIT, © 2026 Peter Steinberger)
// Sources/CodexBar/SettingsStore.swift, minus its two adaptive modes: this build polls on a
// fixed interval rather than computing a delay per tick.

import Combine
import Foundation

public enum RefreshFrequency: String, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes

    public var id: String { self.rawValue }

    /// nil for `.manual`, which runs no timer at all.
    public var seconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        }
    }

    public var label: String {
        switch self {
        case .manual: "Manual"
        case .oneMinute: "Every minute"
        case .twoMinutes: "Every 2 minutes"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        }
    }
}

public enum CostChartLabelMode: String {
    case tokens
    case cost
}

/// The two faces of a quota window's reset label. The countdown answers "how much longer", the
/// clock answers "when exactly" — which one a reader wants depends on whether they are pacing
/// themselves or planning around the reset, so the label carries both and swaps on a click.
public enum QuotaResetDisplayMode: String {
    case countdown
    case clock

    public var toggled: QuotaResetDisplayMode {
        self == .countdown ? .clock : .countdown
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    private enum Key {
        static let refreshFrequency = "refreshFrequency"
        static let menuBarProvider = "menuBarProvider"
        static let costChartLabelMode = "costChartLabelMode"
        static let quotaResetDisplayMode = "quotaResetDisplayMode"
        /// Pre-single-item builds stored one visibility switch per provider.
        static func providerEnabled(_ provider: Provider) -> String {
            "provider.\(provider.rawValue).enabled"
        }
    }

    private let defaults: UserDefaults

    /// Five minutes by default: the quota endpoints are shared with the CLIs and rate-limit,
    /// and a shorter cadence buys little for a number that moves over hours.
    @Published public var refreshFrequency: RefreshFrequency {
        didSet {
            guard oldValue != self.refreshFrequency else { return }
            self.defaults.set(self.refreshFrequency.rawValue, forKey: Key.refreshFrequency)
        }
    }

    /// The one provider the menu bar item shows, picked from the switch at the top of its card or
    /// in Settings.
    @Published public var menuBarProvider: Provider {
        didSet {
            guard oldValue != self.menuBarProvider else { return }
            self.defaults.set(self.menuBarProvider.rawValue, forKey: Key.menuBarProvider)
        }
    }

    /// Shared by both providers so the selected chart label stays consistent while switching or
    /// reopening the menu.
    @Published public var costChartLabelMode: CostChartLabelMode {
        didSet {
            guard oldValue != self.costChartLabelMode else { return }
            self.defaults.set(self.costChartLabelMode.rawValue, forKey: Key.costChartLabelMode)
        }
    }

    /// Shared by both windows and both providers: the reader asked one question by clicking one
    /// label, and answering it on that row alone would leave the card reading two different ways.
    @Published public var quotaResetDisplayMode: QuotaResetDisplayMode {
        didSet {
            guard oldValue != self.quotaResetDisplayMode else { return }
            self.defaults.set(self.quotaResetDisplayMode.rawValue, forKey: Key.quotaResetDisplayMode)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.refreshFrequency = (defaults.string(forKey: Key.refreshFrequency))
            .flatMap(RefreshFrequency.init(rawValue:)) ?? .fiveMinutes
        self.menuBarProvider = Self.initialMenuBarProvider(defaults: defaults)
        self.costChartLabelMode = (defaults.string(forKey: Key.costChartLabelMode))
            .flatMap(CostChartLabelMode.init(rawValue:)) ?? .tokens
        self.quotaResetDisplayMode = (defaults.string(forKey: Key.quotaResetDisplayMode))
            .flatMap(QuotaResetDisplayMode.init(rawValue:)) ?? .countdown
    }

    /// Older builds showed one item per provider behind a pair of switches. When exactly one of
    /// them was on, that is the provider the single item should keep showing.
    private static func initialMenuBarProvider(defaults: UserDefaults) -> Provider {
        if let stored = defaults.string(forKey: Key.menuBarProvider),
           let provider = Provider(rawValue: stored) {
            return provider
        }
        let legacy = Provider.allCases.filter {
            defaults.object(forKey: Key.providerEnabled($0)) as? Bool == true
        }
        return legacy.count == 1 ? legacy[0] : (Provider.allCases.first ?? .codex)
    }
}
