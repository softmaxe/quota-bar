// The one layer that sits above the price book: the rates the user sets in the pricing settings,
// or edits by hand in the override file.

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
    static var applicationSupportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("QuotaBar", isDirectory: true)
    }

    /// The override file as it sits on disk.
    public static func loadFromDisk() -> PricingOverlay {
        PricingOverlay(userOverrides: OverrideFile().load())
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
}
