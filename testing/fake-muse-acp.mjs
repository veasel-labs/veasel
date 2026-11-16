// Veasel-authored fake for the Muse ACP host (`muse acp`, Muse
// Code 1.4.20, verified live 2026-11-16). Mirrors the observed wire
// behavior: session/new defaults the `mode` config option to allowAll,
// so a prompt arriving before mode is set to onRequest is refused here
// to prove the runner never runs a turn under the default.
import readline from 'node:readline';

const write = (frame) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...frame })}\n`);
const notify = (method, params) => write({ method, params });
const sessionId = 'muse-fake-session-1';
let mode = 'allowAll';
let promptRequestId = null;

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const frame = JSON.parse(line);
  const reply = (result) => write({ id: frame.id, result });
  if (frame.method === 'initialize') {
    reply({ protocolVersion: 1, agentCapabilities: { loadSession: true } });
  } else if (frame.method === 'session/new') {
    reply({
      sessionId,
      configOptions: [
        { id: 'mode', category: 'mode', currentValue: mode, options: [
          { value: 'allowAll' }, { value: 'promptUnmatched' }, { value: 'onRequest' }, { value: 'denyUnmatched' },
        ] },
        { id: 'model', category: 'model', currentValue: 'muse-wonder-1.0', options: [{ value: 'muse-wonder-1.0' }] },
      ],
    });
  } else if (frame.method === 'session/load') {
    // A loaded session starts again from the CLI default mode, so the
    // runner must re-force onRequest after load as well.
    mode = 'allowAll';
    reply({ sessionId: frame.params.sessionId });
  } else if (frame.method === 'session/set_config_option') {
    if (frame.params.configId === 'mode') mode = frame.params.value;
    reply({});
  } else if (frame.method === 'session/prompt') {
    promptRequestId = frame.id;
    if (mode !== 'onRequest') {
      write({ id: frame.id, error: { code: -32603, message: `refusing prompt under mode ${mode}` } });
      promptRequestId = null;
      return;
    }
    const text = frame.params.prompt?.[0]?.text;
    if (text === 'approval') {
      write({
        id: 'permission-1',
        method: 'session/request_permission',
        params: {
          sessionId,
          toolCall: { toolCallId: 'tool-1', title: 'Run echo', name: 'command_execution', rawInput: { command: 'echo hi' } },
          options: [
            { optionId: 'once', name: 'Allow once', kind: 'allow_once' },
            { optionId: 'reject', name: 'Reject', kind: 'reject_once' },
          ],
        },
      });
    } else {
      notify('session/update', {
        sessionId,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'MUSE_OK' } },
      });
      reply({ stopReason: 'end_turn' });
      promptRequestId = null;
    }
  } else if (frame.id === 'permission-1') {
    const accepted = frame.result?.outcome?.optionId === 'once';
    notify('session/update', {
      sessionId,
      update: {
        sessionUpdate: 'agent_message_chunk',
        content: { type: 'text', text: accepted ? 'Allowed once.' : 'Not allowed.' },
      },
    });
    write({ id: promptRequestId, result: { stopReason: 'end_turn' } });
    promptRequestId = null;
  }
});
