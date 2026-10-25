const maxAuthExportBytes = 64 * 1024
const authExportTimeoutMs = 10_000

type OpenCodeCredential = {
  integrationID?: unknown
  active?: unknown
  value?: { type?: unknown; key?: unknown }
}

/** Extract only the active OpenCode Go API credential; never return raw export data. */
export function parseOpenCodeGoApiKey(exportText: string): string {
  let entries: unknown
  try {
    entries = JSON.parse(exportText)
  } catch {
    throw new Error("OpenCode CLI returned an invalid credential export")
  }
  if (!Array.isArray(entries)) {
    throw new Error("OpenCode CLI returned an invalid credential export")
  }
  const active = (entries as OpenCodeCredential[]).filter(
    (entry) => entry?.integrationID === "opencode-go" && entry.active === true,
  )
  if (active.length !== 1) {
    throw new Error(
      active.length === 0
        ? "No active OpenCode Go credential was found in the CLI"
        : "OpenCode CLI has multiple active OpenCode Go credentials",
    )
  }
  const value = active[0]?.value
  if (
    value?.type !== "key"
    || typeof value.key !== "string"
    || value.key.length === 0
    || value.key.length > 4096
    || value.key.trim() !== value.key
    || /[\u0000-\u001f\u007f]/.test(value.key)
  ) {
    throw new Error("The active OpenCode Go credential is not a supported API key")
  }
  return value.key
}

async function readBounded(stream: ReadableStream<Uint8Array>): Promise<string> {
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (!value) continue
      size += value.byteLength
      if (size > maxAuthExportBytes) {
        await reader.cancel()
        throw new Error("OpenCode CLI credential export exceeded its size limit")
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(bytes)
}

/** Import through OpenCode's explicit, provider-scoped export without a shell or secret logging. */
export async function exportOpenCodeGoApiKey(): Promise<string> {
  let process: ReturnType<typeof Bun.spawn>
  try {
    process = Bun.spawn(["opencode", "auth", "export", "opencode-go"], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "ignore",
    })
  } catch {
    throw new Error("OpenCode CLI was not found; enter an OpenCode Console API key instead")
  }
  const stdout = process.stdout
  if (!(stdout instanceof ReadableStream)) {
    process.kill()
    throw new Error("OpenCode CLI credential export did not provide a readable output stream")
  }

  let timedOut = false
  const timeout = setTimeout(() => {
    timedOut = true
    process.kill()
  }, authExportTimeoutMs)
  try {
    const [output, exitCode] = await Promise.all([readBounded(stdout), process.exited])
    if (timedOut) {
      throw new Error("OpenCode CLI credential export timed out")
    }
    if (exitCode !== 0) {
      throw new Error("OpenCode CLI could not export credentials; enter an OpenCode Console API key instead")
    }
    return parseOpenCodeGoApiKey(output)
  } catch (error) {
    try {
      process.kill()
    } catch {
      // The CLI may already have exited.
    }
    await process.exited.catch(() => {})
    if (timedOut) throw new Error("OpenCode CLI credential export timed out")
    if (error instanceof Error && error.message.startsWith("OpenCode CLI")) throw error
    throw new Error("OpenCode CLI credential import failed; enter an OpenCode Console API key instead")
  } finally {
    clearTimeout(timeout)
  }
}
