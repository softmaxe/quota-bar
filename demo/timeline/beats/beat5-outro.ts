import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";

export const beat5: Beat<{ reveal: number }> = {
  index: 5, key: "outro", title: "Report and outro", start: 62, end: 75,
  captions: [
    {"id": "b5-1", "text": {"en": "An offline report, in either language.", "zh": "离线报告，中英文随时切换。"}, "start": 62.5, "end": 68.2, "placement": CAPTION_PLACEMENT},
    {"id": "b5-2", "text": {"en": "QuotaBar. Keep track as you work.", "zh": "QuotaBar，工作时随时掌握用量。"}, "start": 68.7, "end": 73.5, "placement": CAPTION_PLACEMENT},
  ],
  cues: [{type: "click", at: 62.5}],
  moments: {reveal: 62.5},
  reviewFrames: [{name: "beat-5-outro-drawn", at: 65}],
};
