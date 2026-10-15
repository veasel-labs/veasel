// Formats the extractive workspace repository map for TUI display.
// Sizes are measured UTF-8 bytes plus a bytes/4 token bound — never provider usage.

export type WorkspaceRepositoryMap = {
  text: string
  bytes: number
  estimated_token_bound: number
  budget_bytes: number
  file_count: number
  symbol_count: number
  files_scanned: number
  truncated: boolean
  untrusted: boolean
  ranked_paths: string[]
}

const previewPathLimit = 12
const previewTextBytes = 2_400

export function formatRepositoryMapSummary(map: WorkspaceRepositoryMap, hint = ""): string {
  const lines = [
    "WORKSPACE REPOSITORY MAP",
    "Untrusted extractive ranking (paths and declarations). Not tree-sitter/PageRank parity.",
  ]
  if (hint.trim().length > 0) {
    lines.push(`Hint: ${hint.trim()}`)
  }
  lines.push(
    `Measured: ${map.bytes} UTF-8 bytes (budget ${map.budget_bytes}; bytes/4 bound ${map.estimated_token_bound})`,
    `Coverage: ${map.file_count} ranked files · ${map.symbol_count} symbols · ${map.files_scanned} scanned${map.truncated ? " · truncated" : ""}`,
  )
  const paths = map.ranked_paths ?? []
  if (paths.length > 0) {
    lines.push("Ranked paths:")
    for (const path of paths.slice(0, previewPathLimit)) {
      lines.push(`  ${path}`)
    }
    if (paths.length > previewPathLimit) {
      lines.push(`  … ${paths.length - previewPathLimit} more`)
    }
  } else {
    lines.push("Ranked paths: (none)")
  }
  const body = (map.text ?? "").trim()
  if (body.length > 0) {
    lines.push("", "Map preview:")
    lines.push(truncateUtf8Preview(body, previewTextBytes))
  }
  return lines.join("\n")
}

export function truncateUtf8Preview(text: string, maxBytes: number): string {
  if (maxBytes <= 0) return ""
  const encoded = Buffer.from(text, "utf8")
  if (encoded.length <= maxBytes) return text
  let cut = maxBytes
  while (cut > 0 && (encoded[cut] & 0xc0) === 0x80) cut -= 1
  const kept = encoded.subarray(0, cut).toString("utf8")
  const hidden = encoded.length - cut
  return `${kept}\n… ${hidden} more UTF-8 bytes hidden`
}
