import { defineConfig } from '@playwright/test';

/**
 * Display-free config for the fake-CLI fixture spec: it talks to the real V
 * backend over HTTP, so it needs neither Electron, a browser, nor the Vite
 * preview server the main config starts.
 */
export default defineConfig({
  testDir: './e2e/electron',
  testMatch: ['focus-fixture.api.spec.ts'],
  workers: 1,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  reporter: [['list']],
});
