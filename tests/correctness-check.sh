#!/usr/bin/env bash
# Behavioral check for the code-review-correctness skill. Builds a throwaway repository
# per scenario from the fixture writers, asks Codex to apply the skill to the second
# commit, and asserts the findings by their structured fields: how many there are, which
# line each cites, the enumerated kind and subject, and the numbers the model gives for
# what the code does. Runs two scenarios, one model call each:
#
#   pagination  eval 1: a planted off-by-one, a pre-existing bug in an unchanged file,
#               and an unused import the repository's linter already flags
#   intent      eval 2: a retry that matches the description, plus a changed default and
#               a dropped Authorization header that the description denies
#
#   tests/correctness-check.sh [--self-test] [path/to/SKILL.md]
#
# --self-test makes no model call. It replays the assertions against each scenario's
# control, observed from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at
# effort high per ~/.codex/config.toml; the run was ephemeral, so no rollout confirms them.
# The control must pass, and one mutation per fact a predicate reads, generated from that
# control by moving that fact alone outside what the predicate accepts and named
# <predicate-id>.json or <predicate-id>.<fact>.json, which self_test reads up to the first
# dot, must fail with its predicate's id; a predicate that stopped reading one of its facts
# would leave that fact's mutation passing. Needs the codex CLI signed in otherwise. stdin
# is closed on the codex call because codex exec waits on it when run from a pipe.
#
# Predicates, one printed line each:
#
#   pagination
#     one-finding     exactly one finding
#     anchor          it cites the pages line or the guard line
#     demo-drops      its demonstration drops a final partial page: the item count is not
#                     a multiple of the size, and a page that should hold items is empty
#     kind-defect     it is a defect, not an intent mismatch
#     no-legacy       no finding is located in the unchanged app/legacy.py
#     no-util         no finding is located in app/util.py, whose unused import ruff flags
#     coverage        two files changed, two reviewed, none skipped
#   intent
#     header-finding  an auth_header intent mismatch on the new headers lines in _head, at
#                     high severity; its behavior_change is printed for the reader, not
#                     asserted, because every run words that one differently while the
#                     enumerated fields and the line stay put
#     timeout-finding a timeout intent mismatch on the default line, 30 before, 10 after
#     no-retry-defect the retry the description asks for is not reported as a defect
#
# The dropped header is both a departure from the description and a defect, so the intent
# schema says intent_mismatch wins when both apply; without that the kind field records
# which of two true statements the model weighed first and the predicate tests nothing.
#
# Exit codes: 0 every predicate held, 1 a predicate failed, 2 the check could not run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
. "$here/fixtures/eval1.sh"
. "$here/fixtures/eval2.sh"

self_test_mode=0
[ "${1:-}" = "--self-test" ] && { self_test_mode=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review-correctness/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }

make_tmp

# build <name> <base writer> <change writer> <base message> <change message>. The writers
# only write files, so the two commits and their order live here.
build() {
  local dir=$fixture/$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email check@example.invalid
  git -C "$dir" config user.name check
  "$2" "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$4"
  "$3" "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$5"
}

# The fixtures are built before the self-test so both modes read the same anchors, taken
# from the files themselves rather than written down here.
build pagination write_eval1_base write_eval1_change "list endpoint" "paginate the list endpoint"
build intent write_eval2_base write_eval2_change "upload client" "add a retry to the upload client"
eval1_anchors "$fixture/pagination" > "$out/anchors-pagination.txt"
eval2_anchors "$fixture/intent" > "$out/anchors-intent.txt"

# The predicates and the mutations read the same anchor file, so a mutation is derived
# from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

LEGACY = "app/legacy.py"          # the unchanged pre-existing bug
UTIL = "app/util.py"              # the unused import ruff.toml already selects

SPAN = re.compile(r"^(.*?)(?::(\d+)(?:-(\d+))?)?$")


def span(where):
    """`path:line`, `path:first-last` or a bare path -> (path, first, last)."""
    path, first, last = SPAN.match(where.strip().lstrip("./")).groups()
    if first is None:
        return path, None, None
    return path, int(first), int(last or first)


def on(where, path):
    """True when a location names that file, however the model spelled the prefix."""
    named = span(where)[0]
    return named == path or named.endswith("/" + path)


def covers(where, accepted):
    """True when a location names a line of one of the accepted `path:line` anchors."""
    _, first, last = span(where)
    if first is None:
        return False
    return any(on(where, span(a)[0]) and first <= span(a)[1] <= last for a in accepted)


def cites(finding, accepted):
    return any(covers(where, accepted) for where in finding["locations"])


