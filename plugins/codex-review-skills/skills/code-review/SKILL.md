---
name: code-review
description: "Run a full code review of a pull request, branch, commit, or the working tree by fanning out to every code-review-* sub-review in this plugin, verifying the findings, and merging them. Use whenever the user asks for a review, a final pass before merge, or 'what's wrong with this change', even if they do not say 'code review'."
---

Work out the target first. A pull request number or URL means its diff against the base
branch: resolve the exact base and head commits with the host's CLI (`gh pr view` on
GitHub, `az repos pr show` on Azure DevOps), fetch either that is not local, and diff
them. A branch name means its diff against the merge base with the default branch. A
commit means that commit. With no argument, review the working tree against HEAD. Fix
the comparison once, as two commits or the working tree, and give every subagent the
same one. Then find the stated intent: the pull request title and description, the
commit messages, or for an uncommitted working tree the user's own description of the
change. If none exists, say so and review against what the diff itself appears to do.

Read `project_doc_fallback_filenames` from the Codex configuration if it is readable, so
the guidelines pass knows which instruction files count. Codex loads no fallback file
unless one is configured, so if the configuration is not readable, tell the guidelines
pass that the fallback names are unknown rather than guessing one.

Run one subagent for every other skill in this plugin whose name starts with
`code-review-`. Spawn each with a fresh context, not a fork of this thread's history:
`fork_context` false or `fork_turns` "none", whichever the spawn tool offers. Codex
applies a reasoning override only to a fresh context, and a fork would hand every pass
this thread's reading of the diff. Use xhigh reasoning, or the highest level the model
accepts, unless the user named a level (low, medium, high, xhigh) with the request. Give
each subagent the full path to its `SKILL.md`, the comparison, the intent, the user's
request and any constraint it states, the fallback names, and the finding format below.
Name each subagent after its skill, with underscores for the hyphens, since the spawn
tool allows only lowercase letters, digits, and underscores. Tell each that the review
is read-only: it changes no file, branch, index, or stash. Codex caps how many agents
run at once; when a spawn is refused for that reason, wait for a running pass to finish
and spawn it again. Do not run any pass, or the verification below, yourself in the
main thread; independent passes are the point, since a single reader anchors on the
first problem it sees. A pass that could not be run is reported as not run.

## Finding format

Ask every subagent to report each finding as:

- `path:line`, the changed file and the line the finding anchors to.
- severity: high (security, data loss, crash, or a critical function failing), medium
  (an edge case, performance, or maintainability problem that can go wrong), or low
  (style, readability, minor best practice).
- what is wrong, in one sentence.
- why it matters, with the fact that shows it: the rule quoted, the caller that passes
  the bad value, the test that would fail. Cite only what was observed in the
  repository, the diff, the pull request, or a command's output; never a test count,
  commit, ticket, or line that was not seen.
- what the code must do.

## Verification

Merge the subagents' findings: two are one finding when they name the same defect with
the same required fix, even at different lines; keep both locations and the more
specific wording. Then spawn one more subagent named verification, fresh context and the
same reasoning level, with the merged list, the comparison, the intent, and the
read-only rule. It tries to refute each finding against the code and returns a verdict:
confirmed when it read the line and the defect holds; refuted when it can point to the
line that disproves it; unconfirmed when it could do neither.

## Report

Number the confirmed findings and sort them by severity. List unconfirmed findings after
them under their own heading, unnumbered, each with what would settle it. List refuted
findings last, one line each with the disproving `path:line`. State any pass that was not
run, with the reason, before the coverage totals; that is the one place a pass is named.
Include the coverage totals from the correctness pass: files changed, reviewed, skipped
with reasons. Use raw
Markdown. Name the project's own tools where a finding needs them; do not name the
review passes, the model, or the review tooling.

Do not post a comment, review, or label on the pull request host unless asked.
