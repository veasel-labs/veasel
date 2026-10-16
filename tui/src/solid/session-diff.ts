export type WorkspaceEditStatus =
  | "pending"
  | "applying"
  | "applied"
  | "rejected"
  | "conflict"
  | "interrupted"

export type WorkspaceEditSummary = {
  id: string
  path: string
  status: WorkspaceEditStatus
  created_at?: string
  updated_at?: string
}

export type WorkspaceEditProposal = WorkspaceEditSummary & {
  session_id?: string
  diff: string
}

export type SessionDiffFileRow = {
  id: string
  path: string
  status: WorkspaceEditStatus
  /** Basename for compact lists. */
  name: string
  searchText: string
}

export function basenamePath(path: string): string {
  const parts = path.split(/[/\\]/).filter(Boolean)
  return parts[parts.length - 1] ?? path
}

/** Flat file list for the session diff picker (sorted by path). */
export function sessionDiffFileRows(edits: readonly WorkspaceEditSummary[]): SessionDiffFileRow[] {
  return [...edits]
    .map((edit) => ({
      id: edit.id,
      path: edit.path,
      status: edit.status,
      name: basenamePath(edit.path),
      searchText: `${edit.status} ${edit.path} ${edit.id}`,
    }))
    .sort((left, right) => left.path.localeCompare(right.path))
}

export function filterSessionDiffRows(
  rows: readonly SessionDiffFileRow[],
  query: string,
): SessionDiffFileRow[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return [...rows]
  return rows.filter((row) => row.searchText.toLowerCase().includes(needle))
}

export function sessionDiffStatusLabel(status: WorkspaceEditStatus): string {
  return status.toUpperCase()
}

/** Count +/- lines from a unified diff for the dialog chrome. */
export function summarizeUnifiedDiff(diff: string): { added: number; removed: number } {
  let added = 0
  let removed = 0
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@")) continue
    if (line.startsWith("+")) added += 1
    else if (line.startsWith("-")) removed += 1
  }
  return { added, removed }
}
