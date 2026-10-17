/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { DialogSelect } from "../ui/dialog-select"
import type { SolidSessionEntry } from "./session-list-dialog"

export type SolidOpenProject = {
  id: string
  name: string
  path: string
}

export type SolidOpenWorktree = {
  id: string
  name: string
  path: string
  projectId: string
}

export type OpenDialogProps = {
  currentDirectory?: string
  onCreateSession?: () => void
  recentSessions: SolidSessionEntry[]
  projects: SolidOpenProject[]
  worktreesByProject: Record<string, SolidOpenWorktree[]>
  onOpenSession: (session: SolidSessionEntry) => void
  onOpenWorktree: (worktree: SolidOpenWorktree) => void
}

/** Demo projects for Open… dialog / tests. */
export function demoOpenProjects(): SolidOpenProject[] {
  return [
    { id: "veasel", name: "veasel", path: "~/veasel" },
    { id: "workspace", name: "ai-workspace", path: "~/.ai-workspace" },
  ]
}

export function demoOpenWorktrees(): SolidOpenWorktree[] {
  return [
    {
      id: "wt-solid",
      name: "tui-solid",
      path: "~/.ai-workspace/worktrees/veasel-tui-solid",
      projectId: "veasel",
    },
    {
      id: "wt-parity",
      name: "tui-parity",
      path: "~/.ai-workspace/worktrees/veasel-tui-parity",
      projectId: "veasel",
    },
    {
      id: "wt-budget",
      name: "model-output-budget",
      path: "~/.ai-workspace/worktrees/veasel-model-output-budget",
      projectId: "workspace",
    },
  ]
}

export function groupWorktreesByProject(
  worktrees: SolidOpenWorktree[],
): Record<string, SolidOpenWorktree[]> {
  const grouped: Record<string, SolidOpenWorktree[]> = {}
  for (const worktree of worktrees) {
    grouped[worktree.projectId] ??= []
    grouped[worktree.projectId]!.push(worktree)
  }
  return grouped
}

export function buildOpenRootOptions(
  props: Pick<OpenDialogProps, "recentSessions" | "projects" | "currentDirectory" | "onCreateSession">,
): Array<{
  title: string
  value: string
  category: string
  description?: string
  searchText: string
}> {
  const sessionOptions = props.recentSessions.map((session) => ({
    title: session.title,
    value: `session:${session.id}`,
    category: "Recent sessions",
    description: session.directory ?? "",
    searchText: `${session.title} ${session.directory ?? ""} ${session.id}`,
  }))
  const projectOptions = props.projects.map((project) => ({
    title: project.name,
    value: `project:${project.id}`,
    category: "Projects",
    description: project.path,
    searchText: `${project.name} ${project.path}`,
  }))
  const createOptions = props.onCreateSession ? [{
    title: "New session in this project",
    value: "create-session",
    category: "Start",
    description: props.currentDirectory ?? "",
    searchText: `new session create ${props.currentDirectory ?? ""}`,
  }] : []
  return [...sessionOptions, ...projectOptions, ...createOptions]
}

function OpenWorktreesPane(props: {
  project: SolidOpenProject
  worktrees: SolidOpenWorktree[]
  onOpenWorktree: (worktree: SolidOpenWorktree) => void
  onBack: () => void
}) {
  return (
    <DialogSelect
      title={`Open · ${props.project.name}`}
      placeholder="Filter worktrees…"
      footer="Enter opens · Esc back"
      options={props.worktrees.map((worktree) => ({
        title: worktree.name,
        value: worktree.id,
        description: worktree.path,
        searchText: `${worktree.name} ${worktree.path}`,
      }))}
      onSelect={(option) => {
        const worktree = props.worktrees.find((item) => item.id === option.value)
        if (worktree) props.onOpenWorktree(worktree)
      }}
      onCancel={() => props.onBack()}
    />
  )
}

export function openOpenDialog(
  dialog: ReturnType<typeof useDialog>,
  props: OpenDialogProps,
) {
  dialog.replace(
    () => (
      <DialogSelect
        title="Open"
        placeholder="Filter sessions or projects…"
        dismissOnSelect={false}
        options={buildOpenRootOptions(props)}
        footer="Enter opens · type to filter · Esc closes"
        onSelect={(option) => {
          if (option.value === "create-session") {
            dialog.clear()
            props.onCreateSession?.()
            return
          }
          if (option.value.startsWith("session:")) {
            const id = option.value.slice("session:".length)
            const session = props.recentSessions.find((item) => item.id === id)
            dialog.clear()
            if (session) props.onOpenSession(session)
            return
          }
          if (option.value.startsWith("project:")) {
            const projectId = option.value.slice("project:".length)
            const project = props.projects.find((item) => item.id === projectId)
            const worktrees = props.worktreesByProject[projectId] ?? []
            if (!project) return
            dialog.push(() => (
              <OpenWorktreesPane
                project={project}
                worktrees={worktrees}
                onOpenWorktree={(worktree) => {
                  dialog.clear()
                  props.onOpenWorktree(worktree)
                }}
                onBack={() => dialog.pop()}
              />
            ))
          }
        }}
      />
    ),
    { size: "large" },
  )
}
