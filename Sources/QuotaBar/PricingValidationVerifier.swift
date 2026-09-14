#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

@MainActor
enum PricingValidationVerifier {
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

    private final class Recorder {
        var writes: [[String: ModelPricing]] = []
        var failWrite = false
        var freezeGate: Gate?

        func operations() -> PricingEditorModel.SaveOperations {
            PricingEditorModel.SaveOperations(
                freeze: { [self] in
                    if let gate = self.freezeGate { await gate.wait() }
                },
                write: { [self] overrides in
                    if self.failWrite { throw SaveFailure.simulated }
                    self.writes.append(overrides)
                },
                invalidate: {}
            )
        }
    }

    private enum SaveFailure: Error { case simulated }

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
        recorder.freezeGate = gate
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
        recorder.freezeGate = nil

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
            fixtures: .init(usage: [:], overlay: PricingOverlay(), beforeCommit: { await loadGate.wait() }),
            saveOperations: recorder.operations()
        )
        let pendingLoad = Task { await loading.load() }
        Self.expect(await Self.wait(until: { loadGate.continuation != nil }),
                    "catalog rebuild did not reach the pending commit", &failures)
        loading.debugSetRows([priced])
        loading.binding(for: priced.id, keyPath: \.input).wrappedValue = "11"
        loadGate.release()
        await pendingLoad.value
        Self.expect(loading.rows.first?.input == "11" && loading.hasUnsavedChanges,
                    "an in-flight catalog rebuild overwrote the draft", &failures)

        VerifierReport.finish(
            failures,
            label: "pricing validation verification",
            passed: "pricing validation, save lifecycle, restore, discard, and async draft preservation passed"
        )
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
