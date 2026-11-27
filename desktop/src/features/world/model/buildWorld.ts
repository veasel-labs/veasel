import { isTerminalJobStatus } from '../../../lib/api';
import { memoryFilePath, memoryInspectExtra } from '../inspectors';
import { projectFacades } from './facades';
import { jobStandAtId, projectScopedMemory, workspaceLevelMemory } from './memoryScope';
import type {
  MemoryEntryRecord,
  PlaceActivity,
  ProjectRecord,
  SemanticEntity,
  ToolRecord,
  WorldDomainInput,
  WorldModel,
} from './types';

function workspaceLabel(path: string): string {
  const trimmed = path.replace(/[/\\]+$/, '');
  const parts = trimmed.split(/[/\\]/).filter(Boolean);
  const name = parts[parts.length - 1] ?? '';
  // The default harness directory is an implementation path, not the name of
  // the place users think of as their workspace.
  if (name.toLowerCase() === '.ai-workspace') return 'AI Workspace';
  return name || path || 'Workspace';
}

function jobCommandLine(job: WorldDomainInput['jobs'][number]): string {
  return [job.cmd, ...job.args].filter(Boolean).join(' ');
}

function characterTheme(status: string): SemanticEntity['themeKey'] {
  if (status === 'failed' || status === 'rejected' || status === 'error') return 'agent.blocked';
  if (status === 'queued' || status === 'running') return 'agent.working';
  return 'agent.idle';
}

function provenanceDetail(entry: MemoryEntryRecord): string {
  const parts = [
    entry.kind,
    entry.provenance.project ? `project ${entry.provenance.project}` : '',
    entry.provenance.author ? `by ${entry.provenance.author}` : '',
    entry.provenance.file || '',
  ].filter(Boolean);
  return parts.join(' · ') || entry.id;
}

/** Match work only when its normalized workspace is at or under the project root. */
export function jobBelongsToProject(job: { workspace: string }, project: ProjectRecord): boolean {
  return Boolean(
    job.workspace.trim() && project.target.trim() && pathIsWithin(job.workspace.trim(), project.target.trim()),
  );
}

function normalizedRootLength(root: string): number {
  return root.replace(/\\/g, '/').replace(/\/+$/, '').length;
}

function mostSpecificProject(path: string, projects: readonly ProjectRecord[]): ProjectRecord | undefined {
  if (!path.trim()) return undefined;
  return projects
    .filter((project) => project.target.trim() && pathIsWithin(path, project.target))
    .sort((a, b) => normalizedRootLength(b.target) - normalizedRootLength(a.target) || a.name.localeCompare(b.name))[0];
}

function sessionBelongsToProject(
  session: NonNullable<WorldDomainInput['personSessions']>[number],
  project: ProjectRecord,
  projects: readonly ProjectRecord[],
): boolean {
  if (!session.cwd.trim() || !project.target.trim() || !pathIsWithin(session.cwd, project.target)) return false;
  const explicit = projects.find((candidate) => candidate.name === session.projectId);
  return explicit && explicit.target.trim() && pathIsWithin(session.cwd, explicit.target)
    ? explicit.name === project.name
    : mostSpecificProject(session.cwd, projects)?.name === project.name;
}

function activityForJobs(jobs: WorldDomainInput['jobs']): PlaceActivity {
  let working = 0;
  let blocked = 0;
  for (const job of jobs) {
    if (job.status === 'failed' || job.status === 'rejected') blocked += 1;
    else if (!isTerminalJobStatus(job.status)) working += 1;
  }
  if (blocked > 0) return 'blocked';
  if (working > 0) return 'working';
  return 'calm';
}

function activityForProject(
  jobs: WorldDomainInput['jobs'],
  sessions: NonNullable<WorldDomainInput['personSessions']>,
): PlaceActivity {
  const jobsActivity = activityForJobs(jobs);
  if (
    jobsActivity === 'blocked' ||
    sessions.some((session) => session.status === 'failed' || session.status === 'error')
  )
    return 'blocked';
  if (jobsActivity === 'working' || sessions.some((session) => session.status === 'running')) return 'working';
  return 'calm';
}

