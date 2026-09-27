import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { ROOT } from "../../scripts/paths";
import { beat4, COST_NOTES, COST_PINNED_DAY } from "../../timeline/beats/beat4-cost";
import { QUOTA_MOMENTS } from "../../timeline/quota";
import { USAGE_FIXTURES } from "../../video/interface/fixtures";

describe("cost story", () => {
  it("draws all ten days before pinning Sep 22 and opening its model breakdown", () => {
    const m = beat4.moments;
    expect([beat4.start, beat4.end]).toEqual([QUOTA_MOMENTS.night, QUOTA_MOMENTS.outro]);
    expect(m.bars).toHaveLength(USAGE_FIXTURES.Claude.cost.length);
    expect(m.costMode).toBeLessThan(m.barsStart);
    expect(m.bars[0]).toBe(m.barsStart);
    expect(m.bars.at(-1)).toBeLessThan(m.barsEnd);
    expect(m.barsEnd).toBeLessThan(m.pinDay);
    expect(m.pinDay).toBeLessThan(m.modelsOpen);
    expect(m.modelsOpen).toBeLessThan(m.ledger);
    expect(COST_PINNED_DAY + 15).toBe(22);
    expect(USAGE_FIXTURES.Claude.cost[COST_PINNED_DAY]).toBe(41.3);
    expect(USAGE_FIXTURES.Claude.tokens[COST_PINNED_DAY]).toBe(33);
    const models = USAGE_FIXTURES.Claude.models[COST_PINNED_DAY];
    expect(models.map((row) => row.name)).toEqual(["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]);
    expect(models.reduce((sum, row) => sum + Number(row.cost.slice(1)), 0)).toBeCloseTo(41.3);
    expect(models.reduce((sum, row) => sum + Number(row.tokens.slice(0, -1)), 0)).toBeCloseTo(33);
    for (const at of m.bars) expect(beat4.cues.some((cue) => cue.type === "tick" && cue.at === at)).toBe(true);
    for (const at of [m.costMode, m.pinDay, m.modelsOpen]) {
      expect(beat4.cues.some((cue) => cue.type === "click" && cue.at === at)).toBe(true);
    }
  });

  it("has translated ledger notes whose handwritten glyphs are bundled", () => {
    const charset = new Set(fs.readFileSync(path.join(ROOT, "video/public/fonts/LXGWWenKai-Regular.subset.charset.txt"), "utf8"));
    for (const text of Object.values(COST_NOTES)) {
      expect(Object.keys(text)).toEqual(["en", "zh"]);
      for (const line of Object.values(text)) {
        expect(line.trim()).not.toBe("");
        expect([...line].filter((char) => !charset.has(char))).toEqual([]);
      }
    }
    expect(beat4.reviewFrames.some((frame) => frame.at > beat4.moments.modelsOpen && frame.at < beat4.moments.ledger)).toBe(true);
    expect(beat4.reviewFrames.some((frame) => frame.at > beat4.moments.ratesMarked)).toBe(true);
  });
});
