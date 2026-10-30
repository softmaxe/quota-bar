# Interaction implementation

How the menu bar card, its controls, and its motion behave, and how to check them. Product screenshots in `images/interactions/` render the native views with sample data.

## What changed

- The status card uses a native `NSPopover`. On macOS 27, AppKit's expanded interface session owns its opening and status-button highlight. A repeated icon click, an outside click, Escape, or a closing action cancels the session. Earlier systems use application-managed dismissal and selection. Opening preserves the foreground application. Native controls provide focus, reset-time menus, unit selection, date selection, and disclosure. The 280 pt width remains fixed; tall content scrolls while Refresh, Settings, and Quit remain available below it. Closing the popover stops its clocks. Provider-switch animation preserves the tab's identity while resetting provider-specific content.
- Cmd-R dispatches through a validated AppKit application command, Cmd-1 / Cmd-2 switch providers, Cmd-comma opens settings, and Escape closes the popover. Edit commands use the responder chain for normal text editing in settings.
- Signed-out cards preserve the provider's reason and offer the correct CLI command, copy feedback, and a Check sign-in action. Copying a command does not execute it. Credentials and permission errors retain their separate recovery paths.
- Refresh failures retain quota readings and show the last successful update near a warning. Server and local cooldowns jointly determine when retry is available. A local usage scan exposes its own progress, failure, and retry.
- Pricing is a read-only table of the rates every estimate uses, grouped into Claude, Codex, and Others, with each row naming its source: the price book or models.dev.
- Data shows how much usage is saved and backs it up. Export writes a consistent copy of the database to a chosen file. Import merges a copy of the chosen file, so it only adds, and reports what it changed; it needs no confirmation.
- Local usage has a visible Tokens / Cost selector and ten calendar date columns. Dates support whole-column pointer targets and keyboard selection. Model details are collapsed as a group; complete labels remain available to accessibility. Unit changes and refreshes preserve a still-valid date selection. Unpriced and partially priced usage have distinct labels; dates not covered by the last completed scan do not claim zero usage.
- Quota headlines display authoritative values; a changed reading rolls in over 120 ms. Reset feedback lasts about 0.82 seconds and respects Reduce Motion. Each quota bar carries its pace marker inline, with the outcome line below it; duplicate Top model text is removed. Credits follow local usage.

## Interaction timing

The status card opens at its final size on left mouse-down, without the native popover's zoom. Right clicks retain AppKit's mouse-up behavior. Closing fades the entire window in place over 180 ms on the app's front-loaded `(0.16, 1, 0.3, 1)` curve, following the quick reveal and stationary dismissal in the supplied macOS Wi-Fi and Sound menu recording. The duration is a project choice, not an Apple timing specification. Control activation and clocks stop when dismissal starts; the fallback clears its status selection immediately. The fading window ignores mouse input, and a temporary monitor discards its keyboard events until AppKit closes it and releases keyboard focus. On macOS 27, the expanded interface session and its remote click monitor remain until the fade finishes, because cancelling the session immediately closes the popover. A new icon click during the fade restores the same card and invalidates the old completion. A globally handled reopening press is not handled again if the remote host also forwards local mouse events. An expanded interface session can request immediate dismissal. Each fresh opening measures the collapsed card before showing it, including when the previous card was expanded or changed while closed. Content resizing remains unanimated to keep text and chart positions stable.

Opening the card does not activate the app. The first click or keyboard interaction inside it waits for the app's foreground activation before reaching a control. Otherwise, the activation notification can cancel a newly opened native reset-time menu, requiring a second click. Pending events retain their order and are discarded when the card closes. Escape bypasses activation. On macOS 27, `NSApp.isActive` can already be true during a status-item session, so the input handler checks the foreground process and explicitly requests activation.

Custom buttons acknowledge a press immediately through opacity and a slight drawn squish (0.975, or 0.99 for full-width rows; chart bars keep their height), then release over 100 ms with a 450 ms spring. Tab selection settles within 180 ms when clicked; keyboard switches (⌘-number shortcuts or Space on a focused tab) change selection without animation. Usage bars glide to a refreshed value over 250 ms. Disclosure chevrons settle within 160 ms, and chart hover feedback uses a short critically damped response. Popover disclosure content, including the model breakdown rows, rises 4 pt while fading in over 200 ms; heights still cut. A provider switched by click slides its content 12 pt in from the tab's side; keyboard switches and opening the card never slide. Refreshed quota values roll in their direction of change over 120 ms, and refreshed local usage totals roll over the same 120 ms. Hovering or selecting a day and changing units replace values without rolling. Refreshing, checking sign-in, and updating local usage show three pulsing dots. A first local scan shows nothing for 500 ms, then a breathing placeholder, and the result fades in over 150 ms. Copying a sign-in command and a successful sign-in check draw a resolving check. A card taller than the screen fades its scrolling edges. Unit changes update chart heights and labels together. These timings are project choices guided by brief feedback and uninterrupted interaction, not fixed Apple requirements.

