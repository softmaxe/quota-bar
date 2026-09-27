import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";

const moments = {
  editor: 0.15,
  firstKeys: 0.8,
  secondKeys: 2.6,
  limit: 4.8,
  circle: 5.05,
  circleComplete: 5.85,
  note: 6.05,
  camera: 7.6,
  cameraComplete: 8.9,
  icon: 8.95,
  iconComplete: 10,
  menuNote: 10.15,
  menuNoteComplete: 10.85,
};

export const beat1: Beat<typeof moments> = {
  index: 1, key: "quota", title: "Quota runs out", start: 0, end: 12,
  captions: [
    {id: "b1-coding", text: {en: "Just one more change...", zh: "再改一点，就写好了……"},
      start: 0.4, end: 4.4, placement: CAPTION_PLACEMENT},
    {id: "b1-question", text: {en: "How much quota is left?", zh: "还剩多少额度？"},
      start: moments.limit, end: 8, placement: CAPTION_PLACEMENT},
    {id: "b1-menu-bar", text: {en: "Keep it in the menu bar.", zh: "在菜单栏里，随时看一眼。"},
      start: 8.3, end: 11.8, placement: CAPTION_PLACEMENT},
  ],
  cues: [
    {type: "shortcut", at: moments.firstKeys, params: {gain: 0.15}},
    {type: "shortcut", at: moments.secondKeys, params: {gain: 0.15}},
    {type: "click", at: moments.limit, params: {gain: 0.22}},
    {type: "pen_scribble", at: moments.circle, params: {duration: moments.circleComplete - moments.circle}},
    {type: "pen_scribble", at: moments.note, params: {duration: 0.6, gain: 0.25}},
    {type: "pen_scribble", at: moments.icon, params: {duration: moments.iconComplete - moments.icon}},
    {type: "pen_scribble", at: moments.menuNote, params: {duration: moments.menuNoteComplete - moments.menuNote}},
  ],
  moments,
  reviewFrames: [
    {name: "beat-1-coding", at: 2.7},
    {name: "beat-1-rate-limit-circled", at: 6.7},
    {name: "beat-1-icon-drawing", at: 9.5},
    {name: "beat-1-menu-bar-introduced", at: 11.2},
  ],
};
