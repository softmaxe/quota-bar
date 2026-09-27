/** Quota readings use the existing demo fixtures; all percentages are remaining. */
export type Provider = "Codex" | "Claude";
export type RobotPose = "coding" | "alarmed" | "sweating" | "relieved" | "proud" | "waving";

export interface QuotaWindow {
  remainingPercent: number;
  /** Unix milliseconds in the story's local clock; null means unknown. */
  resetsAt: number | null;
  summary: string;
  countdown: string;
  resetLabel: string;
  pace?: {title: string; expected: string; headroom: string};
}

export interface QuotaReading {
  provider: Provider;
  plan: string;
  session: QuotaWindow | null;
  weekly: QuotaWindow | null;
}

export const QUOTA_MOMENTS = {
  morning: 0, cardOpen: 12.7, showClaude: 18, showCodex: 25, returnClaude: 27,
  afternoon: 30, drainStart: 31.5, runningLow: 35, exhausted: 37,
  reset: 40, night: 45, outro: 62, wave: 68,
} as const;

const date = (day: number, time: string) => Date.parse(`2026-09-${day}T${time}:00+08:00`);
const window = (remainingPercent: number, summary: string, countdown: string, resetLabel: string,
  resetsAt: number, pace?: QuotaWindow["pace"]): QuotaWindow =>
  ({remainingPercent, summary, countdown, resetLabel, resetsAt, ...(pace ? {pace} : {})});
const lasts = "Lasts until reset";

/** Sample quota readings shared by the story and interface previews. */
export const QUOTA_READINGS = {
  morning: {provider: "Codex", plan: "Plus",
    session: window(88, lasts, "in 2h 59m", "10:49 AM", date(24, "10:49")),
    weekly: window(86, lasts, "in 4d 23h", "Tue 6:49 AM", date(29, "06:49"))},
  cafeCodex: {provider: "Codex", plan: "Plus",
    session: window(71, lasts, "in 19m", "10:49 AM", date(24, "10:49")),
    weekly: window(84, lasts, "in 4d 20h", "Tue 6:49 AM", date(29, "06:49"))},
  cafeClaude: {provider: "Claude", plan: "Pro",
    session: window(62, lasts, "in 3h 40m", "2:10 PM", date(24, "14:10"),
      {title: "Session · 12% in reserve", expected: "Expected 50% left now", headroom: "1.6× headroom at current pace"}),
    weekly: window(58, "Runs out in 1d 18h", "in 2d 4h", "Sat 2:30 PM", date(26, "14:30"),
      {title: "Weekly · 6% in deficit", expected: "Expected 64% left now", headroom: "0.8× headroom at current pace"})},
  lowClaude: {provider: "Claude", plan: "Pro",
    session: window(0, "Limit reached", "in 2h 50m", "6:00 PM", date(24, "18:00")),
    weekly: window(31, "Runs out in 1d 2h", "in 1d 23h", "Sat 2:30 PM", date(26, "14:30"))},
  lowCodex: {provider: "Codex", plan: "Plus",
    session: window(64, lasts, "in 2h 41m", "5:51 PM", date(24, "17:51")),
    weekly: window(79, lasts, "in 4d 15h", "Tue 6:49 AM", date(29, "06:49"))},
  reset: {provider: "Claude", plan: "Pro",
    session: window(100, lasts, "in 5h", "11:00 PM", date(24, "23:00")),
    weekly: window(30, lasts, "in 1d 20h", "Sat 2:30 PM", date(26, "14:30"))},
  night: {provider: "Claude", plan: "Pro",
    session: window(78, lasts, "in 1h 20m", "11:00 PM", date(24, "23:00")),
    weekly: window(27, lasts, "in 1d 16h", "Sat 2:30 PM", date(26, "14:30"))},
} satisfies Record<string, QuotaReading>;

/** Matches Sources/QuotaBarCore/MenuBarProviderPolicy.swift, including stale resets. */
export function tightestRemaining(reading: QuotaReading, nowMs: number): number | null {
  const remaining = [reading.session, reading.weekly].flatMap((quota) => quota === null ? [] :
    [quota.resetsAt !== null && quota.resetsAt <= nowMs ? 100 : quota.remainingPercent]);
  return remaining.length ? Math.min(...remaining) : null;
}

export function isRunningLow(reading: QuotaReading, nowMs: number): boolean {
  const remaining = tightestRemaining(reading, nowMs);
  return remaining !== null && remaining <= 10;
}

const mix = (a: number, b: number, t: number, start: number, end: number) =>
  a + (b - a) * Math.min(1, Math.max(0, (t - start) / (end - start)));

export function providerAt(t: number): Provider {
  return t < QUOTA_MOMENTS.showClaude || (t >= QUOTA_MOMENTS.showCodex && t < QUOTA_MOMENTS.returnClaude)
    ? "Codex" : "Claude";
}

