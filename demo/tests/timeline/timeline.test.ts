/** Assert the exported JSON consumed by the renderer and audio package. */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { exportTimeline } from "../../scripts/export-timeline";
import { ROOT } from "../../scripts/paths";
import { reviewFrameTimes } from "../../scripts/review-frames";
import { LANGUAGES, type Film } from "../../timeline";
import { momentTimes } from "../../timeline/helpers";
import { clauses, tokenize } from "../../video/components/captionLayout";

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "quotabar-timeline-"));
const film: Film = JSON.parse(fs.readFileSync(exportTimeline(path.join(temp, "timeline.json")), "utf8"));
afterAll(() => fs.rmSync(temp, {recursive: true, force: true}));
const captions = film.beats.flatMap((b) => b.captions);

describe("exported Film timeline", () => {
  it("contains five Beats that tile the 75-second Film without gaps", () => {
    expect(film).toMatchObject({durationSeconds: 75, width: 1920, height: 1080, fps: 30});
    expect(film.beats.map((b) => [b.key, b.start, b.end])).toEqual([
      ["quota", 0, 12], ["glance", 12, 30], ["reset", 30, 45], ["cost", 45, 62], ["outro", 62, 75],
    ]);
    expect(film.beats.map((b) => b.index)).toEqual([1, 2, 3, 4, 5]);
    for (const [i, beat] of film.beats.entries()) {
      expect(beat.end).toBeGreaterThan(beat.start);
      expect(beat.start).toBe(i ? film.beats[i - 1].end : 0);
      expect(beat.captions.length).toBeGreaterThan(0);
    }
    expect(film.beats.at(-1)!.end).toBe(film.durationSeconds);
  });

  it("has nonempty translations for exactly the same unique Caption entries", () => {
    expect(new Set(captions.map((c) => c.id)).size).toBe(captions.length);
    for (const caption of captions) {
      expect(Object.keys(caption.text).sort()).toEqual([...LANGUAGES].sort());
      for (const language of LANGUAGES) expect(caption.text[language].trim(), caption.id).not.toBe("");
    }
  });

  it("keeps Captions at least 2.5 seconds long, without any overlap", () => {
    const ordered = [...captions].sort((a, b) => a.start - b.start);
    for (const [i, caption] of ordered.entries()) {
      expect(caption.end - caption.start, caption.id).toBeGreaterThanOrEqual(2.5 - 1e-9);
      if (i) expect(caption.start, caption.id).toBeGreaterThanOrEqual(ordered[i - 1].end);
    }
    for (const beat of film.beats) for (const caption of beat.captions) {
      expect(caption.start, caption.id).toBeGreaterThanOrEqual(beat.start);
      expect(caption.end, caption.id).toBeLessThanOrEqual(beat.end);
    }
  });

  it("places every cue at a named moment or Caption start inside its Beat, in story order", () => {
    for (const beat of film.beats) {
      const times = momentTimes(beat.moments).map(([, at]) => at);
      for (const time of times) {
        expect(time).toBeGreaterThanOrEqual(beat.start);
        expect(time).toBeLessThan(beat.end);
      }
      const named = new Set([...times, ...beat.captions.map((c) => c.start)]);
      let previous = beat.start;
      for (const cue of beat.cues) {
        expect(cue.at).toBeGreaterThanOrEqual(previous);
        expect(cue.at).toBeLessThan(beat.end);
        expect(named.has(cue.at), `${cue.type}@${cue.at}`).toBe(true);
        expect(cue.type).toMatch(/^[a-z][a-z0-9_]*$/);
        expect(fs.existsSync(path.join(ROOT, "audio/quotabar_audio/sfx", `${cue.type}.py`)), cue.type).toBe(true);
        previous = cue.at;
      }
    }
  });

  it("exports valid, uniquely named review frames for each Beat and Caption", () => {
    const frames = reviewFrameTimes();
    expect(new Set(frames.map((f) => f.name)).size).toBe(frames.length);
    for (const frame of frames) {
      expect(frame.name).toMatch(/^[a-z0-9-]+$/);
      expect(frame.at).toBeGreaterThanOrEqual(0);
      expect(frame.at).toBeLessThan(film.durationSeconds);
    }
    for (const beat of film.beats) {
      expect(beat.reviewFrames.length).toBeGreaterThan(0);
      for (const frame of beat.reviewFrames) {
        expect(frame.at).toBeGreaterThanOrEqual(beat.start);
        expect(frame.at).toBeLessThan(beat.end);
      }
    }
  });
});

describe("Caption font and frame bounds", () => {
  const fonts = path.join(ROOT, "video/public/fonts");
  const charset = new Set(fs.readFileSync(path.join(fonts, "LXGWWenKai-Regular.subset.charset.txt"), "utf8"));
  const metrics: {unitsPerEm: number; advances: Record<string, number>} = JSON.parse(
    fs.readFileSync(path.join(fonts, "LXGWWenKai-Regular.subset.metrics.json"), "utf8"));

  for (const language of LANGUAGES) it(`fits every ${language} Caption with the bundled glyph widths`, () => {
    for (const caption of captions) {
      const text = caption.text[language];
      expect([...text].filter((char) => !charset.has(char)), caption.id).toEqual([]);
      const p = caption.placement;
      const left = p.x - (p.align === "center" ? p.width / 2 : p.align === "right" ? p.width : 0);
      expect(left, caption.id).toBeGreaterThanOrEqual(36);
      expect(left + p.width, caption.id).toBeLessThanOrEqual(film.width - 36);
      expect(p.y, caption.id).toBeGreaterThanOrEqual(36);
      // Leave 10% width for rotation, ink, and browser shaping. Count wrapping
      // with actual advances from the shipped font, without shrinking the text.
      let used = 0;
      let lines = 1;
      const tokens = tokenize(text);
      const units = clauses(tokens, p.fontSize, p.width).flatMap((clause) =>
        clause.keep ? [clause.tokens.map((i) => tokens[i]).join("")] : clause.tokens.map((i) => tokens[i]));
      for (const token of units) {
        const width = [...token].reduce((sum, char) => sum + metrics.advances[String(char.codePointAt(0))], 0)
          / metrics.unitsPerEm * p.fontSize;
        expect(width, `${caption.id}: ${token}`).toBeLessThanOrEqual(p.width * 0.9);
        if (used + width > p.width * 0.9) {lines++; used = 0;}
        used += width;
      }
      const rotatedExtra = Math.sin(Math.abs(p.rotate ?? 0) * Math.PI / 180) * p.width;
      expect(p.y + lines * p.fontSize * 1.35 + rotatedExtra, caption.id).toBeLessThanOrEqual(film.height - 36);
    }
  });
});
