# QuotaBar interaction proposal

Implementation is recorded in [the implementation report](../design-implementation.md). The figures below remain the approved design baseline.

This directory preserves the approved design proposal. Use the root README and implementation report for current behavior and product screenshots. `proposal.html` is the editable source for the four annotated PNG figures. Product labels are in English; Chinese annotations explain the proposal for this review.

The main and stale-state before images are offscreen renders from commit `7a9a0a5`. The disconnected and invalid-price before states are reconstructions based on that same baseline, not recordings of a live user session. All values are synthetic examples. The after views are HTML representations of the proposed native macOS interfaces. They do not connect accounts, invoke the CLIs, save prices, or change preferences.

## Scope and release order

| Order | Scope | Reason |
| --- | --- | --- |
| 1 | Price validation and draft lifecycle | Invalid base-rate text can remove an existing price override while reporting a successful save. |
| 2 | Connection guidance and stale-data feedback | People need a next step when disconnected and must distinguish saved readings from a successful refresh. |
| 3 | Explicit metric selection and accessible actions | Frequent actions should be discoverable and usable without precise pointer targeting. Include honest cost availability labels. |
| 4 | Secondary density and motion | Fold model detail and pace calculations, remove duplicated top-model text, and shorten celebration motion after the functional paths work. |

Retain provider colors, the provider selector, the 280 pt menu width, quota/credit data, refresh cooldowns, and last-good readings. Do not add notifications, a new account system, or background credential repair.

## 1. Price validation and draft lifecycle

Affected implementation: `PricingEditorModel.swift`, `RateField.swift`, `PricingSettingsView.swift`, `SettingsWindowController.swift`, and the application termination path.

- Validate edited fields before writing anything. Required base rates for a priced row must be finite, nonnegative numbers. Thresholds must be finite positive integers within the supported range.
- Preserve legitimately unpriced, untouched rows. Do not require every model in the catalog to have a price. Optional blank fields retain their documented fallback semantics; a nonempty invalid string must not become an implicit blank.
- Distinguish clearing an override from a typing error. Restore defaults through an explicit row action. Treat the action as a draft edit until saved and allow Discard to undo it.
- Keep a draft separate from saved values. Show field-local errors with the model, field name, and correction. Save stays disabled while validation errors exist.
- Show `Unsaved changes`, `Saving…`, `Saved`, and a retryable save error as distinct states. Editing after a successful save must remove the old `Saved` indication.
- Prevent duplicate saves. Keep the captured draft consistent across asynchronous save work; either disable editing during save or reconcile later edits without clearing their dirty state.
- Preserve drafts when switching settings tabs or closing the settings window. On application quit, offer Save, Discard, or Cancel when valid unsaved edits remain; invalid drafts require correction, discard, or cancellation of quitting. Do not silently clear drafts during an asynchronous catalog reload.
- Give fields accessibility labels containing model, rate category, and unit. Present errors with text and a symbol, not color alone.

Acceptance examples: `abc`, `-1`, `NaN`, `Infinity`, and invalid threshold values do not modify the override file. An untouched unpriced row does not block an unrelated valid edit. Simulated save failure preserves the draft. Discard restores the last saved values. A second edit after saving returns the footer to unsaved state. Catalog refresh cannot overwrite a draft created while its asynchronous work was pending.

## 2. Connection and stale-data states

Affected implementation: `ProviderDisplay.swift`, `UsageStore.swift`, `MenuCardView.swift`, `StatusItemController.swift`, and `RefreshRowPolicy.swift`.

- Preserve typed state and the useful reason instead of dropping the signed-out reason.
- For a missing login, show a brief task explanation, the provider-specific CLI command, Copy command, and Check sign-in. Copying must not execute the command. Use `codex login` for Codex and `claude` for Claude. Keep the status label `Not signed in` to distinguish credential absence from a network problem.
- Use a single primary check action in the disconnected card; avoid a duplicate Refresh action in that state. Show checking and cooldown states at the action.
- Preserve the existing selected-provider and credential-recovery policies. Permission and decode failures are not missing-login states. Keep specific recovery instructions for those errors.
- On refresh failure, retain last-good readings and put a warning near the provider header. Include the age of the last successful fetch and the actionable cause.
- Refresh eligibility and the warning must derive from the same effective retry deadline, the later of server rate-limit eligibility and the local refresh cooldown. A countdown must update while the menu remains open. Successful refresh removes the warning. The before/after rate-limit example preserves the server's 4:24 PM retry time.
- Local usage may load independently; do not label quota refresh completion as local-scan completion. Show local scan status if that work delays the usage section.

