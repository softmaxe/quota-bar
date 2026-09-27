/** Sample local usage and offline-report data shared by both films. */
export const USAGE_FIXTURES = {
  Claude: {
    tokens: [3, 5, 21, 33, 17, 26, 2, 33, 15, 37],
    cost: [4.1, 6.3, 24.8, 39.6, 18.2, 30.1, 2.4, 41.3, 16.9, 44.6],
    month: { tokens: "637M", cost: "$712.40" },
    models: { 7: [
      { name: "claude-opus-5", tokens: "21M", cost: "$28.40" },
      { name: "claude-sonnet-5", tokens: "9.6M", cost: "$9.10" },
      { name: "claude-haiku-4-5", tokens: "2.4M", cost: "$3.80" },
    ] },
  },
  Codex: {
    tokens: [2, 1, 4, 6, 9, 11, 5, 8, 10, 24],
    cost: [2.2, 1.1, 4.6, 6.9, 10.4, 12.7, 5.8, 9.1, 11.5, 27.6],
    month: { tokens: "418M", cost: "$466.80" },
    models: {},
  },
} as const;

export const REPORT_FIXTURE = {
  filename: "QuotaBar-Usage-2026-09-25.html",
  start: "2026-09-19", end: "2026-09-25", tokens: "227.0M", cost: "$261.80", coverage: "100.00%",
  days: [26, 37, 7, 41, 25, 61, 30],
  models: ["claude-opus-5", "gpt-6-astra", "claude-sonnet-5", "Other"],
  modelShares: [1, 0.82, 0.6, 0.42],
  copy: {
    en: { version: "Usage trend report", local: "Local saved usage", headline: "This report covers", total: "Total tokens", cost: "Estimated API cost", coverage: "Pricing coverage", daily: "When usage peaked", dailyNote: "One point per day. Hollow points mark weekends.", models: "Which models cost the most", composition: "Where the tokens went" },
    zh: { version: "用量趋势报告", local: "本地已存用量", headline: "本报告覆盖", total: "Token 总用量", cost: "估算 API 费用", coverage: "定价覆盖", daily: "用量在哪天达到峰值", dailyNote: "一点代表一天，空心点表示周末。", models: "哪些模型费用最多", composition: "Tokens 用在了哪里" },
  },
} as const;