def anchors(path):
    found = {}
    for line in open(path):
        if line.strip():
            name, where = line.strip().split("=", 1)
            found.setdefault(name, []).append(where)
    return found


class Report:
    def __init__(self):
        self.bad = 0

    def __call__(self, ok, pid, msg):
        self.bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")


def writer(dest, made):
    def write(name, doc):
        json.dump(doc, open(os.path.join(dest, name + ".json"), "w"), indent=2)
        made.append(name)
    return write


def target(doc, accepted):
    """The finding on the pagination lines, or the first one, so a location moved off them
    fails the anchor predicate alone and leaves the others reading the same finding."""
    findings = doc["findings"]
    return next((f for f in findings if cites(f, accepted)), findings[0] if findings else None)


def setting(field, value):
    """A break that puts one value the fact rejects in the object the fact reads."""
    return lambda obj: obj.update({field: value})


def rephrase(half, text):
    """A break that drops the number a fact reads from one half of behavior_change."""
    return lambda f: f["behavior_change"].update({half: text})


def pagination_facts(anchor):
    """predicate id -> the objects the predicate reads, the fact whose mutation keeps the
    plain file name, and the facts one of those objects must hold: a key, the wording, the
    test, and the break one mutation applies to prove the test is still read."""
    accepted = anchor["pages"] + anchor["guard"]
    return {
        "demo-drops": (lambda doc: [f["demonstration"] for f in [target(doc, accepted)] if f],
                       "partial", [
            ("partial", "an item count that is not a whole number of pages",
             lambda d: d["size"] > 0 and d["items_count"] % d["size"] != 0,
             lambda d: d.update(items_count=d["size"] * 2)),
            ("expected", "a page that should hold items",
             lambda d: d["expected_count"] > 0, setting("expected_count", 0)),
            ("actual", "nothing returned for it",
             lambda d: d["actual_count"] == 0,
             lambda d: d.update(actual_count=d["expected_count"])),
        ]),
        "coverage": (lambda doc: [doc["coverage"]], "changed", [
            ("changed", "2 files changed", lambda c: c["changed"] == 2, setting("changed", 1)),
            ("reviewed", "2 reviewed", lambda c: c["reviewed"] == 2, setting("reviewed", 1)),
            ("skipped", "none skipped", lambda c: not c["skipped"],
             setting("skipped", [{"file": UTIL, "reason": "only an import changed"}])),
        ]),
    }


def intent_facts(anchor):
    """The same table for the intent scenario. behavior_change is asserted for the timeout
    finding, whose halves carry the two defaults; for the header finding it is printed for
    the reader and not asserted, because every run words that one differently."""
    return {
        "header-finding": (lambda doc: doc["findings"], "severity", [
            ("severity", "severity high",
             lambda f: f["severity"] == "high", setting("severity", "medium")),
            ("subject", "subject auth_header",
             lambda f: f["subject"] == "auth_header", setting("subject", "other")),
            ("kind", "kind intent_mismatch",
             lambda f: f["kind"] == "intent_mismatch", setting("kind", "defect")),
            ("location", f"a location on {' or '.join(anchor['head_headers'])}",
             lambda f: cites(f, anchor["head_headers"]),
             setting("locations", list(anchor["timeout_default"]))),
        ]),
        "timeout-finding": (lambda doc: doc["findings"], "subject", [
            ("subject", "subject timeout",
             lambda f: f["subject"] == "timeout", setting("subject", "other")),
            ("kind", "kind intent_mismatch",
             lambda f: f["kind"] == "intent_mismatch", setting("kind", "defect")),
            ("location", f"a location on {' or '.join(anchor['timeout_default'])}",
             lambda f: cites(f, anchor["timeout_default"]),
             setting("locations", list(anchor["head_headers"]))),
            ("before", "30 before",
             lambda f: "30" in f["behavior_change"]["before"],
             rephrase("before", "callers waited the old default")),
            ("after", "10 after",
             lambda f: "10" in f["behavior_change"]["after"],
             rephrase("after", "callers wait less")),
        ]),
    }


def report_facts(report, table, pid, doc, lead):
    """One predicate line from a fact table: it holds when an object the predicate reads
    holds every fact, and on failure names what the closest object lacked."""
    pick, _, facts = table[pid]
    missed = min(([w for _, w, holds, _ in facts if not holds(o)] for o in pick(doc)),
                 key=len, default=None)
    report(missed == [], pid, lead + ", ".join(w for _, w, _, _ in facts)
           + ("" if missed == [] else "; nothing to check" if missed is None
              else "; the closest lacks " + ", ".join(missed)))


