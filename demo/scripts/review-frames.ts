import { allCaptions, FILM, type ReviewFrame } from "../timeline";

export const reviewFrameTimes = (): ReviewFrame[] => [
  ...FILM.beats.map((b) => ({name: `beat-${b.index}-${b.key}-mid`, at: (b.start + b.end) / 2})),
  ...allCaptions().map((c) => ({name: `caption-${c.id}`, at: c.end - 0.4})),
  ...FILM.beats.flatMap((b) => b.reviewFrames),
  {name: "final-blank-paper", at: FILM.durationSeconds - 1 / FILM.fps},
];
