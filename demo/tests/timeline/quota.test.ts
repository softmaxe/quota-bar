import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {afterAll, describe, expect, it} from "vitest";
import {exportTimeline} from "../../scripts/export-timeline";
import {FILM} from "../../timeline";
import {
  isRunningLow, providerAt, QUOTA_MOMENTS, QUOTA_READINGS, quotaAt, tightestRemaining,
  type QuotaReading, type QuotaState, type QuotaWindow,
} from "../../timeline/quota";

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "quotabar-quota-"));
const exported = JSON.parse(fs.readFileSync(exportTimeline(path.join(temp, "timeline.json")), "utf8"));
afterAll(() => fs.rmSync(temp, {recursive: true, force: true}));

describe("the exported quota story", () => {
  it("retains the original sample facts and complete pace details", () => {
    const fixtures = exported.quota.readings as Record<string, QuotaReading>;
    expect(Object.fromEntries(Object.entries(fixtures).map(([name, reading]) =>
      [name, [reading.provider, reading.plan, reading.session?.remainingPercent, reading.weekly?.remainingPercent]]))).toEqual({
      morning: ["Codex", "Plus", 88, 86], cafeCodex: ["Codex", "Plus", 71, 84],
      cafeClaude: ["Claude", "Pro", 62, 58], lowClaude: ["Claude", "Pro", 0, 31],
      lowCodex: ["Codex", "Plus", 64, 79], reset: ["Claude", "Pro", 100, 30], night: ["Claude", "Pro", 78, 27],
    });
    expect(fixtures.cafeClaude.session?.pace).toEqual({title: "Session · 12% in reserve",
      expected: "Expected 50% left now", headroom: "1.6× headroom at current pace"});
    expect(fixtures.cafeClaude.weekly?.pace).toEqual({title: "Weekly · 6% in deficit",
      expected: "Expected 64% left now", headroom: "0.8× headroom at current pace"});
  });

  it("exports named audio moments and the visible states across each boundary", () => {
    expect(exported.quota.moments).toMatchObject({runningLow: 35, reset: 40, night: 45, outro: 62});
    const samples = exported.quota.samples as QuotaState[];
    for (const at of Object.values(QUOTA_MOMENTS)) {
      expect(samples.find((state) => state.t === at)).toEqual(quotaAt(at));
      if (at > 0) expect(samples.find((state) => state.t === at - 1 / FILM.fps)).toEqual(quotaAt(at - 1 / FILM.fps));
    }
    expect(samples.find((state) => state.t === QUOTA_MOMENTS.runningLow)).toMatchObject({runningLow: true, provider: "Claude"});
    expect(samples.find((state) => state.t === QUOTA_MOMENTS.reset)).toMatchObject({runningLow: false, pose: "relieved"});
  });

  it("switches the selected provider with the named shortcuts", () => {
    expect(providerAt(QUOTA_MOMENTS.showClaude - 1 / 30)).toBe("Codex");
    expect(providerAt(QUOTA_MOMENTS.showClaude)).toBe("Claude");
    expect(providerAt(QUOTA_MOMENTS.showCodex)).toBe("Codex");
    expect(providerAt(QUOTA_MOMENTS.returnClaude)).toBe("Claude");
    for (const at of [0, 18, 25, 27, 35, 40]) {
      const state = quotaAt(at);
      expect(state.reading).toBe(state.readings[state.provider]);
    }
  });

  it("uses the app rule on every frame, reaching exactly 10% at the alert and clearing at reset", () => {
    const lowFrames: number[] = [];
    for (let frame = 0; frame < FILM.durationSeconds * FILM.fps; frame++) {
      const state = quotaAt(frame / FILM.fps);
      const eligible = [state.reading.session, state.reading.weekly].filter((w): w is QuotaWindow =>
        w !== null && (w.resetsAt === null || w.resetsAt > state.nowMs));
      const expected = eligible.some((w) => w.remainingPercent <= 10);
      expect(state.runningLow, `frame ${frame}`).toBe(expected);
      if (state.runningLow) lowFrames.push(frame);
    }
    expect(lowFrames).toEqual(Array.from({length: 150}, (_, index) => 1050 + index));
    expect(quotaAt(QUOTA_MOMENTS.runningLow).reading.session?.remainingPercent).toBe(10);
    expect(quotaAt(QUOTA_MOMENTS.runningLow - 0.0001).runningLow).toBe(false);
    expect(quotaAt(QUOTA_MOMENTS.reset - 0.0001).runningLow).toBe(true);
    expect(quotaAt(QUOTA_MOMENTS.reset).reading.session).toMatchObject({remainingPercent: 100, summary: "Estimating usage pace…"});
    expect(quotaAt(QUOTA_MOMENTS.reset).reading.session?.pace).toBeUndefined();
  });

  it("keeps countdowns consistent with the story clock and app formatting", () => {
    expect(quotaAt(0).reading.session?.countdown).toBe("in 2h 59m");
    expect(quotaAt(18).reading.session?.countdown).toBe("in 3h 40m");
    expect(quotaAt(37).reading.session?.countdown).toBe("in 2h 50m");
    expect(quotaAt(40).reading.session?.countdown).toBe("in 5h 0m");
    expect(quotaAt(45).reading.session?.countdown).toBe("in 1h 20m");
    expect(quotaAt(37).reading.weekly?.countdown).toBe("in 1d 23h");
    expect(quotaAt(40).nowMs).toBe(Date.parse("2026-09-24T18:00:00+08:00"));
  });
});

describe("the app's running-low boundary policy", () => {
  const now = Date.parse("2026-09-24T18:00:00+08:00");
  const quota = (remainingPercent: number, resetsAt: number | null): QuotaWindow =>
    ({...QUOTA_READINGS.lowClaude.session, remainingPercent, resetsAt});
  const reading = (session: QuotaWindow | null, weekly: QuotaWindow | null): QuotaReading =>
    ({provider: "Claude", plan: "Pro", session, weekly});

  it.each(["session", "weekly"] as const)("handles the %s threshold, missing reset date, and expired window", (key) => {
    for (const [remaining, resetsAt, expected] of [
      [10.01, now + 1, false], [10, now + 1, true], [0, now + 1, true],
      [10, null, true], [0, now, false], [0, now - 1, false],
    ] as const) {
      const snapshot = {...reading(null, null), [key]: quota(remaining, resetsAt)};
      expect(isRunningLow(snapshot, now), `${key} ${remaining} ${resetsAt}`).toBe(expected);
    }
  });

  it("ignores an expired window but still warns for another live low window", () => {
    expect(isRunningLow(reading(quota(0, now), quota(10, now + 1)), now)).toBe(true);
    expect(tightestRemaining(reading(quota(0, now), quota(27, now + 1)), now)).toBe(27);
    expect(tightestRemaining(reading(quota(0, now), null), now)).toBe(100);
    expect(isRunningLow(reading(null, null), now)).toBe(false);
    expect(tightestRemaining(reading(null, null), now)).toBeNull();
  });

  it("does not mutate the saved fixtures while animating readings", () => {
    const before = JSON.stringify(QUOTA_READINGS);
    for (const t of [0, 18, 31.5, 35, 37, 40, 45, 62]) quotaAt(t);
    expect(JSON.stringify(QUOTA_READINGS)).toBe(before);
  });
});
