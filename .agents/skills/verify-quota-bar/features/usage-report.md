# Usage report

The Usage window presents saved usage by period, metric, model or day, with English and Chinese labels.

## Sub-features

- `report-open` opens the Usage window through the card and shortcut.
- `report-period` changes 7-day, 30-day, and custom date ranges.
- `report-metric` switches tokens and cost.
- `report-language` changes English/Chinese labels.
- `report-breakdown` switches model/day detail.
- `report-live` preserves view choices as recorded usage changes.

## How to get to it (user POV)

- Choose `Usage…` from the card or press Cmd-U.
- Use the window's period, Tokens/Cost, EN/中, and Model/Day controls.
- Select Custom to reveal the start and end date fields.

## Driving it with native CUA

Preconditions:

- Start `make preview PREVIEW_STATE=loaded` through the skill's workflow and obtain a working native CUA binding.
- Record initial report choices before changing them: its WebKit storage is persistent, unlike preview preferences.
- Preview report data covers 2026-09-01 through 2026-09-30; custom-range tests must use that range.

- **Open.** Exercise `Usage…` and Cmd-U separately. Wait for populated summary, chart, and breakdown rather than only a visible window.
- **Language.** Resolve `EN` and `中` from the current tree. Activate each and confirm labels change while the selected period and metric remain intact.
- **Period.** In English, click `7 days`, then `30 days`; capture the range labels and corresponding totals. Choose `Custom`, set 2026-09-01 through 2026-09-07 using the visible date inputs, and confirm the requested period is displayed.
- **Metric.** Click `Tokens`, then `Cost`; verify summary, chart labels, and breakdown agree with the selected metric.
- **Breakdown.** Click `Model`, then `Day`; confirm rows represent the chosen grouping and totals remain consistent with the same range.
- **Restore.** Restore the initial report choices through the UI and close the owned window. Capture the restored state.

## Gotchas

- The preview report is a fixed sample snapshot, independent of card samples and its empty scratch database. It cannot prove live ingestion or import-driven report updates; `report-live` needs an actual changing, isolated database.
- The native report uses the default persistent WebKit data store and a fixed application-support page identity. Preview termination does not clear report choices. Never delete the user's WebKit store as cleanup.
- If separately exercising the existing HTML harness, real page handles are `[data-language="en"]`, `[data-language="zh"]`, `[data-period="7"]`, `[data-period="30"]`, `[data-period="custom"]`, `[data-range-from]`, `[data-range-to]`, `[data-metric="tokens"]`, `[data-metric="cost"]`, `[data-breakdown="model"]`, and `[data-breakdown="day"]`. HTML-only coverage does not prove native window entry points.
- These interactive journeys remain unverified until native CUA can bind the owned app.
