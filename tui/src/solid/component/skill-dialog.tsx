/** @jsxImportSource @opentui/solid */
import type { SkillCatalogEntry } from "../../skill-autocomplete"
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"

export type SkillDialogProps = {
  skills: SkillCatalogEntry[]
  onSelect: (skill: SkillCatalogEntry) => void
}

/** Demo skill catalog for Solid shell / tests. */
export function demoSkills(): SkillCatalogEntry[] {
  return [
    {
      key: "code-review",
      description: "Review the current diff with severity-ranked findings",
    },
    {
      key: "tdd-guide",
      description: "Drive red-green-refactor for the focused change",
    },
    {
      key: "docs-generator",
      description: "Generate README / CHANGELOG / API docs from code",
    },
    {
      key: "security-review",
      description: "App-surface hardening pass (OWASP-oriented)",
    },
  ]
}

export function openSkillDialog(
  dialog: ReturnType<typeof useDialog>,
  props: SkillDialogProps,
) {
  const maxName = Math.max(0, ...props.skills.map((skill) => skill.key.length))
  openDialogSelect(dialog, {
    title: "Skills",
    placeholder: "Filter skills…",
    size: "large",
    options: props.skills.map((skill) => ({
      title: skill.key.padEnd(maxName),
      value: skill.key,
      description: skill.description.replace(/\s+/g, " ").trim(),
      searchText: `${skill.key} ${skill.description}`,
    })),
    onSelect: (option) => {
      const skill = props.skills.find((item) => item.key === option.value)
      if (skill) props.onSelect(skill)
    },
    footer: "Enter inserts $skill into the composer path next",
  })
}
