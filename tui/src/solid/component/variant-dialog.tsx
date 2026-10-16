/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"

export type VariantDialogProps = {
  variants: string[]
  current?: string
  onSelect: (variant: string | undefined) => void
}

/** Demo model variants (OpenCode-style; Veasel maps to output-budget later). */
export function demoVariants(): string[] {
  return ["default", "fast", "max"]
}

export function openVariantDialog(
  dialog: ReturnType<typeof useDialog>,
  props: VariantDialogProps,
) {
  const variants = props.variants.length > 0 ? props.variants : demoVariants()
  openDialogSelect(dialog, {
    title: "Select variant",
    placeholder: "Filter variants…",
    current: props.current ?? "default",
    flatOnFilter: true,
    options: variants.map((variant) => ({
      title: variant === "default" ? "Default" : variant,
      value: variant,
      searchText: variant,
    })),
    onSelect: (option) => {
      props.onSelect(option.value === "default" ? undefined : option.value)
    },
  })
}
