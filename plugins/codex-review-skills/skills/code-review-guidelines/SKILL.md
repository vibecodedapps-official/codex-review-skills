---
name: code-review-guidelines
description: "Audit a change against the rules the repository states for itself in AGENTS.md, AGENTS.override.md, and configured fallbacks such as CLAUDE.md, resolved the way Codex resolves them and quoted exactly. Run by code-review, or alone when the user asks whether a change follows the project's conventions or instruction files."
---

Audit the changed files against the rules the repository states for itself, and
nothing else.

## Which files count

Walk from the repository root down to each directory that holds a changed file. In
each directory exactly one instruction file is active: `AGENTS.override.md` if present,
otherwise `AGENTS.md`, otherwise a fallback name the configuration lists in
`project_doc_fallback_filenames`, such as `CLAUDE.md`. A file that a higher-priority
sibling supersedes states nothing; do not enforce it, and do not report compliance with
the active file as a violation of the superseded one.

Codex loads no fallback file unless the configuration names it, so a fallback counts
only when confirmed: use the names the caller passed, or read them from the Codex
configuration if you can. If neither is available, treat only `AGENTS.override.md` and
`AGENTS.md` as active, and say in the report that fallback instruction files were not
evaluated because the configuration was not available. Never invent a fallback name.

A rule applies to a changed file when the active instruction file that states it sits
in that file's directory or an ancestor. A rule from a sibling or unrelated directory
does not apply. When two applicable files conflict, the deeper one wins for files under
its directory.

Follow every `@path` import and every doc or README an instruction file points at. A
rule found there inherits the scope of the instruction file that imported or referenced
it, not the scope of its own location: a rule in `docs/review.md` reached from the root
`AGENTS.md` governs the whole repository. Track that importing file as the source of
applicability, and quote the rule from the file that holds it.

## What to report

A finding only when all of these hold:

- You can quote the exact rule, and name the file and line it comes from. When the rule
  was reached through an import or reference, name the importing instruction file too.
- The rule is scoped to the changed file by the walk above, using the importing file's
  location for an imported rule.
- The diff breaks it in a way you can point to by file and line.

Say what the rule requires, what the diff does instead, and what the code must do.

## What not to report

- A rule you infer from the code's style but cannot quote from an instruction file.
- A rule the code explicitly silences at that site, such as a lint-ignore comment
  that the instruction file allows.
- Pre-existing violations in unchanged lines.
- A rule whose scope excludes the file, however similar the file looks.

Instruction files also carry facts: a port registry, a required command, a listed
package, a stated version. When the diff changes such a fact, check that the
instruction file and any doc it points at were updated in the same change, and report
the one that was not.

Do not stop after finding one issue; check every changed file against every rule that
applies to it.

## Report

One finding per broken rule per changed file, at the `path:line` in the diff that breaks
it. Severity follows the rule's own weight: high when it guards safety, access, data, or
a hard constraint the file marks as such; medium for a required command, structure, or
process; low for naming and style. Quote the rule with its file and line, name the
importing file when it was reached by import, and say what the code must do.
