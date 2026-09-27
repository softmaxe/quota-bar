import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";

export const beat3: Beat<{ reveal: number }> = {
  index: 3, key: "reset", title: "Running low, then reset", start: 30, end: 45,
  captions: [
    {"id": "b3-1", "text": {"en": "A warning when quota runs low.", "zh": "额度不足，机器人提醒你。"}, "start": 30.5, "end": 37.2, "placement": CAPTION_PLACEMENT},
    {"id": "b3-2", "text": {"en": "A fresh window. Back to work.", "zh": "额度重置，继续工作。"}, "start": 37.7, "end": 44.5, "placement": CAPTION_PLACEMENT},
  ],
  cues: [{type: "click", at: 30.5}],
  moments: {reveal: 30.5},
  reviewFrames: [{name: "beat-3-reset-drawn", at: 33}],
};
