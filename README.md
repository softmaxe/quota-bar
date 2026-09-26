<p align="center">
  <img src="Resources/AppIcon.png" alt="QuotaBar app logo" width="96">
</p>

<h1 align="center">QuotaBar</h1>

<p align="center">
  <a href="README.md"><kbd>English</kbd></a>
  <a href="README.zh-CN.md"><kbd>简体中文</kbd></a>
</p>

Check Codex and Claude quota, reset times, local token usage, and estimated API cost from the macOS menu bar.

[Install](#install) · [First launch](#first-launch) · [Quota](#how-quota-tracking-works) · [Cost](#how-cost-tracking-works) · [Reports](#exporting-a-usage-report) · [Pricing](#editing-model-prices) · [Development](#build-and-develop) · [Troubleshooting](#troubleshooting)

https://github.com/user-attachments/assets/f46bd989-6a1d-4de5-a88a-94dbd85d790f

The video, screenshots, and animations use sample data. The app is in English; exported reports support Chinese and English. View the card in [dark](docs/images/interactions/main-dark.png) or [light](docs/images/interactions/main-light.png) appearance.

## Features

- Track session and weekly quota, reset times, usage pace, and Codex credits. Failed refreshes keep the last good reading.
- View tokens and estimated API cost by day and model. Include OpenCode and Pi Agent OAuth usage that matches your Codex account.
- Estimate Standard, Fast, and long-context costs with the bundled price book. Edit Standard rates in Settings.
- Export the last 7 or 30 days of saved usage as an offline HTML report with Chinese and English views.

## Install

Requires macOS 14 or later. Prebuilt releases and the Homebrew cask support Apple Silicon. They do not require Xcode or Swift.

Quota tracking requires an OAuth login through Codex CLI or Claude Code on the same Mac. An API key cannot provide quota readings.

### Homebrew

```bash
brew install --cask softmaxe/tap/quota-bar
```

<details>
<summary>Update or uninstall</summary>

```bash
brew upgrade --cask quota-bar
brew uninstall --cask quota-bar
```

To remove the app and its saved data:

```bash
brew uninstall --zap --cask quota-bar
```

</details>

<details>
<summary>Manual download and first-launch security prompt</summary>

Download the `arm64` ZIP from [GitHub Releases](https://github.com/softmaxe/quota-bar/releases), unzip it, and move `QuotaBar.app` to `/Applications`.

Download the matching `.sha256` file into the same directory as the ZIP. Run this command there before unzipping:

```bash
shasum -a 256 -c QuotaBar-*-macos-arm64.zip.sha256
```

Releases are ad hoc signed, not notarized with an Apple Developer ID. If macOS blocks the first launch, try opening the app once, then go to **System Settings → Privacy & Security** and choose **Open Anyway**. As a fallback, after confirming the app is in `/Applications`, remove quarantine from this app only:

```bash
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

</details>

## First launch

Sign in through each CLI you want to track. QuotaBar reuses its credentials and has no separate login flow:

```bash
codex login
claude
```

Open QuotaBar, click its menu bar icon, and select Codex or Claude. Open [Settings](docs/images/settings-general.png) to choose a refresh interval or [edit model prices](#editing-model-prices).

If a provider is not signed in, choose **Copy command**, run it in Terminal, then return and choose **Check sign-in**.

QuotaBar reads Codex credentials from `$CODEX_HOME/auth.json`, or `~/.codex/auth.json` by default. It reads Claude credentials from the `Claude Code-credentials` entry in macOS Keychain.

Reading Claude credentials may trigger a macOS Keychain prompt. If a manual **Refresh** receives HTTP 401, QuotaBar lets Claude Code attempt one short credential refresh. Automatic refreshes never start Claude Code.

## How quota tracking works

<p align="center">
  <img src="docs/images/hero.png" width="620" alt="Claude and Codex quota cards rendered with sample data">
</p>

### Quota windows and usage pace

Each quota window shows the percentage left and its reset time. Choose **Countdown** or **Clock time** to change the reset-time display for both windows. Unlimited sessions show **Session ∞** and **No limit**. An empty window shows **Limit reached**.

Expand **Usage pace details** for reserve, deficit, and headroom. QuotaBar compares usage with time elapsed. After at least three comparable recorded weekly windows, it also uses that history to estimate weekly pace. Quota samples are kept for 56 days.

After QuotaBar detects a reset, opening the card plays a brief bar animation while the headline shows the new reading. The app respects macOS Reduce Motion.

<details>
<summary>Quota reset animation</summary>

<p align="center">
  <img src="docs/images/quota-reset.gif" width="560" alt="Brief quota reset feedback while the headline keeps the new reading">
</p>

</details>

### Refresh and recovery

Choose manual refresh or an interval of 1, 2, 5, 15, or 30 minutes in Settings. The default is 5 minutes.

- Polling, opening the card, and clicking **Refresh** update only the selected provider. Switching tabs requests an update for the newly selected provider.
- Each provider has a one-minute refresh cooldown. A server rate limit can extend the wait.
- An explicit Claude credential-recovery action can bypass the local cooldown, but still respects the server limit.

A failed refresh keeps the last good quota and shows its age and recovery instructions at the top. The retry control shows the remaining wait when a cooldown applies. Local scanning has its own progress and **Retry local scan** action.

<details>
<summary>Sign-in and refresh-failure examples</summary>

<table align="center">
  <tr><th>Sign-in guidance</th><th>Refresh failure with saved quota</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/interactions/sign-in.png" width="280" alt="Codex sign-in card with a copyable CLI command and Check sign-in button"></td>
    <td valign="top"><img src="docs/images/interactions/refresh-failed.png" width="280" alt="Refresh warning above saved quota, with its age and retry countdown"></td>
  </tr>
</table>

</details>

### Menu bar and shortcuts

The menu bar robot shows the selected provider's status. It turns red when either quota window has 10% or less left, unless that window's reset time has passed. It dims after a failed refresh and fades further when no data is available.

<p align="center">
  <img src="docs/images/menu-bar-icons.png" width="440" alt="Menu bar robot states: normal, running low, refresh failed, and no data">
</p>

The icon is Material Design Icons' `robot-excited`. The card scrolls when needed and reopens with details collapsed. These shortcuts work while the card is open:

| Shortcut | Action |
| --- | --- |
| ⌘1 / ⌘2 | Show Codex / Claude |
| ⌘R | Refresh or check sign-in, when available |
| ⌘, | Open settings |
| ⌘Q | Quit, with a prompt for unsaved price edits |
| Esc | Close the card |

## How cost tracking works

QuotaBar counts tokens in local session logs and estimates what that usage would cost at API rates. These estimates are not subscription charges or billing statements.

### Reading the chart

Choose **Tokens** or **Cost** above the chart. The chart shows the last 10 calendar days; the summary shows today and the last 30 days.

Hover to preview a day, click to pin it, or use the Left and Right Arrow keys when a date is focused. Expand **Model breakdown** to see that day's models and keep the date fixed. Reopen the card to resume hover previews. Switching units keeps the selected date.

The chart distinguishes zero usage from missing data:

| Display | Meaning |
| --- | --- |
| **0** or **$0.00** | The value rounds to zero. The chart shows a solid gray stub. Missing prices are marked separately. |
| **—**, **Not scanned yet** | The date is later than the last completed scan and has no recorded usage. The chart shows a dashed stub. |
| **—**, **Unpriced** | Usage is recorded, but no rate applies. Cost view shows a dashed stub. |
| **Partial estimate** | The amount includes priced usage only; unpriced usage is excluded. |

For missing Standard rates, use **Settings → Pricing**. Fast usage needs a multiplier in the bundled price book and cannot be priced with a manual override.

<details>
<summary>Chart date previews</summary>

<p align="center">
  <img src="docs/images/chart-hover.gif" width="560" alt="Chart date previews with token totals and a collapsed Model breakdown">
</p>

</details>

### Data sources

| Source | Local data |
| --- | --- |
| Codex | `$CODEX_HOME/sessions` and `$CODEX_HOME/archived_sessions`, or the same paths under `~/.codex` |
| Claude | `$CLAUDE_CONFIG_DIR/projects`, or `~/.claude/projects` and `~/.config/claude/projects` |
| OpenCode | `$OPENCODE_DATA_HOME/opencode.db`, `$XDG_DATA_HOME/opencode/opencode.db`, or `~/.local/share/opencode/opencode.db` |
| Pi Agent | `$PI_CODING_AGENT_SESSION_DIR`, `$PI_CODING_AGENT_DIR/sessions`, or `~/.pi/agent/sessions` |

For OpenCode `openai` usage and Pi Agent `openai-codex` assistant usage, QuotaBar checks each app's current OAuth credentials against the Codex account. Matching usage counts toward Codex totals. Other providers, API-key credentials, and account mismatches are excluded. These totals do not affect quota bars. See [Limitations](#limitations) for historical OpenCode authentication changes.

### Saved history

The first scan of a large history may take time. QuotaBar saves token counts, dates, models, sources, and pricing tiers in SQLite, along with record IDs and scan positions. It calculates costs when reading or exporting that usage.

Saved usage survives source-session deletion and app restarts, including records older than 30 days. Sessions deleted before scanning cannot be recovered.

<details>
<summary>Incremental scanning and database migration</summary>

Codex and Claude resume from the last byte read. OpenCode and Pi Agent deduplicate records by stable IDs. Codex rollout UUIDs prevent archive moves and copies from counting twice.

Scanner upgrades preserve recorded history instead of rebuilding it from source logs.

</details>

### Pricing rules

- Standard usage uses your saved override, if any. Otherwise, it uses the bundled [price book](Sources/QuotaBarCore/Resources/Pricing/price-book.json).
- The price book stores rates in dated periods. Each day's usage uses that day's rates. An override replaces Standard rates for every recorded day of its model.
- Codex Fast usage multiplies the price book's rates by that period's Fast multiplier. It ignores overrides. Without a Fast multiplier, usage stays unpriced.
- Long-context rates apply when a request's input and cache tokens exceed its threshold. QuotaBar records that classification during scanning; later threshold changes do not reclassify saved usage.

Provider billing rules, cache accounting, and price changes can make estimates differ from an invoice. See [Maintaining the price book](docs/pricing.md) to update bundled rates.

## Exporting a usage report

1. Open **Settings → Export**, or press ⌘3 while the settings window is active.
2. Choose **Last 7 days** or **Last 30 days**.
3. Leave **Open after export** selected to open the result immediately.
4. Choose **Export Report…** and select a destination. If the period has no saved usage, QuotaBar reports that before opening the Save panel.

<p align="center">
  <img src="docs/images/report-export.png" width="760" alt="English view of the offline usage report, with a Chinese/English switch and sample data">
</p>

The report is a single offline HTML file with a Chinese/English switch. It includes saved Codex and Claude usage, plus eligible OpenCode and Pi Agent usage, for the selected period. Charts and expandable tables show daily usage, cost by model, and token and cache composition.

Export reads saved data without refreshing quota, rescanning logs, or making network requests. It uses the same pricing rules as the card and marks unpriced usage. Totals include cache costs; the report lists cache token counts without a separate cache cost.

The file includes the period, capture time, timezone, sources, models, token counts, and estimated costs. It excludes prompts, responses, reasoning text, credentials, and account IDs. See [Usage report export](docs/usage-report-export.md) for the full data format and checks.

## Editing model prices

Open **Settings → Pricing** to override Standard rates in USD per million tokens. Expand a model row for one-hour cache write rates, the long-context threshold, and rates above it.

The table lists supported API models and unpriced models found locally. Click a column heading to sort; reset the order to restore the API model list and sort **Others** by usage.

<p align="center">
  <img src="docs/images/settings-pricing.png" width="620" alt="Pricing settings with editable rates, expanded long-context fields, and per-model action menus">
</p>

- Rates must be finite and nonnegative. A long-context threshold must be a positive whole token count. You must set it before saving any rates above the threshold. Invalid fields disable **Save**.
- **Save** shows progress and its result. Drafts survive failed saves, tab switches, and closing Settings while the app is running. **Discard** restores the last saved rates.
- To remove an override, choose **Restore default rate** or **Clear custom rate** in the model's **…** menu, then save.
- Quitting with a valid draft offers **Save**, **Discard**, or **Cancel**. Invalid drafts must be corrected before saving.

<details>
<summary>Invalid price example</summary>

<p align="center">
  <img src="docs/images/interactions/pricing-invalid.png" width="620" alt="A nonnumeric input rate with an inline error, an error summary, and Save disabled">
</p>

</details>

Saving reprices the model's recorded Standard usage, including previously unpriced usage. Restoring the default returns it to the price book's dated rates. Fast usage keeps using the price book. Threshold changes affect only newly scanned requests.

## Privacy and network access

QuotaBar reads CLI credentials and local session records. It does not write to CLI credential stores. Manual Claude recovery can launch Claude Code, which may update its own credentials.

QuotaBar uses timestamps, models, token counts, record IDs, and account IDs needed to match OAuth sessions. It does not store prompts, responses, or reasoning text in its usage history or upload them.

<details>
<summary>Local storage paths</summary>

```text
~/Library/Application Support/QuotaBar/usage-history.json
~/Library/Application Support/QuotaBar/pricing-overrides.json
~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite
~/Library/Preferences/com.quotabar.app.plist
```

</details>

Codex quota requests use the `chatgpt_base_url` in `$CODEX_HOME/config.toml`, if set, or the default ChatGPT endpoint. QuotaBar also contacts `auth.openai.com` to refresh Codex tokens, and `api.anthropic.com` for Claude quota. Model prices ship with the app and are not fetched. It does not send local session records to these services.

## Build and develop

Building requires full Xcode with a Swift 6 toolchain. The project uses Swift Package Manager. `Scripts/swift.sh` defaults to `/Applications/Xcode.app/Contents/Developer` without changing the global `xcode-select` setting.

The release workflow requires the macOS 27 SDK for native menu bar sessions on macOS 27. Local builds with older SDKs use the legacy menu bar handling. The minimum runtime remains macOS 14.

```bash
git clone https://github.com/softmaxe/quota-bar.git
cd quota-bar
make app
open build/QuotaBar.app
```

To use another full Xcode installation, set `DEVELOPER_DIR` to its `Contents/Developer` directory:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
make app
```

<details>
<summary>Development commands</summary>

| Command | Purpose |
| --- | --- |
| `make build` | Build the debug binary. |
| `make run` | Build and run in the foreground. |
| `make test` | Run core assertions and UI/policy verifiers. |
| `make probe` | Check both provider integrations. |
| `make probe-cost` | Rescan local logs and print cost totals. |
| `make benchmark-startup` | Measure status-item construction offline in a debug build. |
| `make benchmark-cost` | Benchmark Codex scans with offline pricing; reads local logs. |
| `make benchmark-cost PROVIDER=claude` | Benchmark Claude with the same offline pricing. |
| `make logs` | Stream logs for `com.quotabar.app`. |
| `make readme-assets` | Rebuild screenshots, state examples, and GIFs. |
| `make demo-video` | Render the README demo videos with music. |
| `make clean` | Remove build output. |

`make probe` prints account and usage metadata. Review its output before sharing it.

</details>

<details>
<summary>UI previews and screenshots</summary>

To preview interactions with sample quota and cost data, run:

```bash
make build
.build/debug/QuotaBar --preview-interface loaded
```

Use `signed-out` or `stale` instead of `loaded` to inspect those states. Preview uses isolated preferences and temporary history. It does not read credentials, contact providers, or scan real logs. Choose **Quit** in the preview to clear its temporary data. Running it alongside the installed app adds a second menu bar icon.

`make readme-assets` renders both READMEs' shared images from the current views with sample data, including the sign-in, refresh-failure, and invalid-price states. Regenerate them after changing the UI.

`make demo-video` renders [docs/demo](docs/demo) to `build/demo/quotabar-demo-en.mp4` and `build/demo/quotabar-demo-zh.mp4`. It requires ffmpeg, Node.js, `playwright-cli`, and Brave. Set `CHROMIUM_PATH` to use another Chromium browser. The first run downloads instrument samples. Upload new videos as attachments in a GitHub comment and replace the links at the top of both READMEs.

Image generation requires ffmpeg. The report screenshot also needs Node.js and Playwright from `playwright-cli` or `PLAYWRIGHT_MODULE`. It uses Brave by default, or the browser at `CHROMIUM_PATH`. See [report development checks](docs/usage-report-export.md#verification) and [rendering notes](docs/design-implementation.md).

</details>

<details>
<summary>Packaging and releases</summary>

To create a test package, run **Build and Release** from the repository's **Actions** tab and select the branch to build. Manual runs upload a development ZIP and SHA-256 file as workflow artifacts without publishing a release.

To publish a release, push a tag matching `vMAJOR.MINOR.PATCH`. The tag supplies the app's version. Local `make app` builds use the nearest reachable release tag, or `0.0.0` if none exists. Set `VERSION` to override it.

The workflow runs tests, packages an `arm64` ZIP, and verifies its signature, version, architecture, and checksum. It then publishes a GitHub Release and updates `softmaxe/homebrew-tap`. Tagged runs require the repository's `TAP_GITHUB_TOKEN` secret. Both **Release** and **Update Homebrew tap** must succeed.

</details>

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Provider is not signed in | Copy the command in the card, complete the CLI login, then choose **Check sign-in**. Use `make probe` for the raw error. |
| Data is stale or refresh returns HTTP 429 | Read the warning above the saved quota. Wait for the retry countdown, then retry; a server limit may last longer than one minute. |
| Local scan failed | Read the local usage error and choose **Retry local scan**. Confirm the CLI writes session logs to the paths above. |
| Cost shows Unpriced or Partial estimate | Add missing Standard rates in **Settings → Pricing**. Fast usage needs a multiplier in the bundled price book. |
| A date shows Not scanned yet | Wait for the local scan to finish. This means the date is not covered yet, rather than zero usage. |
| Price changes cannot be saved | Correct the marked fields. If saving failed, the draft remains available to retry or discard. |
| OpenCode usage is missing | Confirm OpenCode uses `openai` OAuth with the same account as Codex. Check **Settings → Pricing** for database or authentication errors. |
| Pi Agent usage is missing | Confirm Pi Agent uses `/login openai-codex` with the same account as Codex. Check **Settings → Pricing** for session or authentication errors. |

## Limitations

- Prebuilt releases and the Homebrew cask support Apple Silicon only. Release ZIPs are ad hoc signed and not notarized.
- Claude credential recovery runs only after a manual **Refresh** and may still require opening Claude Code for interactive sign-in.
- Cost figures come from local logs and are not billing statements.
- OpenCode does not save the authentication method for each historical request. QuotaBar cannot reconstruct an OAuth to API key to OAuth switch that happened while it was not running.

## License and acknowledgements

QuotaBar is licensed under [AGPL-3.0](LICENSE). Code adapted from CodexBar remains available under its MIT terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

QuotaBar is a rebuild of [CodexBar](https://github.com/steipete/CodexBar) and uses its ideas and implementation details. Copyright © 2026 Peter Steinberger.
