---
name: verify-quota-bar
description: Verify QuotaBar's native macOS menu bar behavior using its existing AppKit interaction harness and isolated sample previews. Use after changes to quota cards, local usage, settings, pricing, or usage reports; record which user entry points were actually exercised.
---

# Verify QuotaBar

Read `docs/design-implementation.md` and [the feature map](features/README.md) first.
The primary surface is a native AppKit/SwiftUI menu bar app, with a WKWebView usage
report. `QuotaBarProbe` is a secondary integration diagnostic, not the UI driver.
There is no HTTP server or port to start.

## Launch

Run from the repository root on a logged-in macOS desktop. Full Xcode with Swift 6,
`uv`, and the Rust toolchain in `rust-toolchain.toml` are required. The repository's
wrapper selects `/Applications/Xcode.app/Contents/Developer`; set `DEVELOPER_DIR`
only when using a different full Xcode installation. Do not use bare `swift build`:
it bypasses the Rust integration.

```sh
make build
uv run --no-project python .agents/skills/verify-quota-bar/scripts/control.py doctor
```

The reproducible smoke journey is the existing short-lived native interaction
verifier. It creates its own status item and popover, supplies offline display
fixtures, routes native events, asserts their effects, clears its preference suite,
and exits. It needs no login, migrations, seed database, or long-running server.
Launch and drive it together:

```sh
VERIFY_EVIDENCE="$(mktemp -d /tmp/quotabar-verification.XXXXXX)"
uv run --no-project python .agents/skills/verify-quota-bar/scripts/control.py menu "$VERIFY_EVIDENCE"
```

The helper runs `.build/debug/QuotaBar --verify-menu-interaction`. A successful
build or `status_item_init_ms` alone is not readiness/proof. Require exit 0 and
`Menu lifecycle, status-button toggling, dismissal, and foreground preservation checks passed`,
with `passed: true` in `result.json`. The verifier checks that the status button
exists, the popover is shown, and its native keyboard window is usable before
continuing. It covers the **fallback** status-button implementation, not macOS 27's
remote expanded-interface pointer handling.

For other mapped journeys, start the repository's sample preview in a foreground
terminal session, retaining the session handle:

```sh
make preview PREVIEW_STATE=loaded
```

Other exact states are `signed-out`, `stale`, and `motion`. Preview seeds quota,
chart, and pricing display data itself. Its history/database start empty; displayed
usage is **not** inserted into the database. Readiness requires the visible provider
tabs, sample values, and `Settings…`/`Quit` controls, plus the log
`Interface preview: loaded. Use the popover's Quit action to close.`
The log can be buffered when stdout is redirected, so use a PTY for interactive
preview. Quit through this preview's `Quit` control for normal teardown.

Do not use `make run` or `make kill`: they kill every process named QuotaBar,
including the user's installed app. Preview can coexist with the installed app,
but two previews share the fixed `QuotaBarInterfacePreview` preference suite.
Refuse concurrent preview/verifier driving, including across worktrees. The helper
serializes its own runs through `/tmp/quotabar-menu-verification-<uid>.lock` and
refuses an existing preview/verifier. Do not delete a lock owned by another run.

## Doctor

Run this read-only check before driving or whenever behavior looks wrong:

```sh
uv run --no-project python .agents/skills/verify-quota-bar/scripts/control.py doctor
```

It reports the resolved debug executable, SHA-256, Git revision and working-tree
status, macOS version, and desktop user; it rejects missing binaries and concurrent
preview/verifier processes. It is a **preflight** check, not proof that an arbitrary
GUI process is healthy. Build immediately beforehand; a hash does not establish
that source changes were compiled.

For an already launched interactive preview, inspect the exact PID and arguments
from `ps -axo pid,comm,args`, matching this checkout's resolved executable and
`--preview-interface` state. Check that PID with `ps -p` and `lsof -nP -p`; then
require its own current accessibility tree to show the expected sample controls.
Never select an instance using only the name `QuotaBar`. If ownership or visible
readiness cannot be established, stop that journey and record the failure.

## Drive

Start with `quota-fallback-lifecycle` in [quota and recovery](features/quota-and-recovery.md).
The `menu` command above drives the existing `MenuLifecycleVerifier` without
modifying production code. Its event routing exercises status-button presses and
releases, accessibility activation, Cmd-1/Cmd-3 provider selection, Escape,
foreground preservation, and dismissal/reopening. Initial fixture setters arrange
state; they are not the claimed user actions. Read the verifier source when a
failure needs diagnosis; do not bypass its assertions to get a passing exit.