function projectWorldState(
  project: ProjectRecord,
  activity: PlaceActivity,
  jobCount: number,
  personCount: number,
  jobsKnown: boolean,
  runningSessions: number,
  stoppedSessions: number,
  awaitingApproval: number,
  awaitingInput: number,
): string {
  if (project.status === 'broken') return 'broken';
  if (activity === 'blocked') return 'needs attention';
  const stopped = stoppedSessions ? `${stoppedSessions} session${stoppedSessions === 1 ? '' : 's'} stopped` : '';
  if (awaitingApproval || awaitingInput) {
    const waiting = [
      awaitingApproval ? `${awaitingApproval} awaiting approval` : '',
      awaitingInput ? `${awaitingInput} awaiting input` : '',
      stopped,
      !jobsKnown ? 'job state unknown' : '',
    ].filter(Boolean);
    return waiting.join(' · ');
  }
  if (!jobsKnown)
    return `${runningSessions ? `${runningSessions} session${runningSessions === 1 ? '' : 's'} working · ` : ''}${personCount ? `${personCount} Person session${personCount === 1 ? '' : 's'} open · ` : ''}${stopped ? `${stopped} · ` : ''}job state unknown`;
  if (activity === 'working') {
    const active = [
      jobCount ? `${jobCount} job${jobCount === 1 ? '' : 's'} active` : '',
      runningSessions ? `${runningSessions} session${runningSessions === 1 ? '' : 's'} working` : '',
    ].filter(Boolean);
    return active.join(' · ');
  }
  if (stopped) return stopped;
  if (personCount > 0) return `${personCount} Person session${personCount === 1 ? '' : 's'} open`;
  return 'calm';
}

function pushPersonCharacters(
  entities: SemanticEntity[],
  sessions: NonNullable<WorldDomainInput['personSessions']>,
  projectId?: string,
  standAtId?: string,
): void {
  for (const session of sessions) {
    // Activity is claimed only from the real session status: a running
    // session works, a failed one needs attention, anything else is idle.
    const working = session.status === 'running';
    const blocked = session.status === 'failed' || session.status === 'error';
    entities.push({
      id: `character:person:${session.personId}:${session.id}`,
      kind: 'character',
      concept: 'Person session',
      name: session.name,
      state: session.status ?? 'session open',
      themeKey: blocked ? 'agent.blocked' : working ? 'agent.working' : 'agent.idle',
      characterSprite: session.avatarCharacter,
      characterAccent: session.avatarAccent,
      availability: 'present',
      hrefPath: session.focusThreadId ? '/focus' : '/people',
      hrefExtra: session.focusThreadId
        ? { thread: session.focusThreadId }
        : { person: session.personId, session: session.id },
      projectId,
      detail: `${session.role} · ${session.provider ?? 'runner unknown'}${session.model ? ` · ${session.model}` : ''} · session ${session.id}`,
      standAtId,
    });
  }
}

function visibleTools(tools: ToolRecord[]): ToolRecord[] {
  // Only tools the API actually detected — never invent rack slots.
  return tools.filter((tool) => tool.detected).sort((a, b) => a.id.localeCompare(b.id));
}

function pushJobCharacters(
  entities: SemanticEntity[],
  jobs: WorldDomainInput['jobs'],
  opts: {
    projectId?: string;
    tools: readonly ToolRecord[];
    memoryPlaceId?: string;
    terminalObjectId?: string;
  },
): void {
  for (const job of jobs) {
    // A failed/rejected job remains an Operations record, not a live worker.
    if (isTerminalJobStatus(job.status)) continue;
    const standAtId = jobStandAtId(job, {
      tools: opts.tools,
      memoryPlaceId: opts.memoryPlaceId,
      terminalObjectId: opts.terminalObjectId,
    });
    entities.push({
      id: `character:job:${job.id}`,
      kind: 'character',
      concept: 'Job',
      name: jobCommandLine(job) || job.id,
      state: job.status,
      themeKey: characterTheme(job.status),
      availability: 'present',
      hrefPath: '/operations',
      hrefExtra: { job: job.id },
      projectId: opts.projectId,
      detail: `Job ${job.id}`,
      activity: 'working',
      standAtId,
    });
  }
}

