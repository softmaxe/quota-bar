import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 30_000,
    projects: [
      { extends: true, test: { name: "timeline", include: ["tests/timeline/**/*.test.ts"] } },
      {
        extends: true,
        test: {
          name: "film",
          include: ["tests/film/**/*.test.ts"],
          globalSetup: ["tests/film/global-setup.ts"],
        },
      },
    ],
  },
});
