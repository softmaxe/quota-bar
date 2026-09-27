# QuotaBar demo film

The Film follows the Menu bar robot through one day of coding. English and Chinese
Captions carry the same story without narration. App windows stay in English in
both films; the exported report demonstrates its own Chinese and English switch.

| Beat | Time | Story |
| --- | --- | --- |
| Quota runs out | 0–12 s | Coding stops at a rate limit. Red pen circles the message, then the camera finds the robot in the menu bar. |
| One glance | 12–30 s | The card shows provider quotas, reset time and pace. Keyboard shortcuts switch between Codex and Claude. |
| Running low, then reset | 30–45 s | The afternoon quota drains, the robot turns red, and the reset refills the bar. |
| Every dollar | 45–62 s | Daily cost bars appear at night. Pinning a day reveals its models; the Price book note explains the dated rates. |
| Report and outro | 62–75 s | An offline report changes language. The robot waves beside the install command and repository link, then the picture fades to paper. |

The corner clock and paper wash follow the day's light. A synthesised score at
88 BPM combines a chip melody, electric-piano chords and light drums. It changes
with the low-quota warning, reset and evening report.

All product readings are sample data. `timeline/quota.ts` owns quota state and
the local story clock; `video/interface/fixtures.ts` owns cost and report data.
The robot follows the selected provider's tightest quota window: 10% or less
remaining triggers its warning, and an expired reset counts as a full window.
Cost is an API-rate estimate, not a bill.

## Build

Install Node.js 22 or newer, `uv`, and `ffmpeg` with `ffprobe`. The audio package
requires Python 3.11 or newer, managed by `uv`. Package dependencies stay in this
directory. From the repository root:

```sh
npm ci --prefix demo
uv sync --locked --project demo/audio
make demo-video
```

The build exports the timeline, synthesises stereo audio, renders both languages,
muxes their MP4s with ffmpeg, and exports PNG review frames. Each film is 75 seconds
at 1920×1080 and 30 fps, with H.264 video and AAC audio. Output goes to:

- `demo/out/quotabar-demo-en.mp4` and `demo/out/quotabar-demo-zh.mp4`
- `demo/out/timeline.json` and `demo/out/audio.wav`
- `demo/out/frames/en/` and `demo/out/frames/zh/`, with each Beat midpoint, Caption end,
  named story moment and the last frame

To limit render workers, run `npm --prefix demo run build -- --concurrency=4`.
Remotion provisions its headless browser on first use. Initial setup needs
network access for dependencies and that browser; subsequent builds use the
installed tools and bundled font. Picture textures, music and effects are
generated in code, with no downloaded instrument samples or input image assets.

## Previews

Run `npm --prefix demo run studio` from the repository root. The composition
picker includes:

- `Film-en` and `Film-zh`: the complete films with shared timing.
- `CharacterSheet`: all six Menu bar robot poses.
- `InterfacePreview`: 14 interface and red-pen states, each held for three seconds.

For a single review image, run this from `demo/`:

```sh
npx remotion still video/index.ts Film-en out/opening.png --frame=201 --public-dir=video/public
```

Change the composition to `Film-zh` for the Chinese frame. Preview compositions
and stills render picture only; the build's MP4s include the synthesised soundtrack.

## Editing

A Film is the complete 75-second timeline. A Beat is one contiguous part of the
story. A Caption is one bilingual text entry and its display interval. A Cue
names a synthesised effect and the instant it begins.

Each file in `timeline/beats/` owns its Beat's Captions, Cues, named moments and
review frames. Times are absolute Film seconds. `timeline/index.ts` composes the
Beats and exports the JSON consumed by the audio package. Each matching component
in `video/beats/` receives `language` and uses `useBeatTime(beat)` for absolute time.
The Film renders Captions above the Beat drawings and fades the whole foreground,
including the clock and wash, to paper in the last second. Keep drawings above
the Caption area at y=885 and leave the top-right clock area clear.

Sound effects live in `audio/quotabar_audio/sfx/`. A Cue's `type` selects its module,
whose `synthesize(sr, **params)` function returns mono audio. The sound-effects
layer places it on the stereo track. Cue types are `click`, `shortcut`,
`robot_alert`, `reset_scale`, `pen_scribble` and `tick`. Each module in `layers/`
exposes `render(timeline, sr)` and returns a stereo buffer for the whole Film.
The music reads the same Beat boundaries and quota moments as the picture.

From `demo/`, extend the font subset with
`uv run scripts/subset_font.py path/to/LXGWWenKai-Regular.ttf`.
It writes the WOFF2, character coverage and glyph metrics together. The source
font comes from the [LXGW WenKai releases](https://github.com/lxgw/LxgwWenKai/releases).
The normal build uses the bundled subset and does not fetch a font. The paper,
Rough.js, animation and Caption code was copied and adapted from the Pelican Test
Film. LXGW WenKai's full license and web-font permission are retained in
[`video/public/fonts/OFL.txt`](video/public/fonts/OFL.txt). The Menu bar robot is
adapted from the Material Design Icons `robot-excited` icon, credited in the
root [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Checks

Run these from the repository root:

```sh
npm --prefix demo run typecheck
npm --prefix demo test
npm --prefix demo run test:audio
npm --prefix demo run test:film
```

Or run `npm --prefix demo run test:all`. Timeline tests inspect the exported JSON for Beat
coverage, Caption duration and overlap, translations, font coverage, frame bounds
and ordered Cues with synthesis modules. They also check the robot's state against
the app's running-low rule. Python tests feed JSON to the public audio command and
inspect WAV duration and audible Cue timing, then check each synthesis module.
Film tests use
`ffprobe` to check both MP4s and `ffmpeg` to verify that the final second is below
-40 dB. They also verify each review PNG.

Film tests rebuild both complete films when picture, timeline, audio, font, build
configuration or locked dependency content changes, or when an output is missing.
Use the first three checks while editing, then run the film tests after the final
build. Review the exported PNGs for visual layout. The Swift application and its
CI do not depend on this package.
