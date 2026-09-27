/** All times are absolute Film seconds; intervals are half-open [start, end). */
export type Seconds = number;
export type Language = "en" | "zh";
export const LANGUAGES: readonly Language[] = ["en", "zh"];
export type LocalizedText = Record<Language, string>;

export interface CaptionPlacement {
  x: number;
  y: number;
  width: number;
  align: "left" | "center" | "right";
  fontSize: number;
  rotate?: number;
}

export interface Caption {
  id: string;
  text: LocalizedText;
  start: Seconds;
  end: Seconds;
  placement: CaptionPlacement;
  variant?: "title" | "narration";
}

/** Each type names audio/quotabar_audio/sfx/<type>.py. */
export interface SoundCue {
  type: string;
  at: Seconds;
  params?: Record<string, number | string | boolean>;
}

export type BeatKey = "quota" | "glance" | "reset" | "cost" | "outro";
export type Moments = Record<string, Seconds | readonly Seconds[]>;
export interface ReviewFrame { name: string; at: Seconds }

export interface Beat<M extends Moments = Moments> {
  index: 1 | 2 | 3 | 4 | 5;
  key: BeatKey;
  title: string;
  start: Seconds;
  end: Seconds;
  captions: Caption[];
  cues: SoundCue[];
  moments: M;
  reviewFrames: ReviewFrame[];
}

export interface Film {
  durationSeconds: Seconds;
  fps: number;
  width: number;
  height: number;
  fadeOutSeconds: Seconds;
  beats: Beat[];
}
