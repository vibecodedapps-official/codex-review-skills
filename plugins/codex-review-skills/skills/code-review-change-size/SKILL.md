---
name: code-review-change-size
description: "Judge whether a change is small enough to review well and, if not, propose the first stage to land. Run by code-review, or alone when the user asks whether a pull request should be split or is too big."
---

Reviewer attention falls off past a few hundred changed lines, and a defect in line 700
of a single review is far more likely to slip through than the same defect in a
200-line stage that got its own pass. So count the changed lines, leaving out generated
files, lockfiles, and vendored dependencies. A change that is not mechanical should stay
under 800 changed lines, and under 500 when it alters complex logic. Renames,
formatting, and generated output do not count against it.

If the change is larger, say whether it splits into stages that can each be reviewed and
landed on their own, and name the smallest coherent stage to land first. Base that on
the actual diff: which files depend on which, which call sites move together, and what
must exist before the rest compiles or passes tests.

## Report

If the change is within bounds, report that in one line with the count. Otherwise
report one finding at `path:line` of the file that anchors the first stage, severity
low, saying the count, the proposed stages, and which to land first.
