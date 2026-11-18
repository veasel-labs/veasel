import fs from 'node:fs';
import path from 'node:path';
import type { TestInfo } from '@playwright/test';

/**
 * Journey evidence. Each entry is appended from real run output: the oracle that
 * decided the verdict and the values it observed. `scripts/e2e-evidence.mjs`
 * turns the JSONL into docs/desktop/E2E_EVIDENCE.md; nothing is written by hand.
 */
export function record(testInfo: TestInfo, journey: string, oracle: string, observed: Record<string, unknown>): void {
  const line = JSON.stringify({ journey, oracle, observed, at: new Date().toISOString() });
  const dir = process.env['VEASEL_E2E_EVIDENCE_DIR'];
  if (dir) {
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'evidence.jsonl'), `${line}\n`);
  }
  void testInfo.attach(`evidence-${journey}`, { body: line, contentType: 'application/json' });
}
