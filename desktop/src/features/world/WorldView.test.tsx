import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import WorldView from './WorldView';

const live = vi.hoisted(() => ({
  client: {} as object | null,
  focus: { loaded: true, threads: [] as Array<Record<string, unknown>> },
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
  tools: {
    isPending: false,
    isError: false,
    isSuccess: true,
    data: { ok: true, tools: [] as Array<Record<string, unknown>> } as
      { ok: boolean; tools: Array<Record<string, unknown>> } | undefined,
  },
  jobs: {
    isPending: false,
    isError: false,
    isSuccess: true,
    data: {} as Record<string, Record<string, unknown>> | undefined,
  },
}));

vi.mock('../../data/focus', () => ({ useFocusThreads: () => live.focus }));
vi.mock('../../data/memory', () => ({ useMemoryList: () => live.memory, useMemoryFile: () => live.memoryFile }));
vi.mock('../../data/catalog', () => ({ useTools: () => live.tools }));
vi.mock('../../data/jobs', () => ({ useJobs: () => live.jobs }));
vi.mock('../../shell/useSessionContext', () => ({
  useSessionContext: () => ({ context: { workspace: '/workspace' }, href: (path: string) => path }),
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

function renderWorld() {
  return render(
    <MemoryRouter>
      <WorldView />
    </MemoryRouter>,
  );
}

describe('WorldView live state', () => {
  beforeEach(() => {
    live.client = {};
    live.focus = { loaded: true, threads: [] };
    live.memory = { isPending: false, isError: false, isSuccess: true, data: { ok: true, entries: [] } };
    live.tools = { isPending: false, isError: false, isSuccess: true, data: { ok: true, tools: [] } };
    live.jobs = { isPending: false, isError: false, isSuccess: true, data: {} };
    live.memoryFile = { isPending: false, error: null, data: undefined, refetch: vi.fn() };
  });

  it('opens the canonical memory-file inspector from a world deep link', () => {
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

    render(
      <MemoryRouter initialEntries={['/world?memory=notes.md']}>
        <WorldView />
      </MemoryRouter>,
    );

    expect(screen.getByRole('region', { name: 'Memory record notes.md' })).toBeInTheDocument();
    expect(screen.getByText('from the typed memory endpoint')).toBeInTheDocument();
    expect(screen.queryByTestId('entity:place:memory')).not.toBeInTheDocument();
  });

  it('opens the live tool catalog inspector and routes reviewed installs to Library', () => {
    live.tools.data = {
      ok: true,
      tools: [
        {
          id: 'claude',
          tool_name: 'Claude Code',
          detected: true,
          configured: true,
          enabled: 'true',
          verified: true,
          version: '1.0',
          resolved_path: '/bin/claude',
          config_paths: [],
          reason: '',
          install_hint: 'reviewed',
        },
      ],
    };

    render(
      <MemoryRouter initialEntries={['/world?tool=claude']}>
        <WorldView />
      </MemoryRouter>,
    );

    expect(screen.getByRole('region', { name: 'Coding tool claude' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Review installation in Library' })).toBeInTheDocument();
  });

  it('projects real memory, detected tools, and running jobs into the map', () => {
    live.focus.threads = [
      {
        id: 'thread-1',
        title: 'Veasel work',
        cwd: '/repo/veasel',
        workspace: '/repo/veasel',
        projectName: 'veasel',
        provider: 'codex',
        status: 'running',
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
    live.tools.data = {
      ok: true,
      tools: [
        {
          id: 'codex',
          tool_name: 'Codex CLI',
          detected: true,
          configured: true,
          enabled: 'unknown',
          verified: true,
          version: '1.0',
          resolved_path: '/bin/codex',
          config_paths: [],
          reason: '',
          install_hint: '',
        },
      ],
    };
    live.jobs.data = {
      'job-1': {
        id: 'job-1',
        cmd: 'veasel',
        args: ['check'],
        status: 'running',
        workspace: '/repo/veasel',
        started_at: '',
        ended_at: '',
        exit_code: 0,
        retry_of: '',
      },
    };

    renderWorld();

    expect(screen.getByTestId('entity:place:memory')).toHaveTextContent('1 records');
    expect(screen.getByTestId('entity:object:workshop')).toHaveTextContent('1 detected');
    expect(screen.getByTestId('entity:character:job:job-1')).toHaveTextContent('running');
    expect(screen.getByTestId('entity:character:person:thread-1:thread-1')).toHaveTextContent('running');
    expect(screen.queryByText(/live runtime details are unavailable/i)).not.toBeInTheDocument();
  });

  it('reports unavailable live sources instead of presenting missing activity as known empty', () => {
    live.focus.threads = [
      {
        id: 'thread-1',
        title: 'Veasel work',
        cwd: '/repo/veasel',
        workspace: '/repo/veasel',
        projectName: 'veasel',
        provider: 'codex',
        status: 'idle',
      },
    ];
    live.memory = { isPending: false, isError: true, isSuccess: false, data: { ok: false, entries: [] } };
    live.tools = { isPending: false, isError: true, isSuccess: false, data: { ok: false, tools: [] } };
    live.jobs = { isPending: false, isError: true, isSuccess: false, data: {} };

    renderWorld();

    expect(screen.getByRole('status')).toHaveTextContent('Some live runtime details are unavailable');
    expect(screen.getByTestId('entity:object:workshop')).toHaveTextContent('unknown');
    expect(screen.getByTestId('entity:place:project:veasel')).toHaveTextContent('job state unknown');
    expect(screen.queryByTestId('entity:place:memory')).not.toBeInTheDocument();
    expect(screen.queryByTestId(/^entity:character:job:/)).not.toBeInTheDocument();
  });

  it('does not leave a loading banner when the backend is disconnected', () => {
    live.client = null;
    live.focus = { loaded: false, threads: [] };
    live.memory = { isPending: true, isError: false, isSuccess: false, data: undefined };
    live.tools = { isPending: true, isError: false, isSuccess: false, data: undefined };
    live.jobs = { isPending: true, isError: false, isSuccess: false, data: undefined };

    renderWorld();

    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('marks cached activity as last known after the backend disconnects', () => {
    live.client = null;
    live.focus = { loaded: false, threads: [] };
    live.memory = { isPending: false, isError: false, isSuccess: false, data: undefined };
    live.tools = { isPending: false, isError: false, isSuccess: false, data: undefined };
    live.jobs.data = {
      'job-1': {
        id: 'job-1',
        cmd: 'veasel',
        args: ['check'],
        status: 'running',
        workspace: '/repo/veasel',
        started_at: '',
        ended_at: '',
        exit_code: 0,
        retry_of: '',
      },
    };

    renderWorld();

    expect(screen.getByRole('status')).toHaveTextContent('Connection lost; showing last known workspace data.');
    expect(screen.getByTestId('entity:character:job:job-1')).toHaveTextContent('running');
  });
});
