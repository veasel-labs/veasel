import { describe, expect, test } from "bun:test"
import type { ToolAwareMessage } from "./activity-group"
import {
  applyTranscriptVerbosity,
  cycleTranscriptVerbosity,
  stripThinkingBlocks,
  transcriptVerbosityLabel,
  verbosityExpandsActivity,
} from "./transcript-verbosity"

const sample: ToolAwareMessage[] = [
  { role: "user", content: "ask" },
  {
    role: "assistant",
    content: "```thinking\nhmm\n```\nvisible answer",
  },
  {
    role: "tool",
    content: "read: file.ts",
    toolName: "read",
    toolStatus: "done",
  },
  { role: "assistant", content: "done" },
]

describe("transcript verbosity", () => {
  test("cycles quiet → default → everything and clamps", () => {
    expect(cycleTranscriptVerbosity("quiet")).toBe("default")
    expect(cycleTranscriptVerbosity("default")).toBe("everything")
    expect(cycleTranscriptVerbosity("everything")).toBe("everything")
    expect(cycleTranscriptVerbosity("everything", -1)).toBe("default")
    expect(cycleTranscriptVerbosity("quiet", -1)).toBe("quiet")
    expect(transcriptVerbosityLabel("quiet")).toBe("Quiet")
    expect(verbosityExpandsActivity("everything")).toBe(true)
    expect(verbosityExpandsActivity("default")).toBe(false)
  })

  test("strips thinking fences", () => {
    expect(stripThinkingBlocks("```thinking\nx\n```\nbody")).toBe("body")
  })

  test("quiet hides tools and thinking", () => {
    const quiet = applyTranscriptVerbosity(sample, "quiet")
    expect(quiet.map((item) => item.role)).toEqual(["user", "assistant", "assistant"])
    expect(quiet[1]?.content).toBe("visible answer")
    expect(quiet.some((item) => item.role === "tool")).toBe(false)
  })

  test("default keeps tools and thinking (current LiveApp)", () => {
    const def = applyTranscriptVerbosity(sample, "default")
    expect(def).toEqual(sample)
  })

  test("everything keeps tools and thinking", () => {
    expect(applyTranscriptVerbosity(sample, "everything")).toEqual(sample)
  })
})
