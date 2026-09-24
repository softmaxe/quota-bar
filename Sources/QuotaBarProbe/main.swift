import QuotaBarCore
import Foundation

// Headless check that both providers still return usable data. Run with `make probe`.

func describe(_ window: UsageWindow?, label: String) -> String {
    guard let window else { return "  \(label): (absent)" }
    var line = String(format: "  %@: %.1f%% left", label, window.remainingPercent)
    if let resetsAt = window.resetsAt {
        let remaining = resetsAt.timeIntervalSinceNow
        line += String(format: "  resets in %dh %dm", Int(remaining) / 3600, (Int(remaining) % 3600) / 60)
    }
    if let seconds = window.windowSeconds {
        line += "  (window \(seconds / 3600)h)"
    }
    return line
}

func report(_ provider: Provider, _ state: ProviderState) {
    print("[\(provider.displayName)]")
    switch state {
    case let .signedOut(reason):
        print("  signed out: \(reason)")
    case let .failed(reason):
        print("  FAILED: \(reason)")
    case let .accessDenied(reason):
        print("  ACCESS DENIED: \(reason)")
    case let .rateLimited(reason, retryAfter):
        print("  RATE LIMITED until \(retryAfter): \(reason)")
    case let .recoveryRequired(reason):
        print("  RECOVERY REQUIRED: \(reason)")
    case let .loaded(snapshot):
        print("  plan: \(snapshot.planLabel ?? "(none)")")
        print(describe(snapshot.session, label: "session"))
        print(describe(snapshot.weekly, label: "weekly "))
        if let credits = snapshot.credits {
            print("  credits: has=\(credits.hasCredits) unlimited=\(credits.unlimited) balance=\(credits.balance.map { String($0) } ?? "nil")")
        }
    }
    print("")
}

func reportCost(_ provider: Provider, _ snapshot: CostSnapshot?) {
    guard let snapshot else {
        print("  cost: unavailable")
        return
    }
    let tokens = { (count: Int) in String(format: "%.0fM", Double(count) / 1_000_000) }
    print("  today $\(String(format: "%.2f", snapshot.todayCostUSD))  30d $\(String(format: "%.2f", snapshot.windowCostUSD))")
    print("  latest tokens \(tokens(snapshot.latestTokens))  30d tokens \(tokens(snapshot.windowTokens))")
    print("  days with data: \(snapshot.days.count)  top model: \(snapshot.topModel ?? "(none)")")
    if snapshot.hasUnpricedTokens { print("  NOTE: some tokens had no price entry") }
}

func equivalentCost(_ lhs: CostSnapshot, _ rhs: CostSnapshot) -> Bool {
    lhs.provider == rhs.provider
        && lhs.days == rhs.days
        && lhs.todayCostUSD == rhs.todayCostUSD
        && lhs.windowCostUSD == rhs.windowCostUSD
        && lhs.latestTokens == rhs.latestTokens
        && lhs.windowTokens == rhs.windowTokens
        && lhs.topModel == rhs.topModel
        && lhs.hasUnpricedTokens == rhs.hasUnpricedTokens
}

func milliseconds(_ body: () async -> CostSnapshot?) async -> (CostSnapshot?, Double) {
    let started = ContinuousClock.now
    let snapshot = await body()
    let elapsed = started.duration(to: .now)
    return (snapshot, Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)
}

func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

func benchmarkCost(arguments: [String]) async -> Never {
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(2)
    }

    var provider: Provider?
    var iterations = 3
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--provider":
            guard index + 1 < arguments.count, let value = Provider(rawValue: arguments[index + 1]) else {
                fail("--provider requires codex or claude")
            }
            provider = value
            index += 2
        case "--iterations":
            guard index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]), value > 0, value % 2 == 1 else {
                fail("--iterations requires a positive odd integer")
            }
            iterations = value
            index += 2
        default:
            fail("unknown benchmark argument \(arguments[index])")
        }
    }
    guard let provider else { fail("--provider is required") }

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quotabar-benchmark-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
        fail("could not create the benchmark directory")
    }
    defer { try? FileManager.default.removeItem(at: root) }

    var coldTimes: [Double] = []
    var incrementalTimes: [Double] = []
    var stable = true
    for iteration in 0..<iterations {
        let service = CostService(
            databaseURL: root.appendingPathComponent("cost-\(iteration).sqlite"),
            rateCard: RateCard()
        )
        let (cold, coldTime) = await milliseconds { await service.refresh(provider) }
        guard let cold else { fail("cold scan failed") }
        let (incremental, incrementalTime) = await milliseconds { await service.refresh(provider) }
        guard let incremental else { fail("incremental scan failed") }
        stable = stable && equivalentCost(cold, incremental)
        coldTimes.append(coldTime)
        incrementalTimes.append(incrementalTime)
    }

    // Live logs can grow between the cold and incremental passes, so equality is diagnostic rather
    // than a failure. Fixed fixtures should report `same_snapshot=yes`.
    print("provider=\(provider.rawValue) source=live iterations=\(iterations) same_snapshot=\(stable ? "yes" : "no")")
    print(String(
        format: "empty_db_ms median=%.1f min=%.1f max=%.1f",
        median(coldTimes), coldTimes.min() ?? 0, coldTimes.max() ?? 0
    ))
    print(String(
        format: "incremental_ms median=%.1f min=%.1f max=%.1f",
        median(incrementalTimes), incrementalTimes.min() ?? 0, incrementalTimes.max() ?? 0
    ))
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let benchmarkIndex = arguments.firstIndex(of: "--benchmark-cost") {
    var benchmarkArguments = arguments
    benchmarkArguments.remove(at: benchmarkIndex)
    await benchmarkCost(arguments: benchmarkArguments)
}

let costService = CostService()
// Scanning the logs needs no credentials and no network, so it can be checked on its own.
let costOnly = arguments.contains("--cost-only")

for provider in Provider.allCases {
    if !costOnly {
        switch provider {
        case .codex: report(.codex, await CodexProvider.fetch())
        case .claude: report(.claude, await ClaudeProvider.fetch())
        }
    } else {
        print("[\(provider.displayName)]")
    }
    let started = Date()
    reportCost(provider, await costService.refresh(provider))
    print(String(format: "  scan took %.1fs", Date().timeIntervalSince(started)))
    print("")
}