Reduce Motion makes dismissal immediate and removes custom control transitions while preserving pressed and selected states. The card reads the preference at dismissal, including changes made while it is open. Opening never scales or slides, regardless of the preference. Native links, menus, segmented pickers, and bordered buttons retain their system feedback.

## Validation

The project uses one assertion executable, `QuotaBarTests`, for core and app checks; it imports the app library `QuotaBarApp` with `@testable`, so it always builds in debug. The build commands select full Xcode through `Scripts/swift.sh`:

```sh
make test
```

The default installation is `/Applications/Xcode.app`. Set `DEVELOPER_DIR` to another full Xcode installation's `Contents/Developer` directory if needed. The project does not change global developer settings.

Keep automated coverage for parsing, authentication refresh, scan integrity, pricing, persistence, usage window updates, cooldowns, and native Cmd-R routing. Date boundaries, scan coverage, and reset detection also retain focused regression checks.

Repeated disclosure clicks, popover open/close sweeps, pixel and layout snapshots, and animation-curve sampling are not part of the test suite. Do not add routine checks that pin button labels, enum counts, template structure, or animation constants. Test a specific failure when a behavior changes or a bug is reported; stable visual controls do not need repeated manual or automated clicking.

Build with the macOS 27 SDK in Xcode 27 to enable native expanded interface sessions. Release builds use the `xcode-27` runner and reject older SDKs so the shipped app includes this implementation. CI also builds on `macos-15` to check the fallback. The deployment target remains macOS 14; the `canImport` check uses AppKit's SDK module version so an older SDK never resolves unavailable types.

Run `.build/debug/QuotaBar --verify-menu-interaction` in a logged-in desktop session to check the fallback status-button path. It reproduces the remote menu bar's global mouse notification before forwarding the same click to the status button. A click within the button's screen bounds must remain open for the toggle action; a click outside must dismiss the card. It also dispatches mouse-down and mouse-up separately and checks accessibility activation, keyboard focus, Cmd-1, Escape, foreground application preservation, and local dismissal with isolated data. Animated dismissals wait for completion with a bounded deadline. Focused motion checks cover immediate control-input cleanup, keyboard suppression during fading, key-window consistency, reopening without a stale completion closing or dimming the card, duplicate global/local delivery of a reopening click, and Reduce Motion changes while the card is open. This check presents a real popover and stays separate from the headless `make test` suite. Native expanded sessions and the system menu bar's rendered transitions require actual pointer interaction; `performClick` and posted events do not reproduce the remote host's full behavior.

`MenuLifecycleTests` and `PopoverInputActivationTests`, part of `make test`, check the deferred menu, the activation handoff, mouse and keyboard event ordering, Escape, and cancellation without posting desktop input. To check native menu tracking, open the loaded preview's status icon while another app is frontmost, then click either reset-time control (`↻ …`) once. Its menu must stay open after release; selecting an item must update both reset labels without closing the card. Repeat after dismissing the card and returning focus to another app.

A complete manual VoiceOver and Full Keyboard Access audit remains outstanding. The native AppKit key-equivalent check does not claim a complete assistive-technology audit.

## Preview and rendering

```sh
make preview
make preview PREVIEW_STATE=signed-out
make preview PREVIEW_STATE=stale
make preview PREVIEW_STATE=motion
make card-snapshot
.build/debug/QuotaBar --dump-interaction-states docs/images/interactions
```

`make preview` builds the debug app and opens the isolated sample interface
without stopping the installed app. `PREVIEW_STATE` selects `loaded`,
`signed-out`, `stale`, or `motion`. `make card-snapshot` writes offscreen card
images to `.build/screenshots/card`; set `SNAPSHOT_DIR` to write somewhere else.
The underlying flags are `--preview-interface <state>` and
`--dump-card <directory>`.

The `motion` state slows fetches and the first local scan, starts Claude signed out until Check sign-in, and shortens the refresh cooldown, so each animation can be watched again. Preview uses sample providers, a separate preference suite, temporary history, and no-op pricing writes. Use its Quit command for cleanup. It does not use CLI credentials or scan real session files. Normal app launch retains the real integrations.

`make readme-assets` regenerates the documentation images and all four interaction state screenshots. `--dump-interaction-states` can also render just those state screenshots. The generated `.build` directory is ordinary local build output.

## README synchronization

The English and Simplified Chinese READMEs describe the same controls, keyboard shortcuts, refresh and scan recovery, and cost availability states, and use the same sample images with translated captions and alternative text. Update both together, and run `make readme-assets` when documentation images need updating.
