import type { Beat, LocalizedText } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";
import { QUOTA_MOMENTS } from "../quota";

export const COST_PINNED_DAY = 7;
export const COST_NOTES = {
  days: {en: "Ten days of local usage", zh: "十天的本地用量"},
  pinned: {en: "Sep 22 · 3 models", zh: "9月22日 · 3个模型"},
  book: {en: "Price book", zh: "价格簿"},
  date: {en: "Date", zh: "日期"},
  rates: {en: "Model rates", zh: "模型费率"},
  row: {en: "That day's rates", zh: "当天费率"},
  note: {en: "Saved tokens, priced by day.", zh: "已存用量，按当天费率估算。"},
} satisfies Record<string, LocalizedText>;

const moments = {
  cardOpen: 45.4,
  costMode: 46.2,
  barsStart: 46.6,
  bars: Array.from({length: 10}, (_, index) => 46.6 + index * 0.3),
  barsEnd: 49.6,
  pinDay: 50.4,
  modelsOpen: 51.4,
  modelsMarked: 52.0,
  ledger: 54.8,
  ledgerNote: 55.9,
  ratesMarked: 57.0,
};

export const beat4: Beat<typeof moments> = {
  index: 4, key: "cost", title: "Every dollar", start: QUOTA_MOMENTS.night, end: QUOTA_MOMENTS.outro,
  captions: [
    {id: "b4-1", text: {en: "See what each day costs.", zh: "每天的开销，看得清楚。"}, start: 45.6, end: 50.1, placement: CAPTION_PLACEMENT},
    {id: "b4-2", text: {en: "Pin a day. See each model.", zh: "固定一天，查看各模型的开销。"}, start: moments.pinDay, end: 54.5, placement: CAPTION_PLACEMENT},
    {id: "b4-3", text: {en: "Each model uses the rates for that day.", zh: "每个模型，按当天的费率估算。"}, start: 55, end: 61.5, placement: CAPTION_PLACEMENT},
  ],
  cues: [
    {type: "click", at: moments.cardOpen},
    {type: "click", at: moments.costMode},
    ...moments.bars.map((at) => ({type: "tick", at, params: {duration: 0.12, gain: 0.11}})),
    {type: "click", at: moments.pinDay},
    {type: "click", at: moments.modelsOpen},
    {type: "tick", at: moments.modelsMarked, params: {gain: 0.20}},
    {type: "pen_scribble", at: moments.ledger, params: {duration: 1.1, gain: 0.18}},
    {type: "tick", at: moments.ratesMarked, params: {gain: 0.22}},
  ],
  moments,
  reviewFrames: [
    {name: "beat-4-bars-in-progress", at: 48.1},
    {name: "beat-4-ten-days", at: 49.8},
    {name: "beat-4-pinned-day", at: 50.9},
    {name: "beat-4-model-breakdown", at: 53.4},
    {name: "beat-4-price-book", at: 59.5},
  ],
};