For full interactive journeys use the native computer-use harness, when it can
bind the owned preview. Initialize it with `await cua.getState()`, identify the
exact running app target, then use `cua.getApp` only with an unambiguous target
supported by the tool. Read the returned API documentation before acting. Resolve
each control's **current** index from `getAXState()`, call `click(index)`, then read
the new tree. The feature files name real labels, not persistent numeric IDs.
Keyboard equivalents use `pressKey('super+1')`, `pressKey('super+3')`,
`pressKey('super+comma')`, `pressKey('super+u')`, and `pressKey('Escape')` with the
appropriate window focused. Do not use coordinates without a fresh screenshot.

This environment's CUA rejected the bare SwiftPM executable with `Invalid app`;
binding a temporary uniquely identified debug app bundle returned
`Computer Use server error -10005: timeoutReached`. Finder remained accessible.
Consequently the initial proof covers the existing fallback harness only. If the
same blocker recurs, record the interactive journey as blocked, clean up its
preview, and do not drive the installed app instead. Offscreen screenshots and
passing fallback checks cannot stand in for native macOS 27 pointer interaction.

## Evidence

The helper's evidence directory is outside `.build` and survives both its cleanup
and `make clean`:

- `doctor.json`: build identity and scope.
- `launch.json`: exact command, PID, and process start time.
- `stdout.txt`, `stderr.txt`, `result.json`: assertions, exit status, and failure reason.
- `open-files.txt`, `sockets.txt`: read-only observations of the owned process.
- `preferences-after.txt`: the verifier's preference domain after exit; absent or
  empty is clean (`cfprefsd` can retain an empty domain).
- `cleanup.json`: child exit, lock removal, and retained proof.

Read these files after the command, including on failure. Socket observations are
samples, not a trace proving that no transient network request occurred. The
verifier's source keeps observers stopped and quota cooldowns pinned. It does not
exercise OAuth, account recovery, models.dev downloads, or real log ingestion.

Interactive proof additionally records the feature ID, entry point, user actions,
before/after AX trees and screenshots, and observed result under that same evidence
directory. Capture motion as video when evaluating timing; static images cannot
prove it. Use `make card-snapshot SNAPSHOT_DIR="$VERIFY_EVIDENCE/cards"` for additional
layout evidence only. Never claim it records the interactive journey.

Exercise the actual user path and capture the action plus result. Verify exported
files and imported record counts as well as visible success messages. Do not call
internal setters or test endpoints as the action under test. Keep mocks at the
existing preview's data-provider boundaries. Missing preconditions are failures,
not permission to substitute a simpler entry point; list every untested entry.

Preview is not globally side-effect-free:

- Quota/scan fixtures bypass live credentials and logs on the ordinary card path.
- `Open at login` uses real `SMAppService`; leave it alone in a default smoke run.
- SSH `Add` starts real SSH sync and can scan real local logs. It requires an
  explicitly selected disposable host and controlled session data.
- The usage window loads HTML from memory with a fixed `usage-report.html` base URL
  under the real application-support directory and uses default persistent WebKit
  storage. Use a separate macOS test account for an isolated report journey, or
  explicitly account for shared report preferences before calling it isolated.
- Copying sign-in commands changes the system clipboard; it does not execute a CLI.

The initial proof is on real macOS, with the existing debug verifier's fallback
controller and offline fixture state. It is not a release-build, native expanded
session, account-integration, or complete accessibility audit. Those paths remain
unverified until their mapped journeys are run.

## Cleanup

The `menu` helper always waits for its child, terminates only that child after a
30-second timeout, clears the verifier's isolated defaults when no competing run
exists, and removes its own lock. It retains every proof file. Interruptions handled
by SIGINT/SIGTERM follow the same cleanup path; SIGKILL cannot run cleanup. For an
abruptly killed helper, use `launch.json` to verify the PID, start time, and full
command before stopping its orphan. The lock's `owner.json` records the helper PID,
start time, and evidence path; confirm that ownership before removing a stale lock.

Interactive preview: choose `Quit` or Cmd-Q on the identified preview. Normal Quit
clears `QuotaBarInterfacePreview` and removes its UUID scratch directory. Before
launch, record existing `QuotaBarInterfacePreview-*` directories under
`$(getconf DARWIN_USER_TEMP_DIR)`; after launch record the new one owned by this run.
Do not assume setting `TMPDIR` moves Foundation's scratch directory: on the verified
machine it did not. If UI teardown is blocked, stop only the recorded PID after
checking its identity, then remove only that run's new scratch directory. Clear
`QuotaBarInterfacePreview` only after confirming no other preview is active. Never
kill by process name, delete all matching scratch directories, or delete evidence.

After every run, including a failed iteration, confirm the owned process is gone
and the evidence files still exist. Record failed attempts separately; do not
replace them with a later passing result.

## Helpers

[scripts/control.py](scripts/control.py) is executable and uses only Python's
standard library. Invoke it through `uv run --no-project python`, as shown in
Launch and Doctor. `--help` lists its two commands. It deliberately wraps the
repository's native verifier rather than recreating its assertions.

Update the feature map when app paths or verification preconditions change.