def mutate_facts(control, table, write):
    """One file per fact, each the control with that fact alone moved outside what the
    predicate accepts, on every object the predicate would otherwise accept."""
    for pid, (pick, plain, facts) in table.items():
        for key, _, _, break_it in facts:
            doc = copy.deepcopy(control)
            good = [o for o in pick(doc) if all(holds(o) for _, _, holds, _ in facts)]
            if not good:
                raise ValueError(f"control holds nothing that {pid} accepts")
            for obj in good:
                break_it(obj)
            write(pid if key == plain else f"{pid}.{key}", doc)


def pagination(doc, anchor):
    findings = doc["findings"]
    accepted = anchor["pages"] + anchor["guard"]
    table = pagination_facts(anchor)
    report = Report()
    for f in findings:
        print(f"  finding: {' '.join(f['locations'])} {f['severity']}/{f['kind']}: {f['claim'][:70]}")
        print(f"    demonstration: {f['demonstration']}")
    for note in doc["notes"]:
        print(f"  note: {note[:70]}")
    print(f"  coverage: {doc['coverage']}")

    hit = target(doc, accepted)
    report(len(findings) == 1, "one-finding", f"exactly one finding ({len(findings)} returned)")
    report(hit is not None and cites(hit, accepted), "anchor",
           f"the finding cites {' or '.join(accepted)}")
    report_facts(report, table, "demo-drops", doc,
                 "the demonstration drops a final partial page: ")
    report(hit is not None and hit["kind"] == "defect", "kind-defect",
           "the finding is a defect, not an intent mismatch")
    for path, pid in ((LEGACY, "no-legacy"), (UTIL, "no-util")):
        report(not [w for f in findings for w in f["locations"] if on(w, path)], pid,
               f"no finding is located in {path}")
    report_facts(report, table, "coverage", doc, "coverage reports ")
    return 1 if report.bad else 0


def intent(doc, anchor):
    findings = doc["findings"]
    table = intent_facts(anchor)
    report = Report()
    for f in findings:
        print(f"  finding: {' '.join(f['locations'])} {f['severity']}/{f['kind']}/{f['subject']}: "
              f"{f['claim'][:70]}")
        print(f"    before: {f['behavior_change']['before'][:72]}")
        print(f"    after:  {f['behavior_change']['after'][:72]}")

    report_facts(report, table, "header-finding", doc,
                 "a finding that _head lost the Authorization header, with ")
    report_facts(report, table, "timeout-finding", doc,
                 "a finding on the changed default timeout, with ")
    report(not [f for f in findings if f["subject"] == "retry" and f["kind"] == "defect"],
           "no-retry-defect", "the retry itself is not reported as a defect")
    return 1 if report.bad else 0


def mutate_pagination(control, anchor, dest):
    """One file per fact a predicate reads, the control with that fact alone rejected."""
    accepted = anchor["pages"] + anchor["guard"]
    made = []
    write = writer(dest, made)

    def hit(doc):
        f = target(doc, accepted)
        if f is None or not cites(f, accepted):
            raise ValueError(f"control has no finding on {accepted}")
        return f

    doc = copy.deepcopy(control)  # the same defect reported twice
    doc["findings"].append(copy.deepcopy(hit(doc)))
    write("one-finding", doc)

    doc = copy.deepcopy(control)  # a line of the same file that the change did not add
    hit(doc)["locations"] = list(anchor["size_guard"])
    write("anchor", doc)

    doc = copy.deepcopy(control)  # a defect reported as a departure from the commit message
    hit(doc)["kind"] = "intent_mismatch"
    write("kind-defect", doc)

    doc = copy.deepcopy(control)  # the unchanged pre-existing bug cited as a location
    hit(doc)["locations"].append(LEGACY + ":3")
    write("no-legacy", doc)

    doc = copy.deepcopy(control)  # the import the repository's linter already catches
    hit(doc)["locations"].append(UTIL + ":1")
    write("no-util", doc)

    mutate_facts(control, pagination_facts(anchor), write)
    print(f"  mutations: {', '.join(made)}")
    return 0


def mutate_intent(control, anchor, dest):
    """One file per fact a predicate reads, the control with that fact alone rejected."""
    made = []
    write = writer(dest, made)

    doc = copy.deepcopy(control)  # the retry the description asks for called a defect
    doc["findings"].append({
        "locations": list(anchor["retry_start"]),
        "severity": "medium",
        "kind": "defect",
        "subject": "retry",
        "claim": "the retry loop retries a failed request",
        "evidence": "the loop runs the request up to three times",
        "behavior_change": {"before": "one attempt", "after": "three attempts"},
        "fix": "do not retry",
    })
    write("no-retry-defect", doc)

    mutate_facts(control, intent_facts(anchor), write)
    print(f"  mutations: {', '.join(made)}")
    return 0


