/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"

export type SolidAgent = {
  id: string
  description: string
}

export type AgentDialogProps = {
  agents: SolidAgent[]
  current?: string
  onSelect: (agent: SolidAgent) => void
  onCancel?: () => void
}

/** Demo agents for Solid shell / tests (Veasel-owned labels). */
export function demoAgents(): SolidAgent[] {
  return [
    { id: "build", description: "Default coding agent for implementation work" },
    { id: "plan", description: "Read-only planning and design exploration" },
    { id: "review", description: "Focused review of diffs and risk" },
  ]
}

export function openAgentDialog(
  dialog: ReturnType<typeof useDialog>,
  props: AgentDialogProps,
) {
  openDialogSelect(dialog, {
    title: "Select agent",
    placeholder: "Filter agents…",
    current: props.current,
    options: props.agents.map((agent) => ({
      title: agent.id,
      value: agent.id,
      description: agent.description,
      searchText: `${agent.id} ${agent.description}`,
    })),
    onSelect: (option) => {
      const agent = props.agents.find((item) => item.id === option.value)
      if (agent) props.onSelect(agent)
    },
    onCancel: props.onCancel,
  })
}
