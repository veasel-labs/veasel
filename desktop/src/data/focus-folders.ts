import { useCallback, useMemo, useState } from 'react';
import type { StartProject } from '../features/focus/NewSession';
import type { FocusThread } from '../types/focus';

/**
 * Folders a Focus session can start in. A session carries its own directory on the Veasel backend, so there is no
 * project registry (and no legacy workspace service): the list is the folders of existing sessions plus the ones the
 * user picked with the native dialog, remembered in this browser profile.
 */
const STORAGE_KEY = 'veasel.focus.folders';

function readPicked(): string[] {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '[]');
    return Array.isArray(parsed) ? parsed.filter((entry): entry is string => typeof entry === 'string') : [];
  } catch {
    return [];
  }
}

function basename(folder: string): string {
  return folder.split(/[\\/]/).filter(Boolean).at(-1) ?? folder;
}

/** Unique display names: a repeated folder name gets its parent folder appended. */
export function foldersToEntries(folders: readonly string[]): StartProject[] {
  const unique = [...new Set(folders)];
  const counts = new Map<string, number>();
  for (const folder of unique) counts.set(basename(folder), (counts.get(basename(folder)) ?? 0) + 1);
  return unique.map((folder) => {
    const name = basename(folder);
    const parts = folder.split(/[\\/]/).filter(Boolean);
    const label = (counts.get(name) ?? 0) > 1 && parts.length > 1 ? `${name} (${parts.at(-2)})` : name;
    return { name: label, target: folder, status: 'ok' };
  });
}

export function useFocusFolders(threads: readonly FocusThread[]): {
  folders: StartProject[];
  choose: () => Promise<StartProject | null>;
} {
  const [picked, setPicked] = useState<string[]>(readPicked);
  const folders = useMemo(
    () => foldersToEntries([...picked, ...threads.map((thread) => thread.cwd).filter((cwd) => cwd.length > 0)]),
    [picked, threads],
  );
  const choose = useCallback(async (): Promise<StartProject | null> => {
    const bridge = typeof window !== 'undefined' ? window.atk : undefined;
    if (!bridge) throw new Error('Choosing a folder needs the Veasel Desktop app.');
    const selected = await bridge.projectChooseDirectory(threads[0]?.cwd ?? '');
    if (!selected) return null;
    const next = [selected, ...picked.filter((entry) => entry !== selected)];
    setPicked(next);
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch {
      // Remembering is a convenience; the folder still works for this session.
    }
    return (
      foldersToEntries([selected, ...picked, ...threads.map((thread) => thread.cwd)]).find(
        (entry) => entry.target === selected,
      ) ?? { name: basename(selected), target: selected, status: 'ok' }
    );
  }, [picked, threads]);
  return { folders, choose };
}