CHECK = {"pagination": pagination, "intent": intent}
MUTATE = {"pagination": mutate_pagination, "intent": mutate_intent}


def main(argv):
    mode, doc, scenario, anchor = argv[0], json.load(open(argv[1])), argv[2], anchors(argv[3])
    if mode == "check":
        return CHECK[scenario](doc, anchor)
    if mode == "mutate":
        return MUTATE[scenario](doc, anchor, argv[4])
    raise ValueError(f"unknown mode {mode}")


try:
    code = main(sys.argv[1:])
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
    code = 2
sys.exit(code)
PY

# assert <output.json> <scenario>. A location may be `path`, `path:line` or `path:a-b`;
# it satisfies an anchor only when it names a line the anchor covers.
assert() {
  python3 "$out/predicates.py" check "$1" "$2" "$out/anchors-$2.txt"
}

# self_test_scenario <scenario>. Derives the mutations from the scenario's control, then
# replays the assertions over both.
self_test_scenario() {
  local name=$1
  local dir=$out/mutations-$name
  mkdir -p "$dir"
  echo "== self-test: $name"
  python3 "$out/predicates.py" mutate "$out/control-$name.json" "$name" "$out/anchors-$name.txt" "$dir"
  self_test assert "$out/control-$name.json" "$dir" "$name"
}

if [ "$self_test_mode" = 1 ]; then
  # Observed live outputs. If a later run disagrees with one, report the difference
  # rather than editing the control to match it.
  cat > "$out/control-pagination.json" <<'EOT'
{"findings":[{"locations":["app/list.py:8","app/list.py:9","app/list.py:10"],"severity":"medium","kind":"defect","claim":"1. Pagination drops the final partial page, including the first page when the list is smaller than the page size.","evidence":"The page count uses floor division, so the subsequent guard rejects a valid page containing the remainder. Executing list_items with 11 items, size 10, and page 1 returns 0 items instead of 1. With 3 items, size 10, and page 0, it returns 0 instead of 3.","fix":"Count partial pages using ceiling division, or remove the page-count guard and let the slice return the remaining items.","demonstration":{"items_count":11,"size":10,"page":1,"expected_count":1,"actual_count":0}}],"coverage":{"changed":2,"reviewed":2,"skipped":[]},"notes":["Reviewed both changed files against the commit's stated intent: paginate the list endpoint. No separate intent mismatch found.","Executed four focused checks: both partial-page cases reproduced the defect; a full final page and empty input returned the expected counts. No test suite was present; the configured linter was not run.","The unused import in app/util.py is covered by the repository's configured F401 lint rule and is excluded under the skill's instructions.","Unchanged pre-existing defect: app/legacy.py:3 uses lo as the upper bound in clamp, causing it to always return lo for ordinary numeric inputs.","Review was read-only; no files were changed."]}
EOT
  cat > "$out/control-intent.json" <<'EOT'
{"findings":[{"locations":["client/upload.py:35","client/upload.py:36"],"severity":"high","kind":"intent_mismatch","subject":"auth_header","claim":"1. HEAD requests lose authentication, breaking the endpoint despite the claim of no caller behavior change.","evidence":"The change replaces _headers() with a dictionary containing only Content-Type. _headers() supplies Authorization, and the module states that every service endpoint rejects requests without it. A mocked before/after check confirmed that HEAD requests previously included the bearer header and now omit it.","behavior_change":{"before":"_head(path) sends the configured bearer token and can succeed against the authenticated service.","after":"_head(path) sends no Authorization header, so the service rejects the request."},"fix":"Keep using _headers() when constructing the HEAD request so it retains authentication."},{"locations":["client/upload.py:21"],"severity":"medium","kind":"intent_mismatch","subject":"timeout","claim":"2. Reducing the default timeout changes caller behavior beyond the described retry addition.","evidence":"The upload signature changes timeout=30 to timeout=10, and that value is passed unchanged to urlopen on each attempt. A mocked before/after check confirmed that callers omitting timeout now pass 10 seconds instead of 30. Repeating a request does not preserve the original per-attempt timeout.","behavior_change":{"before":"A caller omitting timeout allows each network operation up to 30 seconds before timing out.","after":"Each attempt times out after 10 seconds; a service consistently requiring more than 10 but fewer than 30 seconds can fail on every retry where the original request succeeded."},"fix":"Preserve timeout=30 as the default while adding retries."}]}
EOT
  st1=0; self_test_scenario pagination || st1=$?
  st2=0; self_test_scenario intent || st2=$?
  [ "$st1" -gt "$st2" ] && exit "$st1"
  exit "$st2"
