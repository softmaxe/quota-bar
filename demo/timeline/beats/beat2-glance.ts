import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";

export const beat2: Beat<{ reveal: number }> = {
  index: 2, key: "glance", title: "One glance", start: 12, end: 30,
  captions: [
    {"id": "b2-1", "text": {"en": "Codex and Claude, in one glance.", "zh": "一眼看清 Codex 和 Claude 的额度。"}, "start": 12.5, "end": 20.7, "placement": CAPTION_PLACEMENT},
    {"id": "b2-2", "text": {"en": "Know the reset time and your pace.", "zh": "重置时间和使用进度，一目了然。"}, "start": 21.2, "end": 29.5, "placement": CAPTION_PLACEMENT},
  ],
  cues: [{type: "click", at: 12.5}],
  moments: {reveal: 12.5},
  reviewFrames: [{name: "beat-2-glance-drawn", at: 15}],
};
