import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyCommits, nextPrerelease } from "./release-plan.mjs";

test("only feature, fix, performance, and breaking commits trigger versions", () => {
  assert.equal(classifyCommits(["docs: clarify providers", "ci: lint workflows"]), null);
  assert.equal(classifyCommits(["fix: retry a timed out read"]), "patch");
  assert.equal(classifyCommits(["security: reject a provider redirect"]), "patch");
  assert.equal(classifyCommits(["perf(store): add the message index"]), "patch");
  assert.equal(classifyCommits(["feat: add a repository browser"]), "minor");
  assert.equal(classifyCommits(["feat(api)!: remove the preview endpoint"]), "major");
  assert.equal(
    classifyCommits(["feat: add session search\n\nBREAKING CHANGE: session IDs change"]),
    "major",
  );
});

test("prerelease increments follow the V module's current semantic version", () => {
  assert.equal(nextPrerelease("0.1.0", "patch"), "0.1.1-next.0");
  assert.equal(nextPrerelease("0.1.0", "minor"), "0.2.0-next.0");
  assert.equal(nextPrerelease("0.1.0", "major"), "1.0.0-next.0");
  assert.equal(nextPrerelease("0.2.0-next.0", "minor"), "0.3.0-next.0");
  assert.throws(() => nextPrerelease("invalid", "patch"), /Invalid release input/);
});
