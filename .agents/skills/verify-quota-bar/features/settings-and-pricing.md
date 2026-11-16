# Settings and pricing

Settings controls the menu bar provider and refresh cadence, and provides a searchable, read-only list of model rates.

## Sub-features

- `settings-open` opens and revisits Settings by button and shortcut.
- `settings-general` changes the displayed provider and refresh cadence.
- `pricing-search` filters rates by model and clears the filter.
- `pricing-vendors` expands and collapses vendor groups and model details.
- `pricing-source` changes the models.dev setting.
- `settings-login` changes the system login item when that integration is explicitly under test.

## How to get to it (user POV)

- Choose `Settings…` in the card or press Cmd-comma.
- Choose `General`, `Pricing`, or `Usage` in the sidebar, or Cmd-1/2/3 while Settings owns focus.
- General contains provider selection, `Refresh quota`, and `Open at login`.
- Pricing contains `Search models`, vendor groups, and `Price other models with models.dev`.

## Driving it with native CUA

Preconditions:

- Start `make preview PREVIEW_STATE=loaded` through the skill's workflow; bind the owned native app and inspect its current accessibility tree.
- Confirm window title `QuotaBar Settings` before sending pane shortcuts.

- **Open.** Exercise `Settings…` and Cmd-comma separately. Close and reopen the window; its position should be preserved within the available screen.
- **General.** Resolve provider rows by labels beginning `Claude, ` or `Codex, ` and choose one. Confirm the status item now names that provider. Select `Refresh quota` → `Manual`; reopen the pane to confirm the choice persists in this preview session.
- **Pricing pane.** Click `Pricing`; separately use `pressKey` with `super+2` while Settings owns focus. Confirm the rates list, not the popover's Codex tab.
- **Search.** Resolve the native search field with placeholder `Search models`. Read an existing model name from the list, enter that name, and verify matching model rows and rate columns. Clear the field and verify the unfiltered list returns.
- **Disclosure.** Resolve a vendor label ending `model` or `models`. Activate it and verify `Collapsed` changes to `Expanded` with its rows visible; activate again to collapse. Open a model with displayed tier details and inspect those details.
- **Pricing switch.** Toggle `Price other models with models.dev`, revisit Pricing, and verify the chosen setting remains. Restore the initial choice. This proves the preference interaction only in preview.

## Gotchas

- `Open at login` calls the real macOS login-item service even in preview. It is outside the default isolated journey; a scratch preview is not a safe stand-in for a packaged-app login-item test.
- Preview rates are fixtures and models.dev downloads are disabled at the service boundary. A switch interaction does not prove network fetching or repricing real logs.
- Search opens matching vendor groups and disables their disclosure control while filtering. Clear the search before testing manual collapse.
- Cmd-1/2/3 target different controls in Settings and in the card. Verify the active window before sending them.
- These interactive journeys remain unverified until native CUA can bind the owned app.
