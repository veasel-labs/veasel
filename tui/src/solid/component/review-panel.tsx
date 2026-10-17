/** @jsxImportSource @opentui/solid */
import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js"
import { useKeyboard, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import {
  moveActiveReviewIndex,
  reviewHotkey,
  reviewHotkeyHint,
  reviewSelectionKey,
  toggleReviewSelection,
  type ActiveReview,
} from "../../active-review"
import {
  cycleReviewDiffSurface,
  diffRenderableTheme,
  filetypeFromReviewPath,
  reviewDiffSurfaceHint,
  type ReviewDiffSurface,
} from "../../diff-view"
import { moveReviewHunkIndex } from "../../review-diff"
import { noticeSegments, type TranscriptSegment } from "../../transcript"
import { DialogHeader, useDialog } from "../ui/dialog"
import { useSolidTheme, solidToneBold, solidToneFg } from "../theme"
import {
  formatSolidReviewBody,
  hunkCountForReview,
  patchSplitChrome,
  pendingSolidReviews,
  resolveReviewAction,
  reviewKindLabel,
  reviewPanelTitle,
  reviewShortcut,
  reviewSummaryLine,
  settleReviews,
  type ReviewDecision,
  type ReviewDecisionResult,
  type SolidReviewItem,
} from "../reviews"

export type ReviewPanelProps = {
  reviews: SolidReviewItem[]
  /** Called when the operator approves or rejects one or more pending items. */
  onDecide: (
    decision: ReviewDecision,
    targets: ActiveReview[],
  ) => ReviewDecisionResult | Promise<ReviewDecisionResult>
  onClose?: () => void
  /** Initial queue index (clamped). */
  initialIndex?: number
}

function SegmentSpan(props: { segment: TranscriptSegment }) {
  const colors = useSolidTheme()
  const fg = () => solidToneFg(props.segment.tone, colors)
  const bold = () => solidToneBold(props.segment.tone)
  return (
    <Show
      when={bold()}
      fallback={<span style={{ fg: fg() }}>{props.segment.text}</span>}
    >
      <span style={{ fg: fg() }}>
        <strong>{props.segment.text}</strong>
      </span>
    </Show>
  )
}

export function ReviewPanel(props: ReviewPanelProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const dimensions = useTerminalDimensions()
  // Local queue so approve/reject stays responsive without reopening the dialog.
  const [queue, setQueue] = createSignal<SolidReviewItem[]>([...props.reviews])
  const pending = createMemo(() => pendingSolidReviews(queue()))
  const [index, setIndex] = createSignal(
    Math.min(Math.max(0, props.initialIndex ?? 0), Math.max(0, pending().length - 1)),
  )
  const [hunkIndex, setHunkIndex] = createSignal(0)
  const [selectedKeys, setSelectedKeys] = createSignal<Set<string>>(new Set())
  const [diffSurface, setDiffSurface] = createSignal<ReviewDiffSurface>("segments")
  let settledOnce = false
  let disposed = false
  onCleanup(() => {
    disposed = true
  })
  const [busy, setBusy] = createSignal(false)
  const [failures, setFailures] = createSignal<string[]>([])

  const current = createMemo(() => {
    const items = pending()
    if (items.length === 0) return undefined
    const safe = moveActiveReviewIndex(index(), 0, items.length)
    return items[safe]
  })

  createEffect(() => {
    const items = pending()
    if (items.length === 0) {
      if (settledOnce) dialog.clear()
      return
    }
    setIndex((currentIndex) => moveActiveReviewIndex(currentIndex, 0, items.length))
  })

  const hotkeyHint = createMemo(() => {
    const item = current()
    if (!item) return undefined
    const key = reviewSelectionKey({ kind: item.kind, id: item.id })
    return reviewHotkeyHint(
      { kind: item.kind, id: item.id, pending: item.pending },
      {
        hunkCount: hunkCountForReview(item),
        selectedCount: selectedKeys().size,
        currentSelected: selectedKeys().has(key),
        diffSurfaceHint: item.kind === "patch" ? reviewDiffSurfaceHint(diffSurface()) : undefined,
      },
    )
  })

  const bodyText = createMemo(() => {
    const item = current()
    if (!item) return "No pending file, shell, or MCP reviews."
    if (item.kind === "patch" && diffSurface() === "split") {
      return patchSplitChrome(item, hunkIndex())
    }
    return formatSolidReviewBody(item, {
      terminalRows: dimensions().height,
      hunkIndex: hunkIndex(),
    })
  })

  const bodySegments = createMemo(() => noticeSegments(bodyText(), { cols: dimensions().width }))

  const diffTheme = () => diffRenderableTheme(colors)

  const applyDecision = async (decision: ReviewDecision, targets: ActiveReview[]) => {
    if (busy()) return
    setBusy(true)
    setFailures([])
    try {
      const result = await props.onDecide(decision, targets)
      if (disposed) return
      settledOnce = result.settled.length > 0
      setFailures(result.failed)
      setQueue((prev) => settleReviews(prev, result.settled))
      setSelectedKeys(new Set<string>())
      setHunkIndex(0)
    } catch (error) {
      if (!disposed) setFailures([error instanceof Error ? error.message : "Decision request failed"])
    } finally {
      if (!disposed) setBusy(false)
    }
  }

  useKeyboard((key: KeyEvent) => {
    // Toggle closed with the same chord that opened the panel.
    if (key.ctrl && key.name === reviewShortcut.name && !key.meta) {
      key.preventDefault()
      dialog.clear()
      return
    }

    const item = current()
    const hotkey = reviewHotkey(
      { name: key.name, ctrl: key.ctrl, meta: key.meta, shift: key.shift },
      {
        composerEmpty: true,
        review: item ? { kind: item.kind, id: item.id, pending: item.pending } : undefined,
      },
    )
    if (!hotkey) return

    const result = resolveReviewAction(hotkey, queue(), item, selectedKeys())
    if (!result) return
    key.preventDefault()

    if (result.type === "toggleSelect" && item) {
      setSelectedKeys((prev) => toggleReviewSelection(prev, item))
      return
    }
    if (result.type === "navigate") {
      setIndex((currentIndex) => moveActiveReviewIndex(currentIndex, result.delta, pending().length))
      setHunkIndex(0)
      return
    }
    if (result.type === "hunk") {
      setHunkIndex((currentHunk) =>
        moveReviewHunkIndex(currentHunk, result.delta, hunkCountForReview(item)),
      )
      return
    }
    if (result.type === "toggleDiffSurface") {
      setDiffSurface((surface) => cycleReviewDiffSurface(surface))
      return
    }
    if (result.type === "decide") {
      void applyDecision(result.decision, result.targets)
    }
  })

  return (
    <box width="100%" flexDirection="column" gap={1}>
      <DialogHeader
        title={reviewPanelTitle(current(), pending().length)}
        hint={`${reviewShortcut.label} · Esc`}
      />
      <Show
        when={current()}
        fallback={<text fg={colors.muted}>Queue empty — nothing to approve.</text>}
      >
        {(item) => (
          <>
            <box width="100%" flexDirection="row" gap={1}>
              <text fg={colors.statusWarn}>
                <strong>{reviewKindLabel(item().kind).toUpperCase()}</strong>
              </text>
              <text fg={colors.body}>{reviewSummaryLine(item())}</text>
              <text fg={colors.muted}>
                {" "}
                · {moveActiveReviewIndex(index(), 0, pending().length) + 1}/{pending().length} pending
              </text>
            </box>
            <Show when={busy()}>
              <text fg={colors.statusWarn}>Waiting for server confirmation…</text>
            </Show>
            <For each={failures()}>
              {(failure) => <text fg={colors.statusWarn}>{failure}</text>}
            </For>
            <Show when={!busy() && hotkeyHint()}>
              {(hint) => <text fg={colors.muted}>{hint()}</text>}
            </Show>
            <Show
              when={item().kind === "patch" && diffSurface() === "split"}
              fallback={
                <scrollbox
                  width="100%"
                  flexGrow={1}
                  stickyScroll={false}
                  maxHeight={Math.max(8, dimensions().height - 14)}
                >
                  <text>
                    <For each={bodySegments()}>{(segment) => <SegmentSpan segment={segment} />}</For>
                  </text>
                </scrollbox>
              }
            >
              <box width="100%" flexDirection="column" gap={1}>
                <text>
                  <For each={bodySegments()}>{(segment) => <SegmentSpan segment={segment} />}</For>
                </text>
                <diff
                  width="100%"
                  height={Math.max(8, Math.min(16, dimensions().height - 16))}
                  diff={(item() as Extract<SolidReviewItem, { kind: "patch" }>).diff}
                  view="split"
                  filetype={filetypeFromReviewPath(
                    (item() as Extract<SolidReviewItem, { kind: "patch" }>).path,
                  )}
                  fg={diffTheme().fg}
                  addedSignColor={diffTheme().addedSignColor}
                  removedSignColor={diffTheme().removedSignColor}
                  lineNumberFg={diffTheme().lineNumberFg}
                  addedBg={diffTheme().addedBg}
                  removedBg={diffTheme().removedBg}
                  contextBg={diffTheme().contextBg}
                  addedContentBg={diffTheme().addedContentBg}
                  removedContentBg={diffTheme().removedContentBg}
                  contextContentBg={diffTheme().contextContentBg}
                  selectionBg={diffTheme().selectionBg}
                  selectionFg={diffTheme().selectionFg}
                  showLineNumbers={diffTheme().showLineNumbers}
                  syncScroll={diffTheme().syncScroll}
                  wrapMode={diffTheme().wrapMode}
                />
              </box>
            </Show>
          </>
        )}
      </Show>
    </box>
  )
}

/** Open the review panel on the dialog stack (large mint chrome). */
export function openReviewPanel(
  dialog: ReturnType<typeof useDialog>,
  props: ReviewPanelProps,
) {
  dialog.replace(() => <ReviewPanel {...props} />, { size: "large", onClose: props.onClose })
}
