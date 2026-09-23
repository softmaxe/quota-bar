// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/ModelsDevPricing.swift
//
// The one layer that sits above the price book: a JSON file of rates the user sets by hand in
// the pricing settings, or edits directly.

import Foundation

/// The user's hand-set rates, keyed by normalized model name. They apply to every day, since
/// they state what the user believes the model costs rather than when that price began.
public struct PricingOverlay: Sendable {
    public let userOverrides: [String: ModelPricing]

    public init(userOverrides: [String: ModelPricing] = [:]) {
        self.userOverrides = userOverrides
    }
}

public enum PricingOverlayStore {
    /// `~/Library/Application Support/QuotaBar/pricing-overrides.json`, hand-editable.
    public static var userOverridesURL: URL {
        Self.applicationSupportDirectory.appendingPathComponent("pricing-overrides.json")
    }

    static var applicationSupportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("QuotaBar", isDirectory: true)
    }

    /// The override file as it sits on disk.
    public static func loadFromDisk() -> PricingOverlay {
        PricingOverlay(userOverrides: Self.loadUserOverrides())
    }

    /// Where 1.0.x cached the models.dev catalog, which pricing no longer reads.
    static var legacyCatalogCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("QuotaBar/model-pricing", isDirectory: true)
    }

    /// Deletes the catalog cache an earlier version left behind. Only ever QuotaBar's own cache.
    public static func removeLegacyCatalogCache() {
        try? FileManager.default.removeItem(at: Self.legacyCatalogCacheDirectory)
    }

    // MARK: - User overrides

    public static func loadUserOverrides() -> [String: ModelPricing] {
        guard let data = try? Data(contentsOf: Self.userOverridesURL) else { return [:] }
        return Self.parseUserOverrides(data)
    }

    public static func parseUserOverrides(_ data: Data) -> [String: ModelPricing] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: ModelPricing] = [:]
        for (model, value) in root {
            guard let entry = value as? [String: Any],
                  let input = Self.double(entry["input"]),
                  let output = Self.double(entry["output"]) else { continue }
            result[model.lowercased()] = ModelPricing(
                input: input,
                output: output,
                cacheWrite: Self.double(entry["cacheWrite"]),
                cacheWrite1h: Self.double(entry["cacheWrite1h"]),
                cacheRead: Self.double(entry["cacheRead"]),
                thresholdTokens: (entry["thresholdTokens"] as? NSNumber)?.intValue,
                inputAbove: Self.double(entry["inputAbove"]),
                outputAbove: Self.double(entry["outputAbove"]),
                cacheWriteAbove: Self.double(entry["cacheWriteAbove"]),
                cacheWrite1hAbove: Self.double(entry["cacheWrite1hAbove"]),
                cacheReadAbove: Self.double(entry["cacheReadAbove"])
            )
        }
        return result
    }

    /// Writes the hand-edited layer. An empty dictionary removes the file entirely, so the
    /// price book takes over again.
    public static func saveUserOverrides(_ overrides: [String: ModelPricing]) throws {
        let url = Self.userOverridesURL
        guard !overrides.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        var root: [String: Any] = [:]
        for (model, pricing) in overrides {
            var entry: [String: Any] = ["input": pricing.input, "output": pricing.output]
            if let threshold = pricing.thresholdTokens { entry["thresholdTokens"] = threshold }
            for rate in ModelPricing.optionalRates {
                if let value = pricing[keyPath: rate.value] { entry[rate.json] = value }
            }
            root[model] = entry
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
