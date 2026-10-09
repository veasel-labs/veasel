import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import semver from "semver";

export function classifyCommits(messages) {
  const levels = { patch: 1, minor: 2, major: 3 };
  let release = null;

  for (const message of messages) {
    const [subject = "", ...body] = message.trim().split("\n");
    const match = /^([a-z]+)(?:\([^)]+\))?(!)?:/i.exec(subject);
    if (!match) continue;

    const breaking = match[2] === "!" || /^BREAKING CHANGE:/im.test(body.join("\n"));
    const next = breaking
      ? "major"
      : match[1].toLowerCase() === "feat"
        ? "minor"
        : ["fix", "perf", "revert", "security"].includes(match[1].toLowerCase())
          ? "patch"
          : null;
    if (next && (!release || levels[next] > levels[release])) release = next;
  }

  return release;
}

export function classifyChanges(messages, paths) {
  const conventionalRelease = classifyCommits(messages);
  if (conventionalRelease) return conventionalRelease;

  const runtimeChanged = paths.some((path) => {
    if (path.endsWith("_test.v")) return false;
    return (
      path.endsWith(".v") ||
      path.startsWith("tui/src/") ||
      ["tui/package.json", "tui/bun.lock", "v.mod", "v.sum"].includes(path)
    );
  });
  return runtimeChanged ? "patch" : null;
}

export function nextPrerelease(currentVersion, release) {
  const base = semver.valid(currentVersion);
  if (!base || !["patch", "minor", "major"].includes(release)) {
    throw new Error(`Invalid release input: ${currentVersion} / ${release}`);
  }
  return semver.inc(base, `pre${release}`, "next");
}

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

function currentModuleVersion() {
  const content = readFileSync(new URL("../../v.mod", import.meta.url), "utf8");
  const version = /^\s*version:\s*['"]?([^\s'"]+)/m.exec(content)?.[1];
  if (!semver.valid(version)) throw new Error("v.mod must contain a valid semantic version");
  return version;
}

function releasePlan() {
  const lastTag = git(["tag", "--list", "v*", "--sort=-version:refname"])
    .split("\n")
    .filter((tag) => semver.valid(tag.replace(/^v/, "")))
    .sort((left, right) => semver.rcompare(left.slice(1), right.slice(1)))[0];
  const range = lastTag ? `${lastTag}..HEAD` : "HEAD";
  const commits = git(["log", range, "--format=%s%n%b%x00"])
    .split("\0")
    .map((message) => message.trim())
    .filter(Boolean);
  const paths = git(["diff", "--name-only", range, "--"]).split("\n").filter(Boolean);
  const release = classifyChanges(commits, paths);

  if (!release) return { released: false };

  const current = lastTag ? lastTag.slice(1) : currentModuleVersion();
  const version = nextPrerelease(current, release);
  return { released: true, version, tag: `v${version}`, release };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const plan = releasePlan();
  const output = process.env.GITHUB_OUTPUT;
  if (!output) throw new Error("GITHUB_OUTPUT is required to write a release plan");
  appendFileSync(output, `released=${plan.released}\n`);
  if (plan.released) {
    appendFileSync(output, `version=${plan.version}\ntag=${plan.tag}\nrelease=${plan.release}\n`);
    process.stdout.write(`Plan prerelease ${plan.tag} (${plan.release}).\n`);
  } else {
    process.stdout.write("No releasable Conventional Commits since the last version tag.\n");
  }
}
