import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { useFocusBridge } from '../../data/focus';
import type { FocusGitChange } from '../../types/focus';
import styles from './focus.module.css';

const STATE_LABEL: Record<string, string> = {
  M: 'modified',
  A: 'added',
  D: 'deleted',
  R: 'renamed',
  C: 'copied',
  U: 'conflict',
  '?': 'untracked',
};

function describe(change: FocusGitChange): string {
  if (change.untracked) return 'untracked';
  const code = change.worktree !== ' ' ? change.worktree : change.index;
  return STATE_LABEL[code] ?? 'changed';
}

function DiffLines({ path, diff }: { path: string; diff: string }) {
  return (
    <pre className={styles.diffPreview} aria-label={`Changes to ${path}`}>
      {diff.split('\n').map((line, index) => (
        <span
          key={index}
          data-change={
            line.startsWith('+') && !line.startsWith('+++')
              ? 'added'
              : line.startsWith('-') && !line.startsWith('---')
                ? 'removed'
                : undefined
          }
        >
          {`${line}\n`}
        </span>
      ))}
    </pre>
  );
}

/**
 * What the agent changed, read straight from the repository the session runs in (Veasel backend
 * `workspace/git/changes` and `workspace/git/diff`). Read-only: staging and committing stay in the terminal.
 */
export function SessionChanges({ threadId }: { threadId: string }) {
  const bridge = useFocusBridge();
  const [selected, setSelected] = useState<{ path: string; staged: boolean } | null>(null);
  const changes = useQuery({
    queryKey: ['focus', 'git', threadId, 'changes'],
    queryFn: async () => {
      const result = await bridge?.gitChanges(threadId);
      if (!result) throw new Error('Sessions run inside the Veasel Desktop app.');
      if (!result.ok) throw new Error(result.error);
      return result.value;
    },
    enabled: bridge !== undefined,
    staleTime: 0,
    retry: false,
  });
  const first = changes.data?.changes[0];
  const active = selected ?? (first ? { path: first.path, staged: first.worktree === ' ' } : null);
  const diff = useQuery({
    queryKey: ['focus', 'git', threadId, 'diff', active?.path ?? '', active?.staged ?? false],
    queryFn: async () => {
      const result = await bridge?.gitDiff(threadId, active?.path ?? '', active?.staged ?? false);
      if (!result) throw new Error('Sessions run inside the Veasel Desktop app.');
      if (!result.ok) throw new Error(result.error);
      return result.value;
    },
    enabled:
      bridge !== undefined &&
      active !== null &&
      !(changes.data?.changes.find((c) => c.path === active.path)?.untracked ?? false),
    staleTime: 0,
    retry: false,
  });

  if (changes.isPending)
    return (
      <p className={styles.quiet} role="status">
        Reading working tree…
      </p>
    );
  if (changes.isError) {
    return (
      <p className={styles.quiet} role="alert">
        {changes.error.message}
      </p>
    );
  }
  if (changes.data.changes.length === 0) {
    return (
      <p className={styles.quiet} role="status">
        No changes{changes.data.branch ? ` on ${changes.data.branch}` : ''}.
      </p>
    );
  }
  const activeEntry = active ? changes.data.changes.find((entry) => entry.path === active.path) : undefined;
  return (
    <section aria-label="Changes">
      <h2 className={styles.threadGroup}>Changes{changes.data.branch ? ` on ${changes.data.branch}` : ''}</h2>
      <ul>
        {changes.data.changes.map((change) => (
          <li key={`${change.index}${change.worktree}${change.path}`}>
            <button
              type="button"
              className={styles.thread}
              aria-pressed={active?.path === change.path}
              onClick={() => setSelected({ path: change.path, staged: change.worktree === ' ' })}
            >
              <span className={styles.threadTitle}>{change.path}</span>
              <span className={styles.threadMeta}>{describe(change)}</span>
            </button>
          </li>
        ))}
      </ul>
      {changes.data.truncated ? <p className={styles.toolNote}>Only the first changes are listed.</p> : null}
      {active && activeEntry?.untracked ? (
        <p className={styles.quiet}>{active.path} is a new file that git does not track yet.</p>
      ) : null}
      {diff.isError ? (
        <p className={styles.quiet} role="alert">
          {diff.error.message}
        </p>
      ) : null}
      {diff.data && active ? <DiffLines path={active.path} diff={diff.data.diff || '(no textual changes)'} /> : null}
    </section>
  );
}
