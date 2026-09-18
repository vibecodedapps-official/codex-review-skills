# codex-review-skills

A Codex plugin that gives `$code-review` a real review to run: an orchestrator that
runs one subagent per sub-review skill and then verifies the findings, and sub-reviews
for correctness and coverage, compliance with the repository's own instruction files,
test authoring, breaking changes, and change size.

Codex's built-in `/review` is a single pass. The skills here describe what to check by
the kind of surface a change touches (a request contract, a schema, a test suite, a
configuration file, a pipeline) rather than by language or framework, so one install
works across stacks and the reviewer applies only the parts the diff touches.

## Install

```sh
codex plugin marketplace add vibecodedapps-official/codex-review-skills
codex plugin add codex-review-skills@vibecodedapps
```

Start a new Codex session, then:

```text
$code-review
```

To update after the repository changes:

```sh
codex plugin marketplace upgrade
codex plugin add codex-review-skills@vibecodedapps
```

To work on a local clone instead, point the marketplace at the checkout:

```sh
codex plugin marketplace add /path/to/codex-review-skills
codex plugin add codex-review-skills@vibecodedapps
```

Codex lists plugin skills under the plugin name, as `codex-review-skills:code-review`.

## Skills

- `code-review`: the orchestrator. Works out the target (pull request, branch, commit,
  or working tree) as one fixed comparison, reads the stated intent, runs one
  fresh-context subagent per other `code-review-*` skill at xhigh reasoning (or the
  level named with the request), then has one more subagent try to refute every
  finding. A spawn Codex refuses for its concurrency cap is retried, never replaced by
  work in the main thread. The report numbers the confirmed findings with a file path
  and line, lists unconfirmed and refuted ones separately, and includes the coverage
  totals. The review changes no file or git state and posts nothing to the pull request
  host unless asked.
- `code-review-correctness`: the general pass. A checklist of every changed file ending
  reviewed or skipped with a reason, added-code-only focus, intent read from the pull
  request first, each finding confirmed in the code before it is reported, correctness
  and security checks, severity definitions, a do-not-report list, and language and
  file notes applied only where the diff touches them.
- `code-review-guidelines`: audits the diff against the repository's own instruction
  files (`AGENTS.md`, `AGENTS.override.md`, and configured fallbacks such as
  `CLAUDE.md`), resolved the way Codex resolves them and scoped by path, and reports a
  violation only with the exact rule quoted. Also flags a fact an instruction file
  states that the diff changed without updating the file. To add review rules for one
  repository, state them in its `AGENTS.md`, or in a file that `AGENTS.md` references,
  in the directory they apply to; this pass quotes and enforces them.
- `code-review-testing`: a behavior change needs a failing check in the suite the
  repository already has, found from its own configuration rather than assumed.
  Contract changes get an integration test, data changes run against a real store,
  transformations get a fixture with the exact expected output and a rerun, and
  test-only hooks in production code are findings.
- `code-review-breaking-changes`: every surface another party depends on: request and
  response contracts, schema and access policies, data transformations, runtime and
  gateway configuration, environment and configuration, pipelines and deploys, shared
  packages, command-line interfaces, stored user data, extension manifests, and the
  logs and metrics that alarms match on.
- `code-review-change-size`: flags a change over 800 changed lines (500 for complex
  logic), not counting generated files (by `.gitattributes`, header, or build suffix),
  lockfiles, renames, or whitespace-only rewrites, and names the smallest stage to
  land first.

After changing a skill, bump `version` in
`plugins/codex-review-skills/.codex-plugin/plugin.json` so installed clients pick it up.

## Checks

`evals/evals.json` holds a test prompt per skill, with the fixture it needs, the
output expected, the script that runs it, and that script's assertions. Each script
builds a throwaway repository, runs `codex exec` with the skill under test against it,
and prints one `PASS:` or `FAIL:` line per predicate:

```sh
tests/correctness-check.sh
tests/testing-check.sh
tests/breaking-changes-check.sh
tests/guidelines-check.sh
tests/code-review-check.sh
tests/verifier-check.sh
```

