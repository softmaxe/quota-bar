# Usage report export

QuotaBar exports all saved usage as one bilingual HTML file. The file contains its styles, chart code, and data, so it can be opened without QuotaBar or a network connection. The page follows the Usage page of [T3 Code](https://github.com/pingdotgg/t3code).

## Export a report

1. Open **Settings → Export**. You can also press ⌘3 while the settings window is active.
2. Under **Opens with**, choose **Last 7 days** or **Last 30 days**. This sets the period the report shows first.
3. Choose whether to open the file after export.
4. Choose **Export Report…**, then select a destination in the Save panel.

QuotaBar checks for saved usage before opening the Save panel. If it finds none, it shows **No saved usage yet** and does not create a file. A successful export offers **Open Report** and **Show in Finder**. Cancelling the Save panel leaves the destination unchanged, and a failed read or write can be retried.

The settings tabs remain separate. While Settings is active, ⌘1 opens **General**, ⌘2 opens **Pricing**, and ⌘3 opens **Export**. The menu card keeps its existing ⌘1 and ⌘2 shortcuts for Codex and Claude. Adding the Export tab does not change the General or Pricing workflows.

## What the report shows

The top bar picks the period: **7 days**, **30 days**, or **Custom** with a start and end date anywhere in the saved history. Every figure is summed in the page from the embedded days, so a new period needs no new export. Beside it, **Cost** and **Tokens** choose the metric and the language control switches between Simplified Chinese and English.

For the chosen period the report shows:

- the total and each usage source's share, with the number of days it has records
- a daily line per source, with a hover readout of each source and the day's total
- totals for processed tokens, cached input, uncached input, output, and cache savings
- cost by token type and, when Fast usage exists, cost by speed with the Fast premium
- a breakdown by model, marked with the source that used it most, or by day and source

Cache savings is what cache-read tokens would have cost at the input rate, minus what they cost. The Fast premium is what Fast usage cost above the same tokens at Standard rates. A day without saved records shows **No record** in the day breakdown, distinct from recorded zero usage. Notes at the bottom list the sources, capture time, and timezone.

The period, metric, breakdown, and language are stored for that file path. A `?period=7`, `?period=30`, or `?from=YYYY-MM-DD&to=YYYY-MM-DD` query, and `?lang=`, `?metric=`, or `?breakdown=`, opens the page with that view. The page follows the system light or dark appearance and reflows for narrow windows. Hover a table cell for its exact value.

The HTML embeds the snapshot used to render the page, including estimated cost values before display rounding. Anyone with the file can inspect these fields:

- the export's default period, capture timestamp, and timezone
- for every calendar day from the first saved record through the export day: input, output, cache-read, cache-write, and one-hour cache-write token counts, split by source and by model and source
- each day's estimated cost, cost by token type, cache savings, Fast cost, and Fast premium
- unpriced-token counts

History reaches back at most ten years from the export day. The export does not contain prompts, responses, reasoning text, credentials, account IDs, session paths, or stable record IDs.

## Data and cost rules

`UsageReportReader` opens QuotaBar's cost database read-only and uses a SQLite transaction to read one committed snapshot, including committed WAL data. The date window follows the Mac's current calendar and ends on the day of export.

The reader includes every eligible row already stored for Codex and Claude. It also includes OpenCode and Pi Agent rows that the scanner marked as eligible after applying the OAuth account-matching rules described in the root README. Export does not scan the original session files or reassess eligibility.

The export uses the same pricing rules as the menu. Claude and OpenAI models use the price book's rates for each recorded day. Other models use the third-party rates cached from models.dev for that day, unless that setting is off. Fast usage, from Codex's priority tier or Claude's Fast mode, uses the price book's rates and Fast multiplier for that day. Without a Fast multiplier, and for every third-party model, it stays unpriced. The result remains an estimate and may differ from the provider's bill.

Rows without a usable price contribute tokens but no cost. The report labels a fully unpriced total or model as **Unpriced**, and an info mark beside the total gives the share of unpriced tokens. Cost by token type prices each token type of a row alone at that row's rates, so the types add up to the row's cost.

Export only reads SQLite and the local third-party rates cache, and writes the selected HTML file. It does not refresh quota, scan logs, download prices, invoke a CLI, contact a model, or make any network request.

## Implementation

`ExportSettingsModel` runs database reading and HTML rendering away from the main thread, presents the native Save panel, and writes UTF-8 output atomically. One busy state covers the complete operation to prevent overlapping exports.

`UsageReportHTMLRenderer` inserts a script-safe JSON snapshot into the report template. It bundles `report.html`, `report.css`, and `report.js` through SwiftPM resources and needs no chart library. `Scripts/package_app.sh` copies the resource bundle into the app, so release builds do not depend on repository files or remote assets. The design and source marks adapted from T3 Code are credited in `THIRD_PARTY_NOTICES.md`.

The release workflow gets the app version from a `vMAJOR.MINOR.PATCH` Git tag. The export feature does not require a separate hard-coded version change.

## Verification

Run the project checks with the full Xcode toolchain selected by `Scripts/swift.sh`:

```sh
make test
```

The default installation is `/Applications/Xcode.app`. Set `DEVELOPER_DIR` to another full Xcode installation's `Contents/Developer` directory if needed. The project does not change the global `xcode-select` setting.

The Swift checks cover the calendar windows, the embedded history and its per-day source and model splits, supported sources, WAL-visible records, missing and zero dates, dated and unpriced costs, numeric bounds, safe JSON insertion, resource bundling, file writes, empty history, failures, and duplicate-export suppression.

A debug build can export the current local database without opening the settings window:

```sh
make build
.build/debug/QuotaBar --export-usage-report build/usage-report.html
```

The optional browser verifier checks the generated file in both languages, the 7-day, 30-day, and custom periods and their stored choice, narrow layouts, missing and zero dates, unpriced data, long model names, script syntax, and the absence of remote requests.

```sh
node Scripts/verify_usage_report.mjs --file build/usage-report.html
```

It requires Node.js, a Playwright installation discoverable through `playwright-cli`, and a Chromium executable. The default executable is Brave at `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`. Set `PLAYWRIGHT_MODULE` to an absolute Playwright-backed CLI entry path or `CHROMIUM_PATH` to another Chromium executable when those defaults do not match the machine.

To regenerate the public report image with synthetic data:

```sh
.build/debug/QuotaBar --dump-usage-report build/sample-report
node Scripts/report_image.mjs build/sample-report/usage-report.html docs/images/report-export.png
```

The sample generator uses the native renderer and never reads the local database. The same image
is included in `make readme-assets`. It uses the browser dependencies described above.
