import { describe, expect, test } from "bun:test"
import {
  completeSkillMention,
  filterSkills,
  skillMentionAt,
  suggestSkills,
} from "./skill-autocomplete"

describe("skillMentionAt", () => {
  test("finds a $ token at the cursor and ignores mid-word dollars", () => {
    expect(skillMentionAt("run $review-to", 14)).toEqual({ start: 4, end: 14, query: "review-to" })
    expect(skillMentionAt("$review", 7)).toEqual({ start: 0, end: 7, query: "review" })
    expect(skillMentionAt("hi $", 4)).toEqual({ start: 3, end: 4, query: "" })
    expect(skillMentionAt("price$tag", 9)).toBeUndefined()
    expect(skillMentionAt("plain text", 5)).toBeUndefined()
  })
})

describe("filterSkills", () => {
  const skills = [
    { key: "review-tools/review", description: "Review code" },
    { key: "docs/summarize", description: "Summarize docs" },
    { key: "review-tools/audit", description: "Audit changes" },
  ]

  test("ranks prefix and name matches before substring hits", () => {
    expect(filterSkills(skills, "review-tools/r").map((item) => item.key)).toEqual(["review-tools/review"])
    expect(filterSkills(skills, "review").map((item) => item.key)).toEqual([
      "review-tools/review",
      "review-tools/audit",
    ])
    expect(filterSkills(skills, "sum").map((item) => item.name)).toEqual(["$docs/summarize"])
    expect(filterSkills(skills, "review-tools/r")[0]?.description).toBe("exact prefix")
    // Skill-name prefix (not a source prefix) stays in the name-match band.
    expect(filterSkills(skills, "audit")[0]?.description).toBe("name match")
  })

  test("tolerates one typo in the skill name for longer queries", () => {
    expect(filterSkills(skills, "reveiw").map((item) => item.key)).toEqual(["review-tools/review"])
    expect(filterSkills(skills, "reveiw")[0]?.description).toBe("close match")
    expect(filterSkills(skills, "audit").map((item) => item.key)[0]).toBe("review-tools/audit")
    expect(filterSkills(skills, "audit")[0]?.description).toBe("name match")
  })

  test("skips malformed keys and keeps descriptions for empty queries", () => {
    const mixed = [
      { key: "good/skill", description: "Useful" },
      { key: "noslash", description: "bad" },
      { key: "", description: "empty" },
    ]
    expect(filterSkills(mixed, "").map((item) => item.name)).toEqual(["$good/skill"])
    expect(filterSkills(mixed, "")[0]?.description).toBe("Useful")
  })
})

describe("suggestSkills", () => {
  test("filters catalog entries for the active query", () => {
    const suggestions = suggestSkills("aud", [
      { key: "review-tools/review", description: "Review code" },
      { key: "review-tools/audit", description: "Audit changes" },
    ])
    expect(suggestions.map((item) => item.key)).toEqual(["review-tools/audit"])
  })
})

describe("completeSkillMention", () => {
  test("replaces the active $ token and leaves a trailing space at end of draft", () => {
    expect(completeSkillMention("run $rev", 8, {
      name: "$review-tools/review",
      description: "Review code",
      key: "review-tools/review",
    })).toEqual({ value: "run $review-tools/review ", cursor: 25 })
    expect(completeSkillMention("$rev more", 4, {
      name: "$review-tools/review",
      description: "Review code",
      key: "review-tools/review",
    })).toEqual({ value: "$review-tools/review more", cursor: 20 })
  })
})
