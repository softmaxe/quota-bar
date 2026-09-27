import { beat1 } from "./beats/beat1-quota";
import { beat2 } from "./beats/beat2-glance";
import { beat3 } from "./beats/beat3-reset";
import { beat4 } from "./beats/beat4-cost";
import { beat5 } from "./beats/beat5-outro";
import type { Caption, Film, Seconds } from "./types";
export * from "./types";

export const FILM: Film = {
  durationSeconds: 75, fps: 30, width: 1920, height: 1080, fadeOutSeconds: 1,
  beats: [beat1, beat2, beat3, beat4, beat5],
};
export const allCaptions = (film: Film = FILM): Caption[] => film.beats.flatMap((b) => b.captions);
export const toFrame = (time: Seconds, fps = FILM.fps): number => Math.round(time * fps);
