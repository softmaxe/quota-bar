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
        static let modelsDevPricing = "modelsDevPricing"
        static let lastUsageExport = "lastUsageExport"
        static let remoteHosts = "remoteHosts"
        static let remoteAutoSync = "remoteAutoSync"
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

    /// Whether models outside the price book are priced from models.dev, which means
    /// downloading its catalog about once a day. On by default.
    @Published public var modelsDevPricing: Bool {
        didSet {
            guard oldValue != self.modelsDevPricing else { return }
            self.defaults.set(self.modelsDevPricing, forKey: Key.modelsDevPricing)
        }
    }

    /// The SSH hosts whose Claude Code and Codex logs count toward this Mac's usage.
    @Published public var remoteHosts: [String] {
        didSet {
            guard oldValue != self.remoteHosts else { return }
            self.defaults.set(self.remoteHosts, forKey: Key.remoteHosts)
        }
    }

    /// Whether those hosts are mirrored on a schedule rather than only on request. Its own choice,
    /// because a host connection is not a quota refresh.
    @Published public var remoteAutoSync: Bool {
        didSet {
            guard oldValue != self.remoteAutoSync else { return }
            self.defaults.set(self.remoteAutoSync, forKey: Key.remoteAutoSync)
        }
    }

    /// When a usage backup was last exported, so Settings can show how old the newest one is.
    @Published public var lastUsageExport: Date? {
        didSet {
            guard oldValue != self.lastUsageExport else { return }
            self.defaults.set(self.lastUsageExport, forKey: Key.lastUsageExport)
        }
    }

    /// The saved `modelsDevPricing`, readable off the main actor by the cost service.
    public nonisolated static func isModelsDevPricingEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.modelsDevPricing) as? Bool ?? true
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let refreshFrequency = (defaults.string(forKey: Key.refreshFrequency))
            .flatMap(RefreshFrequency.init(rawValue:)) ?? .fiveMinutes
        self.refreshFrequency = refreshFrequency
        self.menuBarProvider = (defaults.string(forKey: Key.menuBarProvider))
            .flatMap(Provider.init(rawValue:)) ?? (Provider.allCases.first ?? .codex)
        self.costChartLabelMode = (defaults.string(forKey: Key.costChartLabelMode))
            .flatMap(CostChartLabelMode.init(rawValue:)) ?? .tokens
        self.quotaResetDisplayMode = (defaults.string(forKey: Key.quotaResetDisplayMode))
            .flatMap(QuotaResetDisplayMode.init(rawValue:)) ?? .countdown
        self.modelsDevPricing = Self.isModelsDevPricingEnabled(defaults)
        self.lastUsageExport = defaults.object(forKey: Key.lastUsageExport) as? Date
        self.remoteHosts = defaults.stringArray(forKey: Key.remoteHosts) ?? []
        // Manual refresh used to stop these connections too, so it keeps doing that until changed.
        self.remoteAutoSync = defaults.object(forKey: Key.remoteAutoSync) as? Bool
            ?? (refreshFrequency != .manual)
    }
}
