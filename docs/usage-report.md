# Usage window

QuotaBar shows all saved usage in one bilingual page inside the app. The page carries its styles, chart code, and data, and makes no network request. It follows the Usage page of [T3 Code](https://github.com/pingdotgg/t3code).

## Open the window

Choose **Usage…** in the menu card, or press ⌘U while the card is open or a QuotaBar window is active. With no saved usage, the window shows **No saved usage yet** instead of the page.

While the window is open, QuotaBar keeps it current. Opening it shows what is saved, then scans the local logs of every provider, not only the one in the menu bar. It scans again every minute and rereads the database whenever any scan finishes, whichever path started it. Scans are incremental, so after the first pass each one reads only what the sources appended. A newer snapshot reaches the page through `window.updateReport`, which redraws in place and keeps the chosen period, metric, breakdown, language, and scroll position. A custom end date past the new last day is clamped. Closing the window stops the timer and keeps the page loaded for the next open.

## What the page shows

The top bar picks the period: **7 days**, **30 days**, or **Custom** with a start and end date anywhere in the saved history. Every figure is summed in the page from the snapshot's days, so a new period needs no new read. Beside it, **Cost** and **Tokens** choose the metric and the language control switches between Simplified Chinese and English.

For the chosen period the page shows:

- the total and each usage source's share, with the number of days it has records
- a daily line per source, with a hover readout of each source and the day's total
- totals for processed tokens, cached input, uncached input, output, and cache savings
- cost by token type and, when Fast usage exists, cost by speed with the Fast premium
- a breakdown by model, marked with the source that used it most, or by day and source

Cache savings is what cache-read tokens would have cost at the input rate, minus what they cost. The Fast premium is what Fast usage cost above the same tokens at Standard rates. A day without saved records shows **No record** in the day breakdown, distinct from recorded zero usage.

The page keeps the period, metric, breakdown, and language in the web view's local storage, under the path `~/Library/Application Support/QuotaBar/usage-report.html`. Nothing is written to that path. The page follows the system light or dark appearance and reflows for narrow windows. Hover a table cell for its exact value.

The snapshot holds, for every calendar day from the first saved record through today, input, output, cache-read, cache-write, and one-hour cache-write token counts, split by source and by model and source, with each day's estimated cost, cost by token type, cache savings, Fast cost, Fast premium, and unpriced-token count. History reaches back at most ten years. It holds no prompts, responses, reasoning text, credentials, account IDs, session paths, or stable record IDs.

## Data and cost rules

`UsageReportReader` opens QuotaBar's cost database read-only and uses a SQLite transaction to read one committed snapshot, including committed WAL data. The date window follows the Mac's current calendar and ends today.

The reader includes every eligible row already stored for Codex and Claude. It also includes OpenCode and Pi Agent rows that the scanner marked as eligible after applying the OAuth account-matching rules described in the root README. The reader itself does not scan session files or reassess eligibility; the window's scans go through the same `UsageStore` path as the menu.

The page uses the same pricing rules as the menu. Models the price book lists use its rates for each recorded day. Other models use the rates cached from models.dev for that day, unless that setting is off. Fast usage, from Codex's priority tier or Claude's Fast mode, uses the price book's rates and Fast multiplier for that day. Without a Fast multiplier, and for every model outside the book, it stays unpriced. The result remains an estimate and may differ from the provider's bill.

Rows without a usable price contribute tokens but no cost. The page labels a fully unpriced total or model as **Unpriced**, and an info mark beside the total gives the share of unpriced tokens. Cost by token type prices each token type of a row alone at that row's rates, so the types add up to the row's cost.

## Implementation

`UsageReportWindowController` reads the snapshot away from the main thread and shows it in a `WKWebView`. The first read loads the rendered page; later reads that differ are passed to `window.updateReport`. Reads requested during a read coalesce into one more. The web view refuses every navigation after the first load.

`UsageReportHTMLRenderer` inserts a script-safe JSON snapshot into the page template, and `scriptLiteral` gives live updates the same encoding. It bundles `report.html`, `report.css`, and `report.js` through SwiftPM resources and needs no chart library. `Scripts/package_app.sh` copies the resource bundle into the app, so release builds do not depend on repository files or remote assets. The design and source marks adapted from T3 Code are credited in `THIRD_PARTY_NOTICES.md`.

## Verification

Run the project checks with the full Xcode toolchain selected by `Scripts/swift.sh`:

```sh
make test
```

The default installation is `/Applications/Xcode.app`. Set `DEVELOPER_DIR` to another full Xcode installation's `Contents/Developer` directory if needed. The project does not change the global `xcode-select` setting.

The Swift checks cover the calendar windows, the snapshot history and its per-day source and model splits, supported sources, WAL-visible records, missing and zero dates, dated and unpriced costs, numeric bounds, safe JSON insertion, live-update encoding, and resource bundling.

A debug build can open the usage window on 29 sample days, hand it the thirtieth as a live update, check that the page took it, and write what it shows to `<directory>/usage-window.png`:

```sh
.build/debug/QuotaBar --dump-usage-window build/usage-window
```

It can also open only the usage window on the saved usage, beside an installed QuotaBar. Without its own scans, that window rereads the database every minute; closing it quits.

```sh
.build/debug/QuotaBar --preview-usage-window
```

The optional browser verifier checks a rendered page in both languages, the 7-day, 30-day, and custom periods and their stored choice, narrow layouts, missing and zero dates, unpriced data, long model names, script syntax, and the absence of remote requests. Render the sample page first:

```sh
.build/debug/QuotaBar --dump-usage-report build
node Scripts/verify_usage_report.mjs --file build/usage-report.html
```

It requires Node.js, a Playwright installation discoverable through `playwright-cli`, and a Chromium executable. The default executable is Brave at `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`. Set `PLAYWRIGHT_MODULE` to an absolute Playwright-backed CLI entry path or `CHROMIUM_PATH` to another Chromium executable when those defaults do not match the machine.

To regenerate the public image with synthetic data:

```sh
.build/debug/QuotaBar --dump-usage-report build/sample-report
node Scripts/report_image.mjs build/sample-report/usage-report.html docs/images/usage-report.png
```

The sample generator uses the native renderer and never reads the local database. The same image
is included in `make readme-assets`. It uses the browser dependencies described above.
