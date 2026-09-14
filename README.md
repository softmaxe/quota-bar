<p align="center">
  <img src="Resources/AppIcon.png" alt="QuotaBar app logo" width="180">
</p>

<h1 align="center">QuotaBar</h1>

<p align="center">
  <a href="README.md"><kbd>English</kbd></a>
  <a href="README.zh-CN.md"><kbd>简体中文</kbd></a>
</p>

A macOS menu bar app for checking Codex and Claude quota, reset times, local token usage, and estimated cost.

<p align="center">
  <img src="docs/images/hero.png" width="620" alt="Claude and Codex quota cards rendered with sample data">
</p>

The screenshots and animations use sample data rendered by the app's views. Their model names, quota, and costs are examples. View the card in [dark](docs/images/interactions/main-dark.png) or [light](docs/images/interactions/main-light.png) appearance.

QuotaBar supports Codex and Claude in one menu bar item. It is a rebuild of [CodexBar](https://github.com/steipete/CodexBar).

## Features

- Shows remaining session and weekly quota, reset time, usage pace, and credits when available.
- Charts local Codex and Claude token use and estimated cost by day and model.
- Prices GPT-6 Astra Standard, Fast, and long-context usage, with editable Standard rates.
- Includes matching OpenCode and Pi Agent OpenAI OAuth usage under Codex.
- Shows one provider at a time as a robot in the menu bar. QuotaBar refreshes the selected provider; switching tabs requests a refresh for the newly selected provider, subject to its cooldown.
- Uses built-in pricing, the public [models.dev](https://models.dev) catalog, and optional manual rate overrides.
- Keeps the last good quota reading when a refresh fails, with its age and a retry action.
- Provides keyboard shortcuts, a visible Tokens / Cost selector, and selectable chart dates.
- Validates price edits, preserves drafts, and asks how to handle unsaved changes before quitting.
- Disables motion when macOS Reduce Motion is enabled.

<p align="center">
  <img src="docs/images/menu-bar-icons.png" width="440" alt="Menu bar robot states: normal, running low, refresh failed, and no data">
</p>

The robot is the `robot-excited` mark from Material Design Icons, the same glyph Omarchy's agents widget puts in its bar. It turns red when the provider you are viewing has 10% or less left in its session or weekly window. The robot dims when a refresh fails and fades further when there is no data yet.

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

- Click the menu bar icon to view quota and local cost.
- Switch between Codex and Claude using the equal-width tabs at the top of the card. Each tab shows the provider's name and color; quota percentages appear in the selected provider's details below.
- Open **Settings** to choose a refresh interval or edit model rates. See [Editing model prices](#editing-model-prices) for saving, validation, and restoring defaults.
- If a provider is not signed in, choose **Copy command**, run the copied command in Terminal, then return and choose **Check sign-in**. Copying the command does not run it.

The selected tab has a highlighted background and a bold name. Hovering the other tab adds a subtle background and brightens its dot without making the name bold. Labels stay in place when you switch.

Reading Claude credentials may trigger a macOS Keychain prompt. If a manual `Refresh` receives HTTP 401, QuotaBar lets Claude Code attempt one short credential refresh. Automatic refreshes never start Claude Code.

## How quota tracking works

Each available quota window shows the percentage left and its reset time. Open the reset-time control and choose **Countdown** or **Clock time** for both windows. **Usage pace details** expands the reserve, deficit, and headroom calculation.

QuotaBar compares consumption with time elapsed. After three comparable weekly windows, it uses your recorded history for the weekly pace instead. Samples are kept for 56 days.

Background refresh can be manual or every 1, 2, 5, 15, or 30 minutes. The default is 5 minutes. Polling, opening the card, and clicking **Refresh** update only the selected provider. Switching tabs requests an update for the newly selected provider. Each provider has its own one-minute refresh cooldown. A server rate limit can extend the wait. An explicit Claude credential-recovery action can bypass the local cooldown, but it still respects the server limit.

When a session or weekly window resets, the next open plays a brief bar animation lasting about 0.82 seconds. The headline immediately shows the new reading. The last reading and pending animation survive an app restart.

The card uses a native popover. Tall content scrolls while the actions at the bottom stay visible. Use these shortcuts while the card is open:

| Shortcut | Action |
| --- | --- |
| ⌘1 / ⌘2 | Show Codex / Claude |
| ⌘R | Refresh or check sign-in, when available |
| ⌘, | Open settings |
| ⌘Q | Quit, with a prompt for unsaved price edits |
| Esc | Close the card |

A failed refresh keeps the last good quota and shows its age and recovery instructions at the top. The retry control shows the remaining wait when a cooldown applies. Local scanning has its own progress and **Retry local scan** action.

<table>
  <tr><th>Sign-in guidance</th><th>Refresh failure with saved quota</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/interactions/sign-in.png" width="280" alt="Codex sign-in card with a copyable CLI command and Check sign-in button"></td>
    <td valign="top"><img src="docs/images/interactions/refresh-failed.png" width="280" alt="Refresh warning above saved quota, with its age and retry countdown"></td>
  </tr>
</table>

<p align="center">
  <img src="docs/images/quota-reset.gif" width="560" alt="Brief quota reset feedback while the headline keeps the new reading">
</p>

## How cost tracking works

QuotaBar calculates token and cost totals from local session data. It does not use a billing API.

Choose **Tokens** or **Cost** using the selector above the chart. The chart shows ten consecutive calendar days, while the totals cover the last 30 days. Hover to preview a day, click to hold that date, or use Left and Right Arrow when a date is focused. **Model breakdown** opens the complete model list for that day.

Missing information has a separate display from zero usage:

| Display | Meaning |
| --- | --- |
| **0** or **$0.00** | The scanned value is zero at the displayed precision. Missing prices have a separate status. |
| **—**, **Not scanned yet** | The date is later than the last completed scan and has no recorded usage yet. |
| **—**, **Unpriced** | Usage is recorded, but no cost can be estimated from its model rates. |
| **Partial estimate** | The amount includes priced usage only; unpriced usage is excluded. |

Open **Settings → Pricing** to add missing rates for future usage. Changing units preserves the selected date.

<p align="center">
  <img src="docs/images/chart-hover.gif" width="560" alt="Chart date previews with token totals and a collapsed Model breakdown">
</p>

| Source | Local data |
| --- | --- |
| Codex | `$CODEX_HOME/sessions` and `$CODEX_HOME/archived_sessions`, or the same paths under `~/.codex` |
| Claude | `$CLAUDE_CONFIG_DIR/projects`, or `~/.claude/projects` and `~/.config/claude/projects` |
| OpenCode | `$OPENCODE_DATA_HOME/opencode.db`, `$XDG_DATA_HOME/opencode/opencode.db`, or `~/.local/share/opencode/opencode.db` |
| Pi Agent | `$PI_CODING_AGENT_SESSION_DIR`, `$PI_CODING_AGENT_DIR/sessions`, or `~/.pi/agent/sessions` |

OpenCode data is included only when its `openai` provider uses OAuth and its account ID matches the current Codex account. Other providers, API-key sessions, and account mismatches are ignored. OpenCode totals do not affect quota bars.

Pi Agent data follows the same rule. Only `openai-codex` assistant usage from a matching OAuth account is included. Pi Agent totals do not affect quota bars, and their cost is estimated from QuotaBar's model prices rather than treated as an OpenAI billing statement.

The first scan of a large history may take time. QuotaBar keeps a compact SQLite usage history with the day, model, harness, token counts, and estimated cost, plus identifiers and scan positions for deduplication. Codex and Claude resume from the last byte read, while OpenCode and Pi Agent deduplicate records by stable IDs. Deleting source sessions does not delete recorded usage, even after restarting QuotaBar. Standard Codex rollout UUIDs prevent archive moves and copies from counting twice. The totals cover the last 30 days and the chart shows the last ten calendar days; older records remain stored. The pricing catalog is cached for 24 hours. Manual rate changes apply to new usage only, so past totals keep the prices used when they were scanned.

On first use, QuotaBar copies any existing cost database from `~/Library/Caches/QuotaBar/cost-usage/` to the persistent location below, including committed SQLite WAL data. The old cache remains intact. Only usage already scanned can survive source deletion; sessions deleted before QuotaBar scanned them cannot be recovered. Scanner upgrades preserve recorded history instead of rebuilding it from source logs.

Codex also caches the active model, service tier, and last token totals, so appending to a long session does not replay its earlier records.

Standard rates use manual overrides first, then the catalog, then the [built-in pricing table](Sources/QuotaBarCore/Cost/CostPricing.swift). Astra falls back to its complete built-in row when a catalog entry omits cache or long-context rates. Codex Fast usage uses a separate built-in table and ignores manual overrides and catalog rates. A Fast model without an entry stays unpriced. These rules describe QuotaBar's estimates, not a guarantee of current provider pricing.

Cost totals are estimates. Provider billing rules, cache accounting, and price changes can make them differ from an invoice.

## Editing model prices

Open **Settings → Pricing**. Rates are in USD per million tokens. Expand a model row to edit its one-hour cache write rate, long-context threshold, and rates above that threshold.

<p align="center">
  <img src="docs/images/settings-pricing.png" width="620" alt="Pricing settings with editable rates, expanded long-context fields, and per-model action menus">
</p>

- Rates must be finite numbers at least zero. A long-context threshold, when set, must be a positive whole token count. Invalid fields show an error and disable **Save**.
- **Save** shows progress and a saved or failed result. A failed save keeps your edits. Switching settings tabs or reopening the settings window also keeps the draft while the app is running.
- **Discard** returns to the last saved rates. To remove a manual override, use the model's **… → Restore default rate**, or **Clear custom rate** when no default exists, then save. These actions change the draft first.
- Quitting with a valid draft offers **Save**, **Discard**, or **Cancel**. An invalid draft must be corrected before saving; **Cancel** returns to editing.

<p align="center">
  <img src="docs/images/interactions/pricing-invalid.png" width="620" alt="A nonnumeric input rate with an inline error, an error summary, and Save disabled">
</p>

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

If the selected Command Line Tools SDK reports a missing `SwiftUIMacros` plugin, use the installed Xcode toolchain for that command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
make app
```

Common commands:

```bash
make build          # Build the debug binary
make run            # Build and run in the foreground
make test           # Run core assertions and UI/policy verifiers
make probe          # Check both provider integrations
make probe-cost     # Rescan local logs; may refresh model prices
make benchmark-startup # Measure status-item construction offline in a debug build
make benchmark-cost # Measure Codex scans with offline pricing; reads local logs
make logs           # Stream logs for com.quotabar.app
make readme-assets  # Rebuild screenshots, state examples, and GIFs; requires ffmpeg
make clean
```

`make probe` prints account and usage metadata. Review its output before sharing it.

`make readme-assets` renders both READMEs' shared images from the current views with sample data, including the sign-in, refresh-failure, and invalid-price states. Regenerate them after changing the UI. The [implementation notes](docs/design-implementation.md) describe the rendering commands and verification limits.

To create a test package, run **Build and Release** from the repository's **Actions** tab. To publish a release, push a tag matching `vMAJOR.MINOR.PATCH`. The workflow tests and packages an `arm64` ZIP, then creates the GitHub Release.

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
- Claude credential recovery runs only after a manual `Refresh` and may still require opening Claude Code for interactive sign-in.
- Cost figures come from local logs and are not billing statements.
- OpenCode does not save the authentication method for each historical request. QuotaBar cannot reconstruct an OAuth to API key to OAuth switch that happened while it was not running.

## License

QuotaBar is licensed under [AGPL-3.0](LICENSE). Code adapted from CodexBar remains available under its MIT terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgements

QuotaBar uses ideas and implementation details from CodexBar, Copyright © 2026 Peter Steinberger.
