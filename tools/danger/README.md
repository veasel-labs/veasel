# Pull request review policy

This directory contains the TypeScript DangerJS policy used by
`.github/workflows/danger.yml`. The workflow runs the policy from the pull
request's trusted base commit, while Danger reads the proposed pull request
through GitHub's API. It never checks out or executes the pull request head
with a token that can write review comments.

The policy leaves non-draft review nudges for descriptive titles, concise
summaries, unusually large changes, and code changes that omit regression
tests. These are advisory comments; CI remains the source of required build
and test checks. `policy.test.ts` exercises the pure review rules.

Run `npm ci --ignore-scripts`, `npm run check`, and `npm test` from this
directory. `npm run local -- --base main` runs the policy locally against the
current branch.

## Dependency note

The npm audit database currently reports a high-severity denial-of-service
advisory for the transitive `braces` dependency used by DangerJS through
`micromatch` ([GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)).
The published range includes the latest registry version (`braces` 3.0.3), and
the registry currently offers no fixed release. DangerJS is a CI-only review
tool and is not included in Veasel Code binaries. The lockfile is monitored by
Dependabot; do not mask the advisory with an unreviewed override. Reassess this
note when upstream publishes a fixed compatible version.