function buildGrounds(input: WorldDomainInput): SemanticEntity[] {
  const entities: SemanticEntity[] = [];

  entities.push({
    id: 'place:workspace',
    kind: 'place',
    concept: 'Active harness / workspace root',
    name: workspaceLabel(input.workspacePath) || 'Workspace',
    state: input.harnessNotice ? 'notice' : input.workspacePath ? 'known' : 'missing',
    themeKey: 'workspace.grounds',
    availability: input.workspacePath ? 'present' : 'empty',
    hrefPath: '/workspace',
    detail: input.harnessNotice || input.workspacePath || 'No workspace path in session context',
    facade: 'landmark-workspace',
  });

  if (input.memory.available) {
    // World archive: workspace-level only (empty project or non-roster label).
    const archive = workspaceLevelMemory(input.memory.entries, input.projects);
    const count = archive.length;
    entities.push({
      id: 'place:memory',
      kind: 'place',
      concept: 'Memory archive',
      name: 'Memory archive',
      state: count > 0 ? `${count} records` : 'empty',
      themeKey: 'memory.index',
      availability: count > 0 ? 'present' : 'empty',
      hrefPath: '/world',
      hrefExtra: { place: 'place:memory' },
      // Overview only — open a record tile (or stay selected). Never pretend Workspace is memory.
      detail:
        count > 0
          ? `${count} workspace-level memory record${count === 1 ? '' : 's'} (typed memory API)`
          : 'Memory API reachable; archive is empty',
      facade: 'landmark-archive',
    });

    // Keep the grounds scannable — a few recent ledgers beside the archive, not a card wall.
    const GROUNDS_MEMORY_LEDGERS = 3;
    for (const entry of archive.slice(0, GROUNDS_MEMORY_LEDGERS)) {
      const path = memoryFilePath(entry);
      const more = count > GROUNDS_MEMORY_LEDGERS ? ` · showing ${GROUNDS_MEMORY_LEDGERS} of ${count} on grounds` : '';
      entities.push({
        id: `object:memory:${entry.id}`,
        kind: 'object',
        concept: 'Memory entry',
        name: entry.title || entry.id,
        state: entry.kind || 'listed',
        themeKey: 'memory.entry',
        availability: 'present',
        hrefPath: '/world',
        hrefExtra: memoryInspectExtra(entry),
        detail: (provenanceDetail(entry) || path) + more,
      });
    }
  }

  // Shared landmarks are places (3×3 footprints) so silhouettes read as buildings.
  entities.push({
    id: 'object:terminal',
    kind: 'place',
    concept: 'Terminal / PTY workstation',
    name: 'Terminal',
    state: 'launcher',
    themeKey: 'tool.terminal',
    availability: 'present',
    hrefPath: '/terminal',
    hrefExtra: { create: 'terminal', cwd: input.workspacePath || undefined },
    detail: 'Review and open a real terminal session in this workspace',
    facade: 'landmark-terminal',
  });

  // Library is the knowledge/capability inspector — not a second invented room.
  entities.push({
    id: 'object:library',
    kind: 'place',
    concept: 'Capability library',
    name: 'Library',
    state: 'catalog',
    themeKey: 'capability.shelf',
    availability: 'present',
    hrefPath: '/library',
    detail: 'Skills, agents, packs — reusable catalog capabilities',
    facade: 'landmark-library',
  });

  const tools = input.toolsKnown ? visibleTools(input.tools) : [];
  const toolDetail = `${tools.length} coding-tool runtime${tools.length === 1 ? '' : 's'} detected · inspect in Library`;
  entities.push({
    id: 'object:workshop',
    kind: 'place',
    concept: 'Shared coding-tool workshop',
    name: 'Workshop',
    state: input.toolsKnown ? (tools.length ? `${tools.length} detected` : 'empty') : 'unknown',
    themeKey: 'tool.coding',
    availability: input.toolsKnown ? (tools.length ? 'present' : 'empty') : 'unavailable',
    hrefPath: '/library',
    detail: input.toolsKnown
      ? tools.length
        ? toolDetail
        : 'No coding-tool runtime detected · browse available capabilities in Library'
      : 'Coding-tool inventory is unavailable · retry from Library',
    facade: 'landmark-workshop',
  });
  // Files use the typed workspace tree API — open Workspace Files panel.
  entities.push({
    id: 'object:files',
    kind: 'place',
    concept: 'Workspace files',
    name: 'Files',
    state: 'workspace tree',
    themeKey: 'files.workspace',
    availability: 'present',
    hrefPath: '/workspace',
    hrefExtra: { panel: 'files' },
    detail: 'Workspace-contained tree via GET /api/v1/files',
    facade: 'landmark-files',
  });

  // Operations is the shared runtime building — not a second home.
  entities.push({
    id: 'object:operations',
    kind: 'place',
    concept: 'Operations / runtime',
    name: 'Operations',
    state: 'inspector',
    themeKey: 'ops.crate',
    availability: 'present',
    hrefPath: '/operations',
    detail: 'Jobs, loops, swarms, and doctor — real serve state only',
    facade: 'landmark-operations',
  });

  entities.push({
    id: 'object:settings',
    kind: 'place',
    concept: 'Settings',
    name: 'Settings',
    state: 'configuration',
    themeKey: 'ops.lamp',
    availability: 'present',
    hrefPath: '/settings',
    detail: 'Appearance, harness, and coding-tool connections',
    facade: 'landmark-settings',
  });

  entities.push({
    id: 'object:attention',
    kind: 'place',
    concept: 'Attention inbox',
    name: 'Needs you',
    state: 'inspector',
    themeKey: 'attention.inbox',
    availability: 'present',
    hrefPath: '/office',
    detail: 'Failures and blocked work — attention inspector, not home',
    facade: 'landmark-attention',
  });

  const groundsStand = {
    tools: [],
    memoryPlaceId: input.memory.available ? 'place:memory' : undefined,
    terminalObjectId: 'object:terminal',
  };

  if (!input.projectsKnown) {
    // Omit fabricated project buildings when the list call failed.
  } else if (input.projects.length === 0) {
    entities.push({
      id: 'place:projects-empty',
      kind: 'marker',
      concept: 'Project directory',
      name: 'Add project',
      state: 'empty',
      themeKey: 'project.building',
      availability: 'empty',
      hrefPath: '/workspace',
      hrefExtra: { panel: 'projects' },
      detail: 'Link a repository here to give it a house in the workspace valley',
      facade: 'project-board',
    });
  } else {
    const facades = projectFacades(input.projects.map((project) => project.name));
    for (const project of input.projects) {
      const projectJobs = input.jobs.filter(
        (job) =>
          jobBelongsToProject(job, project) &&
          mostSpecificProject(job.workspace, input.projects)?.name === project.name,
      );
      const projectSessions = (input.personSessions ?? []).filter((session) =>
        sessionBelongsToProject(session, project, input.projects),
      );
      const jobsKnown = input.jobsKnown ?? true;
      const awaitingApproval = projectSessions.filter((session) => session.status === 'awaiting-approval').length;
      const awaitingInput = projectSessions.filter((session) => session.status === 'awaiting-input').length;
      const runningSessions = projectSessions.filter((session) => session.status === 'running').length;
      const stoppedSessions = projectSessions.filter((session) => session.status === 'interrupted').length;
      const hasFailedSession = projectSessions.some(
        (session) => session.status === 'failed' || session.status === 'error',
      );
      const activity = jobsKnown
        ? activityForProject(projectJobs, projectSessions)
        : hasFailedSession
          ? 'blocked'
          : 'unknown';
      const liveCount = projectJobs.filter((job) => !isTerminalJobStatus(job.status)).length;
      const projectPlaceId = `place:project:${project.name}`;
      entities.push({
        id: projectPlaceId,
        kind: 'place',
        concept: 'Project',
        name: project.name,
        state: projectWorldState(
          project,
          activity,
          liveCount,
          projectSessions.length,
          jobsKnown,
          runningSessions,
          stoppedSessions,
          awaitingApproval,
          awaitingInput,
        ),
        themeKey: 'project.building',
        availability: 'present',
        hrefPath: '/world',
        hrefExtra: { project: project.name },
        projectId: project.name,
        detail: `${project.status} → ${project.target}${liveCount ? ` · ${liveCount} job(s)` : ''}${projectSessions.length ? ` · ${projectSessions.length} Person session(s)` : ''}`,
        activity,
        facade: facades.get(project.name),
      });

      // Real project sessions belong at their project house. Coding tools are
      // shared workspace resources and must not pull project work back to the
      // global workshop.
      pushJobCharacters(entities, projectJobs, {
        projectId: project.name,
        tools: [],
        terminalObjectId: projectPlaceId,
      });
      pushPersonCharacters(entities, projectSessions, project.name, projectPlaceId);
    }
  }

  // Workspace-scoped jobs (no project match) still appear on the grounds.
  const unmatched = input.jobs.filter((job) => !input.projects.some((project) => jobBelongsToProject(job, project)));
  pushJobCharacters(entities, unmatched, groundsStand);
  return entities;
}

