import assert from "node:assert/strict";
import { test } from "node:test";
import { reviewWarnings } from "./policy";

test("draft pull requests are left for their author without review warnings", () => {
  assert.deepEqual(
    reviewWarnings({
      title: "WIP",
      body: "",
      changedFiles: ["main.v"],
      additions: 1,
      deletions: 0,
      draft: true,
    }),
    [],
  );
});

test("code changes without tests prompt a regression-test review", () => {
  const warnings = reviewWarnings({
    title: "feat: add provider request timeouts",
    body: "This change adds a timeout to provider requests and runs the focused checks.",
    changedFiles: ["provider.v"],
    additions: 22,
    deletions: 3,
    draft: false,
  });
  assert.ok(warnings.some((warning) => warning.includes("regression test")));
  assert.equal(warnings.some((warning) => warning.includes("descriptive")), false);
  assert.equal(warnings.some((warning) => warning.includes("Conventional Commit")), false);
  assert.equal(warnings.some((warning) => warning.includes("summary")), false);
});

test("matching tests satisfy the code coverage reminder", () => {
  const warnings = reviewWarnings({
    title: "fix: test provider request timeouts",
    body: "This change adds a timeout to provider requests and validates the behavior with tests.",
    changedFiles: ["provider.v", "provider_test.v"],
    additions: 34,
    deletions: 1,
    draft: false,
  });
  assert.equal(warnings.some((warning) => warning.includes("regression test")), false);
});
