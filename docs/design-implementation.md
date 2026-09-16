# Interaction implementation

This implementation follows the approved interaction proposal. The original before/after boards remain in `design-proposal/` for comparison. Product screenshots in `images/interactions/` render the implemented native views with sample data.

## What changed

- The status card now uses a transient `NSPopover`. Native controls provide focus, reset-time menus, unit selection, date selection, and disclosure. The 280 pt width remains fixed; tall content scrolls while Refresh, Settings, and Quit remain available below it. Closing the popover stops its clocks. Provider-switch animation preserves the tab's identity while resetting provider-specific content.
- Cmd-R dispatches through a validated AppKit application command, Cmd-1 / Cmd-2 switch providers, Cmd-comma opens settings, and Escape closes the popover. Edit commands use the responder chain for normal text editing in settings.
- Signed-out cards preserve the provider's reason and offer the correct CLI command, copy feedback, and a Check sign-in action. Copying a command does not execute it. Credentials and permission errors retain their separate recovery paths.
- Refresh failures retain quota readings and show the last successful update near a warning. Server and local cooldowns jointly determine when retry is available. A local usage scan exposes its own progress, failure, and retry.
- Pricing validates finite nonnegative rates and positive integer thresholds before persistence. Invalid text cannot implicitly remove an override. Restore defaults and Discard are explicit draft operations. Saving prevents duplicate writes; errors preserve edits. Catalog reloads cannot replace a draft created while their asynchronous work was pending. Quitting protects unsaved edits, with Cancel as the default when an invalid draft cannot be saved.
- Local usage has a visible Tokens / Cost selector and ten calendar date columns. Dates support whole-column pointer targets and keyboard selection. Model details are collapsed as a group; complete labels remain available to accessibility. Unit changes and refreshes preserve a still-valid date selection. Unpriced and partially priced usage have distinct labels; dates not covered by the last completed scan do not claim zero usage.
- Quota headlines immediately display authoritative values. Reset feedback lasts about 0.82 seconds and respects Reduce Motion. Pace calculations are available through Usage pace details; duplicate Top model text is removed. Credits follow local usage.

## Interaction timing

The status card opens on left mouse-down with the native popover animation disabled. Right clicks retain AppKit's mouse-up behavior. Each opening measures the collapsed card before showing it, including when the previous card was expanded or changed while closed.

Custom buttons acknowledge a press immediately through opacity and restore it over 100 ms. Tab selection settles within 180 ms, disclosure chevrons and pricing expansion within 160 ms, and chart hover feedback uses a short critically damped response. Pricing rows appear together without stagger or scale effects. Unit changes update chart heights and labels together. These timings are project choices guided by brief feedback and uninterrupted interaction, not fixed Apple requirements.

Reduce Motion removes custom transitions while preserving pressed and selected states. Native links, menus, segmented pickers, and bordered buttons retain their system feedback. The popover verifier exercises left and right mouse events, repeated opening, first-frame height, and stable content positions.

## Validation

The project uses an assertion executable and native UI verifiers rather than XCTest. Run the repository command with the installed Xcode toolchain:

The implementation verification run passed 506 core assertions and all 17 UI/policy verifiers. The release app was built and its ad-hoc signature verified with `make app`.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
make test
```

The local Command Line Tools selection lacks the `SwiftUIMacros` plugin for its selected SDK; using the installed Xcode toolchain works without changing global developer settings.

Validation includes core assertions, price validation and asynchronous save failures, draft preservation, server/local cooldowns, native Cmd-R routing, a capped popover viewport with a fixed action footer, calendar slots, price availability, model disclosure, label layout, relative clocks, and motion. The obsolete custom menu-row/pointer-warp implementation and its dedicated verifier were removed after the popover replacement.

Dark and light sample views, signed-out guidance, a cooldown error, and an invalid pricing field were rendered and inspected. Desktop automation could not attach to the temporary preview app, so a complete manual VoiceOver and Full Keyboard Access audit remains outstanding. Native AppKit key-equivalent and layout verification runs successfully; those checks do not claim a complete assistive-technology audit.

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

The documentation follow-up passed `make readme-assets`, the quota recovery and reset-label verifiers, shell syntax validation, and `git diff --check`. Both READMEs have matching image references and command examples; their local paths, anchors, and image alternative text were checked. Representative screenshots and GIF frames were visually inspected.
