import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router';
import { flushSync } from 'react-dom';
import { useFocusBackendDown, useFocusOperations, useFocusProviders, useFocusThreads } from '../../data/focus';
import { useMemoryFile, useMemoryList } from '../../data/memory';
import { useBackend } from '../../data/backend';
import { useSessionContext } from '../../shell/useSessionContext';
import { EmptyState } from '../../ui';
import { MemoryRecordInspector } from './MemoryRecordInspector';
import { ToolRecordInspector } from './ToolRecordInspector';
import { worldDetailBackExtra, worldDetailBackLabel } from './inspectors';
import { buildWorldModel, layoutWorld, type LaidOutEntity, type MemorySummary, type ProjectRecord } from './model';
import { WORLD_THEME_PACKS, worldThemePack } from './theme/cyberpunkCity';
import { useWorldDetailEscape } from './useWorldDetailEscape';
import { WorldEntityList, WorldEntityMap } from './WorldEntityMap';
import styles from './world.module.css';

function activityStatusFromOperation(threadStatus: string, operationStatus?: string): string {
  if (!operationStatus) return threadStatus;
  if (operationStatus === 'queued' || operationStatus === 'running' || operationStatus === 'cancelling') {
    return threadStatus === 'awaiting-approval' || threadStatus === 'awaiting-input' ? threadStatus : 'running';
  }
  if (operationStatus === 'cancelled') return 'interrupted';
  if (operationStatus === 'failed' || operationStatus === 'uncertain') return 'error';
  if (operationStatus === 'completed') return 'idle';
  return threadStatus;
}

