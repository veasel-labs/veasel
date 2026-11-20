import { defineConfig } from '@playwright/test';

/**
 * Acceptance: the Electron Focus journeys, the World journeys (#693), plus the display-free fixture oracles.
 * No webServer (the renderer is prebuilt: `pnpm build:all`) and the output directory is
 * configurable so the source tree can be mounted read-only in the container runner.
 */
export default defineConfig({
  testDir: './e2e/electron',
  testMatch: [
    'focus-fixture.api.spec.ts',
    'focus-journeys.spec.ts',
    'world-walk.spec.ts',
    'world-interactions.spec.ts',
  ],
  workers: 1,
  retries: 0,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  outputDir: process.env['VEASEL_E2E_OUTPUT_DIR'] ?? '/out/test-results',
  reporter: [['list'], ['json']],
  use: { trace: 'on-first-retry' },
});
