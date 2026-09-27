import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Language } from "../timeline";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const OUT_DIR = path.join(ROOT, "out");
export const PATHS = {
  timelineJson: path.join(OUT_DIR, "timeline.json"),
  audioWav: path.join(OUT_DIR, "audio.wav"),
  manifest: path.join(OUT_DIR, "build-manifest.json"),
  videoEntry: path.join(ROOT, "video/index.ts"),
  publicDir: path.join(ROOT, "video/public"),
  audioProject: path.join(ROOT, "audio"),
  film: (language: Language) => path.join(OUT_DIR, `quotabar-demo-${language}.mp4`),
  videoOnly: (language: Language) => path.join(OUT_DIR, `video-only-${language}.mp4`),
  framesDir: (language: Language) => path.join(OUT_DIR, "frames", language),
};
