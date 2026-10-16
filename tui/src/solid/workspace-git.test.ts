import { describe, expect, test } from "bun:test"
import type { ApiGitWorktree, ApiSession } from "../api-client"
import {
  findSessionForDirectory,
  mapApiWorktreesToOpenCatalog,
  mapApiWorktreesToSolidWorkspaces,
  sanitizeWorktreeName,
  suggestedLinkedWorktreePath,
  worktreeDisplayName,
} from "./workspace-git"

const sampleTrees: ApiGitWorktree[] = [
  {
    path: "/home/u/veasel",
    branch: "main",
    locked: false,
    missing: false,
    is_main: true,
  },
  {
    path: "/home/u/feature-x",
    branch: "feature-x",
    locked: false,
    missing: false,
    is_main: false,
  },
  {
    path: "/home/u/gone",
    locked: false,
    missing: true,
    is_main: false,
  },
]

describe("workspace-git mappers", () => {
  test("sanitizeWorktreeName strips unsafe chars", () => {
    expect(sanitizeWorktreeName("  Feature Branch!  ")).toBe("Feature-Branch")
    expect(sanitizeWorktreeName("///")).toBe("worktree")
  })

  test("suggestedLinkedWorktreePath places sibling under parent", () => {
    expect(suggestedLinkedWorktreePath("/home/u/veasel", "feature-x")).toBe(
      "/home/u/feature-x",
    )
  })

  test("worktreeDisplayName prefers branch then basename", () => {
    expect(worktreeDisplayName(sampleTrees[0]!)).toBe("main")
    expect(
      worktreeDisplayName({
        path: "/tmp/orphan",
        locked: false,
        missing: false,
        is_main: false,
      }),
    ).toBe("orphan")
  })

  test("mapApiWorktreesToSolidWorkspaces tags main vs linked", () => {
    const mapped = mapApiWorktreesToSolidWorkspaces(sampleTrees)
    expect(mapped[0]).toEqual({
      id: "/home/u/veasel",
      name: "main",
      path: "/home/u/veasel",
      kind: "main",
    })
    expect(mapped[1]?.kind).toBe("worktree")
  })

  test("mapApiWorktreesToOpenCatalog skips missing checkouts", () => {
    const { projects, worktrees } = mapApiWorktreesToOpenCatalog(sampleTrees)
    expect(projects).toHaveLength(1)
    expect(projects[0]?.path).toBe("/home/u/veasel")
    expect(worktrees.map((item) => item.path)).toEqual([
      "/home/u/veasel",
      "/home/u/feature-x",
    ])
  })

  test("findSessionForDirectory matches exact path", () => {
    const sessions: ApiSession[] = [
      {
        id: "a",
        title: "One",
        directory: "/home/u/veasel",
        created_at: "2026-01-01T00:00:00Z",
      },
    ]
    expect(findSessionForDirectory(sessions, "/home/u/veasel")?.id).toBe("a")
    expect(findSessionForDirectory(sessions, "/home/u/other")).toBeUndefined()
  })
})
