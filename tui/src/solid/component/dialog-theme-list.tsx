/** @jsxImportSource @opentui/solid */
import { themes, type BuiltinThemeId } from "../../themes"
import { DialogSelect, openDialogSelect } from "../ui/dialog-select"
import { useDialog } from "../ui/dialog"

export type DialogThemeListProps = {
  current: BuiltinThemeId
  onSelect?: (id: BuiltinThemeId) => void
  /** Live preview while moving the highlight (OpenCode-style). */
  onPreview?: (id: BuiltinThemeId) => void
}

const builtinIds = Object.keys(themes) as BuiltinThemeId[]

export function DialogThemeList(props: DialogThemeListProps) {
  return (
    <DialogSelect
      title="Themes"
      current={props.current}
      placeholder="Search themes…"
      options={builtinIds.map((id) => ({
        title: id,
        value: id,
        category: "Builtin",
        searchText: id === "mint" ? "default veasel" : id,
      }))}
      onSelect={(option) => props.onSelect?.(option.value)}
    />
  )
}

export function openDialogThemeList(
  dialog: ReturnType<typeof useDialog>,
  props: DialogThemeListProps,
) {
  const initial = props.current
  let confirmed = false
  openDialogSelect(dialog, {
    title: "Themes",
    current: props.current,
    placeholder: "Search themes…",
    options: builtinIds.map((id) => ({
      title: id,
      value: id,
      category: "Builtin",
      searchText: id === "mint" ? "default veasel" : id,
    })),
    onMove: (option) => props.onPreview?.(option.value),
    onSelect: (option) => {
      confirmed = true
      props.onSelect?.(option.value)
    },
    onCancel: () => {
      if (!confirmed) props.onPreview?.(initial)
    },
    footer: "Enter applies · Esc restores previous",
  })
}
