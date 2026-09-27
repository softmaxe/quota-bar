# QuotaBar demo film

The Film follows the Menu bar robot through one day of coding. English and Chinese
Captions carry the same story without narration. App windows stay in English.

| Beat | Time | Story |
| --- | --- | --- |
| Quota runs out | 0–12 s | An unexpected rate limit, then the menu bar |
| One glance | 12–30 s | Provider quotas, reset time, pace and shortcuts |
| Running low, then reset | 30–45 s | The warning and a fresh quota window |
| Every dollar | 45–62 s | Daily cost, model breakdown and the Price book |
| Report and outro | 62–75 s | An offline report and installation |

The current pipeline includes placeholder Beat drawings. The character, interface
kit, final story drawings and complete score are tracked in issues #78 through #85.

## Build

Install Node.js 22 or newer, `uv`, and `ffmpeg` with `ffprobe`. Dependencies stay in
this directory. Remotion manages its headless browser; the initial setup needs
network access to install dependencies and obtain that browser. Builds use the
bundled font and generate all picture textures, music and effects in code.

```sh
cd demo
npm ci
uv sync --project audio
npm run build
```

Use `npm run build -- --concurrency=4` to limit render workers. Output goes to:

- `out/quotabar-demo-en.mp4` and `out/quotabar-demo-zh.mp4`
- `out/timeline.json` and `out/audio.wav`
- `out/frames/en/` and `out/frames/zh/`, with each Beat midpoint, Caption end,
  named story moment and the last frame

Open `npm run studio` to inspect the `Film-en` and `Film-zh` compositions. The
picture uses copied and adapted paper, Rough.js, animation and Caption components
from the Pelican Test Film. LXGW WenKai is bundled as a WOFF2 subset under the SIL
Open Font License in `video/public/fonts/OFL.txt`. No recorded samples or image
assets are needed.

## Editing

A **Film** is the complete 75-second timeline. A **Beat** is one contiguous part
of the story. A **Caption** is one bilingual text entry and its display interval.
A **Cue** names a synthesised effect and the instant it begins.

Each file in `timeline/beats/` owns its Beat's Captions, Cues, named moments and
review frames. Times are absolute Film seconds. `timeline/index.ts` composes the
Beats and exports the JSON consumed by the audio package. Each matching component
in `video/beats/` receives `language` and uses `useBeatTime(beat)` for absolute time.
The Film renders Captions above the Beat drawings and fades to paper at the end.

Sound effects live in `audio/quotabar_audio/sfx/`. A Cue's `type` selects its module,
whose `synthesize(sr, **params)` function returns mono audio. The sound-effects
layer places it on the stereo track. Each module in `layers/` exposes
`render(timeline, sr)` and returns a stereo buffer for the whole Film.

To extend the font subset, run `uv run scripts/subset_font.py path/to/LXGWWenKai-Regular.ttf`.
It writes the WOFF2, character coverage and glyph metrics together. The source
font comes from the [LXGW WenKai releases](https://github.com/lxgw/LxgwWenKai/releases).
The normal build uses the bundled subset and does not fetch a font.

## Checks

```sh
npm run typecheck
npm test
npm run test:audio
npm run test:film
```

Or run `npm run test:all`. Timeline tests inspect the exported JSON for Beat
coverage, Caption duration and overlap, translations, font coverage, frame bounds
and ordered Cues with synthesis modules. Python tests feed JSON to the public
audio command and inspect WAV duration and audible Cue timing. Film tests use
`ffprobe` to check both MP4s and `ffmpeg` to measure the quiet final second. They
also verify each review PNG.

Film tests rebuild when picture, timeline, audio, font, build configuration or
locked dependency content changes. Review the exported PNGs for visual layout.
The Swift application and its CI do not depend on this package.
