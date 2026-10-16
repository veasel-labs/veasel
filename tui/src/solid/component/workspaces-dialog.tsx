/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"
import { openDialogPrompt } from "../ui/dialog-prompt"

export type SolidWorkspace = {
  id: string
  name: string
  path: string
  kind: "main" | "worktree"
}

export type WorkspacesDialogProps = {
  workspaces: SolidWorkspace[]
  current?: string
  onSelect: (workspace: SolidWorkspace) => void
  onCreateWorktree?: (name: string) => void
}

/** Demo workspaces / worktrees for Solid shell / tests. */
export function demoWorkspaces(): SolidWorkspace[] {
  return [
    { id: "main", name: "veasel", path: "~/veasel", kind: "main" },
    {
      id: "wt-solid",
      name: "tui-solid",
      path: "~/.ai-workspace/worktrees/veasel-tui-solid",
      kind: "worktree",
    },
    {
      id: "wt-dialogs",
      name: "tui-dialogs",
      path: "~/.ai-workspace/worktrees/veasel-tui-dialogs",
      kind: "worktree",
    },
  ]
}

export function openWorkspacesDialog(
  dialog: ReturnType<typeof useDialog>,
  props: WorkspacesDialogProps,
) {
  openDialogSelect(dialog, {
    title: "Workspaces",
    placeholder: "Filter workspaces…",
    size: "large",
    current: props.current,
    dismissOnSelect: false,
    options: [
      ...props.workspaces.map((workspace) => ({
        title: workspace.name,
        value: workspace.id,
        category: workspace.kind === "main" ? "Main" : "Worktrees",
        description: workspace.path,
        searchText: `${workspace.name} ${workspace.path}`,
      })),
      ...(props.onCreateWorktree
        ? [
            {
              title: "+ New worktree…",
              value: "__new__",
              category: "Actions",
              description: "Name a git worktree for this session",
            },
          ]
        : []),
    ],
    onSelect: (option) => {
      if (option.value === "__new__" && props.onCreateWorktree) {
        openDialogPrompt(dialog, {
          title: "Worktree name",
          placeholder: "feature-branch",
          description: "Creates a Solid stub worktree entry (HTTP wire next)",
          onConfirm: (name) => {
            const trimmed = name.trim()
            if (!trimmed) return
            props.onCreateWorktree?.(trimmed)
          },
        })
        return
      }
      const workspace = props.workspaces.find((item) => item.id === option.value)
      dialog.clear()
      if (workspace) props.onSelect(workspace)
    },
    footer: "Enter selects · + New worktree names via prompt",
  })
}
