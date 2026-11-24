#!/usr/bin/env node
// Deterministic stand-in for the installed `claude` CLI (stream-json protocol
// spoken by provider_cli_claude.v / provider_cli_session.v). No network, no
// credentials. Every spawn and every side effect is appended as JSONL to
// $FAKE_CLI_LOG so tests can use it as an independent oracle.
//
// The scenario is the LAST `[[name]]` marker in the user text:
//   [[fix]]    stream text, ask to Edit src/math.js (bug fix), apply only if allowed
//   [[reject]] stream text, ask to Edit README.md, apply only if allowed
//   [[applyexpire]] Edit approved by a human, then an unanswered `git push` approval that expires
//   [[slow]]   stream text forever (until killed) - cancel / crash tests
//   [[shell]]  ask to run a Bash command; the edit never applies without approval
//   (none)     stream a short answer
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const log = (event, extra = {}) => {
  const file = process.env.FAKE_CLI_LOG;
  if (!file) return;
  fs.appendFileSync(
    file,
    `${JSON.stringify({ cli: 'claude', event, pid: process.pid, cwd: process.cwd(), at: Date.now(), ...extra })}\n`,
  );
};
const send = (frame) => process.stdout.write(`${JSON.stringify(frame)}\n`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

if (process.argv.includes('--version')) {
  process.stdout.write('2.1.322 (Claude Code, fake)\n');
  process.exit(0);
}

if (process.argv.slice(2).join(' ') === 'auth status --json') {
  log('auth-status');
  process.stdout.write('{"loggedIn":false}\n');
  process.exit(0);
}

log('spawn', { argv: process.argv.slice(2) });
process.on('SIGTERM', () => {
  log('sigterm');
  process.exit(143);
});

const resumeIndex = process.argv.indexOf('--resume');
const sessionId = resumeIndex >= 0 ? process.argv[resumeIndex + 1] : `fake-session-${process.pid}`;
const pending = new Map();
let userText = null;

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let frame;
  try {
    frame = JSON.parse(line);
  } catch {
    return;
  }
  if (frame.type === 'control_response') {
    const resolve = pending.get(frame.response?.request_id);
    if (resolve) resolve(frame.response?.response?.behavior === 'allow');
  } else if (frame.type === 'user' && userText === null) {
    userText = (frame.message?.content ?? []).map((part) => part.text ?? '').join('');
    void run(userText);
  }
});
rl.on('close', () => {
  log('stdin-closed');
  // A real CLI keeps working on its turn after stdin ends; only an idle one exits.
  if (userText === null) process.exit(0);
});

// Frame shapes mirror a real claude -p stream: a tool_use block, then the permission
// request, then (after the decision) a tool_result. The backend derives durable turn
// outcomes from the tool_result frames (docs/TURN_OUTCOMES.md).
function toolResult(toolId, isError, content) {
  send({
    type: 'user',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: toolId, is_error: isError, content }] },
  });
}

function ask(requestId, toolName, input) {
  send({
    type: 'assistant',
    parent_tool_use_id: null,
    message: {
      id: `msg_${requestId}`,
      content: [{ type: 'tool_use', id: `toolu_${requestId}`, name: toolName, input }],
    },
  });
  send({
    type: 'control_request',
    request_id: requestId,
    request: { subtype: 'can_use_tool', tool_name: toolName, input, tool_use_id: `toolu_${requestId}` },
  });
  log('approval-requested', { requestId, toolName });
  return new Promise((resolve) => pending.set(requestId, resolve));
}

async function stream(text, delayMs = 350) {
  for (const word of text.split(/(?<=\s)/)) {
    send({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: word } } });
    await sleep(delayMs);
  }
}

function applyEdit(file, oldString, newString) {
  const target = path.join(process.cwd(), file);
  const before = fs.readFileSync(target, 'utf8');
  if (!before.includes(oldString)) throw new Error(`old_string not found in ${file}`);
  fs.writeFileSync(target, before.replace(oldString, newString));
  log('edit-applied', { file });
  return true;
}

