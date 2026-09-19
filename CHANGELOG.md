# Changelog

Notable changes to the plugin, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). `version` in
`plugins/codex-review-skills/.codex-plugin/plugin.json` matches the newest entry here.

## [0.3.0] - 2026-09-18

### Added

- `tests/report-check.sh`, recorded as eval 8: one model call acts at the orchestrator's
  Report step over five findings that already carry their verdicts, and the predicates
  read the Markdown it returns for the numbering and severity order of the confirmed
  findings, the locations they cite, the unconfirmed and refuted entries, the pass that
  was not run, the coverage totals, and any pass, model, or tool named where it should
  not be.
- A "How it works" section in the README, the fast path of running one sub-review on its
  own, and an invocation that names a reasoning level.
- This changelog and `tests/version.sh`, which compares the newest entry here with the
  manifest version and fails in CI when they disagree.

### Changed

- The orchestrator's Report section now says where a pass that was not run belongs:
  before the coverage totals, the one place a pass is named.

## [0.2.0] - 2026-09-18

### Added

- A verification subagent that tries to refute every merged finding before the report is
  written, returning confirmed, refuted, or unconfirmed with the line it read.
- A check script per eval. Each builds its fixture, runs `codex exec` against the skill
  under test with an output schema, and asserts predicates on the structured fields
  rather than on prose. Each carries the output of a live run as its control and one
  generated mutation per fact a predicate reads, and `--self-test` replays them with no
  model call, so a predicate that stops reading a fact is caught. CI runs the
  self-tests.
- The orchestrator check reads the spawn arguments and each child's reasoning effort
  from the Codex session rollout, since the `--json` stream does not carry them, and
  exits 3 when no rollout can be found rather than passing.

### Changed

- Every pass now starts as a fresh-context subagent with the comparison, the intent, and
  the user's constraints. Codex applies a reasoning override only to a subagent spawned
  without a full-history fork, so the orchestrator's xhigh setting was dropped silently
  and each pass inherited the orchestrator's reading of the diff.
- Subagents are named after their skills with underscores for the hyphens, because the
  spawn tool accepts only lowercase letters, digits, and underscores; a hyphenated name
  cost one refused call per run.

### Fixed

- A spawn refused for the concurrency cap is waited on and spawned again. The
  orchestrator had skipped the change-size pass and verified in its own thread; it now
  runs no pass itself and reports a pass it could not run.
- The guidelines check accepted a finding whose quoted rule inverted the real rule, and
  one anchored at a line that does not exist. It now matches a phrase from the rule file
  and checks that every cited line exists.

## [0.1.0] - 2026-09-18

### Added

- The `code-review` orchestrator, which fixes one comparison, fans out to every
  sub-review skill, and merges the findings in one format.
- Five sub-reviews: correctness and coverage, compliance with the repository's own
  instruction files, test authoring, breaking changes, and change size. They describe
  what to check by the kind of surface a change touches rather than by language or
  framework, so one install works across stacks.
- Instruction-file resolution in the guidelines pass the way Codex resolves it: one
  active file per directory, override before base, fallback names only when the
  configuration gives them, and imported rules scoped by the file that imported them.
- `tests/guidelines-check.sh`, which builds a fixture repository and runs the guidelines
  skill in a fallback and a no-fallback scenario.
