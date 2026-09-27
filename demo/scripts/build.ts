/** Timeline -> synthesised audio -> both pictures -> MP4 mux -> PNG review frames. */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { bundle } from "@remotion/bundler";
import { renderMedia, selectComposition } from "@remotion/renderer";
import { FILM, LANGUAGES } from "../timeline";
import { sourceHash } from "./build-state";
import { exportTimeline } from "./export-timeline";
import { OUT_DIR, PATHS, ROOT } from "./paths";
import { reviewFrameTimes } from "./review-frames";

const run = (command: string, args: string[]) => execFileSync(command, args, {cwd: ROOT, stdio: "inherit"});

function concurrency(): number {
  const arg = process.argv.find((a) => a.startsWith("--concurrency="));
  if (!arg) return Math.max(1, Math.min(8, Math.floor(os.cpus().length * 0.75)));
  const value = arg.slice("--concurrency=".length);
  if (!/^[1-9]\d*$/.test(value)) throw new Error("--concurrency must be a positive integer");
  return Number(value);
}

export async function buildFilms(): Promise<void> {
  const start = Date.now();
  const renderConcurrency = concurrency();
  fs.mkdirSync(OUT_DIR, {recursive: true});
  fs.rmSync(PATHS.manifest, {force: true});
  console.log("Export timeline");
  exportTimeline();
  console.log("Synthesise audio");
  run("uv", ["run", "--locked", "--project", PATHS.audioProject, "python", "-m", "quotabar_audio", PATHS.timelineJson, PATHS.audioWav]);
  const sourceAtStart = sourceHash();
  const bundleDir = fs.mkdtempSync(path.join(OUT_DIR, ".bundle-"));
  try {
    const serveUrl = await bundle({entryPoint: PATHS.videoEntry, publicDir: PATHS.publicDir, outDir: bundleDir});
    for (const language of LANGUAGES) {
      console.log(`Render ${language}`);
      const composition = await selectComposition({serveUrl, id: `Film-${language}`});
      let lastPct = -1;
      await renderMedia({serveUrl, composition, codec: "h264", crf: 18, pixelFormat: "yuv420p",
        muted: true, imageFormat: "jpeg", jpegQuality: 92, concurrency: renderConcurrency,
        outputLocation: PATHS.videoOnly(language),
        onProgress: ({progress}) => {
          const pct = Math.floor(progress * 10) * 10;
          if (pct !== lastPct) { lastPct = pct; console.log(`  ${language} ${pct}%`); }
        },
      });
      console.log(`Mux ${language}`);
      run("ffmpeg", ["-y", "-loglevel", "error", "-i", PATHS.videoOnly(language), "-i", PATHS.audioWav,
        "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
        "-t", String(FILM.durationSeconds), "-movflags", "+faststart", PATHS.film(language)]);
      console.log(`Export ${language} review frames`);
      fs.rmSync(PATHS.framesDir(language), {recursive: true, force: true});
      fs.mkdirSync(PATHS.framesDir(language), {recursive: true});
      for (const {name, at} of reviewFrameTimes()) {
        run("ffmpeg", ["-y", "-loglevel", "error", "-ss", at.toFixed(6), "-i", PATHS.film(language),
          "-frames:v", "1", path.join(PATHS.framesDir(language), `${name}.png`)]);
      }
      fs.rmSync(PATHS.videoOnly(language));
    }
    if (sourceHash() !== sourceAtStart) throw new Error("Film sources changed during the build; rebuild before reviewing");
    fs.writeFileSync(PATHS.manifest, JSON.stringify({sourceHash: sourceAtStart}, null, 2) + "\n");
    console.log(`Built both films and review frames in ${((Date.now() - start) / 1000).toFixed(1)}s: ${OUT_DIR}`);
  } finally {
    fs.rmSync(bundleDir, {recursive: true, force: true});
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  buildFilms().catch((error) => {console.error(error); process.exitCode = 1;});
}
