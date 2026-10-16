import { basename, dirname, join } from "node:path"
import type { ApiGitWorktree, ApiSession } from "../api-client"
import type { SolidOpenProject, SolidOpenWorktree } from "./component/open-dialog"
import type { SolidWorkspace } from "./component/workspaces-dialog"

/** Sanitize a worktree / branch name for filesystem + git `-b`. */
export function sanitizeWorktreeName(name: string): string {
  const trimmed = name.trim()
  const safe = trimmed
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "")
  return safe.length > 0 ? safe : "worktree"
}

/**
 * Suggest an absolute sibling path for `git worktree add`.
 * Example: main `/home/u/veasel` + name `feature` → `/home/u/feature`.
 */
export function suggestedLinkedWorktreePath(mainCheckoutPath: string, name: string): string {
  const safe = sanitizeWorktreeName(name)
  const leaf = safe.includes("/") ? basename(safe) : safe
  return join(dirname(mainCheckoutPath), leaf)
}

export function worktreeDisplayName(tree: ApiGitWorktree): string {
  if (tree.branch && tree.branch.length > 0) return tree.branch
  if (tree.is_main) return basename(tree.path) || "main"
  return basename(tree.path) || "worktree"
}

/** Map API catalog rows into Workspaces dialog entries. */
export function mapApiWorktreesToSolidWorkspaces(trees: ApiGitWorktree[]): SolidWorkspace[] {
  return trees.map((tree) => ({
    id: tree.path,
    name: worktreeDisplayName(tree),
    path: tree.path,
    kind: tree.is_main ? "main" : "worktree",
  }))
}

/** Single-project Open… grouping for the active session workspace. */
export function mapApiWorktreesToOpenCatalog(
  trees: ApiGitWorktree[],
  projectId = "workspace",
): {
  projects: SolidOpenProject[]
  worktrees: SolidOpenWorktree[]
} {
  const main = trees.find((tree) => tree.is_main) ?? trees[0]
  const projectPath = main?.path ?? ""
  const projects: SolidOpenProject[] = [
    {
      id: projectId,
      name: main ? worktreeDisplayName(main) : projectId,
      path: projectPath,
    },
  ]
  const worktrees: SolidOpenWorktree[] = trees
    .filter((tree) => !tree.missing)
    .map((tree) => ({
      id: tree.path,
      name: worktreeDisplayName(tree),
      path: tree.path,
      projectId,
    }))
  return { projects, worktrees }
}

/** Prefer an existing session whose directory matches the worktree path. */
export function findSessionForDirectory(
  sessions: ApiSession[],
  directory: string,
): ApiSession | undefined {
  return sessions.find((session) => session.directory === directory)
}
