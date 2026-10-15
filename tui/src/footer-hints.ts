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

export function homeFooterForFilter(filter: string): string {
  return filter.trim().length > 0 ? homeFilterFooterHint : homeFooterHint
}
