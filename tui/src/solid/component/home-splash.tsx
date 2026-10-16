/** @jsxImportSource @opentui/solid */
import { For } from "solid-js"
import { themes, type Theme } from "../../themes"
import {
  VEASEL_PORTRAIT_ROWS,
  portraitRowCells,
} from "../../veasel-portrait"
import { solidMint } from "../theme"
import { paletteShortcut } from "../commands"
import { activityToggleShortcut } from "../activity-group"
import { reviewShortcut } from "../reviews"

export type HomeSplashProps = {
  theme?: Theme
  directory?: string
  /** Compact layout for narrow / short terminals. */
  compact?: boolean
}

/** Drop ear-tips + chin on short terminals so chrome still fits at 80×30. */
function portraitRows(compact: boolean): string[] {
  const rows = [...VEASEL_PORTRAIT_ROWS]
  if (compact) return rows.slice(2, -2)
  return rows
}

/**
 * Empty-home composition: pixel Veasel + brand + one clear CTA path.
 * Portrait adaptation remains CC BY-NC 4.0 (THIRD_PARTY_NOTICES.md).
 */
export function HomeSplash(props: HomeSplashProps) {
  const theme = () => props.theme ?? themes.mint
  const directory = () => props.directory ?? "~/your-project"
  const compact = () => props.compact ?? true
  const connectLine = `/connect · ${paletteShortcut.label} commands · /theme`
  const reviewLine = `${activityToggleShortcut.label} activity · ${reviewShortcut.label} reviews`

  return (
    <box
      width="100%"
      flexGrow={1}
      flexDirection="column"
      alignItems="center"
      justifyContent="flex-start"
      backgroundColor={solidMint.panelBg}
      gap={1}
      paddingTop={1}
      paddingBottom={1}
    >
      <box width="100%" flexDirection="column" alignItems="center" flexShrink={0}>
        <text fg={solidMint.brand}>VEASEL CODE</text>
        <text fg={solidMint.muted}>your local V-powered workspace</text>
        <text fg={solidMint.headerMeta}>{directory()}</text>
      </box>

      <box flexDirection="column" alignItems="center" flexShrink={0}>
        <For each={portraitRows(compact())}>
          {(row) => (
            <text>
              <For each={portraitRowCells(theme(), row)}>
                {(cell) => <span style={{ fg: cell.color }}>{cell.glyph}</span>}
              </For>
            </text>
          )}
        </For>
      </box>

      <box
        flexDirection="column"
        alignItems="center"
        flexShrink={0}
        paddingLeft={2}
        paddingRight={2}
        border
        borderColor={solidMint.headerBorder}
        backgroundColor={solidMint.shellBg}
      >
        <text fg={solidMint.body}>Ask anything to begin — or set up once</text>
        <text fg={solidMint.muted}>{connectLine}</text>
        <text fg={solidMint.muted}>{reviewLine}</text>
      </box>

      <text fg={solidMint.headerMeta}>OPENTUI · REVIEW-GATED · LOCAL · PIXEL VEASEL</text>
    </box>
  )
}
