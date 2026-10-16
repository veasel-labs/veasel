import { basename, extname } from "node:path"
import { existsSync, statSync } from "node:fs"

export const composerAttachmentLimit = 16

const imageExts = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg", ".bmp"])

export type ComposerAttachmentKind = "image" | "file"

export type ComposerAttachment = {
  id: string
  path: string
  name: string
  kind: ComposerAttachmentKind
  bytes?: number
}

export function attachmentKindForPath(path: string): ComposerAttachmentKind {
  return imageExts.has(extname(path).toLowerCase()) ? "image" : "file"
}

export function normalizeAttachmentPath(raw: string): string | undefined {
  const trimmed = raw.trim().replace(/^['"]+|['"]+$/g, "")
  if (!trimmed) return undefined
  if (/^(https?):\/\//i.test(trimmed)) return undefined
  if (trimmed.startsWith("file://")) {
    try {
      const url = new URL(trimmed)
      if (url.hostname && url.hostname !== "localhost") return undefined
      return decodeURIComponent(url.pathname)
    } catch {
      return undefined
    }
  }
  // Single-line path-like paste (absolute, home, or relative with a slash/dot).
  if (trimmed.includes("\n") || trimmed.includes("\r")) return undefined
  if (!(trimmed.startsWith("/") || trimmed.startsWith("~/") || trimmed.startsWith("./") || trimmed.startsWith("../"))) {
    return undefined
  }
  return trimmed
}

export function resolveAttachmentPath(
  raw: string,
  options: { exists?: (path: string) => boolean; home?: string } = {},
): string | undefined {
  const normalized = normalizeAttachmentPath(raw)
  if (!normalized) return undefined
  const home = options.home ?? process.env.HOME ?? ""
  const expanded = normalized.startsWith("~/") ? `${home}/${normalized.slice(2)}` : normalized
  const exists = options.exists ?? ((path) => existsSync(path))
  if (!exists(expanded)) return undefined
  return expanded
}

export function createComposerAttachment(
  path: string,
  options: { stat?: (path: string) => { size: number }; now?: number } = {},
): ComposerAttachment {
  const kind = attachmentKindForPath(path)
  let bytes: number | undefined
  try {
    const stat = options.stat ?? ((p) => statSync(p))
    bytes = stat(path).size
  } catch {
    bytes = undefined
  }
  const now = options.now ?? Date.now()
  return {
    id: `att-${now.toString(36)}-${Math.random().toString(36).slice(2, 7)}`,
    path,
    name: basename(path),
    kind,
    bytes,
  }
}

export function addComposerAttachment(
  attachments: readonly ComposerAttachment[],
  next: ComposerAttachment,
): ComposerAttachment[] {
  if (attachments.some((item) => item.path === next.path)) return [...attachments]
  return [...attachments, next].slice(-composerAttachmentLimit)
}

export function removeComposerAttachment(
  attachments: readonly ComposerAttachment[],
  id: string,
): ComposerAttachment[] {
  return attachments.filter((item) => item.id !== id)
}

/** Append @path mentions so the turn stays text-API compatible. */
export function formatMessageWithAttachments(text: string, attachments: readonly ComposerAttachment[]): string {
  const body = text.trimEnd()
  if (attachments.length === 0) return body
  const mentions = attachments.map((item) => `@${item.path}`).join(" ")
  if (!body.trim()) return mentions
  return `${body}\n\n${mentions}`
}

export function attachmentChipLabel(attachment: ComposerAttachment): string {
  const kind = attachment.kind === "image" ? "img" : "file"
  const size =
    typeof attachment.bytes === "number"
      ? attachment.bytes < 1024
        ? `${attachment.bytes}B`
        : attachment.bytes < 1024 * 1024
          ? `${Math.round(attachment.bytes / 1024)}KB`
          : `${(attachment.bytes / (1024 * 1024)).toFixed(1)}MB`
      : undefined
  return size ? `[${kind}] ${attachment.name} · ${size}` : `[${kind}] ${attachment.name}`
}

/** Small Veasel-branded ASCII frame; no bitmap decode (Kitty/iTerm later). */
export function asciiImagePreview(attachment: ComposerAttachment): string {
  const label = attachment.name.length > 28 ? `${attachment.name.slice(0, 27)}…` : attachment.name
  const size =
    typeof attachment.bytes === "number" ? `${Math.max(1, Math.round(attachment.bytes / 1024))} KB` : "size ?"
  const inner = 32
  const top = `┌${"─".repeat(inner)}┐`
  const mid = (text: string) => {
    const pad = Math.max(0, inner - text.length)
    const left = Math.floor(pad / 2)
    const right = pad - left
    return `│${" ".repeat(left)}${text}${" ".repeat(right)}│`
  }
  return [top, mid("VEASEL · image"), mid(label), mid(size), `└${"─".repeat(inner)}┘`].join("\n")
}
