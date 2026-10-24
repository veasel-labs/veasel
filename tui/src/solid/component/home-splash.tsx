/** @jsxImportSource @opentui/solid */
import { For, Show } from "solid-js"
import stringWidth from "string-width"
import { type Theme } from "../../themes"
import { useTerminalDimensions } from "@opentui/solid"
import {
  VEASEL_PORTRAIT_ROWS,
  portraitRowCells,
} from "../../veasel-portrait"
import { useSolidTheme } from "../theme"
import { paletteShortcut } from "../commands"
import { activityToggleShortcut } from "../activity-group"
import { reviewShortcut } from "../reviews"

export type HomeSplashProps = {
  theme?: Theme
  directory?: string
  /** Available terminal cells for the project path. */
  directoryMaxWidth?: number
  /** Compact layout for narrow / short terminals. */
  compact?: boolean
}

/** Keep the path ending visible without letting it wrap through the splash. */
export function compactDirectory(path: string, maxWidth: number): string {
  const limit = Math.max(1, Math.floor(maxWidth))
  if (stringWidth(path) <= limit) return path
  if (limit === 1) return "…"

  const separator = path.includes("\\") && !path.includes("/") ? "\\" : "/"
  const parts = path.split(/[\\/]+/).filter(Boolean)
  const fileName = parts.at(-1) ?? path
  let suffix = fileName

  for (let index = parts.length - 2; index >= 0; index -= 1) {
    const candidate = `${parts[index]}${separator}${suffix}`
    if (stringWidth(`…${separator}${candidate}`) > limit) break
    suffix = candidate
  }

  const withParent = `…${separator}${suffix}`
  if (stringWidth(withParent) <= limit) return withParent

  let tail = ""
  for (const character of [...fileName].reverse()) {
    if (stringWidth(`…${character}${tail}`) > limit) break
    tail = `${character}${tail}`
  }
  return `…${tail}`
}

export function homeSplashCompact(width: number, height: number): boolean {
  return width < 76 || height < 36
}

/**
 * Empty-home composition: original pixel companion + brand + one clear CTA path.
 */
export function HomeSplash(props: HomeSplashProps) {
  const colors = useSolidTheme()
  const dimensions = useTerminalDimensions()
  const theme = () => props.theme ?? colors
  const directory = () => props.directory ?? "~/your-project"
  const visibleDirectory = () =>
    compactDirectory(directory(), props.directoryMaxWidth ?? 64)
  const compact = () =>
    props.compact ?? homeSplashCompact(dimensions().width, dimensions().height)
  const connectLine = `/connect · ${paletteShortcut.label} commands · /theme`
  const reviewLine = `${activityToggleShortcut.label} activity · ${reviewShortcut.label} reviews`
  const portraitPairs = Array.from(
    { length: Math.ceil(VEASEL_PORTRAIT_ROWS.length / 2) },
    (_, index) => index,
  )

  return (
    <box
      width="100%"
      flexGrow={1}
      flexDirection="column"
      alignItems="center"
      justifyContent="flex-start"
      backgroundColor={colors.panelBg}
      gap={compact() ? 0 : 1}
      paddingTop={compact() ? 0 : 1}
      paddingBottom={compact() ? 0 : 1}
    >
      <box width="100%" flexDirection="column" alignItems="center" flexShrink={0}>
        <text fg={colors.brand}>VEASEL CODE</text>
        {!compact() && (
          <text fg={colors.muted}>your local V-powered workspace</text>
        )}
        <text fg={colors.headerMeta}>{visibleDirectory()}</text>
      </box>

      <box flexDirection="column" alignItems="center" flexShrink={0}>
        <For each={portraitPairs}>
          {(pair) => (
            <text>
              <For
                each={portraitRowCells(
                  theme(),
                  VEASEL_PORTRAIT_ROWS[pair * 2] ?? "",
                  VEASEL_PORTRAIT_ROWS[pair * 2 + 1] ?? "",
                )}
              >
                {(cell) => <span style={{ fg: cell.color, bg: cell.background }}>{cell.glyph}</span>}
              </For>
            </text>
          )}
        </For>
      </box>

      <Show
        when={!compact()}
        fallback={
          <box flexDirection="column" alignItems="center" flexShrink={0}>
            <text fg={colors.body}>Ask anything to begin</text>
            <text fg={colors.muted}>{connectLine}</text>
            <text fg={colors.muted}>{reviewLine}</text>
          </box>
        }
      >
        <box
          flexDirection="column"
          alignItems="center"
          flexShrink={0}
          paddingLeft={2}
          paddingRight={2}
          border
          borderColor={colors.headerBorder}
          backgroundColor={colors.shellBg}
        >
          <text fg={colors.body}>Ask anything to begin — or set up once</text>
          <text fg={colors.muted}>{connectLine}</text>
          <text fg={colors.muted}>{reviewLine}</text>
        </box>
        <text fg={colors.headerMeta}>OPENTUI · REVIEW-GATED · LOCAL · PIXEL VEASEL</text>
      </Show>
    </box>
  )
}