async function run(text) {
  const markers = [...text.matchAll(/\[\[(\w+)\]\]/g)];
  const scenario = markers.length > 0 ? markers[markers.length - 1][1] : 'echo';
  send({ type: 'system', subtype: 'init', session_id: sessionId, model: 'fake-claude-1' });
  log('scenario', { scenario });
  let summary = 'Done.';
  if (scenario === 'fix') {
    await stream('Reading src/math.js. The add function subtracts instead of adding. Proposing a one-line fix. ');
    const input = {
      file_path: path.join(process.cwd(), 'src/math.js'),
      old_string: 'return a - b;',
      new_string: 'return a + b;',
    };
    if (await ask('fake-req-fix', 'Edit', input)) {
      applyEdit('src/math.js', input.old_string, input.new_string);
      toolResult('toolu_fake-req-fix', false, 'updated');
      summary = 'Applied the fix to src/math.js.';
    } else {
      toolResult('toolu_fake-req-fix', true, 'denied');
      log('edit-denied', { file: 'src/math.js' });
      summary = 'The fix was not applied.';
    }
    await stream(`${summary} `);
  } else if (scenario === 'reject') {
    await stream('Also proposing a README note. ');
    const input = {
      file_path: path.join(process.cwd(), 'README.md'),
      old_string: '# Fixture',
      new_string: '# Fixture (edited by fake agent)',
    };
    if (await ask('fake-req-reject', 'Edit', input)) {
      applyEdit('README.md', input.old_string, input.new_string);
      toolResult('toolu_fake-req-reject', false, 'updated');
      summary = 'Applied the README change.';
    } else {
      toolResult('toolu_fake-req-reject', true, 'denied');
      log('edit-denied', { file: 'README.md' });
      summary = 'README change was not applied.';
    }
    await stream(`${summary} `);
  } else if (scenario === 'shell') {
    await stream('I need to run the tests. ');
    const allowed = await ask('fake-req-shell', 'Bash', {
      command: 'node test.js',
      description: 'Run the fixture tests',
    });
    toolResult('toolu_fake-req-shell', !allowed, allowed ? 'ran' : 'denied');
    if (allowed) log('shell-allowed');
    summary = allowed ? 'Ran the shell command.' : 'Shell command was not allowed.';
    await stream(`${summary} `);
  } else if (scenario === 'applyexpire') {
    // Edit is approved by the human; the later shell approval is left unanswered and the
    // backend expires it (VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS) and denies it in-band.
    await stream('Applying the fix, then I will push. ');
    const input = {
      file_path: path.join(process.cwd(), 'src/math.js'),
      old_string: 'return a - b;',
      new_string: 'return a + b;',
    };
    if (await ask('fake-req-fix', 'Edit', input)) {
      applyEdit('src/math.js', input.old_string, input.new_string);
      toolResult('toolu_fake-req-fix', false, 'updated');
      const pushed = await ask('fake-req-push', 'Bash', { command: 'git push origin main' });
      toolResult('toolu_fake-req-push', !pushed, pushed ? 'pushed' : 'denied');
      log(pushed ? 'push-allowed' : 'push-denied');
      summary = pushed ? 'Pushed.' : 'Push skipped.';
    } else {
      toolResult('toolu_fake-req-fix', true, 'denied');
      summary = 'The fix was not applied.';
    }
    await stream(`${summary} `);
  } else if (scenario === 'slow') {
    for (let index = 0; ; index += 1) await stream(`working on step ${index}. `, 500);
  } else {
    await stream('Hello from the fake Claude Code. Nothing to change. ');
  }
  send({
    type: 'result',
    subtype: 'success',
    session_id: sessionId,
    result: summary,
    usage: { input_tokens: 10, output_tokens: 5 },
    total_cost_usd: 0,
  });
  log('result', { scenario });
  await sleep(50);
  process.exit(0);
}
