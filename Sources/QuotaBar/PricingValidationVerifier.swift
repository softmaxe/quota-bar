#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

@MainActor
enum PricingValidationVerifier {
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { self.continuation = $0 }
        }

        func release() {
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    @MainActor
    private final class Recorder {
        var writes: [[String: ModelPricing]] = []
        var failWrite = false
        var invalidateGate: Gate?

        func operations() -> PricingEditorModel.SaveOperations {
            PricingEditorModel.SaveOperations(
                write: { [self] overrides in
                    if self.failWrite { throw SaveFailure.simulated }
                    self.writes.append(overrides)
                },
                invalidate: { [self] in
                    if let gate = self.invalidateGate { await gate.wait() }
                }
            )
        }
    }

    private enum SaveFailure: Error { case simulated }

    @MainActor
    private final class UsageRead {
        var result: Result<[Provider: [ModelUsageTotal]], Error> = .success([:])
        var gate: Gate?

        func read() async throws -> [Provider: [ModelUsageTotal]] {
            let result = self.result
            if let gate = self.gate { await gate.wait() }
            return try result.get()
        }
    }

    static func run() -> Never {
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
    }

    private static func verify() async -> Never {
        var failures: [String] = []
        let recorder = Recorder()
        let priced = Self.row(model: "custom-priced", input: "7", output: "8", hasDefault: true)
        let unpriced = Self.row(model: "local-unpriced", input: "", output: "", hasDefault: false)
        let model = PricingEditorModel(costService: CostService(), saveOperations: recorder.operations())
        model.debugSetRows(
            [priced, unpriced],
            overrides: [priced.model: ModelPricing(input: 7, output: 8)],
            defaults: [priced.id: ModelPricing(input: 3, output: 4)]
        )
        let input = model.binding(for: priced.id, keyPath: \.input)
        let threshold = model.binding(for: priced.id, keyPath: \.thresholdTokens)

        input.wrappedValue = "1,000"
        let grouped = model.rows.first(where: { $0.id == priced.id })
        Self.expect(grouped?.isPriced == true && grouped?.derivedCacheWrite1h == 2_000,
                    "grouped valid input disagreed with pricing status or derived rate", &failures)
        input.wrappedValue = "7"

        for invalid in ["abc", "-1", "NaN", "Infinity", "-Infinity"] {
            input.wrappedValue = invalid
            Self.expect(model.error(for: priced.id, field: .input) != nil,
                        "\(invalid) did not identify the input field", &failures)
            Self.expect(!(await model.save()), "\(invalid) was accepted for save", &failures)
            Self.expect(recorder.writes.isEmpty, "\(invalid) reached override writing", &failures)
        }
        input.wrappedValue = "7"
        for invalid in ["0", "-1", "1.5", "Infinity", "1,00", "9223372036854775808"] {
            threshold.wrappedValue = invalid
            Self.expect(model.error(for: priced.id, field: .thresholdTokens) != nil,
                        "\(invalid) was accepted as a threshold", &failures)
            Self.expect(!(await model.save()), "\(invalid) reached threshold save", &failures)
        }
        threshold.wrappedValue = ""
        // A long-context rate that does not read as a number still needs a threshold to apply to.
        let inputAbove = model.binding(for: priced.id, keyPath: \.inputAbove)
        inputAbove.wrappedValue = "abc"
        Self.expect(model.error(for: priced.id, field: .inputAbove) != nil,
                    "an unreadable long-context rate was not flagged", &failures)
        Self.expect(model.error(for: priced.id, field: .thresholdTokens) != nil,
                    "an unreadable long-context rate did not ask for a threshold", &failures)
        // A negative rate is refused, and the one-hour placeholder does not derive from it.
        input.wrappedValue = "-1"
        Self.expect(model.rows.first(where: { $0.id == priced.id })?.derivedCacheWrite1h == nil,
                    "a negative input produced a one-hour placeholder", &failures)
        inputAbove.wrappedValue = ""
        input.wrappedValue = ""
        Self.expect(model.error(for: priced.id, field: .input) != nil,
                    "clearing a priced base rate did not require an explicit restore", &failures)
        model.reset(id: priced.id)
        Self.expect(model.validationErrors.isEmpty && model.hasUnsavedChanges,
                    "restoring a default did not produce a valid draft", &failures)
        model.discard()
        Self.expect(!model.hasUnsavedChanges && model.rows.first(where: { $0.id == priced.id })?.input == "7",
                    "Discard did not restore saved values", &failures)

        input.wrappedValue = "9"
        let gate = Gate()
        recorder.invalidateGate = gate
        let firstSave = Task { await model.save() }
        Self.expect(await Self.wait(until: { gate.continuation != nil }),
                    "the asynchronous save did not begin", &failures)
        Self.expect(model.saveStatus == .saving, "Saving status was not visible", &failures)
        Self.expect(!(await model.save()), "a duplicate save was accepted", &failures)
        input.wrappedValue = "10"
        Self.expect(model.rows.first(where: { $0.id == priced.id })?.input == "9",
                    "editing changed the captured draft during save", &failures)
        gate.release()
        Self.expect(await firstSave.value, "the first save failed", &failures)
        Self.expect(model.saveStatus == .saved && recorder.writes.last?[priced.model]?.input == 9,
                    "success did not save the captured rate", &failures)
        recorder.invalidateGate = nil

        input.wrappedValue = "10"
        Self.expect(model.saveStatus == .dirty && model.lastSavedAt == nil,
                    "an edit after Saved did not return to Unsaved changes", &failures)
        recorder.failWrite = true
        Self.expect(!(await model.save()), "simulated write failure was reported as success", &failures)
        Self.expect(model.hasUnsavedChanges && model.rows.first(where: { $0.id == priced.id })?.input == "10",
                    "save failure lost the draft", &failures)
        if case .failed = model.saveStatus {} else {
            failures.append("save failure did not show a retryable error")
        }
        recorder.failWrite = false
        Self.expect(await model.save(), "retry did not save the preserved draft", &failures)
        Self.expect(recorder.writes.last?[priced.model]?.input == 10,
                    "untouched unpriced row blocked a valid edit", &failures)

        model.reset(id: priced.id)
        Self.expect(await model.save(), "explicit restore did not save", &failures)
        Self.expect(recorder.writes.last?[priced.model] == nil,
                    "restoring the fallback did not remove the custom override", &failures)
        model.binding(for: unpriced.id, keyPath: \.input).wrappedValue = "1"
        model.binding(for: unpriced.id, keyPath: \.output).wrappedValue = "2"
        Self.expect(await model.save(), "pricing a formerly unpriced model failed", &failures)
        model.reset(id: unpriced.id)
        Self.expect(await model.save(), "explicit clear without a fallback failed", &failures)
        Self.expect(recorder.writes.last?[unpriced.model] == nil,
                    "explicit clear left a custom price behind", &failures)

        let loadGate = Gate()
        let loading = PricingEditorModel(
            costService: CostService(),
            fixtures: .init(usage: [:], beforeCommit: { await loadGate.wait() }),
            saveOperations: recorder.operations()
        )
        let pendingLoad = Task { await loading.load() }
        Self.expect(await Self.wait(until: { loadGate.continuation != nil }),
                    "table rebuild did not reach the pending commit", &failures)
        loading.debugSetRows([priced])
        loading.binding(for: priced.id, keyPath: \.input).wrappedValue = "11"
        loadGate.release()
        await pendingLoad.value
        Self.expect(loading.rows.first(where: { $0.id == priced.id })?.input == "11" && loading.hasUnsavedChanges,
                    "an in-flight table rebuild overwrote the draft", &failures)

        do {
            try await self.verifyUsageRecovery(&failures)
        } catch {
            failures.append("usage recovery verification threw: \(error)")
        }

        VerifierReport.finish(
            failures,
            label: "pricing validation verification",
            passed: "pricing validation, save lifecycle, restore, discard, and async draft preservation passed"
        )
    }

    private static func verifyUsageRecovery(_ failures: inout [String]) async throws {
        let book = try PriceBook(data: Data("""
            {"schemaVersion": 1, "providers": {"codex": {
                "source": "https://example.com", "checkedAt": "2026-09-01", "models": [
                    {"id": "editable-model", "showInSettings": true,
                     "periods": [{"rates": {"input": 1, "output": 2}}]},
                    {"id": "restore-model", "showInSettings": true,
                     "periods": [{"rates": {"input": 3, "output": 4}}]}
                ]
            }}}
            """.utf8))
        let hidden = ModelPricing(input: 77, output: 88)
        let card = RateCard(book: book, overrides: [
            "editable-model": ModelPricing(input: 7, output: 8),
            // Restore must remain a change even when its rate text equals the fallback.
            "restore-model": ModelPricing(input: 3, output: 4),
            "hidden-model": hidden,
        ])
        let editableID = "codex|editable-model"
        let restoreID = "codex|restore-model"
        let localID = "codex|local-unpriced"
        let source = UsageRead()
        let recorder = Recorder()
        let model = PricingEditorModel(
            costService: CostService(),
            fixtures: .init(usage: [:], rateCard: card, readUsage: { try await source.read() }),
            saveOperations: recorder.operations()
        )
        var savedCallbacks = 0
        model.onSaved = { savedCallbacks += 1 }
        source.result = .failure(SaveFailure.simulated)
        await model.load()
        self.expect(!model.isLoading && !model.isReadingUsage && !model.hasLoadedUsage
                    && model.usageReadError != nil && Set(model.rows.map(\.model)) == ["editable-model", "restore-model"],
                    "initial read failure did not keep the normal rates editable with unavailable usage", &failures)
        let input = model.binding(for: editableID, keyPath: \.input)
        input.wrappedValue = "invalid"
        let validation = model.validationErrors
        let failedRows = model.rows
        await model.retryUsage()
        self.expect(model.rows == failedRows && model.validationErrors == validation && model.hasUnsavedChanges,
                    "a failed retry changed rate drafts or field validation", &failures)
        input.wrappedValue = "9"
        recorder.failWrite = true
        self.expect(!(await model.save()), "save failure fixture unexpectedly saved", &failures)
        let saveError = model.saveError
        let saveStatus = model.saveStatus
        source.result = .success([.codex: [.init(model: "editable-model", tokens: 10)]])
        await model.retryUsage()
        self.expect(model.hasLoadedUsage && model.usageReadError == nil && model.rows.first?.usageTokens == 10,
                    "successful retry did not recover initial unavailable usage", &failures)
        self.expect(input.wrappedValue == "9" && model.hasUnsavedChanges
                    && model.saveError == saveError && model.saveStatus == saveStatus,
                    "usage recovery changed a draft or cleared a separate save error", &failures)
        self.expect(recorder.writes.isEmpty && savedCallbacks == 0,
                    "usage recovery wrote overrides or triggered save side effects", &failures)
        recorder.failWrite = false
        self.expect(await model.save(), "recovered initial draft did not save", &failures)
        self.expect(recorder.writes.last?["editable-model"]?.input == 9
                    && recorder.writes.last?["hidden-model"] == hidden,
                    "save after initial failure lost the intended rate or hidden override", &failures)
        let savedAt = model.lastSavedAt
        source.result = .success([.codex: [.init(model: "editable-model", tokens: 20)]])
        await model.retryUsage()
        self.expect(!model.hasUnsavedChanges && model.saveStatus == .saved && model.lastSavedAt == savedAt,
                    "metadata-only recovery created dirty state or cleared Saved feedback", &failures)
        input.wrappedValue = "11"
        model.discard()
        self.expect(input.wrappedValue == "9" && model.rows.first?.usageTokens == 20 && !model.hasUnsavedChanges,
                    "Discard reverted recovered usage or the saved rate", &failures)
        let successfulRows = model.rows
        source.result = .failure(SaveFailure.simulated)
        await model.load()
        self.expect(model.rows == successfulRows && model.hasLoadedUsage && model.usageReadError != nil,
                    "refresh failure after success removed known counts or models", &failures)
        await model.retryUsage()
        self.expect(model.rows == successfulRows && model.hasLoadedUsage && model.usageReadError != nil,
                    "repeated retry failure replaced the last successful usage", &failures)

        // Start a separate editor to keep a saved Restore override until the in-flight retry.
        let drafts = PricingEditorModel(
            costService: CostService(),
            fixtures: .init(usage: [:], rateCard: card, readUsage: { try await source.read() }),
            saveOperations: recorder.operations()
        )
        source.result = .success([.codex: [.init(model: "local-unpriced", tokens: 5)]])
        await drafts.load()
        drafts.reset(id: restoreID)
        self.expect(drafts.hasUnsavedChanges && drafts.binding(for: restoreID, keyPath: \.input).wrappedValue == "3",
                    "Restore with unchanged fallback strings did not remain a pending override removal", &failures)
        let restoredRows = drafts.rows
        source.result = .failure(SaveFailure.simulated)
        await drafts.retryUsage()
        self.expect(drafts.hasUnsavedChanges && drafts.rows == restoredRows && drafts.usageReadError != nil,
                    "failed retry lost a pending Restore", &failures)
        drafts.binding(for: editableID, keyPath: \.input).wrappedValue = "12"
        source.result = .success([.codex: [
            .init(model: "editable-model", tokens: 50), .init(model: "new-model", tokens: 6),
        ]])
        let readGate = Gate()
        source.gate = readGate
        let pendingRetry = Task { await drafts.retryUsage() }
        self.expect(await self.wait(until: { readGate.continuation != nil }), "retry did not suspend", &failures)
        drafts.binding(for: editableID, keyPath: \.output).wrappedValue = "13"
        drafts.binding(for: localID, keyPath: \.input).wrappedValue = "14"
        drafts.binding(for: localID, keyPath: \.output).wrappedValue = "15"
        drafts.reset(id: restoreID)
        readGate.release()
        await pendingRetry.value
        source.gate = nil
        self.expect(drafts.binding(for: editableID, keyPath: \.input).wrappedValue == "12"
                    && drafts.binding(for: editableID, keyPath: \.output).wrappedValue == "13"
                    && drafts.binding(for: localID, keyPath: \.input).wrappedValue == "14"
                    && drafts.rows.first(where: { $0.id == localID })?.seenInLogs == false
                    && drafts.hasUnsavedChanges && drafts.validationErrors.isEmpty,
                    "retry overwrote a pre-existing or in-flight edit, or removed a disappearing draft row", &failures)
        self.expect(drafts.rows.first(where: { $0.model == "new-model" })?.usageTokens == 6,
                    "retry did not discover a new row", &failures)
        let beforeDraftSave = recorder.writes.count
        self.expect(await drafts.save(), "drafts preserved through retry did not save", &failures)
        self.expect(recorder.writes.count == beforeDraftSave + 1
                    && recorder.writes.last?["editable-model"] == ModelPricing(input: 12, output: 13)
                    && recorder.writes.last?["local-unpriced"] == ModelPricing(input: 14, output: 15)
                    && recorder.writes.last?["restore-model"] == nil
                    && recorder.writes.last?["hidden-model"] == hidden
                    && recorder.writes.last?["new-model"] == nil,
                    "save after recovery changed hidden rates, Restore, or intended draft values", &failures)
        drafts.binding(for: "codex|new-model", keyPath: \.input).wrappedValue = "16"
        drafts.discard()
        self.expect(!drafts.hasUnsavedChanges && drafts.validationErrors.isEmpty
                    && drafts.rows.first(where: { $0.model == "new-model" })?.input == ""
                    && drafts.rows.first(where: { $0.id == editableID })?.usageTokens == 50,
                    "newly discovered rows did not acquire a clean Discard baseline", &failures)

        // Retry completes during Save's invalidation await. Discard must keep that metadata.
        drafts.binding(for: editableID, keyPath: \.input).wrappedValue = "17"
        let invalidateGate = Gate()
        recorder.invalidateGate = invalidateGate
        let pendingSave = Task { await drafts.save() }
        self.expect(await self.wait(until: { invalidateGate.continuation != nil }),
                    "save did not suspend for recovery overlap", &failures)
        source.result = .success([.codex: [.init(model: "editable-model", tokens: 70)]])
        await drafts.retryUsage()
        invalidateGate.release()
        self.expect(await pendingSave.value, "overlapping Save failed", &failures)
        recorder.invalidateGate = nil
        drafts.discard()
        self.expect(!drafts.hasUnsavedChanges && drafts.binding(for: editableID, keyPath: \.input).wrappedValue == "17"
                    && drafts.rows.first(where: { $0.id == editableID })?.usageTokens == 70,
                    "Save completion restored stale usage to the Discard baseline", &failures)

        // Save finishes before retry. The read must use the new override layer at completion.
        source.result = .success([.codex: [
            .init(model: "editable-model", tokens: 80), .init(model: "late-model", tokens: 8),
        ]])
        source.gate = readGate
        let delayedRetry = Task { await drafts.retryUsage() }
        self.expect(await self.wait(until: { readGate.continuation != nil }), "late retry did not suspend", &failures)
        drafts.reset(id: editableID)
        self.expect(await drafts.save(), "Restore during a pending retry did not save", &failures)
        readGate.release()
        await delayedRetry.value
        source.gate = nil
        self.expect(!drafts.hasUnsavedChanges && drafts.saveStatus == .saved
                    && drafts.binding(for: editableID, keyPath: \.input).wrappedValue == "1"
                    && drafts.rows.first(where: { $0.id == editableID })?.usageTokens == 80,
                    "a late retry restored stale saved rates or changed Saved state", &failures)
        drafts.binding(for: restoreID, keyPath: \.input).wrappedValue = "18"
        self.expect(await drafts.save(), "saving after late recovery failed", &failures)
        self.expect(recorder.writes.last?["editable-model"] == nil
                    && recorder.writes.last?["local-unpriced"] == ModelPricing(input: 14, output: 15)
                    && recorder.writes.last?["hidden-model"] == hidden,
                    "a late retry restored stale overrides or deleted a now-hidden saved override", &failures)
    }

    private static func row(model: String, input: String, output: String, hasDefault: Bool) -> PricingRow {
        PricingRow(
            provider: .codex, group: .others, model: model,
            seenInLogs: true, hasDefault: hasDefault, usageTokens: 1,
            input: input, output: output, cacheWrite: "", cacheWrite1h: "", cacheRead: "",
            thresholdTokens: "", inputAbove: "", outputAbove: "", cacheWriteAbove: "",
            cacheWrite1hAbove: "", cacheReadAbove: ""
        )
    }

    private static func expect(_ condition: Bool, _ message: String, _ failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    private static func wait(until ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return ready()
    }
}
#endif
