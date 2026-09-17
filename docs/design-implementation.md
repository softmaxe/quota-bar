# Interaction implementation

This implementation follows the approved interaction proposal. The original before/after boards remain in `design-proposal/` for comparison. Product screenshots in `images/interactions/` render the implemented native views with sample data.

## What changed

- The status card uses a native `NSPopover`. On macOS 27, AppKit's expanded interface session owns its opening and status-button highlight. A repeated icon click, an outside click, Escape, or a closing action cancels the session. Earlier systems use application-managed dismissal and selection. Opening preserves the foreground application. Native controls provide focus, reset-time menus, unit selection, date selection, and disclosure. The 280 pt width remains fixed; tall content scrolls while Refresh, Settings, and Quit remain available below it. Closing the popover stops its clocks. Provider-switch animation preserves the tab's identity while resetting provider-specific content.
- Cmd-R dispatches through a validated AppKit application command, Cmd-1 / Cmd-2 switch providers, Cmd-comma opens settings, and Escape closes the popover. Edit commands use the responder chain for normal text editing in settings.
- Signed-out cards preserve the provider's reason and offer the correct CLI command, copy feedback, and a Check sign-in action. Copying a command does not execute it. Credentials and permission errors retain their separate recovery paths.
- Refresh failures retain quota readings and show the last successful update near a warning. Server and local cooldowns jointly determine when retry is available. A local usage scan exposes its own progress, failure, and retry.
- Pricing validates finite nonnegative rates and positive integer thresholds before persistence. Invalid text cannot implicitly remove an override. Restore defaults and Discard are explicit draft operations. Saving prevents duplicate writes; errors preserve edits. Catalog reloads cannot replace a draft created while their asynchronous work was pending. Quitting protects unsaved edits, with Cancel as the default when an invalid draft cannot be saved.
- Local usage has a visible Tokens / Cost selector and ten calendar date columns. Dates support whole-column pointer targets and keyboard selection. Model details are collapsed as a group; complete labels remain available to accessibility. Unit changes and refreshes preserve a still-valid date selection. Unpriced and partially priced usage have distinct labels; dates not covered by the last completed scan do not claim zero usage.
- Quota headlines immediately display authoritative values. Reset feedback lasts about 0.82 seconds and respects Reduce Motion. Pace calculations are available through Usage pace details; duplicate Top model text is removed. Credits follow local usage.

## Interaction timing

The status card opens on left mouse-down with the native popover animation disabled. Right clicks retain AppKit's mouse-up behavior. Each opening measures the collapsed card before showing it, including when the previous card was expanded or changed while closed.

Custom buttons acknowledge a press immediately through opacity and restore it over 100 ms. Tab selection settles within 180 ms, disclosure chevrons and pricing expansion within 160 ms, and chart hover feedback uses a short critically damped response. Pricing rows appear together without stagger or scale effects. Unit changes update chart heights and labels together. These timings are project choices guided by brief feedback and uninterrupted interaction, not fixed Apple requirements.

Reduce Motion removes custom transitions while preserving pressed and selected states. Native links, menus, segmented pickers, and bordered buttons retain their system feedback.

## Validation

The project uses an assertion executable and debug launch flags for app state checks. The build commands select full Xcode through `Scripts/swift.sh`:

```sh
make test
```

The default installation is `/Applications/Xcode.app`. Set `DEVELOPER_DIR` to another full Xcode installation's `Contents/Developer` directory if needed. The project does not change global developer settings.

Keep automated coverage for parsing, authentication refresh, scan integrity, pricing, persistence, export failures, draft preservation, cooldowns, and native Cmd-R routing. Date boundaries, scan coverage, and reset detection also retain focused regression checks.

Repeated disclosure clicks, popover open/close sweeps, pixel and layout snapshots, and animation-curve sampling are not part of the test suite. Do not add routine checks that pin button labels, enum counts, template structure, or animation constants. Test a specific failure when a behavior changes or a bug is reported; stable visual controls do not need repeated manual or automated clicking.

Build with the macOS 27 SDK in Xcode 27 to enable native expanded interface sessions. Release builds use the `xcode-27` runner and reject older SDKs so the shipped app includes this implementation. CI also builds on `macos-15` to check the fallback. The deployment target remains macOS 14; the `canImport` check uses AppKit's SDK module version so an older SDK never resolves unavailable types.

Run `.build/debug/QuotaBar --verify-menu-interaction` in a logged-in desktop session to check the fallback status-button path. It reproduces the remote menu bar's global mouse notification before forwarding the same click to the status button. A click within the button's screen bounds must remain open for the toggle action; a click outside must dismiss the card. It also dispatches mouse-down and mouse-up separately and checks accessibility activation, keyboard focus, Cmd-1, Escape, foreground application preservation, and local dismissal with isolated data. This check presents a real popover and stays separate from the headless `make test` suite. Native expanded sessions and the system menu bar's rendered transitions require actual pointer interaction; `performClick` and posted events do not reproduce the remote host's full behavior.

Dark and light sample views, signed-out guidance, a cooldown error, and an invalid pricing field were rendered and inspected during implementation. A complete manual VoiceOver and Full Keyboard Access audit remains outstanding. The native AppKit key-equivalent check does not claim a complete assistive-technology audit.

## Preview and rendering

```sh
.build/debug/QuotaBar --preview-interface loaded
.build/debug/QuotaBar --preview-interface signed-out
.build/debug/QuotaBar --preview-interface stale
.build/debug/QuotaBar --dump-interaction-states docs/images/interactions
```

Preview uses sample providers, a separate preference suite, temporary history, and no-op pricing writes. Use its Quit command for cleanup. It does not use CLI credentials or scan real session files. Normal app launch retains the real integrations.

`make readme-assets` regenerates the documentation images, motion examples, and all five interaction state screenshots. `--dump-interaction-states` can also render just those state screenshots. The generated `.build` directory is ordinary local build output.

## README synchronization

The English and Simplified Chinese READMEs describe the same controls, keyboard shortcuts, refresh and scan recovery, pricing draft lifecycle, and cost availability states. Both versions use the same sample images, with translated captions and alternative text. The pricing section explains that saving a new rate does not reprice previously recorded usage.

The root READMEs show current product views. The annotated before/after boards in `design-proposal/` remain the historical design baseline and are labeled accordingly.

The reset GIF now keeps the new percentage visible throughout the animation and reuses the production reset-time menu below the bar. The obsolete, unreferenced label-click unit-toggle GIF was removed. The asset script converts hosted screenshots to sRGB before compositing or GIF encoding, preserving provider colors when ffmpeg drops the source color profile.

The documentation follow-up checked both READMEs for matching image references and command examples. Representative screenshots and GIF frames were visually inspected. Run `make readme-assets` when documentation images need updating.