Acceptance examples: first launch without credentials offers the correct command; checking cannot submit duplicate work; a failure with cached quota leaves the values intact and visibly identifies them as saved data; a subsequent success removes the warning; a recoverable credential state follows existing manual-recovery rules.

## 3. Explicit controls and chart semantics

Affected implementation: `CostSectionView.swift`, `CostChartHighlightPolicy.swift`, `MenuCardView.swift`, `MouseLocationReader.swift`, `MenuActionRowView.swift`, `StatusItemController.swift`, and relevant cost aggregation/display state.

- Put a visible Tokens / Cost segmented selector above usage metrics. Keep the saved unit preference and update metrics, bar heights, labels, and breakdown ordering together.
- A bar click selects a day; it no longer changes units. Hover previews a day and moving to detail leaves the last preview readable. A click or keyboard selection pins that date until another date is selected or the data changes.
- Give each date its full chart-column hit area. Preserve quantitative bar heights and the existing selected-day marker. The dashed hit-area rectangle in the figure is an annotation, not proposed product chrome.
- Show ten consecutive calendar days, with start/end labels and a clear distinction from the 30-day aggregate. Insert empty dates only when the scan is complete and the data supports interpreting the gap as no recorded usage.
- Add keyboard previous/next-day navigation and accessibility descriptions of date, unit, value, and pricing availability. Expose model disclosure and the unit selector as actionable controls.
- Render the reset-time label as a recognizable control. It opens a choice between countdown and clock display for both quota windows. It must not suggest or perform a manual quota reset.
- The proposed Cmd-R command must actually be implemented and tested before being displayed. The current view-backed NSMenuItem does not provide it automatically. Use an AppKit action/event path appropriate to the active menu; do not assume adding SwiftUI `.keyboardShortcut` to the existing card solves focus and event routing. If the existing NSMenu cannot support reliable focus, evaluate NSPopover as a separate, bounded container change before implementation.
- Use a typed pricing availability state: fully priced zero is `$0.00`; completely unpriced usage is `—` / `Unpriced`; mixed usage shows the known subtotal and `Partial estimate`. Include unpriced usage counts or details. Do not replace a valid partial subtotal with an entirely unknown value.

Acceptance examples: low and zero-height dates are selectable without targeting a thin visible bar; changing units preserves the selected date; keyboard navigation reaches both units and dates; VoiceOver identifies value and date; missing price never silently appears as zero; mixed pricing preserves the known subtotal with an explicit partial label.

## 4. Density and motion

- Keep the immediately useful pace outcome below each quota bar. Make the existing reserve, deficit, and headroom explanation available through Usage pace details. Keep the pace marker and detailed values together in that disclosure.
- Show the selected day's total and a Model breakdown disclosure. Remove the duplicated Top model line. Keep existing model data and source/tier distinctions in the expanded view.
- Preserve Credits when relevant. The proposal does not change its balance semantics or investigate the current fixed-scale display.
- Make authoritative quota values available immediately during reset feedback. Shorter supporting motion is a design preference, not an Apple timing requirement. Respect Reduce Motion throughout.

## Verification and limits

The deliverables are static proposal figures. Rendering and overflow checks apply to the figures, not to the native app implementation. Before shipping, test the native 280 pt layout, real NSMenu or NSPopover focus, VoiceOver, Full Keyboard Access, light/dark appearance, increased contrast, Reduce Motion, longest reset labels, long model names, and asynchronous refresh/save failures.

The proposal-rendering step did not change product source files or settings. The subsequent implementation and its verification are recorded in [the implementation report](../design-implementation.md).

## Files and removal

- `proposal.html`: editable annotated board source.
- `01-pricing.png`: invalid-price and save-state comparison.
- `02-connection.png`: disconnected onboarding comparison.
- `03-stale.png`: refresh-failure comparison.
- `04-daily.png`: everyday interaction and cost-availability comparison.
- `assets/before-main.png`, `assets/before-stale.png`: fresh native view renders used as evidence.

To remove these design deliverables from the repository root:

```sh
rm docs/design-proposal/01-pricing.png docs/design-proposal/02-connection.png docs/design-proposal/03-stale.png docs/design-proposal/04-daily.png
rm docs/design-proposal/proposal.html docs/design-proposal/README.md
rm docs/design-proposal/assets/before-main.png docs/design-proposal/assets/before-stale.png
rmdir docs/design-proposal/assets docs/design-proposal
```
