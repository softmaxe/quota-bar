import { describe, expect, it } from "vitest";
import { beat1 } from "../../timeline/beats/beat1-quota";
import { quotaAt } from "../../timeline/quota";

describe("Beat 1 story timing", () => {
  const m = beat1.moments;

  it("holds the circled interruption before moving to the menu bar", () => {
    expect(m.firstKeys).toBeLessThan(m.limit);
    expect(m.limit).toBeLessThan(m.circle);
    expect(m.circleComplete - m.circle).toBeGreaterThanOrEqual(0.5);
    expect(m.camera - m.circleComplete).toBeGreaterThanOrEqual(1.5);
    expect(m.cameraComplete).toBeLessThan(m.icon);
    expect(m.iconComplete).toBeLessThan(m.menuNote);
    expect(beat1.end - m.menuNoteComplete).toBeGreaterThanOrEqual(1);
  });

  it("asks the quota question at the limit and introduces the menu bar during the move", () => {
    const question = beat1.captions.find((caption) => caption.id === "b1-question")!;
    const menu = beat1.captions.find((caption) => caption.id === "b1-menu-bar")!;
    expect(question.start).toBe(m.limit);
    expect(question.end).toBeGreaterThan(m.circleComplete);
    expect(menu.start).toBeGreaterThan(m.camera);
    expect(menu.start).toBeLessThan(m.cameraComplete);
    expect(menu.end).toBeGreaterThan(m.iconComplete);
  });

  it("uses one continuous pen cue for each drawing gesture", () => {
    for (const [start, end] of [[m.circle, m.circleComplete], [m.icon, m.iconComplete], [m.menuNote, m.menuNoteComplete]]) {
      const cues = beat1.cues.filter((cue) => cue.type === "pen_scribble" && cue.at === start);
      expect(cues).toHaveLength(1);
      expect(cues[0].params!.duration).toBeCloseTo(end - start, 9);
    }
  });

  it("shows the alarmed pose without inventing a red quota warning", () => {
    expect(quotaAt(m.limit - 1 / 30).pose).toBe("coding");
    expect(quotaAt(m.limit).pose).toBe("alarmed");
    for (const time of [m.editor, m.limit, m.circleComplete, m.iconComplete]) {
      const state = quotaAt(time);
      expect(state.provider).toBe("Codex");
      expect(state.reading.session!.remainingPercent).toBe(88);
      expect(state.runningLow).toBe(false);
    }
  });
});