/**
 * Project interior — inside one house. Not a dashboard: only places backed by
 * real capabilities for this project (memory API, terminal, project files, jobs).
 */
function buildInterior(input: WorldDomainInput, focus: string): SemanticEntity[] {
  const entities: SemanticEntity[] = [];
  const project = input.projects.find((row) => row.name === focus);

  entities.push({
    id: 'object:exit-grounds',
    kind: 'object',
    concept: 'Return to workspace grounds',
    name: 'Exit',
    state: 'return',
    themeKey: 'workspace.grounds',
    availability: 'present',
    hrefPath: '/world',
    detail: 'Leave the project interior',
    facade: 'door-exit',
  });

  if (!project) {
    entities.push({
      id: 'place:projects-empty',
      kind: 'marker',
      concept: 'Project',
      name: focus,
      state: 'missing',
      themeKey: 'project.building',
      availability: 'unavailable',
      hrefPath: '/world',
      detail: 'Project not in the current roster',
    });
    return entities;
  }

  const projectJobs = input.jobs.filter(
    (job) =>
      jobBelongsToProject(job, project) && mostSpecificProject(job.workspace, input.projects)?.name === project.name,
  );
  const projectSessions = (input.personSessions ?? []).filter((session) =>
    sessionBelongsToProject(session, project, input.projects),
  );
  const jobsKnown = input.jobsKnown ?? true;
  const awaitingApproval = projectSessions.filter((session) => session.status === 'awaiting-approval').length;
  const awaitingInput = projectSessions.filter((session) => session.status === 'awaiting-input').length;
  const runningSessions = projectSessions.filter((session) => session.status === 'running').length;
  const stoppedSessions = projectSessions.filter((session) => session.status === 'interrupted').length;
  const hasFailedSession = projectSessions.some((session) => session.status === 'failed' || session.status === 'error');
  const activity = jobsKnown
    ? activityForProject(projectJobs, projectSessions)
    : hasFailedSession
      ? 'blocked'
      : 'unknown';
  const liveCount = projectJobs.filter(
    (job) => !isTerminalJobStatus(job.status) || job.status === 'failed' || job.status === 'rejected',
  ).length;

  entities.push({
    id: `place:project:${project.name}`,
    kind: 'place',
    concept: 'Project overview board',
    name: project.name,
    state: projectWorldState(
      project,
      activity,
      liveCount,
      projectSessions.length,
      jobsKnown,
      runningSessions,
      stoppedSessions,
      awaitingApproval,
      awaitingInput,
    ),
    themeKey: 'project.building',
    availability: 'present',
    hrefPath: '/workspace',
    hrefExtra: { panel: 'projects' },
    projectId: project.name,
    detail: `${project.status} → ${project.target}${projectSessions.length ? ` · ${projectSessions.length} Person session(s)` : ''}`,
    activity,
    facade: 'project-board',
  });

  if (input.memory.available) {
    const scoped = projectScopedMemory(input.memory.entries, project.name);
    entities.push({
      id: `place:memory-project:${project.name}`,
      kind: 'place',
      concept: 'Project memory records',
      name: 'Records',
      state: scoped.length > 0 ? `${scoped.length} records` : 'empty',
      themeKey: 'memory.index',
      availability: scoped.length > 0 ? 'present' : 'empty',
      hrefPath: '/world',
      hrefExtra: { project: project.name, place: `place:memory-project:${project.name}` },
      projectId: project.name,
      detail:
        scoped.length > 0
          ? `${scoped.length} memory record${scoped.length === 1 ? '' : 's'} for this project`
          : 'Memory API reachable; no records scoped to this project',
      facade: 'landmark-archive',
    });

    for (const entry of scoped) {
      const path = memoryFilePath(entry);
      entities.push({
        id: `object:memory:${entry.id}`,
        kind: 'object',
        concept: 'Memory entry',
        name: entry.title || entry.id,
        state: entry.kind || 'listed',
        themeKey: 'memory.entry',
        availability: 'present',
        hrefPath: '/world',
        hrefExtra: memoryInspectExtra(entry, project.name),
        projectId: project.name,
        detail: provenanceDetail(entry) || path,
      });
    }
  }

  entities.push({
    id: `object:terminal-project:${project.name}`,
    kind: 'object',
    concept: 'Terminal / PTY workstation',
    name: 'Terminal',
    state: 'launcher',
    themeKey: 'tool.terminal',
    availability: 'present',
    hrefPath: '/terminal',
    hrefExtra: {
      create: 'terminal',
      cwd: resolveProjectTarget(input.workspacePath, project.target),
      project: project.name,
    },
    projectId: project.name,
    detail: `Open Terminal · cwd hint ${project.target}`,
    facade: 'tool-terminal-desk',
  });

  entities.push({
    id: `object:files-project:${project.name}`,
    kind: 'object',
    concept: 'Project files',
    name: 'Files',
    state: 'project tree',
    themeKey: 'files.project',
    availability: 'present',
    hrefPath: '/workspace',
    hrefExtra: { panel: 'files', project: project.name },
    projectId: project.name,
    detail: `Project files · ${project.target}`,
    facade: 'desk-files',
  });

  pushJobCharacters(entities, projectJobs, {
    projectId: project.name,
    tools: [],
    memoryPlaceId: input.memory.available ? `place:memory-project:${project.name}` : undefined,
    terminalObjectId: `object:terminal-project:${project.name}`,
  });
  pushPersonCharacters(entities, projectSessions, project.name, `object:terminal-project:${project.name}`);

  return entities;
}

