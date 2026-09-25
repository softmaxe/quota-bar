#!/bin/bash
# Renders the README demo films, English and Chinese, with their score into build/demo/.
#
# The film is docs/demo/demo.html: every frame is drawn in the browser from the shared timeline,
# so a render is reproducible. Needs ffmpeg, Node, playwright-cli, and a Chromium browser
# (Brave by default, like Scripts/report_image.mjs; set CHROMIUM_PATH to use another).
# Arguments pass through to Scripts/demo_video.mjs, e.g. `zh`, `--audio`, `--stills 9.5,31`.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
command -v playwright-cli >/dev/null || { echo "playwright-cli is required: brew install playwright-cli" >&2; exit 1; }

node --test docs/demo/
node Scripts/demo_video.mjs "$@"
