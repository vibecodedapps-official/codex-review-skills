#!/usr/bin/env bash
# Behavioral check for the code-review-testing skill. Builds a throwaway repository with a
# pytest suite that reads its records from tests/fixtures, commits it, then applies the
# change without committing, so the review target is the working tree against HEAD as the
# eval's prompt says. One scenario, one model call:
#
#   dedupe  importer/dedupe.py matches a stored record on (email, source_id) rather than
#           email alone, and the only test added asserts that a mock store was called
#
#   tests/testing-check.sh [--self-test] [path/to/SKILL.md]
#
# --self-test makes no model call. It replays the assertions against the control, observed
# from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at effort high per
# ~/.codex/config.toml; the run was ephemeral, so no rollout confirms them. The control
# must pass, and one mutation per fact a predicate reads, generated from that control by
# moving that fact alone outside what the predicate accepts and named <predicate-id>.json
# or <predicate-id>.<fact>.json, must fail with its own predicate id. Needs
# the codex CLI signed in otherwise. stdin is closed on the codex call because codex exec
# waits on it when run from a pipe.
#
# tests/test_dedupe.py is recorded with `git add -N`, so the added test reaches `git diff`
# instead of only `git status`; the change itself stays uncommitted.
#
# Predicates, one printed line each. They are located on the files, not counted, so one
# finding carrying both locations is as acceptable as two findings:
#   dedupe-finding      a finding locates the changed key match in importer/dedupe.py
#   dedupe-obligations  that finding states all four obligations the skill asks of a
#                       field-mapping test: representative record, exact expected output,
#                       existing target record, rerun
#   dedupe-location     that finding names pytest as the runner, a test under tests/, and
#                       the fixture data the suite already loads, by any handle it has:
#                       tests/fixtures, tests/conftest.py, or the source_records fixture
#   mock-finding        a finding locates tests/test_dedupe.py and calls its assertion
#                       mock_only
#   mock-evidence       that finding reports passes_without_change, so the test is known to
#                       pass with the change reverted
#
# Exit codes: 0 every predicate held, 1 a predicate failed, 2 the check could not run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
. "$here/fixtures/eval3.sh"

self_test_mode=0
[ "${1:-}" = "--self-test" ] && { self_test_mode=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review-testing/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }

make_tmp

# The fixture is built before the self-test so both modes read the anchors from real files.
write_eval3_base "$fixture"
cd "$fixture"
git init -q
git config user.email check@example.invalid
git config user.name check
git add -A && git commit -q -m "import records, matching duplicates on email"

write_eval3_change "$fixture"
git add -N tests/test_dedupe.py
eval3_anchors "$fixture" > "$out/anchors.txt"

# The predicates and the mutations share one description of what a finding must carry, so
# a mutation is derived from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

DEDUPE = "importer/dedupe.py"          # the changed key match
MOCK_TEST = "tests/test_dedupe.py"     # the test that asserts a mock call only
UNCHANGED_TEST = "tests/test_import.py"  # a test the change leaves alone
OBLIGATIONS = ("representative_record", "exact_expected_output",
               "existing_target_record", "rerun")
RUNNER = re.compile(r"pytest", re.I)
# every handle the records the suite already loads go by: the directory, the conftest that
# reads it, and the fixture function the tests take
HANDLES = ("tests/fixtures", "tests/conftest.py", "source_records")

split = lambda p: re.match(r"^(.*?)(?::(\d+)(?:-\d+)?)?$", p.strip().lstrip("./")).groups()
loc = lambda p: split(p)[0]
paths = lambda f: [loc(p) for p in f["locations"]]


def anchors(path):
    return dict(l.split("=", 1) for l in open(path).read().splitlines() if l.strip())


def obligations(f):
    return {k: str(f["obligations"].get(k, "")).strip() for k in OBLIGATIONS}


def told(f):
    """The fields that may name the existing fixture data."""
    return [f["test_location"], f["suite"], *obligations(f).values()]


def unname(text):
    """The same sentence with every handle on the existing fixture data taken out."""
    for h in HANDLES:
        text = text.replace(h, "a dict built in the test")
    return text


def break_handles(f):
    f["test_location"], f["suite"] = unname(f["test_location"]), unname(f["suite"])
    f["obligations"] = {k: unname(str(v)) for k, v in f["obligations"].items()}


def break_mock_location(f):
    f["locations"] = [p for p in f["locations"] if loc(p) != MOCK_TEST] or [UNCHANGED_TEST]


def stated(key):
    return lambda f: bool(obligations(f)[key])


def blank(key):
    def broken(f):
        f["obligations"][key] = ""
    return broken


