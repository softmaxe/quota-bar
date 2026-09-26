import Foundation

/// Reads the scan cache without going through `CostService`.
///
/// The service is an actor and a log scan runs inside it, so anything that asks it a question
/// while a refresh is in flight waits for the scan to finish — seconds, for a question that
/// takes milliseconds to answer. The cache is in WAL mode, so a connection of its own can read
/// the same rows concurrently with the writer.
public enum CostUsageReader {
    /// Models seen in local logs with their cumulative token totals, most-used first.
    /// An absent cache means no recorded usage. Existing but unreadable caches throw.
    public static func knownModelUsage(
        provider: Provider,
        databaseURL: URL = CostService.defaultDatabaseURL
    ) throws -> [ModelUsageTotal] {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return []
            }
            throw error
        }
        return try RecordedUsageReader(databaseURL: databaseURL).modelUsage(provider: provider)
            .filter { $0.model != CostPricing.unknownModel }
    }
}
