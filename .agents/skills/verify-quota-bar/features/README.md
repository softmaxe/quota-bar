# QuotaBar verification map

Read [the verification skill](../SKILL.md) before choosing a journey. This map is the maintained source of user paths, required fixtures, and observable outcomes.

## Baseline preconditions

- Build through the repository's Swift/Rust wrapper and run the skill's doctor.
- Use one owned preview at a time. `QuotaBarInterfacePreview` is a shared, fixed preference suite; a second preview clears the first one's preferences.
- Preview startup is `make preview PREVIEW_STATE=loaded`; `signed-out`, `stale`, and `motion` select other fixtures. Follow the skill's process ownership and evidence instructions.
- A logged-in macOS desktop and working native accessibility automation are required for interactive journeys. Never drive the installed application by mistake.

## Driving conventions

- Bind native CUA to the exact owned app path. Read its current accessibility snapshot, resolve the named control to a fresh element index, and click it with the documented CUA API.
- Use `pressKey` with `super+1`, `super+2`, or `super+3` only after confirming which window owns focus: these select providers in the popover and panes in Settings.
- Reacquire handles after navigation. Dynamic quota readings, dates, and vendor counts are not fixed selectors.
- Use the existing lifecycle verifier for its mapped fallback behavior. It does not replace physical pointer interaction with the macOS 27 remote menu bar.

## Proof and failure reporting

- Record feature ID, entry point, command/action, before state, resulting state, and relevant side effects in the skill's evidence directory.
- Retain screenshots and accessibility snapshots for interactive proof; retain stdout, stderr, and exit code for the executable verifier. Keep evidence after cleanup.
- Every listed entry point remains a separate coverage obligation. Missing seed data or automation access is a failed/blocked journey, not permission to substitute an easier path.
- The creation run passed the fallback lifecycle verifier. Full native CUA journeys remain unverified: binding the bare executable returned `Invalid app`; binding a temporary app bundle returned `timeoutReached`.

## Features

- [Quota and recovery](quota-and-recovery.md): status item, provider selection, reset display, refresh, and sign-in recovery.
- [Local usage](local-usage.md): dates, Tokens/Cost, model details, and Pi upstream usage.
- [Settings and pricing](settings-and-pricing.md): settings navigation, preferences, and rate search.
- [Usage report](usage-report.md): report window, periods, units, language, and breakdown.
- [Saved usage and sources](saved-usage-and-sources.md): backup import/export and SSH sources.