`tests/correctness-check.sh` builds one repository per scenario and makes two model
calls: that the pagination change draws exactly one finding, on the line that counts
the pages, carrying the item count and page that show the dropped final page, and that
neither the unchanged file's own bug nor the import the linter config flags is
reported; and that the upload client's changed default and dropped authorization
header are reported as intent mismatches while the retry the description asks for is
not reported as a defect.

`tests/testing-check.sh` builds a repository with a pytest suite whose records come
from `tests/fixtures`, leaves the change uncommitted, and makes one model call: that
the changed key match is reported with all four obligations a field-mapping test owes,
named against pytest and the fixture data the suite already loads, and that the added
test is reported as asserting a mock call and passing with the change reverted.

`tests/breaking-changes-check.sh` builds a two-commit repository and makes one model
call: that the renamed response field is a high finding naming the worker that indexes
it, the `KeyError` that follows and the missing migration path, that the variable read
from the environment at import is a high finding naming the deploy workflow that does
not supply it, and that the version bump alone stays low.

`tests/guidelines-check.sh` builds a repository whose instruction files exercise the
resolution rules (an `AGENTS.override.md` that withdraws a sibling rule, a `CLAUDE.md`
that counts only when configured as a fallback, a deeper file overriding the root, and
a root file referencing `docs/review.md` for changes under `src/`) and makes two model
calls, one with the fallback configured and one without: which of the four changed
files receive a finding in each, which rule file and rule each cites with the rule
text quoted, and that every cited line exists.

`tests/code-review-check.sh` builds one repository whose branch carries the pagination
change and the breaking change on disjoint paths, and makes one model call, which fans
out to a subagent per sub-review and one more to verify them: that all three planted
defects are confirmed once each whatever category or line they are filed under, that
the pre-existing bug is left alone, that coverage names every changed file, that a
refuted finding points at a line that exists, that the run left the repository's refs,
HEAD, tree, stashes and status as it found them, and that the session rollout shows at
least six spawns with a fresh context at xhigh, a child thread for each of the five
sub-reviews and for the verification pass, and every one of them running at xhigh.
Codex caps how many agents run at once and refuses a spawn over that cap, which the
orchestrator answers by waiting and spawning the pass again, so the rollout can hold
more spawn calls than child threads; the passes are counted by their child threads.
About eight minutes.

`tests/verifier-check.sh` builds the pagination repository at its change commit and
makes one model call, handing the verification pass three candidates: that the real
defect is confirmed, that the claim the guard above it denies is refuted at that line,
and that the claim resting on a caller the repository does not have is left
unconfirmed with what would settle it.

Each script takes a different `SKILL.md` path to check another version. `--self-test`
runs the assertions alone, with no model call, against the control (the output a live
run produced, stored in the script with the date, the CLI version, and the model and
effort that run used) and against one mutation per fact a predicate reads, each the
control with that one fact moved outside what the predicate accepts; every mutation
must fail, and fail on its own predicate, so a fact that stopped being read is caught.
`tests/run-self-tests.sh` runs every check that way, and `CHECK_KEEP_TMP=1` keeps the
throwaway repository and the model's output, which is how a control is recorded.

`.github/workflows/check.yml` runs `bash -n` over the scripts and the fixture writers,
a parse of the JSON manifests, and `tests/run-self-tests.sh` on every push to `main`
and every pull request. It does not call a model, so it checks the assertions, not the
skills.

Two things the checks leave uncovered. Every prompt asks for the report as JSON so its
fields can be asserted, so the Markdown the skills actually emit is never exercised.
And the spawn evidence in the orchestrator check is read from the Codex session
rollout under `~/.codex/sessions`, which is why that check alone runs without
`--ephemeral`; when no rollout for the run can be found it prints `spawn parameters:
unverified` and exits 3 rather than passing.

## License

[MIT](LICENSE), copyright 2026 vibecodedapps.net.
