import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

describe('Desktop workflow ledger (docs/desktop/workflows.yaml)', () => {
  it('marks a journey ok only with evidence at a recorded build', () => {
    const text = readLedger();
    const journeys: Array<Record<string, unknown>> = [];
    let current: Record<string, unknown> | null = null;
    for (const line of text.split('\n')) {
      const idMatch = line.match(/^ {2}- id: (.+)$/);
      if (idMatch) {
        current = { id: idMatch[1] };
        journeys.push(current);
        continue;
      }
      const statusMatch = line.match(/^ {4}status: (.+)$/);
      if (statusMatch && current) current.status = statusMatch[1];
    }
    expect(journeys.length).toBeGreaterThan(5);
    for (const journey of journeys) {
      expect(['ok', 'partial', 'blocked', 'not-implemented']).toContain(journey.status);
    }
    // Veasel Desktop journeys (#689): none may claim `ok` until a packaged
    // build records the evidence named in the ledger. Pin the current
    // honest states so a status bump without evidence fails here.
    // Upgraded 2026-11-19 with packaged evidence at v0.96.9-next.0 (see the
    // ledger notes): backend auth verified on published binaries, a real
    // OpenCode UI turn with approvals, and verified Linux packaging. Any
    // future status change must update the evidence note in the same diff.
    for (const id of ['desktop-proxy-trust-boundary', 'focus-provider-turn', 'focus-approvals', 'linux-packaging']) {
      const journey = journeys.find((j) => j.id === id);
      expect(journey, id).toBeDefined();
      expect(journey!.status).toBe('ok');
    }
    // TUI continuity is proven at API-client level only; verified-release
    // still lacks distribution sync. Neither may claim ok yet.
    for (const id of ['tui-desktop-continuity', 'verified-release']) {
      const journey = journeys.find((j) => j.id === id);
      expect(journey, id).toBeDefined();
      expect(journey!.status).toBe('partial');
    }
  });
});

function readLedger(): string {
  return readFileSync(resolve(__dirname, '../../docs/desktop/workflows.yaml'), 'utf-8');
}
