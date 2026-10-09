import { danger, warn } from "danger";
import { reviewWarnings } from "./policy";

const pr = danger.github.pr;
const warnings = reviewWarnings({
  title: pr.title,
  body: pr.body ?? "",
  changedFiles: danger.git.modified_files.concat(
    danger.git.created_files,
    danger.git.deleted_files,
  ),
  additions: pr.additions,
  deletions: pr.deletions,
  draft: pr.draft,
});

for (const warning of warnings) warn(warning);
