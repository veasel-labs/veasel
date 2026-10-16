import type { HighlightEntry } from "./component/highlights-dialog"

/** Shipped LiveApp/Solid highlights shown in What's new (keep in sync with tip merges). */
export function liveReleaseHighlights(): HighlightEntry[] {
  return [
    {
      title: "Provider connect without the classic wizard",
      body: "Press s → pick a provider → paste an API key → discover models → save. F2 switches models; F3 sets output-budget variants.",
    },
    {
      title: "Pending reviews over HTTP",
      body: "Ctrl+R loads edits, shell commands, and MCP calls, then approve/reject from the Solid review panel.",
    },
    {
      title: "Execution policy agents",
      body: "F4 picks ask / auto-edit / sandbox-auto; the next turn sends execution_policy on POST /v1/sessions/:id/messages.",
    },
    {
      title: "Session tabs, timeline, export, MCP, skills",
      body: "Ctrl+] / [ switch tabs; Ctrl+T timeline; Ctrl+E export; Ctrl+M MCP; Ctrl+I status; skills insert $mentions.",
    },
  ]
}
