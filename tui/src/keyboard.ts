export type QuitKey = { name: string; ctrl: boolean; meta: boolean }

export type QuitContext = {
  creatingSession: boolean
  composerActive: boolean
}

// Global key handlers run before the focused input, so a bare "q" must not quit
// while the user is typing a session title or a chat message.
export function shouldQuitOnKey(key: QuitKey, context: QuitContext): boolean {
  if (key.name !== "q" || key.ctrl || key.meta) return false
  return !context.creatingSession && !context.composerActive
}
