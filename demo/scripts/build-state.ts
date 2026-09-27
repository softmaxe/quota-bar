import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { LANGUAGES } from "../timeline";
import { PATHS, ROOT } from "./paths";
import { reviewFrameTimes } from "./review-frames";

const SOURCES = ["timeline", "video", "audio/quotabar_audio", "audio/pyproject.toml", "audio/uv.lock",
  "scripts", "package.json", "package-lock.json", "remotion.config.ts", "tsconfig.json"];
const IGNORED = new Set(["__pycache__", ".venv", "node_modules"]);

/** Content hashes survive a checkout or merge without mistaking old renders for new ones. */
export function sourceHash(): string {
  const hash = createHash("sha256");
  function visit(file: string): void {
    const absolute = path.join(ROOT, file);
    if (fs.statSync(absolute).isDirectory()) {
      for (const child of fs.readdirSync(absolute).sort()) {
        if (!IGNORED.has(child) && !child.startsWith(".")) visit(path.join(file, child));
      }
    } else {
      hash.update(file).update("\0").update(fs.readFileSync(absolute)).update("\0");
    }
  }
  SOURCES.forEach(visit);
  return hash.digest("hex");
}

export function expectedOutputs(): string[] {
  return [PATHS.timelineJson, PATHS.audioWav, ...LANGUAGES.flatMap((language) => [
    PATHS.film(language),
    ...reviewFrameTimes().map(({name}) => path.join(PATHS.framesDir(language), `${name}.png`)),
  ])];
}

export function staleReason(): string | null {
  const missing = [PATHS.manifest, ...expectedOutputs()].find((file) => !fs.existsSync(file));
  if (missing) return `${path.relative(ROOT, missing)} is missing`;
  const manifest = JSON.parse(fs.readFileSync(PATHS.manifest, "utf8"));
  return manifest.sourceHash === sourceHash() ? null : "Film sources changed after the last build";
}
