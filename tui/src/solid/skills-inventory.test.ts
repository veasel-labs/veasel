import { describe, expect, test } from "bun:test"
import { skillCatalogFromPlugins } from "./skills-inventory"

describe("skills inventory", () => {
  test("flattens plugin skills and marks enabled ones", () => {
    const entries = skillCatalogFromPlugins(
      {
        plugins: [
          {
            name: "local-tools",
            skills: [
              { name: "review", description: "Review  diffs" },
              { name: "docs", description: "Write docs" },
            ],
          },
        ],
      },
      [{ plugin_name: "local-tools", skill_name: "review" }],
    )
    expect(entries.map((entry) => entry.key)).toEqual([
      "local-tools/docs",
      "local-tools/review",
    ])
    expect(entries.find((entry) => entry.key === "local-tools/review")?.description).toContain(
      "enabled ·",
    )
  })
})
