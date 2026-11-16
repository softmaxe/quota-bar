// Injected into a temporary probe source copy by validate_rust_pipeline.py.
// This hook always pins every log path, SQLite database and pricing input to synthetic data.
func validationTokens(_ value: TokenTotals) -> [String: Int] {
    ["input": value.input, "output": value.output, "cacheWrite": value.cacheWrite,
     "cacheWrite1h": value.cacheWrite1h, "cacheRead": value.cacheRead]
}

func validationSnapshot(_ snapshot: CostSnapshot) -> [String: Any] {
    let days: [[String: Any]] = snapshot.days.map { day in
        let models: [[String: Any]] = day.byModel.map { key, value in
            ["source": key.source.rawValue, "model": key.model, "fast": key.isFast,
             "upstream": key.upstreamProvider as Any? ?? NSNull(),
             "tokens": validationTokens(value.tokens), "cost": value.costUSD as Any? ?? NSNull(),
             "loggedFallback": value.usesLoggedCostFallback]
        }.sorted { lhs, rhs in
            let left = try! JSONSerialization.data(withJSONObject: lhs, options: .sortedKeys)
            let right = try! JSONSerialization.data(withJSONObject: rhs, options: .sortedKeys)
            return left.lexicographicallyPrecedes(right)
        }
        return ["day": day.dayKey, "tokens": validationTokens(day.tokens),
                "cost": day.costUSD as Any? ?? NSNull(), "unpricedTokens": day.unpricedTokens,
                "models": models]
    }
    // scannedAt is deliberately omitted: it records the real wall clock of each independent run.
    return ["tab": snapshot.tab.rawValue, "todayCost": snapshot.todayCostUSD,
            "windowCost": snapshot.windowCostUSD, "latestTokens": snapshot.latestTokens,
            "windowTokens": snapshot.windowTokens, "topModel": snapshot.topModel as Any? ?? NSNull(),
            "unpriced": snapshot.hasUnpricedTokens, "days": days]
}

func validationRun(database: String, fixture: String, tab: UsageTab, benchmark: Bool) async throws {
    let root = URL(fileURLWithPath: fixture)
    let env = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
               "CODEX_HOME": root.appendingPathComponent("codex").path,
               "OPENCODE_DATA_HOME": root.appendingPathComponent("opencode").path,
               "PI_CODING_AGENT_DIR": root.appendingPathComponent("pi").path,
               "PI_CODING_AGENT_SESSION_DIR": root.appendingPathComponent("pi/sessions").path]
    let service = CostService(databaseURL: URL(fileURLWithPath: database), env: env, rateCard: RateCard())
    var snapshots: [String: Any] = [:]
    var times: [String: Double] = [:]
    let phases = benchmark ? ["initial", "unchanged", "append", "append-unchanged"] : ["scan"]
    for phase in phases {
        if phase == "append" {
            let relative = tab == .claude ? "claude/projects/app/session-0.jsonl" : "codex/sessions/session-0.jsonl"
            let data = try Data(contentsOf: root.appendingPathComponent("append.jsonl"))
            let file = try FileHandle(forWritingTo: root.appendingPathComponent(relative))
            defer { try? file.close() }
            _ = try file.seekToEnd()
            try file.write(contentsOf: data)
        }
        let started = ContinuousClock.now
        guard let snapshot = await service.refresh(tab) else {
            throw NSError(domain: "RustPipelineValidation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic scan returned no snapshot"])
        }
        let elapsed = started.duration(to: .now)
        times[phase] = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        snapshots[phase] = ["snapshot": validationSnapshot(snapshot),
                            "scanStatus": String(describing: await service.currentScanStatus(of: tab == .claude ? .claude : .codex))]
    }
    let data = try JSONSerialization.data(withJSONObject: ["phases": snapshots, "times_ms": times],
                                          options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--rust-validation",
   let tab = UsageTab(rawValue: CommandLine.arguments[4]),
   ["once", "benchmark"].contains(CommandLine.arguments[5]) {
    do {
        try await validationRun(database: CommandLine.arguments[2], fixture: CommandLine.arguments[3],
                                tab: tab, benchmark: CommandLine.arguments[5] == "benchmark")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Synthetic validation failed: \(error)\n".utf8))
        exit(3)
    }
}
