"""Confirm the text-test metadata describes the actual bundled font."""

import json
from pathlib import Path

from fontTools.ttLib import TTFont


def test_font_charset_and_width_metadata_match_the_bundled_font():
    fonts = Path(__file__).resolve().parents[2] / "video/public/fonts"
    with TTFont(fonts / "LXGWWenKai-Regular.subset.woff2") as font:
        cmap = font.getBestCmap()
        charset = set((fonts / "LXGWWenKai-Regular.subset.charset.txt").read_text().rstrip("\n"))
        assert charset == {chr(cp) for cp in cmap}
        metrics = json.loads((fonts / "LXGWWenKai-Regular.subset.metrics.json").read_text())
        assert metrics == {
            "unitsPerEm": font["head"].unitsPerEm,
            "advances": {str(cp): font["hmtx"].metrics[name][0] for cp, name in cmap.items()},
        }
