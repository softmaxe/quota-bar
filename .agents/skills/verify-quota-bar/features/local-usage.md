# Local usage

The card shows daily tokens or estimated cost, selectable dates, model details, and Pi usage grouped by upstream provider.

## Sub-features

- `usage-unit` switches Tokens/Cost while preserving a valid selected day.
- `usage-date` selects a day by pointer or arrow keys.
- `usage-models` expands and collapses the selected day's model list.
- `usage-pi` shows Pi upstream usage without quota or sign-in controls.
- `usage-retry` recovers a failed local scan through its own retry action.

## How to get to it (user POV)

- Open the menu bar card and select Claude, Codex, or Pi by button or Cmd-1/2/3.
- In local usage, choose Tokens or Cost, click a date column, and expand the model list below it.
- A failed local scan offers `Retry local scan`; Pi's Refresh rescans Pi sessions.

## Driving it with native CUA

Preconditions:

- Start `make preview PREVIEW_STATE=loaded` through the skill's owned-instance workflow and bind the native UI successfully.
- Resolve the actual dates and models from the current accessibility snapshot; sample dates are not fixed handles.

- **Units.** Resolve `Usage unit`, then click `Tokens` and `Cost`. Capture the selected unit and changed labels/totals after each action.
- **Dates.** Click a day whose accessible label contains its date and year. Its hint is `Select day. Use Left and Right Arrow to change day.` Press Left/Right Arrow and verify the selected date and detail values move together.
- **Selection persistence.** Select a day, change units, and refresh when enabled. A still-valid date must remain selected; capture each action and state.
- **Models.** Resolve the disclosure with `Expand model list` hint and `Collapsed` value. Activate it, verify `Expanded` plus model rows, then collapse it again. Record visible full model labels and values.
- **Pi.** Click `Pi` and separately use `pressKey` with `super+3`. Verify upstream provider rows, local usage, and absence of quota/sign-in controls; the status gauge must retain the last quota provider.
- **Recovery.** With a genuine failed local scan fixture, choose `Retry local scan` and verify progress followed by usable data. Report the missing precondition if no failed scan is available.

## Gotchas

- Preview cost results are display fixtures, not records seeded into its SQLite database. They cannot prove log ingestion or backup contents.
- Existing preview states do not seed a local-scan failure. `usage-retry` is blocked without that precondition; ordinary Refresh is not equivalent coverage.
- `motion` delays the first local scan and later refreshes; use it only for a timing journey and capture video.
- Dynamic dates, model counts, and amounts should be read from the current snapshot rather than hard-coded.
- These interactive journeys remain unverified until native CUA can bind the owned app.
