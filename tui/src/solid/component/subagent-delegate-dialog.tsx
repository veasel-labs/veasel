/** @jsxImportSource @opentui/solid */
import type { SolidModelRef } from "./model-dialog"
import { openDialogPrompt } from "../ui/dialog-prompt"
import { openDialogSelect } from "../ui/dialog-select"
import type { DialogHost } from "../ui/dialog"

export type SubagentTarget = { provider: string; model: string }
export type SubagentRole = { id: string; description: string }

export type SubagentDelegateDialogProps = {
  roles: SubagentRole[]
  models: SolidModelRef[]
  currentModel?: SolidModelRef
  initialTask?: string
  onSubmit: (input: { task: string; agent_id: string; target?: SubagentTarget }) => void
}

const inheritanceChoice = "__inherit_parent_model__"

/** Start a delegated task with independent role and model choices. The task
 * executes asynchronously in an isolated workspace unless the server says
 * otherwise. API routing and permission checks remain server responsibilities. */
export function openSubagentDelegateDialog(dialog: DialogHost, props: SubagentDelegateDialogProps) {
  openDialogSelect(dialog, {
    title: "Choose agent role",
    placeholder: "Filter roles…",
    options: props.roles.map((role) => ({
      title: role.id,
      value: role.id,
      description: role.description,
      searchText: `${role.id} ${role.description}`,
    })),
    footer: "Role controls task instructions and permissions · provider/model are selected separately",
    dismissOnSelect: false,
    onSelect: (role) => chooseTarget(dialog, props, role.value),
  })
}

function chooseTarget(dialog: DialogHost, props: SubagentDelegateDialogProps, agentId: string) {
  openDialogSelect(dialog, {
    title: "Choose model",
    placeholder: "Filter providers and models…",
    options: [
      {
        title: "Use this conversation’s model",
        value: inheritanceChoice,
        description: props.currentModel
          ? `${props.currentModel.providerID}/${props.currentModel.modelID}`
          : "Inherit the resolved model from this conversation",
        searchText: "inherit parent current model",
      },
      ...props.models.map((model) => ({
        title: model.name,
        value: `${model.providerID}\0${model.modelID}`,
        category: model.providerName ?? model.providerID,
        description: model.modelID,
        footer: [model.costBadge, model.dataUseNotice].filter(Boolean).join(" · ") || undefined,
        notice: model.dataUseNotice,
        searchText: `${model.providerID} ${model.modelID} ${model.name}`,
      })),
    ],
    footer: "Only listed configured models can be selected · Enter continues · Esc cancels",
    dismissOnSelect: false,
    onSelect: (selected) => {
      const target = selected.value === inheritanceChoice
        ? undefined
        : (() => {
          const [provider, model] = selected.value.split("\0")
          return provider && model ? { provider, model } : undefined
        })()
      if (selected.value !== inheritanceChoice && !target) return
      promptTask(dialog, props, agentId, target)
    },
  })
}

function promptTask(dialog: DialogHost, props: SubagentDelegateDialogProps, agentId: string, target?: SubagentTarget) {
  openDialogPrompt(dialog, {
    title: "Delegate task",
    description: `Role: ${agentId}\nModel: ${target ? `${target.provider}/${target.model}` : "inherit parent model"}\nThe child receives a focused task brief and works in its own workspace.`,
    placeholder: "Describe one bounded task…",
    value: props.initialTask,
    confirmLabel: "delegate",
    onConfirm: (task) => {
      if (!task.trim()) return false
      props.onSubmit({ task: task.trim(), agent_id: agentId, target })
    },
  })
}
