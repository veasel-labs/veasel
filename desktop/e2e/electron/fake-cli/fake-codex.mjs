#!/usr/bin/env node
// Decoy `codex`: installed and discoverable, but it must NEVER be spawned for
// a turn when the user chose Claude Code. Spawning it is the #735 regression
// oracle (the backend ran the global default instead of the chosen provider).
import fs from 'node:fs';

const log = (event, extra = {}) => {
  const file = process.env.FAKE_CLI_LOG;
  if (file)
    fs.appendFileSync(file, `${JSON.stringify({ cli: 'codex', event, pid: process.pid, at: Date.now(), ...extra })}\n`);
};
if (process.argv.includes('--version')) {
  process.stdout.write('codex-cli 0.167.2 (fake)\n');
  process.exit(0);
}
log('spawn', { argv: process.argv.slice(2) });
process.stderr.write('fake codex decoy: not a real turn target\n');
process.exit(1);
