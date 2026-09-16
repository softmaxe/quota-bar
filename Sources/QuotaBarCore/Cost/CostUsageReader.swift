import Foundation

/// Reads the scan cache without going through `CostService`.
///
/// The service is an actor and a log scan runs inside it, so anything that asks it a question
/// while a refresh is in flight waits for the scan to finish — seconds, for a question that
/// takes milliseconds to answer. The cache is in WAL mode, so a connection of its own can read
/// the same rows concurrently with the writer.
public enum CostUsageReader {
    /// Models seen in local logs with their cumulative token totals, most-used first.
    /// Returns nothing when no scan has ever run, which is also what an absent cache means.
    public static func knownModelUsage(
        provider: Provider,
        databaseURL: URL = CostService.defaultDatabaseURL
    ) -> [ModelUsageTotal] {
        guard let cache = try? CostCache(path: databaseURL, readOnly: true),
              let models = try? cache.distinctModelUsage(provider: provider) else { return [] }
        return models.compactMap { entry in
            guard entry.model != CostPricing.unknownModel else { return nil }
            return ModelUsageTotal(model: entry.model, tokens: entry.tokens)
        }
    }
}