export function pathIsWithin(path: string, root: string): boolean {
  const normalize = (value: string) => {
    const slashed = value.replace(/\\/g, '/');
    const prefix = /^[a-z]:\//i.test(slashed) ? slashed.slice(0, 3) : slashed.startsWith('/') ? '/' : '';
    const parts: string[] = [];
    for (const part of slashed.slice(prefix.length).split('/')) {
      if (!part || part === '.') continue;
      if (part === '..' && parts.length && parts[parts.length - 1] !== '..') parts.pop();
      else if (part !== '..' || !prefix) parts.push(part);
    }
    return `${prefix}${parts.join('/')}`.replace(/\/+$/, '') || '/';
  };
  const candidate = normalize(path);
  const parent = normalize(root);
  const windowsPath = /^[a-z]:\//i.test(candidate) || /^[a-z]:\//i.test(parent);
  const left = windowsPath ? candidate.toLowerCase() : candidate;
  const right = windowsPath ? parent.toLowerCase() : parent;
  return left === right || (right === '/' ? left.startsWith('/') : left.startsWith(`${right}/`));
}

/** Resolve a project symlink's literal target relative to workspace/projects. */
export function resolveProjectTarget(workspace: string, target: string): string {
  const normalizedTarget = target.replace(/\\/g, '/');
  const isAbsolute = normalizedTarget.startsWith('/') || /^[a-z]:\//i.test(normalizedTarget);
  const combined = isAbsolute ? normalizedTarget : `${workspace.replace(/[\\/]+$/, '')}/projects/${normalizedTarget}`;
  const prefix = /^[a-z]:\//i.test(combined)
    ? combined.slice(0, 3)
    : combined.startsWith('//')
      ? '//'
      : combined.startsWith('/')
        ? '/'
        : '';
  const segments = combined.slice(prefix.length).split('/');
  const resolved: string[] = [];
  for (const segment of segments) {
    if (!segment || segment === '.') continue;
    if (segment === '..') {
      if (resolved.length > 0 && resolved[resolved.length - 1] !== '..') resolved.pop();
      else if (!prefix) resolved.push(segment);
      continue;
    }
    resolved.push(segment);
  }
  return `${prefix}${resolved.join('/')}` || '.';
}

/**
 * DOMAIN STATE → SEMANTIC WORLD MODEL.
 * Grounds vs project interior. Characters only for proven jobs.
 * Memory archive only when the typed memory API exists (omit on 404).
 * Workspace files open the Workspace Files panel (GET /api/v1/files).
 * Operations and Settings are shared commons places (also on the dock).
 * Library is the capability/catalog inspector destination.
 */
export function buildWorldModel(input: WorldDomainInput): WorldModel {
  const focus = input.focusProjectId?.trim() || null;
  const entities = focus ? buildInterior(input, focus) : buildGrounds(input);

  return {
    workspacePath: input.workspacePath,
    workspaceLabel: workspaceLabel(input.workspacePath),
    focusProjectId: focus,
    entities,
  };
}
