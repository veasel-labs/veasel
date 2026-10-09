export type PullRequestReview = {
  title: string;
  body: string;
  changedFiles: string[];
  additions: number;
  deletions: number;
  draft: boolean;
};

export function reviewWarnings(pr: PullRequestReview): string[] {
  if (pr.draft) return [];

  const warnings: string[] = [];
  const body = pr.body.trim();
  if (pr.title.trim().length < 12 || /^(wip|draft)\b/i.test(pr.title.trim())) {
    warnings.push("Use a descriptive pull request title before requesting review.");
  }
  if (!/^(feat|fix|perf|revert|docs|style|chore|refactor|test|build|ci|security)(\([^)]+\))?!?: .{4,}$/i.test(pr.title.trim())) {
    warnings.push("Use a Conventional Commit title so automated releases can classify this change.");
  }
  if (body.length < 40) {
    warnings.push("Add a short summary and explain how this change was validated.");
  }
  if (pr.changedFiles.length > 35 || pr.additions + pr.deletions > 900) {
    warnings.push("This change is large; consider splitting it into reviewable parts.");
  }

  const touchesCode = pr.changedFiles.some((path) =>
    /(^|\/)([^/]+\.v|tui\/src\/.*\.(ts|tsx))$/.test(path),
  );
  const touchesTests = pr.changedFiles.some((path) =>
    /(^|\/)([^/]+_test\.v|[^/]+\.(test|spec)\.(ts|tsx))$/.test(path),
  );
  if (touchesCode && !touchesTests) {
    warnings.push("Review whether this behavior needs a regression test.");
  }

  return warnings;
}
