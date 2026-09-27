import type { CaptionPlacement, Moments } from "./types";

/** The drawing occupies y=150..810; Captions sit below it in both films. */
export const CAPTION_PLACEMENT: CaptionPlacement = {
  x: 960, y: 885, width: 1640, fontSize: 44, align: "center", rotate: -0.3,
};

export const momentTimes = (moments: Moments): [string, number][] =>
  Object.entries(moments).flatMap(([name, value]) =>
    typeof value === "number" ? [[name, value] as [string, number]] :
      value.map((at, i) => [`${name}[${i}]`, at] as [string, number]),
  );
