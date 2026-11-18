// Scripted stand-in for `claude -p --input-format stream-json` that replays
// the turn shapes behind the durable-outcome tests (epic #689, item B). It
// is separate from tests/focus_reference/testing/fake-claude.mjs, which is a
// verbatim upstream copy and must not be edited.
//
// Scenarios are selected by a token in the user prompt:
//   apply-then-expire  approved Edit is applied, `npm test` passes, then a
//                      `git push` approval is never answered in time and is
//                      denied in-band by Veasel.
//   apply-then-crash   approved Edit is applied, then the CLI dies.
//   deny-only          a Bash approval is denied; nothing is applied.
//   apply-only         approved Edit is applied; the turn finishes cleanly.
import fs from 'node:fs';
import readline from 'node:readline';

const sessionId = 'sess-outcomes-1';
const out = (frame) => process.stdout.write(`${JSON.stringify(frame)}\n`);
const waiting = new Map();
let initialised = false;

function init() {
  if (initialised) return;
  initialised = true;
  out({ type: 'system', subtype: 'init', session_id: sessionId, model: 'fake-model-1' });
}

function text(id, body) {
  out({
    type: 'stream_event',
    api_message_id: id,
    parent_tool_use_id: null,
    event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: body } },
  });
  out({ type: 'assistant', parent_tool_use_id: null, message: { id, content: [{ type: 'text', text: body }] } });
}

function toolUse(id, name, input) {
  out({
    type: 'assistant',
    parent_tool_use_id: null,
    message: { id: `msg_${id}`, content: [{ type: 'tool_use', id, name, input }] },
  });
}

function toolResult(id, isError, content) {
  out({
    type: 'user',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, is_error: isError, content }] },
  });
}

function ask(requestId, toolId, name, input, onDecision) {
  toolUse(toolId, name, input);
  out({
    type: 'control_request',
    request_id: requestId,
    request: { subtype: 'can_use_tool', tool_name: name, input, tool_use_id: toolId },
  });
  waiting.set(requestId, onDecision);
}

function finish() {
  out({
    type: 'result',
    subtype: 'success',
    is_error: false,
    usage: { input_tokens: 10, output_tokens: 5 },
    session_id: sessionId,
  });
}

function applyEdit(file) {
  const source = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(file, source.replace('a - b', 'a + b'));
}

function editThen(prompt, afterApplied) {
  const file = `${process.cwd()}/math.js`;
  const input = { file_path: file, old_string: 'a - b', new_string: 'a + b' };
  text('msg_intro', 'Applying the fix.');
  ask('perm_edit', 'toolu_edit', 'Edit', input, (response) => {
    if (response.behavior !== 'allow') {
      toolResult('toolu_edit', true, response.message);
      text('msg_denied', 'The edit was denied.');
      finish();
      return;
    }
    applyEdit(file);
    toolResult('toolu_edit', false, 'updated');
    afterApplied();
  });
}

function onUser(prompt) {
  init();
  if (prompt.includes('apply-only')) {
    editThen(prompt, () => {
      text('msg_done', 'Fixed.');
      finish();
    });
    return;
  }
  if (prompt.includes('apply-then-crash')) {
    editThen(prompt, () => {
      process.stderr.write('fake provider exploded\n');
      process.exit(3);
    });
    return;
  }
  if (prompt.includes('apply-then-expire')) {
    editThen(prompt, () => {
      toolUse('toolu_test', 'Bash', { command: 'npm test' });
      toolResult('toolu_test', false, '3 passing');
      ask('perm_push', 'toolu_push', 'Bash', { command: 'git push origin main' }, (response) => {
        const allowed = response.behavior === 'allow';
        toolResult('toolu_push', !allowed, allowed ? 'pushed' : response.message);
        text('msg_end', allowed ? 'Pushed.' : 'Push skipped.');
        finish();
      });
    });
    return;
  }
  if (prompt.includes('deny-only')) {
    ask('perm_rm', 'toolu_rm', 'Bash', { command: 'rm -rf build' }, (response) => {
      toolResult('toolu_rm', true, response.message ?? 'denied');
      text('msg_nothing', 'Nothing was changed.');
      finish();
    });
    return;
  }
  text('msg_echo', `echo:${prompt}`);
  finish();
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let frame;
  try {
    frame = JSON.parse(line);
  } catch {
    return;
  }
  if (frame.type === 'control_request' && frame.request?.subtype === 'initialize') {
    out({
      type: 'control_response',
      response: { subtype: 'success', request_id: frame.request_id, response: { models: [] } },
    });
    return;
  }
  if (frame.type === 'control_response') {
    const resolve = waiting.get(frame.response?.request_id);
    waiting.delete(frame.response?.request_id);
    resolve?.(frame.response.response);
    return;
  }
  if (frame.type === 'user') {
    const content = frame.message?.content;
    const prompt = Array.isArray(content) ? content.map((part) => part.text ?? '').join('') : String(content ?? '');
    onUser(prompt);
  }
});
