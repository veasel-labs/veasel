// eslint-disable-next-line import-x/named -- screen is re-exported by Testing Library React at runtime.
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import WorldView from './WorldView';

const live = vi.hoisted(() => ({
  client: {} as object | null,
  session: { workspace: '/workspace' },
  backendDown: false,
  focus: { loaded: true, threads: [] as Array<Record<string, unknown>> },
  operations: {
    isPending: false,
    isError: false,
    isSuccess: true,
    data: [] as Array<Record<string, unknown>> | undefined,
  },
  providers: {
    isPending: false,
    isError: false,
    isSuccess: true,
    data: [] as Array<Record<string, unknown>> | undefined,
  },
  memory: {
    isPending: false,
    isError: false,
    isSuccess: true,
    data: { ok: true, entries: [] as Array<Record<string, unknown>> } as
      { ok: boolean; entries: Array<Record<string, unknown>> } | undefined,
  },
  memoryFile: {
    isPending: false,
    error: null as Error | null,
    data: undefined as unknown,
    refetch: vi.fn(),
  },
}));

vi.mock('../../data/focus', () => ({
  useFocusThreads: () => live.focus,
  useFocusOperations: () => live.operations,
  useFocusProviders: () => live.providers,
  useFocusBackendDown: () => live.backendDown,
}));
vi.mock('../../data/memory', () => ({ useMemoryList: () => live.memory, useMemoryFile: () => live.memoryFile }));
vi.mock('../../shell/useSessionContext', () => ({
  useSessionContext: () => ({ context: live.session, href: (path: string) => path }),
}));
vi.mock('../../data/backend', () => ({ useBackend: () => ({ client: live.client }) }));
vi.mock('./useWorldDetailEscape', () => ({ useWorldDetailEscape: () => undefined }));
vi.mock('./WorldEntityMap', () => ({
  WorldEntityMap: ({ entities }: { entities: Array<{ id: string; state: string }> }) => (
    <div>
      {entities.map((entity) => (
        <span key={entity.id} data-testid={`entity:${entity.id}`}>
          {entity.state}
        </span>
      ))}
    </div>
  ),
  WorldEntityList: () => null,
}));

function renderWorld(entry = '/world') {
  return render(
    <MemoryRouter initialEntries={[entry]}>
      <WorldView />
    </MemoryRouter>,
  );
}

const thread = (status = 'idle') => ({
  id: 'thread-1',
  title: 'Veasel work',
  cwd: '/repo/veasel',
  workspace: '/repo/veasel',
  projectName: 'veasel',
  provider: 'codex',
  status,
});