# Each predicate that reads more than one fact, as the file its findings sit on and one
# entry per fact: its key, whether a finding holds it, and how to break that one fact. The
# predicate is the conjunction, and every fact gets its own mutation, so a fact that stopped
# being read is caught. The key named first keeps the plain <predicate-id>.json file; the
# rest are <predicate-id>.<key>.json.
FACTS = {
    "dedupe-location": (DEDUPE, [
        ("handles", lambda f: any(h in v for v in told(f) for h in HANDLES), break_handles),
        ("runner", lambda f: bool(RUNNER.search(f["runner"])),
         lambda f: f.update(runner="unittest")),
        # outside tests/, with the handles left in place, so only the prefix breaks
        ("test_location", lambda f: loc(f["test_location"]).startswith("tests/"),
         lambda f: f.update(test_location="importer/test_dedupe.py")),
    ]),
    "dedupe-obligations": (DEDUPE, [("rerun", stated("rerun"), blank("rerun"))]
                           + [(k, stated(k), blank(k)) for k in OBLIGATIONS if k != "rerun"]),
    "mock-finding": (MOCK_TEST, [
        ("wrong_assertion", lambda f: f["wrong_assertion"] == "mock_only",
         lambda f: f.update(wrong_assertion="none")),
        # off the added test, with mock_only kept, so only the location breaks
        ("location", lambda f: MOCK_TEST in paths(f), break_mock_location),
    ]),
}


def holds(pid, f):
    return all(fact(f) for _, fact, _ in FACTS[pid][1])


def check(doc, anchor_file):
    findings = doc["findings"]
    anchor = anchors(anchor_file)
    bad = 0

    def report(ok, pid, msg):
        nonlocal bad
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")

    for f in findings:
        print(f"  finding: {', '.join(f['locations'])} severity={f['severity']} "
              f"wrong_assertion={f['wrong_assertion']} "
              f"passes_without_change={f['passes_without_change']} suite={f['suite']!r} "
              f"runner={f['runner']!r} test_location={f['test_location']!r}")
        print(f"    claim: {f['claim']}")
        print(f"    evidence: {f['evidence']}")
        print(f"    obligations: " + "; ".join(f"{k}={v!r}" for k, v in obligations(f).items()))
    cited = {p.strip().lstrip("./") for f in findings for p in f["locations"]}
    print("  anchors: " + ", ".join(f"{k}={v}{' cited' if v in cited else ''}"
                                    for k, v in sorted(anchor.items())))

    dedupe = [f for f in findings if DEDUPE in paths(f)]
    mock = [f for f in findings if holds("mock-finding", f)]
    report(bool(dedupe), "dedupe-finding", f"a finding locates the changed match in {DEDUPE}")
    report(any(holds("dedupe-obligations", f) for f in dedupe), "dedupe-obligations",
           "that finding states all four obligations: " + ", ".join(OBLIGATIONS))
    report(any(holds("dedupe-location", f) for f in dedupe), "dedupe-location",
           "that finding names pytest, a test under tests/, and the fixture data the suite "
           "already loads, by any of: " + ", ".join(HANDLES))
    report(bool(mock), "mock-finding",
           f"a finding locates {MOCK_TEST} with wrong_assertion mock_only")
    report(any(f["passes_without_change"] for f in mock), "mock-evidence",
           "that finding records the test as passing with the change reverted")
    return 1 if bad else 0


def mutate(control, anchor_file, dest):
    """One file per predicate, each the control with one value the predicate rejects."""
    anchor = anchors(anchor_file)
    made = []

    def targets(doc, path, **must):
        hits = [f for f in doc["findings"]
                if path in paths(f) and all(f[k] == v for k, v in must.items())]
        if not hits:
            raise ValueError(f"control has no finding on {path} with {must}")
        return hits

    def write(pid, doc):
        json.dump(doc, open(os.path.join(dest, pid + ".json"), "w"), indent=2)
        made.append(pid)

    doc = copy.deepcopy(control)  # the change is reported against a file it did not touch
    for f in targets(doc, DEDUPE):
        f["locations"] = [p for p in f["locations"] if loc(p) != DEDUPE] or [anchor["unchanged_test"]]
    write("dedupe-finding", doc)

    # One file per fact of each conjunction, breaking that fact alone on every finding the
    # predicate would otherwise accept, so no fact can stop being read unnoticed.
    for pid, (path, facts) in FACTS.items():
        for i, (key, _, break_it) in enumerate(facts):
            doc = copy.deepcopy(control)
            accepted = [f for f in targets(doc, path) if holds(pid, f)]
            if not accepted:
                raise ValueError(f"control has no finding on {path} that {pid} accepts")
            for f in accepted:
                break_it(f)
            write(pid if i == 0 else f"{pid}.{key}", doc)

    doc = copy.deepcopy(control)  # the mock-only test is reported as failing without the change
    for f in targets(doc, MOCK_TEST, wrong_assertion="mock_only"):
        f["passes_without_change"] = False
    write("mock-evidence", doc)

    print(f"  mutations: {', '.join(made)}")
    return 0


def main(argv):
    mode = argv[0]
    if mode == "check":
        return check(json.load(open(argv[1])), argv[2])
    if mode == "mutate":
        return mutate(json.load(open(argv[1])), argv[2], argv[3])
    raise ValueError(f"unknown mode {mode}")


try:
    code = main(sys.argv[1:])
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
    code = 2
sys.exit(code)
PY

# assert <findings.json>. A location may be `path` or `path:line`, and a finding counts
# for a file when any of its locations names that file.
assert() {
  python3 "$out/predicates.py" check "$1" "$out/anchors.txt"
}

