<p align="center">
  <img src="Resources/AppIcon.png" alt="QuotaBar app logo" width="128">
</p>

<h1 align="center">QuotaBar</h1>

<p align="center">
  <a href="README.md"><kbd>English</kbd></a>
  <a href="README.zh-CN.md"><kbd>简体中文</kbd></a>
</p>

A macOS menu bar app for checking Codex and Claude quota, reset times, local token usage, and estimated cost.

[Install](#install) · [First launch](#first-launch) · [Quota](#how-quota-tracking-works) · [Cost](#how-cost-tracking-works) · [Reports](#exporting-a-usage-report) · [Development](#build-and-develop) · [Troubleshooting](#troubleshooting)

<p align="center">
  <img src="docs/images/hero.png" width="620" alt="Claude and Codex quota cards rendered with sample data">
</p>

Screenshots and animations use sample data, including model names, quota, and costs. View the card in [dark](docs/images/interactions/main-dark.png) or [light](docs/images/interactions/main-light.png) appearance.

## Features

- View remaining session and weekly quota, reset times, usage pace, and available credits for the selected provider.
- Chart local tokens and estimated cost by day and model, including matching OpenCode and Pi Agent OAuth usage under Codex.
- Price GPT-6 Astra Standard, Fast, and long-context usage with built-in rates, the [models.dev](https://models.dev) catalog, and editable Standard rates. Price edits are validated, and drafts stay available while the app is running.
- Keep the last good quota reading after a failed refresh, with its age and a retry action.
- Export 7 or 30 days of saved usage as an offline HTML report with Chinese and English views.
- Use keyboard shortcuts, Tokens / Cost switching, chart date selection, and macOS Reduce Motion.

## Install

QuotaBar requires macOS 14 or later. The Homebrew cask and release ZIP currently support Apple Silicon only. Prebuilt releases do not require Xcode or Swift.

Quota tracking uses OAuth credentials created by Codex CLI, Claude Code, or both on the same Mac. API-key-only sessions are not supported.

### Homebrew

```bash
brew install --cask softmaxe/tap/quota-bar
```

Update or remove it with:

```bash
brew upgrade --cask quota-bar
brew uninstall --cask quota-bar
```

To remove the app and its saved data:

```bash
brew uninstall --zap --cask quota-bar
```

### Manual download

Download the `arm64` ZIP from [GitHub Releases](https://github.com/softmaxe/quota-bar/releases), unzip it, and move `QuotaBar.app` to `/Applications`.

Each ZIP has a matching `.sha256` file. Verify it before unzipping:

```bash
shasum -a 256 -c QuotaBar-*-macos-arm64.zip.sha256
```

Releases are ad hoc signed, not notarized with an Apple Developer ID. If macOS blocks the first launch, try opening the app once, then go to **System Settings → Privacy & Security** and choose **Open Anyway**. As a fallback, after confirming the app is in `/Applications`, remove quarantine from this app only:

```bash
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

## First launch

QuotaBar reuses OAuth credentials created by the official CLIs. It has no separate login flow. Sign in through each CLI you want to track:

```bash
codex login
claude
```

Then open QuotaBar:

1. Click the menu bar icon to view quota and local cost.
2. Use the tabs at the top of the card to switch between Codex and Claude. Quota details appear below the selected provider.
3. Open **Settings** to choose a refresh interval or [edit model prices](#editing-model-prices).

If a provider is not signed in, choose **Copy command**, run the copied command in Terminal, then return and choose **Check sign-in**. Copying the command does not run it.

Reading Claude credentials may trigger a macOS Keychain prompt. If a manual **Refresh** receives HTTP 401, QuotaBar lets Claude Code attempt one short credential refresh. Automatic refreshes never start Claude Code.

## How quota tracking works

### Quota windows and usage pace

Each limited quota window shows the percentage left and its reset time. An unlimited session shows **Session ∞** and **No limit** instead of a countdown. Open the reset-time control and choose **Countdown** or **Clock time** for both limited windows. **Usage pace details** expands the reserve, deficit, and headroom calculation.

QuotaBar compares consumption with time elapsed. After three comparable weekly windows, it uses your recorded history for the weekly pace instead. Samples are kept for 56 days.

When a session or weekly window resets, the next open plays a brief bar animation lasting about 0.82 seconds. The headline immediately shows the new reading. The last reading and pending animation survive an app restart.

<p align="center">
  <img src="docs/images/quota-reset.gif" width="560" alt="Brief quota reset feedback while the headline keeps the new reading">
</p>

### Refresh and recovery

Choose manual refresh or an interval of 1, 2, 5, 15, or 30 minutes in Settings. The default is 5 minutes.

- Polling, opening the card, and clicking **Refresh** update only the selected provider. Switching tabs requests an update for the newly selected provider.
- Each provider has a one-minute refresh cooldown. A server rate limit can extend the wait.
- An explicit Claude credential-recovery action can bypass the local cooldown, but still respects the server limit.

A failed refresh keeps the last good quota and shows its age and recovery instructions at the top. The retry control shows the remaining wait when a cooldown applies. Local scanning has its own progress and **Retry local scan** action.

<table align="center">
  <tr><th>Sign-in guidance</th><th>Refresh failure with saved quota</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/interactions/sign-in.png" width="280" alt="Codex sign-in card with a copyable CLI command and Check sign-in button"></td>
    <td valign="top"><img src="docs/images/interactions/refresh-failed.png" width="280" alt="Refresh warning above saved quota, with its age and retry countdown"></td>
  </tr>
</table>

### Menu bar and shortcuts

The menu bar robot shows the selected provider. It turns red when either the session or weekly window has 10% or less left. It dims after a failed refresh and fades further when no data is available.

<p align="center">
  <img src="docs/images/menu-bar-icons.png" width="440" alt="Menu bar robot states: normal, running low, refresh failed, and no data">
</p>

The icon is Material Design Icons' `robot-excited`.

The card uses a native popover. Tall content scrolls while the actions at the bottom stay visible. Each time you reopen the card, it starts with collapsed details at the current content height. Use these shortcuts while the card is open:

| Shortcut | Action |
| --- | --- |
| ⌘1 / ⌘2 | Show Codex / Claude |
| ⌘R | Refresh or check sign-in, when available |
| ⌘, | Open settings |
| ⌘Q | Quit, with a prompt for unsaved price edits |
| Esc | Close the card |

<details>
<summary>Mouse, tab, and motion behavior</summary>

The equal-width provider tabs show a name and color dot. The selected tab has a highlighted background and a bold name. Hovering the other tab adds a subtle background and brightens its dot without making the name bold. Labels stay in place when you switch.

The card opens on left mouse-down and closes immediately when you click the icon again. Right clicks toggle it on mouse-up. Custom buttons respond as you press them; tab selection settles within 180 ms, and disclosure feedback within 160 ms. Rows appear together without a stagger. Reduce Motion removes custom transitions while preserving the controls and their pressed and selected states.

</details>

## How cost tracking works

QuotaBar calculates token and cost totals from local session data. It does not use a billing API.

### Reading the chart

Choose **Tokens** or **Cost** using the selector above the chart. The chart shows ten consecutive calendar days, while the totals cover the last 30 days. Hover to preview a day, click to hold that date, or use Left and Right Arrow when a date is focused. **Model breakdown** opens the complete model list for that day.

Once a date is pinned, click another column or use the arrow keys to change it. Close and reopen the card to return to hover previews. Opening **Model breakdown** also keeps its date fixed while you inspect the rows.

Missing information has a separate display from zero usage:

| Display | Meaning |
| --- | --- |
| **0** or **$0.00** | The scanned value is zero at the displayed precision. Missing prices have a separate status. |
| **—**, **Not scanned yet** | The date is later than the last completed scan and has no recorded usage yet. |
| **—**, **Unpriced** | Usage is recorded, but no cost can be estimated from its model rates. |
| **Partial estimate** | The amount includes priced usage only; unpriced usage is excluded. |

Open **Settings → Pricing** to add missing rates for future usage. Changing units preserves the selected date and updates the bar heights and readings together.

<p align="center">
  <img src="docs/images/chart-hover.gif" width="560" alt="Chart date previews with token totals and a collapsed Model breakdown">
</p>

### Data sources

| Source | Local data |
| --- | --- |
| Codex | `$CODEX_HOME/sessions` and `$CODEX_HOME/archived_sessions`, or the same paths under `~/.codex` |
| Claude | `$CLAUDE_CONFIG_DIR/projects`, or `~/.claude/projects` and `~/.config/claude/projects` |
| OpenCode | `$OPENCODE_DATA_HOME/opencode.db`, `$XDG_DATA_HOME/opencode/opencode.db`, or `~/.local/share/opencode/opencode.db` |
| Pi Agent | `$PI_CODING_AGENT_SESSION_DIR`, `$PI_CODING_AGENT_DIR/sessions`, or `~/.pi/agent/sessions` |

OpenCode data is included only when its `openai` provider uses OAuth and its account ID matches the current Codex account. Other providers, API-key sessions, and account mismatches are ignored. OpenCode totals do not affect quota bars.

Pi Agent data follows the same rule. Only `openai-codex` assistant usage from a matching OAuth account is included. Pi Agent totals do not affect quota bars, and their cost is estimated from QuotaBar's model prices rather than treated as an OpenAI billing statement.

### Saved history

The first scan of a large history may take time. QuotaBar stores usage in SQLite, recording the day, model, source tool, token counts, and estimated cost, along with identifiers and scan positions for deduplication.

Deleting source sessions does not delete recorded usage, even after restarting QuotaBar. Records older than the chart's ten-day and totals' 30-day windows remain stored. Sessions deleted before QuotaBar scanned them cannot be recovered.

<details>
<summary>Incremental scanning and database migration</summary>

Codex and Claude resume from the last byte read. OpenCode and Pi Agent deduplicate records by stable IDs. Standard Codex rollout UUIDs prevent archive moves and copies from counting twice. Codex also caches the active model, service tier, and last token totals, so appending to a long session does not replay earlier records.

On first use, QuotaBar copies any existing cost database from `~/Library/Caches/QuotaBar/cost-usage/` to the [persistent location](#privacy-and-network-access), including committed SQLite WAL data. The old cache remains intact. Scanner upgrades preserve recorded history instead of rebuilding it from source logs.

</details>

### Pricing rules

- Standard rates use manual overrides first, then the catalog, then the [built-in pricing table](Sources/QuotaBarCore/Cost/CostPricing.swift).
- Astra falls back to its complete built-in row when a catalog entry omits cache or long-context rates.
- Codex Fast usage uses a separate built-in table and ignores manual overrides and catalog rates. A Fast model without an entry stays unpriced.

The pricing catalog is cached for 24 hours. Manual rate changes apply to newly recorded usage. Past totals keep the prices used when they were scanned.

Cost totals are estimates. Provider billing rules, cache accounting, and price changes can make them differ from an invoice.

## Exporting a usage report

1. Open **Settings → Export**, or press ⌘3 while the settings window is active.
2. Choose **Last 7 days** or **Last 30 days**.
3. Leave **Open after export** selected to open the result immediately.
4. Choose **Export Report…** and select a destination. If the period has no saved usage, QuotaBar reports that before opening the Save panel.

<p align="center">
  <img src="docs/images/report-export.png" width="760" alt="Bilingual offline usage report rendered with sample data">
</p>

### Report contents

The report is one self-contained HTML file that works offline and supports Chinese and English. It covers every eligible source already stored in QuotaBar's SQLite history: Codex, Claude, matching OpenCode OAuth usage, and matching Pi Agent OAuth usage.

The page shows a daily usage line chart, stored cost estimates by model, token and cache composition, and expandable tables with exact token totals and displayed costs.

### Snapshot and privacy

Export reads saved data. It does not refresh quota, rescan session logs, update prices, or make model or network requests.

- Costs keep the estimates saved when each record was scanned and can differ from a provider bill.
- Unpriced tokens are excluded from the cost total. The report marks partial pricing coverage.
- QuotaBar does not store cache cost as a separate USD amount, so the report does not reconstruct one.

An exported file contains the selected period, capture time and timezone, source and model names, token counts, unpriced-token counts, and stored cost totals. Prompt, response, and reasoning text are not included. See [Usage report export](docs/usage-report-export.md) for the full data contract and developer checks.

## Editing model prices

Open **Settings → Pricing**. Rates are in USD per million tokens. Expand a model row to edit its one-hour cache write rate, long-context threshold, and rates above that threshold.

The table lists supported API models and other models from your local history that have no available rate. It is not a complete catalog of every model you have used. Click a column heading to sort its values; the reset-order button restores the API model order and puts the most-used models first in **Others**.

<p align="center">
  <img src="docs/images/settings-pricing.png" width="620" alt="Pricing settings with editable rates, expanded long-context fields, and per-model action menus">
</p>

- Rates must be finite numbers at least zero. A long-context threshold, when set, must be a positive whole token count. Invalid fields show an error and disable **Save**.
- **Save** shows progress and a saved or failed result. A failed save keeps your edits. Switching settings tabs or reopening the settings window also keeps the draft while the app is running.
- **Discard** returns to the last saved rates. To remove a manual override, open the model's **…** menu and choose **Restore default rate**, or **Clear custom rate** when no default exists, then save. These actions change the draft first.
- Quitting with a valid draft offers **Save**, **Discard**, or **Cancel**. An invalid draft must be corrected before saving; **Cancel** returns to editing.

<details>
<summary>Invalid price example</summary>

<p align="center">
  <img src="docs/images/interactions/pricing-invalid.png" width="620" alt="A nonnumeric input rate with an inline error, an error summary, and Save disabled">
</p>

</details>

Saved rates apply to newly recorded usage. Existing history keeps the prices used when it was scanned, including previously unpriced usage.

## Privacy and network access

QuotaBar reads CLI credentials and parses local session records, but it does not write to CLI credential stores itself. A manual Claude credential recovery can launch Claude Code, which may update its own credentials. QuotaBar uses timestamps, model names, token counts, stable record IDs, and the account IDs needed to match OAuth sessions. Prompt, response, and reasoning text are not stored in QuotaBar's usage history or uploaded.

The app stores its own data here:

```text
~/Library/Application Support/QuotaBar/usage-history.json
~/Library/Application Support/QuotaBar/pricing-overrides.json
~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite
~/Library/Caches/QuotaBar/model-pricing/
~/Library/Preferences/com.quotabar.app.plist
```

Codex quota requests use the `chatgpt_base_url` in `$CODEX_HOME/config.toml`, if set, or the default ChatGPT endpoint. QuotaBar also contacts `auth.openai.com` to refresh Codex tokens, `api.anthropic.com` for Claude quota, and `models.dev` for model pricing. It does not send local session records to these services.

## Build and develop

Building requires the Swift 6 toolchain from Xcode or the Command Line Tools. The project uses Swift Package Manager and has no Xcode project.

```bash
git clone https://github.com/softmaxe/quota-bar.git
cd quota-bar
make app
open build/QuotaBar.app
```

<details>
<summary>If Command Line Tools reports a missing SwiftUIMacros plugin</summary>

Use the installed Xcode toolchain for that command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
make app
```

</details>

### Common commands

| Command | Purpose |
| --- | --- |
| `make build` | Build the debug binary. |
| `make run` | Build and run in the foreground. |
| `make test` | Run core assertions and UI/policy verifiers. |
| `make probe` | Check both provider integrations. |
| `make probe-cost` | Rescan local logs; may refresh model prices. |
| `make benchmark-startup` | Measure status-item construction offline in a debug build. |
| `make benchmark-cost` | Benchmark Codex scans with offline pricing; reads local logs. |
| `make benchmark-cost PROVIDER=claude` | Benchmark Claude with the same offline pricing. |
| `make logs` | Stream logs for `com.quotabar.app`. |
| `make readme-assets` | Rebuild screenshots, state examples, and GIFs. |
| `make clean` | Remove build output. |

`make probe` prints account and usage metadata. Review its output before sharing it.

### UI previews and screenshots

To preview interactions with sample quota and cost data, run:

```bash
make build
.build/debug/QuotaBar --preview-interface loaded
```

Use `signed-out` or `stale` instead of `loaded` to inspect those states. Preview uses isolated preferences and temporary history, with no credential access, provider requests, or real log scans. Choose **Quit** in the preview to clear its temporary data. It can run alongside the installed app, so an additional menu bar icon is expected.

`make readme-assets` renders both READMEs' shared images from the current views with sample data, including the sign-in, refresh-failure, and invalid-price states. Regenerate them after changing the UI.

Asset generation requires ffmpeg. The HTML report image also needs Node.js, Playwright, and a Chromium browser; see [report development checks](docs/usage-report-export.md#verification). The [implementation notes](docs/design-implementation.md) describe the rendering commands and verification limits.

### Packaging and releases

To create a test package, run **Build and Release** from the repository's **Actions** tab and select the branch to build. Manual runs upload a development ZIP and SHA-256 file as workflow artifacts without publishing a release.

To publish a release, push a tag matching `vMAJOR.MINOR.PATCH`. The tag supplies the app's version. The workflow tests and packages an `arm64` ZIP, verifies its signature, version, architecture, and checksum, publishes the GitHub Release, and then updates `softmaxe/homebrew-tap`. Tagged runs require the repository's `TAP_GITHUB_TOKEN` secret. Check both **Release** and **Update Homebrew tap** before treating the release process as complete.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Provider is not signed in | Copy the command in the card, complete the CLI login, then choose **Check sign-in**. Use `make probe` for the raw error. |
| Data is stale or refresh returns HTTP 429 | Read the warning above the saved quota. Wait for the retry countdown, then retry; a server limit may last longer than one minute. |
| Local scan failed | Read the local usage error and choose **Retry local scan**. Confirm the CLI writes session logs to the paths above. |
| Cost shows Unpriced or Partial estimate | Add missing model rates in **Settings → Pricing** for newly recorded usage. Existing history keeps its original pricing. |
| A date shows Not scanned yet | Wait for the local scan to finish. This means the date is not covered yet, rather than zero usage. |
| Price changes cannot be saved | Correct the marked fields. If saving failed, the draft remains available to retry or discard. |
| OpenCode usage is missing | Confirm OpenCode uses `openai` OAuth with the same account as Codex. Check **Settings → Pricing** for database or authentication errors. |
| Pi Agent usage is missing | Confirm Pi Agent uses `/login openai-codex` with the same account as Codex. Check **Settings → Pricing** for session or authentication errors. |

## Limitations

- Prebuilt releases and the Homebrew cask support Apple Silicon only. Release ZIPs are ad hoc signed and not notarized.
- Claude credential recovery runs only after a manual **Refresh** and may still require opening Claude Code for interactive sign-in.
- Cost figures come from local logs and are not billing statements.
- OpenCode does not save the authentication method for each historical request. QuotaBar cannot reconstruct an OAuth to API key to OAuth switch that happened while it was not running.

## License

QuotaBar is licensed under [AGPL-3.0](LICENSE). Code adapted from CodexBar remains available under its MIT terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgements

QuotaBar is a rebuild of [CodexBar](https://github.com/steipete/CodexBar) and uses its ideas and implementation details. Copyright © 2026 Peter Steinberger.
