import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";

export const beat4: Beat<{ reveal: number }> = {
  index: 4, key: "cost", title: "Every dollar", start: 45, end: 62,
  captions: [
    {"id": "b4-1", "text": {"en": "See what each day costs.", "zh": "每天的开销，看得清楚。"}, "start": 45.5, "end": 53.2, "placement": CAPTION_PLACEMENT},
    {"id": "b4-2", "text": {"en": "Each model uses the rates for that day.", "zh": "每个模型，按当天的费率估算。"}, "start": 53.7, "end": 61.5, "placement": CAPTION_PLACEMENT},
  ],
  cues: [{type: "click", at: 45.5}],
  moments: {reveal: 45.5},
  reviewFrames: [{name: "beat-4-cost-drawn", at: 48}],
};
