import Foundation

/// Where QuotaBar keeps what it writes for itself.
public enum AppSupport {
    /// `~/Library/Application Support/QuotaBar`.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("QuotaBar", isDirectory: true)
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
