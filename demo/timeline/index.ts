import { beat1 } from "./beats/beat1-quota";
import { beat2 } from "./beats/beat2-glance";
import { beat3 } from "./beats/beat3-reset";
import { beat4 } from "./beats/beat4-cost";
import { beat5 } from "./beats/beat5-outro";
import type { Beat, Caption, Film, Seconds, SoundCue } from "./types";
export * from "./types";

export const FILM: Film = {
  durationSeconds: 75, fps: 30, width: 1920, height: 1080, fadeOutSeconds: 1,
  beats: [beat1, beat2, beat3, beat4, beat5],
};
export const allCaptions = (film: Film = FILM): Caption[] => film.beats.flatMap((b) => b.captions);
export const allCues = (film: Film = FILM): SoundCue[] => film.beats.flatMap((b) => b.cues).sort((a, b) => a.at - b.at);
export const toFrame = (time: Seconds, fps = FILM.fps): number => Math.round(time * fps);
export const beatByKey = (key: Beat["key"], film: Film = FILM): Beat => {
  const found = film.beats.find((b) => b.key === key);
  if (!found) throw new Error(`No Beat with key ${key}`);
  return found;
};
export const captionById = (beat: Beat, id: string): Caption => {
  const found = beat.captions.find((c) => c.id === id);
  if (!found) throw new Error(`No Caption ${id} in Beat ${beat.index}`);
  return found;
};
