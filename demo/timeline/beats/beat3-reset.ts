import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";
import { QUOTA_MOMENTS } from "../quota";

export const beat3 = {
  index: 3, key: "reset", title: "Running low, then reset", start: 30, end: 45,
  captions: [
    {id: "b3-1", text: {en: "The budget shrinks as you work.", zh: "继续工作，额度渐渐减少。"}, start: 30.3, end: 34.7, placement: CAPTION_PLACEMENT},
    {id: "b3-2", text: {en: "At 10% left, the menu bar robot turns red.", zh: "剩余额度降到10%，菜单栏机器人变红。"}, start: 35, end: 39.6, placement: CAPTION_PLACEMENT},
    {id: "b3-3", text: {en: "A fresh window. Back to work.", zh: "额度重置，继续工作。"}, start: 40.1, end: 44.6, placement: CAPTION_PLACEMENT},
  ],
  cues: [
    {type: "robot_alert", at: QUOTA_MOMENTS.runningLow},
    {type: "pen_scribble", at: 35.2, params: {duration: 0.65}},
    {type: "reset_scale", at: QUOTA_MOMENTS.reset},
    {type: "tick", at: 41},
  ],
  moments: {
    drainStart: QUOTA_MOMENTS.drainStart,
    runningLow: QUOTA_MOMENTS.runningLow,
    annotate: 35.2,
    exhausted: QUOTA_MOMENTS.exhausted,
    reset: QUOTA_MOMENTS.reset,
    filled: 41,
  },
  reviewFrames: [
    {name: "beat-3-draining", at: 33},
    {name: "beat-3-before-warning", at: QUOTA_MOMENTS.runningLow - 1 / 30},
    {name: "beat-3-exactly-ten-percent", at: QUOTA_MOMENTS.runningLow},
    {name: "beat-3-exhausted", at: 37.4},
    {name: "beat-3-before-reset", at: QUOTA_MOMENTS.reset - 1 / 30},
    {name: "beat-3-new-window", at: QUOTA_MOMENTS.reset},
    {name: "beat-3-refilling", at: 40.5},
    {name: "beat-3-reset-complete", at: 42.2},
  ],
} satisfies Beat;
