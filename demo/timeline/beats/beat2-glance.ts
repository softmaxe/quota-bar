import type { Beat, LocalizedText } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";
import { QUOTA_MOMENTS } from "../quota";

export const GLANCE_NOTES = {
  card: {en: "One card. Two providers.", zh: "一个卡片，两个服务。"},
  countdown: {en: "Reset countdown", zh: "重置倒计时"},
  clock: {en: "Or a reset time", zh: "也能看重置时刻"},
  pace: {en: "Pace before reset", zh: "看清重置前的节奏"},
  reserve: {en: "Session: enough in reserve", zh: "本轮额度留有余量"},
  shortcuts: {en: "Switch providers", zh: "快捷切换服务"},
} satisfies Record<string, LocalizedText>;

export const GLANCE_MOMENTS = {
  open: QUOTA_MOMENTS.cardOpen,
  bars: 13.2,
  resetMark: 14.4,
  resetMenu: 15.3,
  resetClock: 16.1,
  showClaude: QUOTA_MOMENTS.showClaude,
  paceOpen: 19.8,
  paceMark: 21,
  paceClose: 24.1,
  showCodex: QUOTA_MOMENTS.showCodex,
  returnClaude: QUOTA_MOMENTS.returnClaude,
} as const;

export const beat2: Beat<typeof GLANCE_MOMENTS> = {
  index: 2, key: "glance", title: "One glance", start: 12, end: 30,
  captions: [
    {id: "b2-open", text: {en: "Open the menu bar card. See what's left.", zh: "点开菜单栏，看看还剩多少额度。"},
      start: 12.4, end: 17.8, placement: CAPTION_PLACEMENT},
    {id: "b2-pace", text: {en: "Reset time and pace help plan the next prompt.", zh: "重置时间和使用节奏，帮你安排下一次提问。"},
      start: 18.2, end: 24.7, placement: CAPTION_PLACEMENT},
    {id: "b2-shortcuts", text: {en: "Switch providers with a shortcut.", zh: "用快捷键切换 Codex 和 Claude。"},
      start: 25.1, end: 29.7, placement: CAPTION_PLACEMENT},
  ],
  cues: [
    {type: "click", at: GLANCE_MOMENTS.open},
    {type: "pen_scribble", at: GLANCE_MOMENTS.bars, params: {duration: 0.65, pan: -0.1}},
    {type: "pen_scribble", at: GLANCE_MOMENTS.resetMark, params: {duration: 0.65, pan: 0.2}},
    {type: "click", at: GLANCE_MOMENTS.resetMenu},
    {type: "click", at: GLANCE_MOMENTS.resetClock},
    {type: "shortcut", at: GLANCE_MOMENTS.showClaude},
    {type: "click", at: GLANCE_MOMENTS.paceOpen},
    {type: "pen_scribble", at: GLANCE_MOMENTS.paceMark, params: {duration: 0.85, pan: 0.1}},
    {type: "click", at: GLANCE_MOMENTS.paceClose},
    {type: "shortcut", at: GLANCE_MOMENTS.showCodex},
    {type: "shortcut", at: GLANCE_MOMENTS.returnClaude},
  ],
  moments: GLANCE_MOMENTS,
  reviewFrames: [
    {name: "beat-2-codex-card", at: 14.2},
    {name: "beat-2-reset-menu", at: 15.8},
    {name: "beat-2-reset-clock", at: 17},
    {name: "beat-2-claude-shortcut", at: 18.9},
    {name: "beat-2-claude-pace", at: 23.2},
    {name: "beat-2-codex-shortcut", at: 26.8},
    {name: "beat-2-claude-return", at: 28.6},
  ],
};
