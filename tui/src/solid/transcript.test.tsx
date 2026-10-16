/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { createSignal } from "solid-js"
import { testRender } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { App, fixtureTurns } from "./app"
import {
  SolidTranscript,
  transcriptMessagesFromChatTurns,
  type ToolAwareMessage,
} from "./transcript"
import { assistantLabel, userLabel } from "../transcript"
import type { ChatTurn } from "../chat-history"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30 } as const

describe("Solid transcript scrollbox", () => {
  test("renders role labels from transcript helpers at 80×30", async () => {
    const setup = await testRender(
      () => (
        <App
          sessionTitle="fixture-session"
          initialMessages={[
            { role: "user", content: "hello transcript" },
            { role: "assistant", content: "mint reply body" },
          ]}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL")
    expect(frame).toContain("fixture-session")
    expect(frame).toContain(userLabel)
    expect(frame).toContain("hello transcript")
    expect(frame).toContain(assistantLabel)
    expect(frame).toContain("mint reply body")
    // Demo viewport is 80×30; frame may include a trailing newline from capture.
    expect(frame.split("\n").length).toBeLessThanOrEqual(31)
  })

  test("long transcript sticks to latest turns", async () => {
    let scroll: ScrollBoxRenderable | undefined
    const turns = fixtureTurns(36, "wide-pad ")
    const latest = turns[turns.length - 1]!.content
    const earliest = turns[0]!.content

    const setup = await testRender(
      () => (
        <App
          sessionTitle="long-session"
          initialMessages={turns}
          followTail={true}
          scrollRef={(box) => {
            scroll = box
          }}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    // Sticky bottom needs a layout pass after content mounts.
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Turn 36")
    expect(frame).toContain(latest.slice(0, 24))
    // Earliest turns should be scrolled out of the 80×30 viewport.
    expect(frame).not.toContain(earliest.slice(0, 24))
    expect(scroll).toBeDefined()
    expect(scroll!.scrollHeight).toBeGreaterThan(scroll!.height)
    expect(scroll!.scrollTop).toBeGreaterThan(0)
  })

  test("streaming append follows the tail", async () => {
    const [stream, setStream] = createSignal("partial stream…")
    let scroll: ScrollBoxRenderable | undefined
    const turns = fixtureTurns(28, "stream-pad ")

    const setup = await testRender(
      () => (
        <App
          sessionTitle="stream-session"
          initialMessages={turns}
          streaming={true}
          streamingText={stream()}
          followTail={true}
          scrollRef={(box) => {
            scroll = box
          }}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("partial stream")

    setStream("TAIL_MARKER_STREAM_END unique")
    await setup.renderOnce()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("TAIL_MARKER_STREAM_END")
    expect(frame).toContain(assistantLabel)
    expect(frame).toContain("streaming")
    expect(scroll).toBeDefined()
    expect(scroll!.scrollTop).toBeGreaterThan(0)
  })

  test("empty transcript shows the start hint", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript messages={[]} followTail={true} />
        </box>
      ),
      { width: 80, height: 20 },
    )
    setups.push(setup)
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("Start with a question")
  })

  test("mount budget keeps a sticky-tail window and cues earlier blocks", async () => {
    const turns = fixtureTurns(48, "budget-pad ")
    const earliest = turns[0]!.content
    const latest = turns[turns.length - 1]!.content
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript
            messages={turns}
            followTail={true}
            mountBudget={10}
            session={{ title: "budget-session", directory: "/tmp" }}
          />
        </box>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("earlier")
    expect(frame).toContain(latest.slice(0, 20))
    expect(frame).not.toContain(earliest.slice(0, 20))
  })

  test("maps chat-history turns into transcript messages", async () => {
    const turns: ChatTurn[] = [
      {
        id: 1,
        session_id: "s1",
        role: "user",
        content: "from chat-history",
        created_at: "2026-10-16T00:00:00Z",
      },
      {
        id: 2,
        session_id: "s1",
        role: "assistant",
        content: "bridged reply",
        created_at: "2026-10-16T00:00:01Z",
      },
    ]
    const setup = await testRender(
      () => (
        <App
          sessionTitle="history-bridge"
          initialMessages={transcriptMessagesFromChatTurns(turns)}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("from chat-history")
    expect(frame).toContain("bridged reply")
  })

  test("groups consecutive tools with collapsed done status at 80×30", async () => {
    const activityFixture: ToolAwareMessage[] = [
      { role: "user", content: "inspect helpers" },
      {
        role: "tool",
        content: "read: activity-group.ts",
        toolName: "read",
        toolStatus: "done",
      },
      {
        role: "tool",
        content: "grep: summarizeActivityGroup",
        toolName: "grep",
        toolStatus: "done",
      },
      { role: "assistant", content: "grouped above" },
    ]
    const setup = await testRender(
      () => (
        <App
          sessionTitle="activity-demo"
          initialMessages={activityFixture}
        />
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL")
    expect(frame).toContain("activity")
    expect(frame).toContain("2 tools")
    expect(frame).toContain("done")
    expect(frame).toContain("Ctrl+G")
    // Collapsed by default when done — item details stay hidden.
    expect(frame).not.toContain("summarizeActivityGroup")
    expect(frame).toContain("grouped above")
    expect(frame.split("\n").length).toBeLessThanOrEqual(31)
  })

  test("Ctrl+G expands the latest activity group", async () => {
    const toolRun: ToolAwareMessage[] = [
      { role: "user", content: "run tools" },
      {
        role: "tool",
        content: "read: unique-expand-marker.ts",
        toolName: "read",
        toolStatus: "done",
      },
      {
        role: "tool",
        content: "shell: echo ok",
        toolName: "shell",
        toolStatus: "done",
      },
    ]
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript messages={toolRun} followTail={true} />
        </box>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    expect(setup.captureCharFrame()).not.toContain("unique-expand-marker")

    setup.mockInput.pressKey("g", { ctrl: true })
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("unique-expand-marker")
    expect(frame).toContain("shell")
    expect(frame).toMatch(/▾ activity|activity/)
  })

  test("running groups start expanded with busy status", async () => {
    const running: ToolAwareMessage[] = [
      {
        role: "tool",
        content: "read: live-file.v",
        toolName: "read",
        toolStatus: "running",
      },
    ]
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript messages={running} followTail={true} />
        </box>
      ),
      { width: 80, height: 20 },
    )
    setups.push(setup)
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("running")
    expect(frame).toContain("live-file.v")
    expect(frame).toContain("busy")
  })

  test("quiet verbosity hides tools and thinking fences", async () => {
    const turns: ToolAwareMessage[] = [
      { role: "user", content: "inspect" },
      {
        role: "assistant",
        content: "```thinking\nhidden\n```\nquiet-visible-answer",
      },
      {
        role: "tool",
        content: "read: quiet-hidden-tool.ts",
        toolName: "read",
        toolStatus: "done",
      },
    ]
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript messages={turns} followTail={true} verbosity="quiet" />
        </box>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("quiet-visible-answer")
    expect(frame).not.toContain("quiet-hidden-tool")
    expect(frame).not.toContain("hidden")
    expect(frame).not.toContain("activity")
  })

  test("messageNavRequest jumps last then previous user message", async () => {
    const turns: ToolAwareMessage[] = [
      { role: "user", content: "alpha-user-marker unique" },
      { role: "assistant", content: "alpha reply pad ".repeat(8) },
      { role: "user", content: "beta-user-marker unique" },
      { role: "assistant", content: "beta reply pad ".repeat(8) },
      { role: "user", content: "gamma-user-marker unique" },
      { role: "assistant", content: "gamma reply pad ".repeat(8) },
    ]
    const jumped: number[] = []
    const [nav, setNav] = createSignal<
      | { tick: number; direction: "next" | "prev"; userOnly?: boolean }
      | { tick: number; action: "last-user" }
      | undefined
    >(undefined)
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript
            messages={turns}
            followTail={true}
            messageNavRequest={nav}
            onMessageNavigated={(info) => jumped.push(info.index)}
          />
        </box>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    setNav({ tick: 1, action: "last-user" })
    await setup.renderOnce()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await setup.renderOnce()
    expect(jumped.at(-1)).toBe(4)

    setNav({ tick: 2, direction: "prev", userOnly: true })
    await setup.renderOnce()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await setup.renderOnce()
    expect(jumped.at(-1)).toBe(2)

    const frame = setup.captureCharFrame()
    expect(frame).toContain("beta-user-marker")
  })
})
