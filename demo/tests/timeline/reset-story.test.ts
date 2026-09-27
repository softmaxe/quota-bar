import { describe, expect, it } from "vitest";
import { beat3 } from "../../timeline/beats/beat3-reset";
import { QUOTA_MOMENTS, quotaAt } from "../../timeline/quota";
import { storyClock } from "../../video/components/DayLight";

describe("the reset story's shared clock and cues", () => {
  it("shows the sampled local time across all five Beats", () => {
    expect([0, 12, 30, 37, 40, 45, 62].map((at) => storyClock(at, "en"))).toEqual([
      {date: "Thu, Sep 24", time: "7:50 AM"},
      {date: "Thu, Sep 24", time: "10:30 AM"},
      {date: "Thu, Sep 24", time: "3:00 PM"},
      {date: "Thu, Sep 24", time: "3:10 PM"},
      {date: "Thu, Sep 24", time: "6:00 PM"},
      {date: "Thu, Sep 24", time: "9:40 PM"},
      {date: "Fri, Sep 25", time: "6:30 PM"},
    ]);
    expect(storyClock(40, "zh")).toEqual({date: "9月24日周四", time: "下午6:00"});
    expect(storyClock(62, "zh")).toEqual({date: "9月25日周五", time: "下午6:30"});
  });

  it("alerts at the authoritative 10% reading and starts the reset sound with the new window", () => {
    expect(beat3.cues.find((cue) => cue.type === "robot_alert")?.at).toBe(QUOTA_MOMENTS.runningLow);
    expect(beat3.cues.find((cue) => cue.type === "reset_scale")?.at).toBe(QUOTA_MOMENTS.reset);
    expect(beat3.cues.find((cue) => cue.type === "tick")?.at).toBe(beat3.moments.filled);
    expect(quotaAt(beat3.moments.reset).reading.session?.remainingPercent).toBe(100);
    expect(quotaAt(beat3.moments.reset).runningLow).toBe(false);
    expect(beat3.moments.filled).toBeGreaterThan(beat3.moments.reset);
  });
});
