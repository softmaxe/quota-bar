#!/bin/bash
# Regenerates every image the README links to, from the app's own offscreen dumps.
#
# The screenshots are renders of the shipped views against fixture data, not captures of a
# running menu bar, so they are reproducible and carry nobody's real account in them. The GIFs
# are frame dumps of the production animation timings assembled by ffmpeg.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN=.build/debug/QuotaBar
OUT=docs/images
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }

swift build -c debug --product QuotaBar
mkdir -p "$OUT"

echo "==> rendering frames"
"$BIN" --dump-card "$WORK/card" >/dev/null
"$BIN" --dump-icons "$WORK/icons" >/dev/null
"$BIN" --dump-settings "$WORK/settings" >/dev/null
"$BIN" --dump-card-celebration "$WORK/reset" claude >/dev/null
"$BIN" --dump-chart-hover "$WORK/hover" claude >/dev/null
"$BIN" --dump-tab-switch "$WORK/tab" >/dev/null
"$BIN" --dump-disclosure "$WORK/disclosure" >/dev/null
"$BIN" --dump-chart-motion "$WORK/chart-motion" >/dev/null
"$BIN" --dump-label-toggle "$WORK/label-toggle" >/dev/null
"$BIN" --dump-reset-toggle "$WORK/reset-toggle" claude >/dev/null

echo "==> hero"
# The two cards are different heights — Codex carries a credits block Claude has no equivalent
# for — so they sit top-aligned on the page ground rather than being padded to match.
ffmpeg -v error -y \
  -i "$WORK/card/claude-loaded.png" -i "$WORK/card/codex-loaded.png" \
  -filter_complex "color=c=0x1a1a1a:s=1240x1258[bg];[bg][0:v]overlay=40:40[t];[t][1:v]overlay=640:40" \
  -frames:v 1 "$OUT/hero.png"

echo "==> quota reset gif"
ffmpeg -v error -y -framerate 25 -i "$WORK/reset/frame-%04d.png" \
  -filter_complex "fps=25,scale=560:-1:flags=lanczos,split [a][b];[a] palettegen=max_colors=128:stats_mode=diff [p];[b][p] paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$OUT/quota-reset.gif"

echo "==> chart hover gif"
ffmpeg -v error -y -framerate 2.2 -i "$WORK/hover/frame-%04d.png" \
  -filter_complex "fps=2.2,scale=560:-1:flags=lanczos,split [a][b];[a] palettegen=max_colors=96 [p];[b][p] paletteuse=dither=bayer:bayer_scale=4" \
  "$OUT/chart-hover.gif"

echo "==> reset toggle gif"
# Ten frames a second, because nothing on this one moves: the label's two faces are a cut in the
# app too. The crop keeps the two quota rows and drops the header and the chart under them, so
# the only thing that changes in frame is the label being clicked.
ffmpeg -v error -y -framerate 10 -i "$WORK/reset-toggle/frame-%04d.png" \
  -filter_complex "fps=10,crop=560:268:0:138,split [a][b];[a] palettegen=max_colors=96:stats_mode=diff [p];[b][p] paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$OUT/reset-toggle.gif"

echo "==> motion strips"
# All four are dumped at 25fps, which is a whole number of GIF delay units, so they play back at
# the speed the app animates at.
strip() {
  ffmpeg -v error -y -framerate 25 -i "$WORK/$1/frame-%04d.png" \
    -filter_complex "fps=25,scale=$2:-1:flags=lanczos,split [a][b];[a] palettegen=max_colors=96:stats_mode=diff [p];[b][p] paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    "$OUT/$3"
}
strip tab 480 tab-switch.gif
strip disclosure 560 disclosure.gif
strip chart-motion 500 chart-motion.gif
strip label-toggle 500 label-toggle.gif

echo "==> menu bar icons"
# One row: normal, the provider on show running low (red), the other provider running low (the
# corner badge), a failed refresh, and no data.
ffmpeg -v error -y \
  -i "$WORK/icons/full.png" -i "$WORK/icons/low.png" -i "$WORK/icons/other-low.png" \
  -i "$WORK/icons/stale-reading.png" -i "$WORK/icons/stale.png" \
  -filter_complex "color=c=0x1a1a1a:s=680x144[bg];\
[0:v]scale=72:72[a0];[1:v]scale=72:72[a1];[2:v]scale=72:72[a2];[3:v]scale=72:72[a3];[4:v]scale=72:72[a4];\
[bg][a0]overlay=40:36[x0];[x0][a1]overlay=160:36[x1];[x1][a2]overlay=280:36[x2];[x2][a3]overlay=400:36[x3];[x3][a4]overlay=520:36" \
  -frames:v 1 "$OUT/menu-bar-icons.png"

echo "==> settings"
# The General pane is a short form in a tall window; the empty half below it says nothing.
ffmpeg -v error -y -i "$WORK/settings/settings.png" -vf "crop=1240:620:0:0" -frames:v 1 "$OUT/settings-general.png"
cp "$WORK/settings/settings-pricing-expanded.png" "$OUT/settings-pricing.png"

echo
echo "wrote:"
ls -1 "$OUT"
