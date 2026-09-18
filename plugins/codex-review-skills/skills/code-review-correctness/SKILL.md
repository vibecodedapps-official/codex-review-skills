---
name: code-review-correctness
description: "The general review pass. Check every changed file for correctness, security, and performance defects with a per-file coverage checklist, confirm each finding in the code, and apply the do-not-report list. Run by code-review, or alone when the user asks for a bug hunt or a review of the logic in a change."
---

Review every changed file, and report a finding only when confident it is a real defect.
A false alarm costs more trust than a missed nit. Security and correctness findings are
blocking; style and idiom suggestions are not.

## Coverage

Build a checklist of every changed file before reading any of them. Each file ends as
reviewed, or skipped with a concrete reason. A small or secondary file (a header, an
interface, a config counterpart, a test) is not covered by reviewing the file it
belongs to. Report the totals: files changed, reviewed, skipped. Do not stop after the
first serious finding.

## Focus

- Read the pull request title and description, or the commit messages, first. Judge
  the change against the stated intent, and report where the diff does not do what it
  says.
- Comment on added and modified code only. Deleted and unchanged code is context.
- When the context is unclear, read the surrounding code or search for the callers
  before judging. Do not flag on assumption.
- Look across the changed files for what one change requires of another: a renamed
  field, a new parameter, a changed return shape, a config key, a doc or type that
  should have moved with it.
- Skip comments, generated markers, and formatting unless asked.
- Confirm each finding in the code before reporting it: the symbol really is undefined,
  the branch really is unreachable, the caller really can pass that value.
- Before dropping a finding as a false positive, point to the line that disproves it.
  Unverifiable is not wrong.

## Do not report

- A defect in unchanged lines. Note it in one line at the end, unmarked as a finding,
  if it is serious.
- Code that looks wrong but is correct once the surrounding code is read.
- A nit a senior engineer would not raise in review.
- Anything a linter, formatter, or type checker in the repo will catch.
- Anything the code explicitly silences at that site with an ignore comment.

## What to check

- Correctness: logic, boundary conditions (empty input, first and last element, null or
  missing key, zero divisor, exact float comparison), error paths, and behavior under
  concurrent calls.
- Security: injection (SQL, shell, template, HTML), untrusted input reaching `eval` or
  deserialization, path traversal, secrets or personal data in logs or source, missing
  authorization checks, weak crypto or `random` for tokens.
- Performance, only on a hot path or at real data scale: N+1 queries, work repeated
  inside a loop, resources not released.
- Maintainability: names that misstate intent, duplicated logic, departure from the
  project's existing pattern.

## Severity

- high: security, data loss, crash, or a critical function failing.
- medium: performance, maintainability, or an edge case that can go wrong.
- low: style, readability, minor best practice.

Number findings and sort by severity. Report each as `path:line`, severity, what is
wrong, why it matters with the fact that shows it, and what the code must do.

## Language and file notes

Apply a section only when the diff contains that language or file type. Sections exist
for what has been written so far; a language without one gets the general checks above.

### Python

Mutable default arguments. Bare `except`, or `except Exception` wider than the failure
handled, or a caught exception dropped without logging or re-raise. Re-raising without
`from err`. `assert` as input validation. `is` against a literal. `open`, sockets, locks,
or connections without `with`. Blocking calls inside `async def`. Tasks created and never
awaited. `yaml.load` without a safe loader, `pickle` on untrusted data, `subprocess` with
`shell=True` built from input.

### .NET

`async void` outside event handlers. `.Result` or `.Wait()` on a task in request code.
A missing `ConfigureAwait` in a library that callers may block on. `IDisposable` not in
`using`. Catching `Exception` and swallowing it. `DateTime.Now` where UTC is stored.
String-built SQL. A nullable reference dereferenced without a check. An entity or DTO
change without the matching migration, mapping, or validator update.

### GitHub workflows

`pull_request_target` that checks out the PR head. A secret echoed or passed anywhere
but an `env:` block. No `permissions:` or `write-all`. A third-party action pinned to a
tag rather than a SHA. A `${{ github.event.* }}` value inside `run:`. No
`timeout-minutes`. No explicit `shell:` on a self-hosted runner. `needs:` naming a job
that does not exist. A misspelled action input, which is silently ignored.
