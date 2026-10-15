// Compact chrome for the always-visible footer. Keep the first screen of
// commands discoverable without opening /help: connect, skills, plugins,
// mcp, theme, and map sit beside navigation keys.
// Keep home under ~72 columns so 80-wide terminals still show the quit cue.
export const homeFooterHint =
  "n new · j/k · 1-9 · type · /connect · /skills · /mcp · q quit"

// Shown while a home session filter is active so clear keys stay visible.
export const homeFilterFooterHint =
  "type · Backspace · Ctrl+L clear · Esc clear · j/k · Enter · q quit"

export const sessionFooterHint =
  "Esc · ↑ · Pg · Ctrl+U · Ctrl+R · Ctrl+Y · /skills · /mcp · /theme · /map"

export function homeFooterForFilter(filter: string): string {
  return filter.trim().length > 0 ? homeFilterFooterHint : homeFooterHint
}
