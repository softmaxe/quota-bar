# Saved usage and sources

The Usage settings pane summarizes recorded usage, exports and merges backups, and adds SSH machines whose session logs should be recorded.

## Sub-features

- `backup-export` writes a readable SQLite backup through the save panel.
- `backup-import` merges a backup and reports added records; repeat import does not duplicate them.
- `source-add` adds an SSH alias or typed host and starts synchronization.
- `source-sync` syncs all hosts, one host, or retries a failed host.
- `source-remove` stops syncing a host while retaining recorded usage.

## How to get to it (user POV)

- Open `Settings…` or Cmd-comma, then `Usage` or Cmd-3 in Settings.
- Under Saved usage, choose `Import…` or `Export…`.
- Under Sources, choose `Add host`, `Sync now`, or a host's `Actions for <host>` menu. A failed host offers `Retry`.

## Driving it with native CUA

Preconditions:

- Bind the owned preview through the skill's native workflow and open Settings → Usage.
- Backup success requires a known synthetic `.sqlite` backup with expected record counts. The default preview does not seed one.
- SSH success requires a deliberately isolated, reachable host with synthetic session logs and noninteractive authentication. Do not substitute a personal host.

- **Import.** Choose `Import…`; confirm the file panel is `Import Usage Backup`, select the synthetic backup, and choose `Import`. Capture the result and changed saved-record count. Repeat import and verify no duplicate records are added.
- **Export.** With saved records present, choose `Export…` and save inside the evidence directory. Its suggested name is `QuotaBar-Backup-YYYY-MM-DD.sqlite`. Verify the file exists, is readable SQLite, passes a read-only integrity check, and contains the expected records; retain the file after cleanup.
- **Add/cancel.** Choose `Add host`, resolve field `SSH host or alias` (placeholder `Search hosts or type devbox`), type the isolated host, then choose `Cancel`; no host row should be added.
- **Add/sync.** Repeat and choose `Add`. Capture syncing followed by the host's recorded/new counts and copied bytes. Independently confirm the expected synthetic records reached the scratch database and mirrored logs stay under the owned scratch directory.
- **Other sync entries.** Exercise `Sync now`, `Actions for <host>` → `Sync this host`, and `Retry` on a deliberately failed host separately. Each must complete or display an actionable failure.
- **Remove.** Choose `Actions for <host>` → `Stop syncing`; its source row disappears while saved records remain.

## Gotchas

- Preview card/report samples are not saved records. Initial scratch usage is empty and `Export…` becomes disabled when its record count is zero. Missing seed data blocks a successful export journey; do not claim success from opening a dialog.
- Import really mutates the preview database and export really writes the chosen destination. Use synthetic data and retain exported proof outside scratch cleanup.
- `Add host` immediately runs real SSH, reads local SSH configuration, and can copy complete remote logs. Preview does not mock this path.
- Remote synchronization also records through the real scanner using the process environment, so it can scan actual local Claude/Codex logs into the scratch database. A fully isolated host alone does not isolate this journey; local scan roots must also be isolated before running it.
- Default preview has no safe SSH fixture or seeded backup. Report these journeys blocked until those preconditions are supplied; never weaken them to mere button visibility.
- These interactive journeys remain unverified until native CUA can bind the owned app.