fi

cat > "$out/schema-pagination.json" <<'EOT'
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
            "description": "every line the finding is about, each as path:line",
            "items": { "type": "string" }
          },
          "severity": { "type": "string", "enum": ["high", "medium", "low"] },
          "kind": {
            "type": "string",
            "description": "defect: the code is wrong. intent_mismatch: it departs from the commit message.",
            "enum": ["defect", "intent_mismatch"]
          },
          "claim": { "type": "string", "description": "what is wrong" },
          "evidence": { "type": "string", "description": "the fact in the code that shows it" },
          "fix": { "type": "string", "description": "what the code must do" },
          "demonstration": {
            "type": "object",
            "description": "one input that shows the defect, with the counts the code produces",
            "properties": {
              "items_count": { "type": "integer", "description": "how many items are passed in" },
              "size": { "type": "integer", "description": "the page size passed in" },
              "page": { "type": "integer", "description": "the page number passed in" },
              "expected_count": { "type": "integer", "description": "items that page should return" },
              "actual_count": { "type": "integer", "description": "items the code returns" }
            },
            "required": ["items_count", "size", "page", "expected_count", "actual_count"],
            "additionalProperties": false
          }
        },
        "required": ["locations", "severity", "kind", "claim", "evidence", "fix", "demonstration"],
        "additionalProperties": false
      }
    },
    "coverage": {
      "type": "object",
      "properties": {
        "changed": { "type": "integer", "description": "files the change touches" },
        "reviewed": { "type": "integer" },
        "skipped": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "file": { "type": "string" },
              "reason": { "type": "string" }
            },
            "required": ["file", "reason"],
            "additionalProperties": false
          }
        }
      },
      "required": ["changed", "reviewed", "skipped"],
      "additionalProperties": false
    },
    "notes": {
      "type": "array",
      "description": "anything reported outside the findings, one line each",
      "items": { "type": "string" }
    }
  },
  "required": ["findings", "coverage", "notes"],
  "additionalProperties": false
}
EOT

cat > "$out/schema-intent.json" <<'EOT'
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
            "description": "every line the finding is about, each as path:line",
            "items": { "type": "string" }
          },
          "severity": { "type": "string", "enum": ["high", "medium", "low"] },
          "kind": {
            "type": "string",
            "description": "intent_mismatch: the change does something the description does not say it does, whether or not the code is also wrong. defect: the code is wrong and the description does not speak to it.",
            "enum": ["defect", "intent_mismatch"]
          },
          "subject": {
            "type": "string",
            "description": "the part of the change the finding is about",
            "enum": ["retry", "timeout", "auth_header", "other"]
          },
          "claim": { "type": "string", "description": "what is wrong" },
          "evidence": { "type": "string", "description": "the fact in the code that shows it" },
          "behavior_change": {
            "type": "object",
            "description": "what a caller saw before the change and sees after it",
            "properties": {
              "before": { "type": "string" },
              "after": { "type": "string" }
            },
            "required": ["before", "after"],
            "additionalProperties": false
          },
          "fix": { "type": "string", "description": "what the code must do" }
        },
        "required": ["locations", "severity", "kind", "subject", "claim", "evidence",
                     "behavior_change", "fix"],
        "additionalProperties": false
      }
    }
  },
  "required": ["findings"],
  "additionalProperties": false
}
EOT

# run <scenario> <prompt>
run() {
  local name=$1 prompt=$2
  echo "== scenario: $name"
  codex_json_run "$fixture/$name" "$(dirname "$skill")" "$out/schema-$name.json" \
    "$out/$name.json" "$out/$name.log" "$prompt" --ephemeral || return 2
  assert "$out/$name.json" "$name"
}

presentation="Presentation only: return the report's content as JSON matching the schema instead of Markdown; every other instruction in the skill stands."
preamble="You are the review subagent for the skill at $skill. Read that file and follow it exactly."

rc1=0
run pagination "$preamble Review the diff of HEAD against HEAD~1. The commit message says: 'paginate the list endpoint'. $presentation" || rc1=$?
rc2=0
run intent "$preamble The change under review is the diff of the base commit HEAD~1 against the head commit HEAD in this repository. Its description reads: 'Add a retry to the upload client. No behavior change for callers.' $presentation" || rc2=$?
[ "$rc1" -gt "$rc2" ] && exit "$rc1"
exit "$rc2"