/** The clock holds while reading UI, and advances only during story transitions. */
export function storyNow(t: number): number {
  if (t < 12) return date(24, "07:50");
  if (t < QUOTA_MOMENTS.afternoon) return date(24, "10:30");
  if (t < QUOTA_MOMENTS.exhausted) return mix(date(24, "15:00"), date(24, "15:10"), t,
    QUOTA_MOMENTS.drainStart, QUOTA_MOMENTS.exhausted);
  if (t < QUOTA_MOMENTS.reset) return mix(date(24, "15:10"), date(24, "18:00"), t,
    QUOTA_MOMENTS.exhausted, QUOTA_MOMENTS.reset);
  if (t < QUOTA_MOMENTS.night) return date(24, "18:00");
  return t < QUOTA_MOMENTS.outro ? date(24, "21:40") : date(25, "18:30");
}

function countdown(resetsAt: number | null, now: number): string {
  if (resetsAt === null) return "";
  const minutes = Math.max(0, Math.floor((resetsAt - now) / 60_000));
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor(minutes % 1440 / 60);
  const rest = minutes % 60;
  if (days) return `in ${days}d ${hours}h`;
  if (hours) return `in ${hours}h ${rest}m`;
  return `in ${rest}m`;
}

function atClock(reading: QuotaReading, nowMs: number): QuotaReading {
  const adjust = (quota: QuotaWindow | null) => quota && {...quota, countdown: countdown(quota.resetsAt, nowMs)};
  return {...reading, session: adjust(reading.session), weekly: adjust(reading.weekly)};
}

function afternoonClaude(t: number): QuotaReading {
  if (t >= QUOTA_MOMENTS.exhausted) return QUOTA_READINGS.lowClaude;
  const session = t <= QUOTA_MOMENTS.runningLow
    ? mix(62, 10, t, QUOTA_MOMENTS.drainStart, QUOTA_MOMENTS.runningLow)
    : mix(10, 0, t, QUOTA_MOMENTS.runningLow, QUOTA_MOMENTS.exhausted);
  const weekly = mix(58, 31, t, QUOTA_MOMENTS.drainStart, QUOTA_MOMENTS.exhausted);
  // Intermediate readings illustrate drainage; they do not invent a precise pace forecast.
  return {...QUOTA_READINGS.lowClaude,
    session: {...QUOTA_READINGS.lowClaude.session, remainingPercent: session, summary: "Estimating usage pace…"},
    weekly: {...QUOTA_READINGS.lowClaude.weekly, remainingPercent: weekly, summary: "Estimating usage pace…"}};
}

export interface QuotaState {
  t: number;
  nowMs: number;
  provider: Provider;
  reading: QuotaReading;
  readings: Record<Provider, QuotaReading>;
  runningLow: boolean;
  pose: RobotPose;
}

/** The authoritative sample state. Reset bar animation must not replace this reading. */
export function quotaAt(t: number): QuotaState {
  if (!Number.isFinite(t)) throw new Error("Quota time must be finite");
  const nowMs = storyNow(t);
  const codex = t < 12 ? QUOTA_READINGS.morning :
    t < QUOTA_MOMENTS.afternoon ? QUOTA_READINGS.cafeCodex : QUOTA_READINGS.lowCodex;
  const claude = t < QUOTA_MOMENTS.afternoon ? QUOTA_READINGS.cafeClaude :
    t < QUOTA_MOMENTS.reset ? afternoonClaude(t) :
    t < QUOTA_MOMENTS.night ? {
      ...QUOTA_READINGS.reset,
      session: {...QUOTA_READINGS.reset.session, summary: "Estimating usage pace…"},
    } : QUOTA_READINGS.night;
  const readings: Record<Provider, QuotaReading> = {Codex: atClock(codex, nowMs), Claude: atClock(claude, nowMs)};
  const provider = providerAt(t);
  const reading = readings[provider];
  const runningLow = isRunningLow(reading, nowMs);
  const pose: RobotPose = runningLow ? "sweating" : t < 4.8 ? "coding" : t < 12 ? "alarmed" :
    t >= QUOTA_MOMENTS.wave ? "waving" : t >= QUOTA_MOMENTS.reset && t < QUOTA_MOMENTS.night ? "relieved" :
    t >= QUOTA_MOMENTS.afternoon && t < QUOTA_MOMENTS.reset ? "coding" : "proud";
  return {t, nowMs, provider, reading, readings, runningLow, pose};
}

/** Named states and their preceding frames make the audio JSON useful for review. */
export function exportedQuota(fps: number) {
  const times = [...new Set(Object.values(QUOTA_MOMENTS).flatMap((at) => [Math.max(0, at - 1 / fps), at]))]
    .sort((a, b) => a - b);
  return {moments: QUOTA_MOMENTS, readings: QUOTA_READINGS, samples: times.map(quotaAt)};
}
