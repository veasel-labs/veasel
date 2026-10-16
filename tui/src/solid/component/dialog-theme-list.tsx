/** @jsxImportSource @opentui/solid */
import { themes, type BuiltinThemeId } from "../../themes"
import { DialogSelect, openDialogSelect } from "../ui/dialog-select"
import { useDialog } from "../ui/dialog"

export type DialogThemeListProps = {
  current: BuiltinThemeId
  onSelect?: (id: BuiltinThemeId) => void
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
    onSelect: (option) => props.onSelect?.(option.value),
  })
}
