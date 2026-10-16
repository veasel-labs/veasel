/** @jsxImportSource @opentui/solid */
import { solidMint } from "../theme"
import type { createPaneResize } from "./pane-resize"

export type PaneResizeHandleProps = {
  resize: ReturnType<typeof createPaneResize>
}

/** One-column drag grip between home sidebar and splash. */
export function PaneResizeHandle(props: PaneResizeHandleProps) {
  const active = () => props.resize.hovered() || props.resize.resizing()
  return (
    <box
      width={1}
      height="100%"
      flexShrink={0}
      backgroundColor={active() ? solidMint.brand : solidMint.panelBorder}
      onMouseOver={props.resize.onMouseOver}
      onMouseOut={props.resize.onMouseOut}
      onMouseDown={props.resize.onMouseDown}
      onMouseDrag={props.resize.onMouseDrag}
      onMouseDragEnd={props.resize.onMouseDragEnd}
      onMouseUp={props.resize.onMouseUp}
    />
  )
}