function projectNameOf(cwd: string, projectName: string | null): string {
  if (projectName) return projectName;
  const parts = cwd
    .replace(/[/\\]+$/, '')
    .split(/[/\\]/)
    .filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

function projectNamesByTarget(threads: readonly { cwd: string; projectName: string | null }[]): Map<string, string> {
  const baseByTarget = new Map<string, string>();
  for (const thread of threads) {
    if (thread.cwd && !baseByTarget.has(thread.cwd)) {
      baseByTarget.set(thread.cwd, projectNameOf(thread.cwd, thread.projectName));
    }
  }

  const targetsByBase = new Map<string, string[]>();
  for (const [target, base] of baseByTarget) {
    targetsByBase.set(base, [...(targetsByBase.get(base) ?? []), target]);
  }

  const names = new Map<string, string>();
  const usedLabels = new Set<string>();
  for (const [base, unsortedTargets] of [...targetsByBase].sort(([a], [b]) => a.localeCompare(b))) {
    const targets = [...unsortedTargets].sort((a, b) => a.localeCompare(b));
    if (targets.length === 1) {
      names.set(targets[0]!, base);
      usedLabels.add(base);
      continue;
    }

    const components = new Map(
      targets.map((target) => {
        const parts = target.replace(/\\/g, '/').split('/').filter(Boolean);
        return [target, parts.slice(0, -1).length ? parts.slice(0, -1) : [target]] as const;
      }),
    );
    let depth = 1;
    const suffixes = () => targets.map((target) => components.get(target)!.slice(-depth).join('/'));
    while (
      depth < Math.max(...[...components.values()].map((parts) => parts.length)) &&
      new Set(suffixes()).size !== targets.length
    ) {
      depth += 1;
    }

    for (const target of targets) {
      const suffix = suffixes()[targets.indexOf(target)] ?? target;
      let label = `${base} · ${suffix}`;
      if (usedLabels.has(label)) label = `${base} · ${target}`;
      names.set(target, label);
      usedLabels.add(label);
    }
  }

  let hasCollisions = true;
  while (hasCollisions) {
    const targetsByLabel = new Map<string, string[]>();
    for (const [target, label] of names) {
      targetsByLabel.set(label, [...(targetsByLabel.get(label) ?? []), target]);
    }
    const collisions = [...targetsByLabel].filter(([, targets]) => targets.length > 1);
    hasCollisions = collisions.length > 0;
    for (const [, targets] of collisions) {
      for (const target of targets) {
        names.set(target, `${names.get(target) ?? baseByTarget.get(target) ?? ''} · ${target}`);
      }
    }
  }
  return names;
}

/**
 * World: semantic spatial home, projected only from real Veasel runtime
 * state (#693). Projects are the distinct working directories of real Focus
 * threads; people and activity come from the canonical session and operation
 * APIs. Optional legacy Toolkit catalogs are not treated as Veasel runtime
 * health, and no activity is invented when the runtime has none.
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
  const focusBackendDown = useFocusBackendDown();
  const operationsQuery = useFocusOperations();
  const providersQuery = useFocusProviders();
  const memoryQuery = useMemoryList({ enabled: Boolean(memoryPath) });
  const memoryFileQuery = useMemoryFile(memoryPath);
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
    const namesByTarget = projectNamesByTarget(threads);
    for (const thread of threads) {
      if (!thread.cwd || byTarget.has(thread.cwd)) continue;
      byTarget.set(thread.cwd, {
        name: namesByTarget.get(thread.cwd) ?? projectNameOf(thread.cwd, thread.projectName),
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
      (providersQuery.data ?? []).map((provider) => ({
        id: provider.id,
        toolName: provider.label,
        detected: provider.installed,
        configured: provider.auth === 'ready',
        enabled: provider.installed ? 'true' : 'false',
        verified: provider.auth === 'ready',
        version: provider.version ?? '',
        authStatus: provider.auth,
        authDetail: provider.authDetail,
        signInHint: provider.signInHint,
        launchBlocker: provider.launchBlocker ?? null,
        binary: provider.binary,
      })),
    [providersQuery.data],
  );

  const latestOperationBySession = useMemo(() => {
    const latest = new Map<string, string>();
    for (const operation of operationsQuery.data ?? []) {
      if (!latest.has(operation.sessionId)) latest.set(operation.sessionId, operation.status);
    }
    return latest;
  }, [operationsQuery.data]);

  const personSessions = useMemo(() => {
    const namesByTarget = projectNamesByTarget(threads);
    return threads.map((thread) => ({
      id: thread.id,
      personId: thread.id,
      name: thread.title || projectNameOf(thread.cwd, thread.projectName),
      role: thread.provider,
      cwd: thread.cwd,
      projectId: namesByTarget.get(thread.cwd) ?? projectNameOf(thread.cwd, thread.projectName),
      provider: thread.provider,
      model: thread.resolvedModel ?? thread.model ?? undefined,
      status: activityStatusFromOperation(thread.status, latestOperationBySession.get(thread.id)),
      focusThreadId: thread.id,
    }));
  }, [latestOperationBySession, threads]);

  const model = useMemo(
    () =>
      buildWorldModel({
        workspacePath,
        projects,
        projectsKnown: loaded || threads.length > 0,
        memory,
        tools,
        toolsKnown: providersQuery.isSuccess,
        jobs: [],
        activityKnown: operationsQuery.isSuccess,
        personSessions,
        focusProjectId: focusProject,
      }),
    [
      workspacePath,
      projects,
      loaded,
      threads,
      memory,
      tools,
      providersQuery.isSuccess,
      operationsQuery.isSuccess,
      personSessions,
      focusProject,
    ],
  );

  const layout = useMemo(() => layoutWorld(model), [model]);
  const selected = layout.entities.find((entity) => entity.id === selectedId) ?? null;
  const needsWorkspace =
    !model.focusProjectId &&
    layout.entities.some((entity) => entity.id === 'place:workspace' && entity.state === 'missing');

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
  const gathering = client !== null && (!loaded || operationsQuery.isPending || providersQuery.isPending);
  const showingLastKnownState =
    (client === null || focusBackendDown) &&
    (threads.length > 0 ||
      operationsQuery.data !== undefined ||
      providersQuery.data !== undefined ||
      (memoryPath !== '' && memoryFileQuery.data !== undefined));
  const liveDataUnavailable =
    showingLastKnownState ||
    (client !== null &&
      !focusBackendDown &&
      (operationsQuery.isError || providersQuery.isError || (memoryPath !== '' && memoryFileQuery.isError)));

  const openEntity = (entity: LaidOutEntity) => {
    if (!entity.hrefPath) return;
    const crossesProjectDoor = entity.id.startsWith('place:project:') || entity.id === 'object:exit-grounds';
    navigateWorld(href(entity.hrefPath, entity.hrefExtra), crossesProjectDoor);
  };

  const toolEntry = toolId ? tools.find((tool) => tool.id === toolId) : undefined;
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
        <div className={styles.worldHeading}>
          <h1 className={styles.worldTitle} title={title}>
            {title}
          </h1>
          <span className={styles.worldMeta}>
            {model.focusProjectId ? 'project interior' : worldPack.label} · {layout.entities.length} places
          </span>
        </div>
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
            error={providersQuery.error as Error | null}
            isPending={providersQuery.isPending}
            onBack={() => navigate(href('/world', worldDetailBackExtra(focusProject)))}
            backLabel={worldDetailBackLabel(focusProject)}
            onRetry={() => void providersQuery.refetch()}
          />
        ) : (
          <>
            {needsWorkspace ? (
              <aside className={styles.workspacePrompt} aria-labelledby="workspace-prompt-title">
                <span className={styles.workspacePromptMark} aria-hidden="true">
                  ⌂
                </span>
                <div className={styles.workspacePromptCopy}>
                  <h2 id="workspace-prompt-title">Your valley is waiting for a workspace</h2>
                  <p>
                    Set a workspace in the context bar above to bring its real sessions, tools, and activity into this
                    world.
                  </p>
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
            — {layout.entities.length} destinations, resources, sessions, and activity
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