describe('WorldView live state', () => {
  beforeEach(() => {
    live.client = {};
    live.session = { workspace: '/workspace' };
    live.backendDown = false;
    live.focus = { loaded: true, threads: [] };
    live.operations = { isPending: false, isError: false, isSuccess: true, data: [] };
    live.providers = { isPending: false, isError: false, isSuccess: true, data: [] };
    live.memory = { isPending: false, isError: false, isSuccess: true, data: { ok: true, entries: [] } };
    live.memoryFile = { isPending: false, error: null, data: undefined, refetch: vi.fn() };
  });

  it('opens a memory-file inspector from a deep link', () => {
    live.memoryFile.data = {
      entry: {
        id: 'notes.md',
        kind: 'note',
        title: 'Real note',
        body: 'from the typed memory endpoint',
        snippet: '',
        tags: [],
        provenance: { file: 'notes.md', author: 'user', timestamp: '', project: '', agent: '' },
      },
    };
    renderWorld('/world?memory=notes.md');
    expect(screen.getByRole('region', { name: 'Memory record notes.md' })).toBeInTheDocument();
    expect(screen.getByText('from the typed memory endpoint')).toBeInTheDocument();
  });

  it('opens provider details from the canonical CLI probe', () => {
    live.providers.data = [
      {
        id: 'claude',
        label: 'Claude Code',
        installed: true,
        binary: '/bin/claude',
        version: '1.0',
        auth: 'ready',
        authDetail: 'Signed in',
        signInHint: null,
        models: [],
        capabilities: {},
        checkedAt: '',
      },
    ];
    renderWorld('/world?tool=claude');
    expect(screen.getByRole('region', { name: 'Coding agent claude' })).toBeInTheDocument();
    expect(screen.getByText('Signed in')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /installation in Library/i })).not.toBeInTheDocument();
  });

  it('projects canonical sessions, operations, providers, and optional memory', () => {
    live.focus.threads = [{ ...thread(), status: 'idle' }];
    live.operations.data = [{ id: 'op-1', sessionId: 'thread-1', status: 'running' }];
    live.providers.data = [
      {
        id: 'codex',
        label: 'Codex CLI',
        installed: true,
        binary: '/bin/codex',
        version: '1.0',
        auth: 'ready',
        authDetail: '',
        signInHint: null,
        models: [],
        capabilities: {},
        checkedAt: '',
      },
    ];
    live.memory.data = {
      ok: true,
      entries: [
        {
          id: 'knowledge/veasel.md',
          kind: 'learning',
          title: 'Veasel note',
          snippet: 'real memory',
          tags: [],
          provenance: { file: 'knowledge/veasel.md', author: 'user', timestamp: '', project: '', agent: '' },
        },
      ],
    };

    renderWorld();

    expect(screen.getByTestId('entity:place:memory')).toHaveTextContent('1 records');
    expect(screen.getByTestId('entity:object:workshop')).toHaveTextContent('1 detected');
    expect(screen.getByTestId('entity:character:person:thread-1:thread-1')).toHaveTextContent('running');
    expect(screen.getByTestId('entity:place:project:veasel')).toHaveTextContent('1 session working');
    expect(screen.queryByText(/live runtime details are unavailable/i)).not.toBeInTheDocument();
  });

  it('keeps same-named repositories in separate houses and assigns each session to its path', () => {
    live.focus.threads = [
      { ...thread(), id: 'session-main', cwd: '/a/x', projectName: 'x' },
      { ...thread(), id: 'session-worktree', cwd: '/b/x', projectName: 'x' },
      { ...thread(), id: 'session-collision', cwd: '/c/x', projectName: 'x · a' },
      { ...thread(), id: 'session-path-collision', cwd: '/a/a', projectName: 'x · /a/x' },
    ];

    renderWorld();

    expect(screen.getByTestId('entity:place:project:x · a · /a/x')).toBeInTheDocument();
    expect(screen.getByTestId('entity:place:project:x · b')).toBeInTheDocument();
    expect(screen.getByTestId('entity:place:project:x · a · /c/x')).toBeInTheDocument();
    expect(screen.getByTestId('entity:place:project:x · /a/x')).toBeInTheDocument();
    expect(screen.getByTestId('entity:character:person:session-main:session-main')).toBeInTheDocument();
    expect(screen.getByTestId('entity:character:person:session-worktree:session-worktree')).toBeInTheDocument();
    expect(screen.getByTestId('entity:character:person:session-collision:session-collision')).toBeInTheDocument();
    expect(
      screen.getByTestId('entity:character:person:session-path-collision:session-path-collision'),
    ).toBeInTheDocument();
  });

  it('surfaces error sessions and omits work-like state when operations are unavailable', () => {
    live.focus.threads = [{ ...thread('error') }];
    live.operations = { isPending: false, isError: true, isSuccess: false, data: undefined };
    live.providers = { isPending: false, isError: true, isSuccess: false, data: undefined };
    live.memory = { isPending: false, isError: true, isSuccess: false, data: { ok: false, entries: [] } };

    renderWorld();

    expect(screen.getByRole('status')).toHaveTextContent('Some live runtime details are unavailable');
    expect(screen.getByTestId('entity:object:workshop')).toHaveTextContent('unknown');
    expect(screen.getByTestId('entity:place:project:veasel')).toHaveTextContent('needs attention');
    expect(screen.queryByTestId(/^entity:character:job:/)).not.toBeInTheDocument();
  });

  it('does not treat an unavailable legacy memory endpoint as runtime failure', () => {
    live.focus.threads = [thread()];
    live.memory = { isPending: false, isError: true, isSuccess: false, data: { ok: false, entries: [] } };

    renderWorld();

    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    expect(screen.queryByTestId('entity:place:memory')).not.toBeInTheDocument();
  });

  it('offers the real workspace picker when there is no workspace context', () => {
    live.session = { workspace: '' };
    renderWorld();
    expect(screen.getByRole('heading', { name: 'Your valley is waiting for a workspace' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Open Focus to choose a workspace' })).toHaveAttribute('href', '/focus');
  });

  it('does not leave a loading banner when the backend is disconnected', () => {
    live.client = null;
    live.focus = { loaded: false, threads: [] };
    live.operations = { isPending: false, isError: false, isSuccess: false, data: undefined };
    live.providers = { isPending: false, isError: false, isSuccess: false, data: undefined };
    renderWorld();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('labels cached canonical activity as last known after disconnect', () => {
    live.client = null;
    live.backendDown = true;
    live.focus = { loaded: false, threads: [thread('running')] };
    live.operations.data = [{ id: 'op-1', sessionId: 'thread-1', status: 'running' }];

    renderWorld();

    expect(screen.getByRole('status')).toHaveTextContent('Connection lost; showing last known workspace data.');
    expect(screen.getByTestId('entity:character:person:thread-1:thread-1')).toHaveTextContent('running');
  });
});
