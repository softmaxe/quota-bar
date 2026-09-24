// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/ModelsDevPricing.swift
//
// The user's overrides as they sit on disk: a JSON file the pricing settings write, which the
// user may also edit by hand.

import Foundation

public struct OverrideFile: Sendable {
    /// What a read of the file kept, and what it dropped and why.
    public struct Parsed: Sendable {
        /// Keyed by lowercased model name.
        public let overrides: [String: ModelPricing]
        /// Model name as written -> the reason its entry was dropped.
        public let ignored: [String: String]
    }

    public let url: URL

    /// `~/Library/Application Support/QuotaBar/pricing-overrides.json`, hand-editable.
    public static var defaultURL: URL {
        PricingOverlayStore.applicationSupportDirectory.appendingPathComponent("pricing-overrides.json")
    }

    public init(url: URL = OverrideFile.defaultURL) {
        self.url = url
    }

    /// The overrides the file holds. A missing or unreadable file overrides nothing, and each
    /// dropped entry is logged so a hand edit that stopped applying can be traced.
    public func load() -> [String: ModelPricing] {
        guard let data = try? Data(contentsOf: self.url) else { return [:] }
        let parsed = Self.parse(data)
        for (model, reason) in parsed.ignored.sorted(by: { $0.key < $1.key }) {
            Log.ui.error("Ignoring the override for \(model, privacy: .public): \(reason, privacy: .public)")
        }
        return parsed.overrides
    }

    /// Reads the file's contents. An entry that breaks a rule the price book's own rates follow is
    /// dropped alone, so the book prices that model and every other override still applies.
    public static func parse(_ data: Data) -> Parsed {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Parsed(overrides: [:], ignored: [:])
        }
        var overrides: [String: ModelPricing] = [:]
        var ignored: [String: String] = [:]
        for (model, value) in root {
            guard let entry = value as? [String: Any] else {
                ignored[model] = "the entry must be a JSON object"
                continue
            }
            do {
                overrides[model.lowercased()] = try ModelPricing(json: entry, numericStrings: true)
            } catch {
                ignored[model] = "\(error)"
            }
        }
        return Parsed(overrides: overrides, ignored: ignored)
    }

    /// Writes the overrides. An empty set removes the file entirely, so the price book takes over
    /// again. Throws, writing nothing, when any override breaks the rules `parse` holds it to.
    public func save(_ overrides: [String: ModelPricing]) throws {
        guard !overrides.isEmpty else {
            try? FileManager.default.removeItem(at: self.url)
            return
        }

        var root: [String: Any] = [:]
        for (model, pricing) in overrides {
            let values = pricing.rateValues
            if let violation = ModelPricing.violations(in: values).first { throw violation }
            var entry: [String: Any] = values
            if let threshold = pricing.thresholdTokens { entry[ModelPricing.thresholdKey] = threshold }
            root[model] = entry
        }

        try FileManager.default.createDirectory(
            at: self.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: self.url, options: .atomic)
    }
}
