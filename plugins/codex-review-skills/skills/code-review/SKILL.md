---
name: code-review
description: "Run a full code review of a pull request, branch, commit, or the working tree by fanning out to every code-review-* sub-review in this plugin and merging their findings. Use whenever the user asks for a review, a final pass before merge, or 'what's wrong with this change', even if they do not say 'code review'."
---

Work out the target first. A pull request number or URL means its diff against the base
branch. A branch name means its diff against the merge base with the default branch. A
commit means that commit. With no argument, review the working tree against HEAD. Then
find the stated intent: the pull request title and description, the commit messages, or
for an uncommitted working tree the user's own description of the change. If none
exists, say so and review against what the diff itself appears to do.

Read `project_doc_fallback_filenames` from the Codex configuration if it is readable, so
the guidelines pass knows which instruction files count. Codex loads no fallback file
unless one is configured, so if the configuration is not readable, tell the guidelines
pass that the fallback names are unknown rather than guessing one.

Run one subagent for every other skill in this plugin whose name starts with
`code-review-`. Give each the full path to its `SKILL.md`, the target, the intent, the
fallback names, and the finding format below. Use xhigh reasoning. Do not run any pass
yourself in the main thread; independent passes are the point, since a single reader
anchors on the first problem it sees.

## Finding format

Ask every subagent to report each finding as:

- `path:line`, the changed file and the line the finding anchors to.
- severity: high (security, data loss, crash, or a critical function failing), medium
  (an edge case, performance, or maintainability problem that can go wrong), or low
  (style, readability, minor best practice).
- what is wrong, in one sentence.
- why it matters, with the fact that shows it: the rule quoted, the caller that passes
  the bad value, the test that would fail.
- what the code must do.

## Report

Return every finding from every subagent. Merge two only when they name the same file,
line, and defect, keeping the more specific wording. Number the findings and sort them
by severity. Include the coverage totals from the correctness pass: files changed,
reviewed, skipped with reasons. Use raw Markdown.

Do not leave GitHub comments, reviews, or labels unless asked.
