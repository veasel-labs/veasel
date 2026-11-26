import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router';
import { flushSync } from 'react-dom';
import { useFocusThreads } from '../../data/focus';
import { useJobs } from '../../data/jobs';
import { useTools } from '../../data/catalog';
import { useMemoryFile, useMemoryList } from '../../data/memory';
import { useBackend } from '../../data/backend';
import { useSessionContext } from '../../shell/useSessionContext';
import { EmptyState } from '../../ui';
import { MemoryRecordInspector } from './MemoryRecordInspector';
import { ToolRecordInspector } from './ToolRecordInspector';
import { installTargetForTool, worldDetailBackExtra, worldDetailBackLabel } from './inspectors';
import { buildWorldModel, layoutWorld, type LaidOutEntity, type MemorySummary, type ProjectRecord } from './model';
import { WORLD_THEME_PACKS, worldThemePack } from './theme/cyberpunkCity';
import { useWorldDetailEscape } from './useWorldDetailEscape';
import { WorldEntityList, WorldEntityMap } from './WorldEntityMap';
import styles from './world.module.css';

function projectNameOf(cwd: string, projectName: string | null): string {
  if (projectName) return projectName;
  const parts = cwd
    .replace(/[/\\]+$/, '')
    .split(/[/\\]/)
    .filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

/**
 * World: semantic spatial home, projected only from real Veasel runtime
 * state (#693). Projects are the distinct working directories of real Focus
 * threads; people and job characters come from the existing session and job
 * APIs with their real provider, model and status. There is no second state
 * store and no invented activity: without real sessions or jobs, no workers
 * appear in the world.
 */
export default function WorldView() {
  const { client } = useBackend();
  const { context, href } = useSessionContext();
  const [params] = useSearchParams();
  const focusProject = params.get('project');
  const focusPlace = params.get('place');
  const memoryPath = params.get('memory')?.trim() || '';
  const toolId = params.get('tool')?.trim() || '';
  const { threads, loaded } = useFocusThreads();
  const memoryQuery = useMemoryList();
  const memoryFileQuery = useMemoryFile(memoryPath);
  const toolsQuery = useTools();
  const jobsQuery = useJobs();
  const navigate = useNavigate();

  const workspacePath = context.workspace || threads[0]?.workspace || threads[0]?.cwd || '';
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [worldPackId, setWorldPackId] = useState<string | null>(() => {
    try {
      return window.localStorage.getItem('at-world-pack');
    } catch {
      return null;
    }
  });
  const worldPack = worldThemePack(worldPackId);
  const chooseWorldPack = useCallback((id: string) => {
    setWorldPackId(id);
    try {
      window.localStorage.setItem('at-world-pack', id);
    } catch {
      /* storage unavailable */
    }
  }, []);

  const navigateWorld = useCallback(
    (to: string, throughProjectDoor = false) => {
      const navigateNow = () => navigate(to);
      if (
        !throughProjectDoor ||
        typeof document.startViewTransition !== 'function' ||
        window.matchMedia('(prefers-reduced-motion: reduce)').matches
      ) {
        navigateNow();
        return;
      }
      try {
        // HashRouter is intentionally declarative and does not consume the
        // data-router `viewTransition` option. Wrap its real location update
        // directly so the map snapshot changes inside the native transition.
        document.startViewTransition(() => flushSync(navigateNow));
      } catch {
        // An interrupted/unavailable transition must never block the door.
        navigateNow();
      }
    },
    [navigate],
  );

  // Projects and characters come from the same canonical thread store
  // Focus uses — never from a second registry.
  const projects: ProjectRecord[] = useMemo(() => {
    const byTarget = new Map<string, ProjectRecord>();
    for (const thread of threads) {
      if (!thread.cwd || byTarget.has(thread.cwd)) continue;
      byTarget.set(thread.cwd, {
        name: projectNameOf(thread.cwd, thread.projectName),
        target: thread.cwd,
        status: 'ok',
      });
    }
    return [...byTarget.values()];
  }, [threads]);

  const memory: MemorySummary = useMemo(() => {
    const entries = memoryQuery.isSuccess && memoryQuery.data.ok ? memoryQuery.data.entries : [];
    return {
      available: memoryQuery.isSuccess && memoryQuery.data.ok,
      entries,
      projectKeys: [...new Set(entries.map((entry) => entry.provenance.project).filter(Boolean))],
    };
  }, [memoryQuery.data, memoryQuery.isSuccess]);

  const tools = useMemo(
    () =>
      toolsQuery.isSuccess && toolsQuery.data.ok
        ? toolsQuery.data.tools.map((tool) => ({
            id: tool.id,
            toolName: tool.tool_name,
            detected: tool.detected,
            configured: tool.configured,
            enabled: tool.enabled,
            verified: tool.verified,
            version: tool.version,
          }))
        : [],
    [toolsQuery.data, toolsQuery.isSuccess],
  );

  const jobs = useMemo(
    () =>
      jobsQuery.isSuccess
        ? Object.values(jobsQuery.data).map((job) => ({
            id: job.id,
            cmd: job.cmd,
            args: job.args,
            status: job.status,
            workspace: job.workspace,
          }))
        : [],
    [jobsQuery.data, jobsQuery.isSuccess],
  );

  const personSessions = useMemo(
    () =>
      threads.map((thread) => ({
        id: thread.id,
        personId: thread.id,
        name: thread.title || projectNameOf(thread.cwd, thread.projectName),
        role: thread.provider,
        cwd: thread.cwd,
        projectId: projectNameOf(thread.cwd, thread.projectName),
        provider: thread.provider,
        model: thread.resolvedModel ?? thread.model ?? undefined,
        status: thread.status,
        focusThreadId: thread.id,
      })),
    [threads],
  );

  const model = useMemo(
    () =>
      buildWorldModel({
        workspacePath,
        projects,
        projectsKnown: loaded,
        memory,
        tools,
        toolsKnown: toolsQuery.isSuccess && toolsQuery.data.ok,
        jobs,
        jobsKnown: jobsQuery.isSuccess,
        personSessions,
        focusProjectId: focusProject,
      }),
    [
      workspacePath,
      projects,
      loaded,
      memory,
      tools,
      toolsQuery.data,
      toolsQuery.isSuccess,
      jobs,
      jobsQuery.isSuccess,
      personSessions,
      focusProject,
    ],
  );

  const layout = useMemo(() => layoutWorld(model), [model]);
  const selected = layout.entities.find((entity) => entity.id === selectedId) ?? null;
  const needsWorkspace =
    !model.focusProjectId && layout.entities.some((entity) => entity.id === 'place:workspace' && entity.state === 'missing');

  useEffect(() => {
    if (memoryPath) {
      const hit = layout.entities.find((entity) => entity.hrefExtra?.memory === memoryPath);
      if (hit) setSelectedId(hit.id);
      return;
    }
    if (toolId) {
      const hit = layout.entities.find((entity) => entity.hrefExtra?.tool === toolId);
      if (hit) setSelectedId(hit.id);
      return;
    }
    if (focusPlace && focusPlace !== 'projects') {
      if (layout.entities.some((entity) => entity.id === focusPlace)) {
        setSelectedId(focusPlace);
      }
      return;
    }
    if (focusProject) {
      const roomId = `place:project:${focusProject}`;
      if (layout.entities.some((entity) => entity.id === roomId)) {
        setSelectedId(roomId);
      }
    }
  }, [memoryPath, toolId, focusPlace, focusProject, layout.entities]);

  // Queries are disabled while there is no connected backend. Do not keep a
  // perpetual loading overlay in that state; the shell already reports the
  // backend connection status.
  const gathering =
    client !== null && (!loaded || memoryQuery.isPending || toolsQuery.isPending || jobsQuery.isPending);
  const showingLastKnownState =
    client === null &&
    (threads.length > 0 ||
      Object.keys(jobsQuery.data ?? {}).length > 0 ||
      memoryQuery.data !== undefined ||
      toolsQuery.data !== undefined);
  const liveDataUnavailable =
    showingLastKnownState ||
    (client !== null &&
      (memoryQuery.isError ||
        toolsQuery.isError ||
        jobsQuery.isError ||
        (memoryQuery.isSuccess && !memoryQuery.data.ok) ||
        (toolsQuery.isSuccess && !toolsQuery.data.ok)));

  const openEntity = (entity: LaidOutEntity) => {
    if (!entity.hrefPath) return;
    const crossesProjectDoor = entity.id.startsWith('place:project:') || entity.id === 'object:exit-grounds';
    navigateWorld(href(entity.hrefPath, entity.hrefExtra), crossesProjectDoor);
  };

  const toolEntry =
    toolId && toolsQuery.data?.ok ? toolsQuery.data.tools.find((tool) => tool.id === toolId) : undefined;
  const detailOpen = Boolean(memoryPath || toolId);
  const goBackFromDetail = useCallback(() => {
    navigate(href('/world', worldDetailBackExtra(focusProject)));
  }, [navigate, href, focusProject]);
  const goBackFromWorld = useCallback(() => {
    if (detailOpen) {
      goBackFromDetail();
      return;
    }
    if (focusProject) {
      navigateWorld(href('/world'), true);
    }
  }, [detailOpen, goBackFromDetail, focusProject, navigateWorld, href]);
  // Escape: leave memory/tool detail first; else leave project interior to grounds.
  useWorldDetailEscape(goBackFromWorld, detailOpen || Boolean(focusProject));

  const title = model.focusProjectId ? `${model.focusProjectId} house` : model.workspaceLabel || 'Workspace world';

  return (
    <div className={styles.world} data-focus={model.focusProjectId ? 'interior' : 'grounds'}>
      <header className={styles.worldHeader}>
        <h1 className={styles.worldTitle}>{title}</h1>
        <span className={styles.worldMeta}>
          {model.focusProjectId ? 'project interior' : worldPack.label} · {layout.entities.length} places
        </span>
        {!model.focusProjectId ? (
          <div className={styles.worldThemePackPicker} role="group" aria-label="World theme">
            {WORLD_THEME_PACKS.map((pack) => (
              <button
                key={pack.id}
                type="button"
                data-world-pack={pack.id}
                data-active={worldPack.id === pack.id || undefined}
                aria-pressed={worldPack.id === pack.id}
                onClick={() => chooseWorldPack(pack.id)}
              >
                {pack.label}
              </button>
            ))}
          </div>
        ) : null}
        {selected ? (
          <span className={styles.selectedChip} aria-live="polite">
            Selected: <strong>{selected.name}</strong> — {selected.concept}
            {selected.state ? ` · ${selected.state}` : ''}
          </span>
        ) : null}
        <Link
          className={styles.worldHeaderLink}
          to={model.focusProjectId ? href('/world') : href('/focus')}
          onClick={(event) => {
            if (
              !model.focusProjectId ||
              event.defaultPrevented ||
              event.button !== 0 ||
              event.metaKey ||
              event.ctrlKey ||
              event.shiftKey ||
              event.altKey
            ) {
              return;
            }
            event.preventDefault();
            navigateWorld(href('/world'), true);
          }}
        >
          {model.focusProjectId ? '← grounds' : 'Open Focus'}
        </Link>
      </header>

      <div className={styles.mapWrap} aria-busy={gathering}>
        {memoryPath ? (
          <MemoryRecordInspector
            path={memoryPath}
            data={memoryFileQuery.data}
            error={memoryFileQuery.error as Error | null}
            isPending={memoryFileQuery.isPending}
            onBack={() => navigate(href('/world', worldDetailBackExtra(focusProject)))}
            backLabel={worldDetailBackLabel(focusProject)}
            onRetry={() => void memoryFileQuery.refetch()}
          />
        ) : toolId ? (
          <ToolRecordInspector
            toolId={toolId}
            tool={toolEntry}
            error={toolsQuery.error as Error | null}
            isPending={toolsQuery.isPending}
            onBack={() => navigate(href('/world', worldDetailBackExtra(focusProject)))}
            backLabel={worldDetailBackLabel(focusProject)}
            onRetry={() => void toolsQuery.refetch()}
            onReviewInstall={
              installTargetForTool(toolId)
                ? () =>
                    navigate(href('/library', { install_target: installTargetForTool(toolId)!, install_review: '1' }))
                : undefined
            }
          />
        ) : (
          <>
            {needsWorkspace ? (
              <aside className={styles.workspacePrompt} aria-labelledby="workspace-prompt-title">
                <span className={styles.workspacePromptMark} aria-hidden="true">⌂</span>
                <div className={styles.workspacePromptCopy}>
                  <h2 id="workspace-prompt-title">Your valley is waiting for a workspace</h2>
                  <p>Set a workspace in the context bar above to bring its real sessions, tools, and activity into this world.</p>
                </div>
                <Link
                  className={styles.workspacePromptAction}
                  to={href('/focus')}
                  aria-label="Open Focus to choose a workspace"
                >
                  Open Focus <span aria-hidden="true">→</span>
                </Link>
              </aside>
            ) : null}
            {layout.entities.length === 0 ? (
              <EmptyState title="Nothing to place yet.">Waiting on workspace context.</EmptyState>
            ) : (
              <WorldEntityMap
                entities={layout.entities}
                selectedId={selectedId}
                theme={worldPack}
                cols={layout.cols}
                rows={layout.rows}
                ariaLabel={model.focusProjectId ? `Interior of ${model.focusProjectId}` : 'Semantic workspace world'}
                mode={model.focusProjectId ? 'interior' : 'grounds'}
                persistKey={`${workspacePath}|${model.focusProjectId ?? 'grounds'}`}
                appearanceKey={workspacePath}
                suspended={detailOpen}
                onSelect={setSelectedId}
                onActivate={openEntity}
              />
            )}
          </>
        )}
        {(gathering || liveDataUnavailable) && layout.entities.length > 0 ? (
          <p className={styles.worldLoadStatus} role="status" aria-live="polite">
            {gathering
              ? 'Checking live workspace details…'
              : showingLastKnownState
                ? 'Connection lost; showing last known workspace data.'
                : 'Some live runtime details are unavailable; missing activity is omitted.'}
          </p>
        ) : null}
      </div>

      <details className={styles.entityListWrap}>
        <summary>
          <span className={styles.worldTitle}>World index</span>{' '}
          <span className={styles.worldMeta}>
            — {layout.entities.length} destinations, resources, sessions, and jobs
          </span>
        </summary>
        {layout.entities.length === 0 ? (
          <EmptyState title="Nothing to place yet.">Waiting on workspace context.</EmptyState>
        ) : (
          <WorldEntityList entities={layout.entities} selectedId={selectedId} href={href} onSelect={setSelectedId} />
        )}
      </details>
    </div>
  );
}
