// Compact chrome for the always-visible footer. Keep the first screen of
// commands discoverable without opening /help: connect, skills, plugins,
// mcp, theme, and map sit beside navigation keys.
// Keep home under ~72 columns so 80-wide terminals still show the quit cue.
export const homeFooterHint =
  "n new · j/k · 1-9 · type · /connect · /skills · /mcp · q quit"

// Shown while a home session filter is active so clear keys stay visible.
export const homeFilterFooterHint =
  "type · Backspace · Ctrl+L clear · Esc clear · j/k · Enter · q quit"

// Keep under ~72 columns: @ path complete and Shift+Enter multiline stay visible
// beside reviews; /theme and reduced-motion stay in /help.
export const sessionFooterHint =
  "Esc · ↑ · ? · @ · S-↵ · Ctrl+U/W/Y · /skills · /mcp · /map"

// Mode-specific session footers swap the always-visible row so discovery stays
// contextual without stuffing every hotkey into the default line (footer spam).
export const sessionPathFooterHint =
  "Tab/Enter insert · ↑/↓ · Esc dismiss · @ paths"

export const sessionSlashFooterHint =
  "Tab/Enter · ↑/↓ · Esc · Home/End · Pg"

export const sessionReviewFooterHint =
  "a/x · A/X · Space · ]/[ · Esc · ? help"

export const sessionReviewPatchFooterHint =
  "a/x · A/X · Space · {/} · v · ]/[ · Esc"

export const sessionStreamingFooterHint =
  "Esc cancel · End follow · Pg scroll · ?"

export type SessionFooterMode = {
  pathComplete?: boolean
  slashComplete?: boolean
  reviewPending?: boolean
  reviewKind?: "patch" | "command" | "mcp"
  streaming?: boolean
}

// Priority: autocomplete (on-screen menu) → pending review overlay → live stream
// → default discovery. Keeps each mode ≤72 columns and avoids overlapping cues.
export function sessionFooterForMode(mode: SessionFooterMode = {}): string {
  if (mode.pathComplete) return sessionPathFooterHint
  if (mode.slashComplete) return sessionSlashFooterHint
  if (mode.reviewPending) {
    return mode.reviewKind === "patch" ? sessionReviewPatchFooterHint : sessionReviewFooterHint
  }
  if (mode.streaming) return sessionStreamingFooterHint
  return sessionFooterHint
}

export function homeFooterForFilter(filter: string): string {
  return filter.trim().length > 0 ? homeFilterFooterHint : homeFooterHint
}
