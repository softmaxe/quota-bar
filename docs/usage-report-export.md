# Usage report export

QuotaBar exports a bilingual usage snapshot as one HTML file. The file contains its styles, chart code, font fallbacks, Chart.js, and data, so it can be opened without QuotaBar or a network connection.

## Export a report

1. Open **Settings → Export**. You can also press ⌘3 while the settings window is active.
2. Choose **Last 7 days** or **Last 30 days**.
3. Choose whether to open the file after export.
4. Choose **Export Report…**, then select a destination in the Save panel.

QuotaBar checks the selected period before opening the Save panel. If it finds no saved usage, it shows **No saved usage in this period** and does not create a file. A successful export offers **Open Report** and **Show in Finder**. Cancelling the Save panel leaves the destination unchanged, and a failed read or write can be retried.

The settings tabs remain separate. While Settings is active, ⌘1 opens **General**, ⌘2 opens **Pricing**, and ⌘3 opens **Export**. The menu card keeps its existing ⌘1 and ⌘2 shortcuts for Codex and Claude. Adding the Export tab does not change the General or Pricing workflows, including unsaved Pricing drafts.

## What the report shows

The report has a daily usage line, stored cost by model, and a token-composition chart for input, output, cache read, and cache write. It also shows the saved source names, capture time, timezone, pricing coverage, and the number of calendar days with records. Missing dates remain distinct from recorded zero usage.

Use the language control in the report to switch between Simplified Chinese and English. The choice is stored for that file path. The layout reflows for narrow windows, and the 30-day plot can scroll horizontally when it needs more room.

The expandable data section gives exact daily token totals, cache-read tokens, cache-write tokens, model token totals, token-composition values, and costs rounded to cents. The HTML also embeds the complete snapshot used to render the page, including the stored cost values before display rounding. Anyone with the file can inspect these fields:

- selected period, capture timestamp, and timezone
- aggregate input, output, cache-read, cache-write, and one-hour cache-write token counts
- daily, model, and source aggregates
- unpriced-token counts and stored cost totals

The export does not contain prompts, responses, reasoning text, credentials, account IDs, session paths, or stable record IDs.

## Data and cost rules

`UsageReportReader` opens QuotaBar's cost database read-only and uses a SQLite transaction to read one committed snapshot, including committed WAL data. The date window follows the Mac's current calendar and ends on the day of export.

The reader includes every eligible row already stored for Codex and Claude. It also includes OpenCode and Pi Agent rows that the scanner marked as eligible after applying the OAuth account-matching rules described in the root README. Export does not scan the original session files or reassess eligibility.

The export uses the cost saved with each database row. It does not apply today's catalog or manual rates to old usage. This keeps historical estimates frozen, but the result remains an estimate and may differ from the provider's bill.

Rows without a usable price contribute tokens but no cost. The report labels a fully unpriced total as **Unpriced** and a mixed total as a partial estimate. Historical cache-read and cache-write costs are not stored as separate USD values, so the report shows cache token counts and does not infer cache cost from current rates.

Export only reads SQLite and writes the selected HTML file. It does not refresh quota, scan logs, fetch pricing, invoke a CLI, contact a model, or make any network request.

## Implementation

`ExportSettingsModel` runs database reading and HTML rendering away from the main thread, presents the native Save panel, and writes UTF-8 output atomically. One busy state covers the complete operation to prevent overlapping exports.

`UsageReportHTMLRenderer` inserts a script-safe JSON snapshot into the report template. It bundles the template, CSS, rendering helpers, palette, and Chart.js through SwiftPM resources. `Scripts/package_app.sh` copies the resource bundle into the app, so release builds do not depend on repository files or remote assets. Chart.js license information is included in `THIRD_PARTY_NOTICES.md` and in the packaged resource bundle.

The release workflow gets the app version from a `vMAJOR.MINOR.PATCH` Git tag. The export feature does not require a separate hard-coded version change.

## Verification

Run the project checks with the full Xcode toolchain selected by `Scripts/swift.sh`:

```sh
make test
```

The default installation is `/Applications/Xcode.app`. Set `DEVELOPER_DIR` to another full Xcode installation's `Contents/Developer` directory if needed. The project does not change the global `xcode-select` setting.

The Swift checks cover the calendar windows, supported sources, WAL-visible records, missing and zero dates, frozen and unpriced costs, numeric bounds, safe JSON insertion, resource bundling, file writes, empty periods, failures, and duplicate-export suppression.

A debug build can export the current local database without opening the settings window:

```sh
make build
.build/debug/QuotaBar --export-usage-report build/usage-report.html
```

The optional browser verifier checks the generated file in both languages, narrow layouts, missing and zero dates, unpriced data, long model names, exact tables, script syntax, and the absence of remote requests.

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
