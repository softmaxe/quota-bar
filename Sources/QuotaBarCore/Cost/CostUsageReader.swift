import Foundation

/// Reads the scan cache without going through `CostService`.
///
/// The service is an actor and a log scan runs inside it, so anything that asks it a question
/// while a refresh is in flight waits for the scan to finish — seconds, for a question that
/// takes milliseconds to answer. The cache is in WAL mode, so a connection of its own can read
/// the same rows concurrently with the writer.
public enum CostUsageReader {
    /// Models seen in local logs with their cumulative token totals under the names they were
    /// recorded as, most-used first. `RateCard.modelUsage` regroups them under model IDs.
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
    }

    /// What the saved usage amounts to. An absent cache means nothing is saved yet.
    public static func savedUsage(databaseURL: URL = CostService.defaultDatabaseURL) throws -> SavedUsageSummary {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return .empty }
        let usage = try RecordedUsageReader(databaseURL: databaseURL).savedUsage()
        let bytes = [databaseURL.path, databaseURL.path + "-wal"].reduce(Int64(0)) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
        return SavedUsageSummary(records: usage.records, firstDay: usage.firstDay, bytes: bytes)
    }

    /// What each host's mirror holds. A host with no mirror yet has an entry of zeros, and an
    /// absent cache means none of its usage has been recorded yet.
    public static func remoteUsage(
        hosts: [String],
        remoteLogs: URL,
        databaseURL: URL = CostService.defaultDatabaseURL
    ) throws -> [String: RemoteHostUsage] {
        let reader = FileManager.default.fileExists(atPath: databaseURL.path)
            ? try RecordedUsageReader(databaseURL: databaseURL)
            : nil
        var usage: [String: RemoteHostUsage] = [:]
        for host in hosts {
            let logs = RemoteLogMirror.logs(of: host, under: remoteLogs)
            let bytes = logs.reduce(Int64(0)) { total, log in
                let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize
                return total + Int64(size ?? 0)
            }
            let recorded = try reader?.mirroredRecords(of: host, logs: logs.map(\.path))
            usage[host] = RemoteHostUsage(
                files: logs.count,
                bytes: bytes,
                records: recorded?.records ?? 0,
                newRecords: recorded?.new ?? 0
            )
        }
        return usage
    }
}
