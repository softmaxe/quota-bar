import fs from "node:fs";
import path from "node:path";
import {afterAll, beforeEach, expect, it, vi} from "vitest";

const state = vi.hoisted(() => ({failure: "", directories: [] as string[], hashes: 0}));

vi.mock("../../scripts/paths", async () => {
  const filesystem = await import("node:fs");
  const os = await import("node:os");
  const paths = await import("node:path");
  const root = filesystem.mkdtempSync(paths.join(os.tmpdir(), "quotabar-build-test-"));
  return {ROOT: root, OUT_DIR: root, PATHS: {
    manifest: paths.join(root, "manifest.json"), videoEntry: "entry.tsx", publicDir: "public", audioProject: "audio",
    timelineJson: paths.join(root, "timeline.json"), audioWav: paths.join(root, "audio.wav"),
    videoOnly: (language: string) => paths.join(root, `${language}-silent.mp4`),
    film: (language: string) => paths.join(root, `${language}.mp4`),
    framesDir: (language: string) => paths.join(root, language),
  }};
});
vi.mock("node:child_process", () => ({execFileSync: vi.fn()}));
vi.mock("../../scripts/export-timeline", () => ({exportTimeline: vi.fn()}));
vi.mock("../../scripts/review-frames", () => ({reviewFrameTimes: () => []}));
vi.mock("../../scripts/build-state", () => ({sourceHash: () =>
  state.failure === "changed" && state.hashes++ > 0 ? "changed" : "original"}));
vi.mock("@remotion/bundler", () => ({bundle: async ({outDir}: {outDir: string}) => {
  state.directories.push(outDir);
  fs.writeFileSync(path.join(outDir, "partial-bundle.js"), "bundle");
  if (state.failure === "bundle") throw new Error("bundle failed");
  return outDir;
}}));
vi.mock("@remotion/renderer", () => ({
  selectComposition: async () => ({}),
  renderMedia: async ({outputLocation}: {outputLocation: string}) => {
    if (state.failure === "render") throw new Error("render failed");
    fs.writeFileSync(outputLocation, "video");
  },
}));

import {buildFilms} from "../../scripts/build";
import {OUT_DIR, PATHS} from "../../scripts/paths";

beforeEach(() => {
  state.directories = [];
  state.hashes = 0;
  vi.spyOn(console, "log").mockImplementation(() => {});
});
afterAll(() => {
  vi.restoreAllMocks();
  fs.rmSync(OUT_DIR, {recursive: true, force: true});
});

it.each(["bundle", "render", "changed", "success"])("cleans build bundles after %s", async (result) => {
  state.failure = result;
  if (result === "success") await buildFilms();
  else await expect(buildFilms()).rejects.toThrow(result === "changed" ? "Film sources changed" : `${result} failed`);
  expect(state.directories).toHaveLength(1);
  for (const directory of state.directories) expect(fs.existsSync(directory)).toBe(false);
  expect(fs.readdirSync(OUT_DIR).filter((name) => name.startsWith(".bundle-"))).toEqual([]);
  expect(fs.existsSync(PATHS.manifest)).toBe(result === "success");
});