if [ "$self_test_mode" = 1 ]; then
  # Observed live output. If a later run disagrees with it, report the difference rather
  # than editing the control to match it.
  cat > "$out/control.json" <<'EOT'
{
  "findings": [
    {
      "locations": [
        "importer/dedupe.py:8",
        "tests/test_dedupe.py:10"
      ],
      "severity": "high",
      "claim": "The duplicate-detection change has no regression check because the new test only asserts a store lookup and passes with the previous email-only matching logic.",
      "evidence": "The changed comparison requires both email and source_id to match, but test_find_existing_looks_up_the_store supplies no candidates, ignores the return value, and only calls assert_called_once(). The other tests cover normalization only. Direct execution of the new test passed against both the working-tree implementation and the HEAD implementation loaded in memory. The configured pytest suite could not run because Python reported 'No module named pytest'.",
      "suite": "The existing tests/ suite configured in pyproject.toml",
      "runner": "pytest",
      "test_location": "tests/test_dedupe.py",
      "obligations": {
        "representative_record": "Reuse source_records[0] from tests/conftest.py: {\"email\":\"ana@example.com\",\"source_id\":\"crm-1001\",\"name\":\"Ana Diaz\",\"signed_up\":\"2024-03-01\"}. Supply a candidate with the same email and source_id=\"crm-9999\", then a candidate with the exact matching key. Include explicit cases for null, empty-string, and legacy-sentinel source_id values.",
        "exact_expected_output": "With only the crm-9999 candidate, assert find_existing returns None. With that candidate followed by the crm-1001 target record, assert it returns the exact crm-1001 object and its complete unchanged contents. For null, empty-string, and sentinel cases, assert equal source_id values match and unequal values return None.",
        "existing_target_record": "{\"email\":\"ana@example.com\",\"source_id\":\"crm-1001\",\"name\":\"Ana locally edited\",\"signed_up\":\"2024-03-01\"}, preceded in the lookup results by a record with the same email and source_id=\"crm-9999\".",
        "rerun": "Repeat detection with the same source record and assert it returns the same existing target object, preserves its locally edited name and all other fields, and leaves the target records unchanged. This must preserve recognition of an existing record so a rerun does not duplicate or clobber it."
      },
      "wrong_assertion": "mock_only",
      "passes_without_change": true
    }
  ]
}
EOT
  mkdir -p "$out/mutations"
  echo "== self-test: dedupe"
  python3 "$out/predicates.py" mutate "$out/control.json" "$out/anchors.txt" "$out/mutations"
  rc=0
  self_test assert "$out/control.json" "$out/mutations" || rc=$?
  exit "$rc"
fi

cat > "$out/schema.json" <<'EOT'
{
  "type": "object",
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "locations": {
            "type": "array",
            "items": { "type": "string" },
            "description": "the changed code or test the finding is about, each as a repository-relative path:line"
          },
          "severity": { "type": "string", "enum": ["low", "medium", "high"] },
          "claim": { "type": "string", "description": "what is wrong, in one sentence" },
          "evidence": { "type": "string", "description": "what you read in the repository that shows it" },
          "suite": { "type": "string", "description": "the existing suite the check belongs in" },
          "runner": { "type": "string", "description": "the runner that suite already uses" },
          "test_location": { "type": "string", "description": "repository-relative path where the check belongs" },
          "obligations": {
            "type": "object",
            "description": "what the missing check must assert; each field is empty when this finding does not require it",
            "properties": {
              "representative_record": { "type": "string", "description": "the representative source record the check feeds in" },
              "exact_expected_output": { "type": "string", "description": "the exact output the check asserts" },
              "existing_target_record": { "type": "string", "description": "the record already in the target the check covers" },
              "rerun": { "type": "string", "description": "what a rerun must not do to that record" }
            },
            "required": ["representative_record", "exact_expected_output", "existing_target_record", "rerun"],
            "additionalProperties": false
          },
          "wrong_assertion": {
            "type": "string",
            "enum": ["none", "mock_only", "log_only", "implementation"],
            "description": "what an existing test asserts instead of behavior; none when the finding is not about a test's assertion"
          },
          "passes_without_change": {
            "type": "boolean",
            "description": "true when the test would still pass with the change under review reverted; false when the finding is not about an existing test"
          }
        },
        "required": ["locations", "severity", "claim", "evidence", "suite", "runner",
                     "test_location", "obligations", "wrong_assertion",
                     "passes_without_change"],
        "additionalProperties": false
      }
    }
  },
  "required": ["findings"],
  "additionalProperties": false
}
EOT

prompt="You are the review subagent for the skill at $skill. Read that file and follow it exactly. Review the working tree changes. I changed how duplicate records are detected during import. Presentation only: return the report's content as JSON matching the schema instead of Markdown; every other instruction in the skill stands."
echo "== scenario: dedupe"
codex_json_run "$fixture" "$(dirname "$skill")" "$out/schema.json" "$out/dedupe.json" \
  "$out/dedupe.log" "$prompt" --ephemeral || exit 2
assert "$out/dedupe.json"
