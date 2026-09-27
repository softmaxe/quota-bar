import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {afterAll, describe, expect, it} from "vitest";
import {exportTimeline} from "../../scripts/export-timeline";
import {ROOT} from "../../scripts/paths";
import type {Film} from "../../timeline";
import {GLANCE_NOTES} from "../../timeline/beats/beat2-glance";
import {providerAt, QUOTA_MOMENTS} from "../../timeline/quota";

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "quotabar-glance-"));
const film: Film = JSON.parse(fs.readFileSync(exportTimeline(path.join(temp, "timeline.json")), "utf8"));
const glance = film.beats.find((beat) => beat.key === "glance")!;
afterAll(() => fs.rmSync(temp, {recursive: true, force: true}));

describe("the exported one-glance story", () => {
  it("synchronizes every shortcut cue with the actual provider change", () => {
    const shortcuts = glance.cues.filter((cue) => cue.type === "shortcut");
    expect(shortcuts.map((cue) => cue.at)).toEqual([
      QUOTA_MOMENTS.showClaude, QUOTA_MOMENTS.showCodex, QUOTA_MOMENTS.returnClaude,
    ]);
    expect(shortcuts.map((cue) => providerAt(cue.at))).toEqual(["Claude", "Codex", "Claude"]);
    for (const cue of shortcuts) expect(providerAt(cue.at - 1 / film.fps)).not.toBe(providerAt(cue.at));
  });

  it("reviews both reset modes, the full pace details and both provider shortcuts", () => {
    const frames = Object.fromEntries(glance.reviewFrames.map((frame) => [frame.name, frame.at]));
    expect(frames["beat-2-reset-menu"]).toBeGreaterThan(glance.moments.resetMenu as number);
    expect(frames["beat-2-reset-menu"]).toBeLessThan(glance.moments.resetClock as number);
    expect(frames["beat-2-reset-clock"]).toBeGreaterThan(glance.moments.resetClock as number);
    expect(frames["beat-2-claude-pace"]).toBeGreaterThan((glance.moments.paceMark as number) + 0.85);
    expect(frames["beat-2-claude-pace"]).toBeLessThan(glance.moments.paceClose as number);
    expect(providerAt(frames["beat-2-codex-card"])).toBe("Codex");
    expect(providerAt(frames["beat-2-claude-pace"])).toBe("Claude");
    expect(providerAt(frames["beat-2-codex-shortcut"])).toBe("Codex");
    expect(providerAt(frames["beat-2-claude-return"])).toBe("Claude");
  });

  it("keeps every handwritten annotation in the shipped font in both languages", () => {
    const charset = new Set(fs.readFileSync(path.join(ROOT, "video/public/fonts/LXGWWenKai-Regular.subset.charset.txt"), "utf8"));
    for (const note of Object.values(GLANCE_NOTES)) for (const text of Object.values(note)) {
      expect(text.trim()).not.toBe("");
      expect([...text].filter((character) => !charset.has(character)), text).toEqual([]);
    }
  });
});
