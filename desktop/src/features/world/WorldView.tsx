import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router';
import { flushSync } from 'react-dom';
import { useFocusThreads } from '../../data/focus';
import { useSessionContext } from '../../shell/useSessionContext';
import { EmptyState } from '../../ui';
import { worldDetailBackExtra } from './inspectors';
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
 * state (#693). Projects are the distinct working directories of real
 * Focus threads; characters are those threads with their real provider,
 * model and status (a character claims activity only while its session
 * is actually running). There is no second session store and no fake
 * activity: with no threads, the world is empty.
 */
export default function WorldView() {
  const { context, href } = useSessionContext();
  const { threads, loaded } = useFocusThreads();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const focusProject = params.get('project');
  const focusPlace = params.get('place');
  const memoryPath = params.get('memory')?.trim() || '';
  const toolId = params.get('tool')?.trim() || '';

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

  const memory: MemorySummary = useMemo(() => ({ available: false, entries: [], projectKeys: [] }), []);

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
        tools: [],
        toolsKnown: false,
        jobs: [],
        personSessions,
        focusProjectId: focusProject,
      }),
    [workspacePath, projects, loaded, memory, personSessions, focusProject],
  );

  const layout = useMemo(() => layoutWorld(model), [model]);
  const selected = layout.entities.find((entity) => entity.id === selectedId) ?? null;

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

  const gathering = !loaded;

  const openEntity = (entity: LaidOutEntity) => {
    if (!entity.hrefPath) return;
    const crossesProjectDoor = entity.id.startsWith('place:project:') || entity.id === 'object:exit-grounds';
    navigateWorld(href(entity.hrefPath, entity.hrefExtra), crossesProjectDoor);
  };

  // Memory/tool detail inspectors targeted the retired legacy backend;
  // until they are ported, no detail overlay opens from the world.
  const detailOpen = false;
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
        {gathering && layout.entities.length > 0 ? (
          <p className={styles.worldLoadStatus} role="status" aria-live="polite">
            Checking live workspace details…
          </p>
        ) : null}
      </div>

      <details className={styles.entityListWrap}>
        <summary>
          <span className={styles.worldTitle}>World index</span>{' '}
          <span className={styles.worldMeta}>— {layout.entities.length} places, resources, and active workers</span>
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
