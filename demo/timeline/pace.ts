import type { QuotaWindow } from "./quota";

/** Matches Formatters.compactDuration, including trailing zero minutes or hours. */
export function compactDuration(seconds: number): string {
  const total = Math.floor(Math.max(0, seconds));
  const days = Math.floor(total / 86400);
  const hours = Math.floor(total % 86400 / 3600);
  const minutes = Math.floor(total % 3600 / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

/** UsagePace.evaluate's linear fallback and MenuCardView's compact summary.
 * Added story readings have no historical pace dataset. Saved named fixtures
 * retain their original summaries; only interpolated afternoon/reset states use this.
 */
export function paceSummary(quota: QuotaWindow, context: "session" | "weekly", nowMs: number): string {
  if (quota.remainingPercent <= 0) return "Limit reached";
  if (quota.resetsAt === null) return "";
  const duration = (context === "session" ? 300 : 10080) * 60;
  const untilReset = (quota.resetsAt - nowMs) / 1000;
  if (untilReset <= 0 || untilReset > duration) return "";
  const elapsed = Math.min(Math.max(duration - untilReset, 0), duration);
  const expected = elapsed / duration * 100;
  const actual = Math.min(100, Math.max(0, 100 - quota.remainingPercent));
  if (elapsed === 0 && actual > 0) return "";
  if (expected < 3 && actual < 3) return "Estimating usage pace…";
  if (actual === 0) return "Lasts until reset";
  const eta = (100 - actual) / (actual / elapsed);
  if (eta >= untilReset) return "Lasts until reset";
  return `${context === "session" ? "Empty in about" : "Runs out in"} ${compactDuration(eta)}`;
}
