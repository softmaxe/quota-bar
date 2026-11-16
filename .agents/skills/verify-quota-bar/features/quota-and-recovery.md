# Quota and recovery

QuotaBar shows quota, reset times, freshness, and recovery actions from its menu bar card while preserving the last successful reading after a refresh failure.

## Sub-features

- `quota-fallback-lifecycle` checks native fallback status-button toggling, dismissal, foreground preservation, and provider key equivalents with the existing verifier.
- `quota-open` opens and closes the card through the actual status item.
- `quota-provider` selects Claude, Codex, or Pi by button and keyboard.
- `quota-reset` switches both reset labels between countdown and date.
- `quota-refresh` refreshes through the card or application command and observes cooldown/failure.
- `quota-sign-in` copies the CLI command and checks sign-in.

## How to get to it (user POV)

- Click the owned `QuotaBar, Codex` or `QuotaBar, Claude` status item; click again, outside the card, or press Escape to dismiss.
- Choose `Claude`, `Codex`, or `Pi`, or press Cmd-1, Cmd-2, or Cmd-3 in the card.
- Open either reset-time menu. Choose `Refresh` or Cmd-R; signed-out cards offer `Copy` and `Check sign-in`.

## Driving it with native CUA and the menu interaction verifier

Preconditions:

- Use the skill's owned build and desktop session. Select the matching preview state; do not overlap preview instances.
- Interactive paths require a successful native CUA binding and a fresh accessibility snapshot.

- **Fallback proof.** Run `.build/debug/QuotaBar --verify-menu-interaction`. Require exit 0 and `Menu lifecycle, status-button toggling, dismissal, and foreground preservation checks passed`. Save the complete transcript. This executable covers `quota-fallback-lifecycle`, including Cmd-1/Cmd-3 dispatch and Pi preserving the quota gauge.
- **Actual opening.** Start `make preview PREVIEW_STATE=loaded`. Resolve the owned status item's current label and click it. Capture open, repeated-click dismissal, and Escape dismissal as separate actions.
- **Provider selection.** Click each named provider button; also use `pressKey` with `super+1`, `super+2`, and `super+3`. Confirm the selected card; Pi must keep the last quota provider's status gauge.
- **Reset display.** Resolve a label beginning `Reset time display, resets `; choose `Show reset date`, then `Show countdown`. Both quota windows must adopt the selected mode.
- **Refresh.** Use `make preview PREVIEW_STATE=motion`, wait for an enabled `Refresh`, then exercise the button and Cmd-R separately. Capture working state and the completed reading. In `stale`, capture retained readings, warning, and retry countdown before retry becomes available.
- **Sign-in.** In `signed-out`, click `Copy claude command` and verify the clipboard contains `claude`. In `motion`, select Claude and choose `Check sign-in`; capture checking and the loaded result.

## Gotchas

- The fallback verifier synthesizes application events; passing it does not prove the macOS 27 remote menu bar's physical pointer path or a full accessibility audit.
- `signed-out` intentionally stays signed out after checking. Use `motion` for the fixture's successful sign-in path; neither verifies real OAuth credentials.
- Copy changes the system clipboard. Preserve and restore its prior contents when exercising that path; do not execute the copied login command.
- `stale` starts with a 90-second retry deadline; `motion` accelerates cooldown and introduces delayed fetches. Capture video for timing claims.
- Native CUA journeys were blocked during skill creation; only `quota-fallback-lifecycle` was executed successfully.
