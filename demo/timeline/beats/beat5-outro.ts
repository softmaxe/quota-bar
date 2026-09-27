import type { Beat } from "../types";
import { CAPTION_PLACEMENT } from "../helpers";
import { QUOTA_MOMENTS } from "../quota";

const moments = {
  reveal: QUOTA_MOMENTS.outro,
  export: 62.5,
  saved: 63.15,
  openReport: 63.9,
  reportDrawn: 64.2,
  languageSwitch: 65.45,
  pageTurned: 66.05,
  wave: QUOTA_MOMENTS.wave,
  title: 68.45,
  install: 69.05,
  installWritten: 71.15,
  repository: 71.25,
  repositoryWritten: 72.65,
};

export const beat5: Beat<typeof moments> = {
  index: 5, key: "outro", title: "Report and outro", start: QUOTA_MOMENTS.outro, end: 75,
  captions: [
    {id: "b5-1", text: {en: "Export an offline report. Read it in either language.", zh: "导出离线报告，中英文随时切换。"}, start: 62.3, end: 67.9, placement: CAPTION_PLACEMENT},
    {id: "b5-2", text: {en: "QuotaBar. Keep track as you work.", zh: "QuotaBar，工作时随时掌握用量。"}, start: 68.7, end: 73.5, placement: CAPTION_PLACEMENT},
  ],
  cues: [
    {type: "click", at: moments.export},
    {type: "tick", at: moments.saved},
    {type: "click", at: moments.openReport},
    {type: "pen_scribble", at: moments.reportDrawn, params: {duration: 0.5, gain: 0.24}},
    {type: "click", at: moments.languageSwitch},
    {type: "pen_scribble", at: moments.title, params: {duration: 0.55, gain: 0.24}},
    {type: "pen_scribble", at: moments.install, params: {duration: 2.1, gain: 0.24}},
    {type: "pen_scribble", at: moments.repository, params: {duration: 1.4, gain: 0.22}},
  ],
  moments,
  reviewFrames: [
    {name: "beat-5-export-saved", at: 63.7},
    {name: "beat-5-report-chinese", at: 65.1},
    {name: "beat-5-report-page-turn", at: 65.65},
    {name: "beat-5-report-english", at: 67.2},
    {name: "beat-5-robot-wave", at: 68.9},
    {name: "beat-5-install-and-repository", at: 73.2},
    {name: "beat-5-fade-to-paper", at: 74.5},
  ],
};
