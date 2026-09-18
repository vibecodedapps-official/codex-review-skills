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
  finding. The report numbers the confirmed findings with a file path and line, lists
  unconfirmed and refuted ones separately, and includes the coverage totals. The review
  changes no file or git state and posts nothing to the pull request host unless asked.
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

`evals/evals.json` holds the draft test prompts for each skill, with the fixture each
needs and the output expected. Only the guidelines case is scripted so far:

```sh
tests/guidelines-check.sh
```

Builds a throwaway repository whose instruction files exercise the guidelines skill's
resolution rules (an `AGENTS.override.md` that withdraws a sibling rule, a `CLAUDE.md`
that counts only when configured as a fallback, a deeper file overriding the root, and
a root file referencing `docs/review.md` for changes under `src/`), runs `codex exec`
with the skill against its second commit in two scenarios (fallback configured, and no
fallback configured), and asserts which of the four changed files receive a finding,
which rule file and rule each cites with the rule text quoted, and that every cited line
exists. Two model calls per run, about a minute. Pass a different `SKILL.md` path to
check another version. `--self-test` runs the assertions alone against canned findings,
including forged sets that must fail (wrong rules and an unchanged file, a rule id with
inverted text, a line that does not exist), with no model call.

`.github/workflows/check.yml` runs the self-test, a parse of the JSON manifests, and
`bash -n` on the script on every push to `main` and every pull request. It does not
call a model, so it checks the assertions, not the skills.

## License

[MIT](LICENSE), copyright 2026 vibecodedapps.net.
