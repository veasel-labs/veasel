import fs from 'node:fs';
import path from 'node:path';
import type { TestInfo } from '@playwright/test';

/**
 * Journey evidence. Entries are built only from values this process computed or from fixed literals:
 * booleans, finite numbers, and sha256 digests of local files. Nothing derived from an HTTP response or
 * from the app's output is ever written (the full detail stays in the test's own assertion messages), and
 * the file name is fixed. `scripts/e2e-evidence.mjs` turns the JSONL into docs/desktop/E2E_EVIDENCE.md.
 */
export type EvidenceValue = boolean | number | null;

const SHA256 = /^[0-9a-f]{64}$/;
const JOURNEY = /^J\d{1,2}[a-z]?$/;

export function record(
  testInfo: TestInfo,
  journey: string,
  oracle: string,
  observed: Record<string, EvidenceValue>,
  digests: Record<string, string> = {},
): void {
  if (!JOURNEY.test(journey)) throw new Error('evidence journey id must look like J4 or J3b');
  const safe: Record<string, EvidenceValue | string> = {};
  for (const [key, value] of Object.entries(observed)) {
    safe[key] = typeof value === 'number' && !Number.isFinite(value) ? null : value;
  }
  for (const [key, digest] of Object.entries(digests)) {
    if (!SHA256.test(digest)) throw new Error(`evidence digest ${key} is not a sha256 hex string`);
    safe[key] = digest;
  }
  const line = JSON.stringify({ journey, oracle, observed: safe, at: new Date().toISOString() });
  const dir = process.env['VEASEL_E2E_EVIDENCE_DIR'];
  if (dir) {
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'evidence.jsonl'), `${line}\n`);
  }
  void testInfo.attach(`evidence-${journey}`, { body: line, contentType: 'application/json' });
}
