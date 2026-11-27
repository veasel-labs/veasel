import readline from 'node:readline';

const write = (frame) => process.stdout.write(`${JSON.stringify(frame)}\n`);
const notify = (method, params) => write({ method, params });

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const frame = JSON.parse(line);
  const reply = (result) => write({ id: frame.id, result });

  if (frame.method === 'initialize') reply({});
  if (frame.method === 'thread/start' || frame.method === 'thread/resume') {
    if (frame.params.approvalsReviewer !== 'user') throw new Error('Approvals must be routed to the user');
    reply({ thread: { id: 'parent' }, model: 'test-model' });
  }
  if (frame.method === 'model/list') reply({ data: [] });
  if (frame.method === 'turn/start') {
    notify('turn/started', { threadId: 'parent', turn: { id: 'turn-1' } });
    reply({ turn: { id: 'turn-1' } });

    const prompt = frame.params.input[0].text;
    if (prompt.startsWith('file-approval')) {
      if (prompt !== 'file-approval-missing') {
        notify('item/fileChange/patchUpdated', {
          threadId: 'parent',
          turnId: prompt === 'file-approval-stale-turn' ? 'stale-turn' : 'turn-1',
          itemId: 'edit-file',
          changes: [{ path: 'src/main.v', kind: { type: 'update', movePath: null }, diff: '@@ -1 +1 @@\n-old\n+new' }],
        });
      }
      if (prompt === 'file-approval-missing-item-id') {
        notify('item/fileChange/patchUpdated', {
          threadId: 'parent',
          turnId: 'turn-1',
          callId: 'unrelated-call',
          changes: [{ path: 'src/main.v', kind: { type: 'update', movePath: null }, diff: '@@ -1 +1 @@\n-stale\n+unsafe' }],
        });
      }
      if (prompt === 'file-approval-missing-turn-id') {
        notify('item/fileChange/patchUpdated', {
          threadId: 'parent',
          itemId: 'edit-file',
          callId: 'unrelated-call',
          changes: [{ path: 'src/main.v', kind: { type: 'update', movePath: null }, diff: '@@ -1 +1 @@\n-stale\n+unsafe' }],
        });
      }

      write({
        id: 'file-approval',
        method: 'item/fileChange/requestApproval',
        params: {
          threadId: prompt === 'file-approval-other-thread' ? 'other-thread' : 'parent',
          turnId: prompt === 'file-approval-stale-request-turn' ? 'stale-turn' : 'turn-1',
          itemId: 'edit-file',
          reason: 'Apply the reviewed file change',
          availableDecisions: ['accept', 'decline'],
        },
      });
      if (prompt === 'file-approval-other-thread' || prompt === 'file-approval-stale-request-turn') {
        notify('turn/completed', { threadId: 'parent', turn: { id: 'turn-1', status: 'completed' } });
      }
      return;
    }

    notify('item/agentMessage/delta', {
      threadId: 'parent',
      turnId: 'turn-1',
      itemId: 'message',
      delta: 'unexpected fixture prompt',
    });
    notify('turn/completed', { threadId: 'parent', turn: { id: 'turn-1', status: 'completed' } });
  }

  if (frame.id === 'file-approval' && frame.result) {
    notify('item/completed', {
      threadId: 'parent',
      turnId: 'turn-1',
      item: { type: 'agentMessage', id: 'answer', text: frame.result.decision },
    });
    notify('turn/completed', { threadId: 'parent', turn: { id: 'turn-1', status: 'completed' } });
  }
});
