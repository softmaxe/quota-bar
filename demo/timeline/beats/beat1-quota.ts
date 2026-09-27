import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";

export const beat1: Beat<{ reveal: number }> = {
  index: 1, key: "quota", title: "Quota runs out", start: 0, end: 12,
  captions: [
    {"id": "b1-1", "text": {"en": "How much quota is left?", "zh": "还剩多少额度？"}, "start": 0.5, "end": 5.7, "placement": CAPTION_PLACEMENT},
    {"id": "b1-2", "text": {"en": "Keep it in the menu bar.", "zh": "在菜单栏里，随时看一眼。"}, "start": 6.2, "end": 11.5, "placement": CAPTION_PLACEMENT},
  ],
  cues: [{type: "click", at: 0.5}],
  moments: {reveal: 0.5},
  reviewFrames: [{name: "beat-1-quota-drawn", at: 3}],
};
