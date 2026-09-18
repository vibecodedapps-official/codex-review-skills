#!/usr/bin/env bash
# Behavioral check for the code-review-guidelines skill. Builds a throwaway repository
# whose instruction files exercise the resolution rules the skill states, asks Codex to
# apply the skill to the repository's second commit, and asserts which changed files
# receive a finding, which rule each cites with the rule text quoted, and that every
# cited line exists. Runs two scenarios, one model call each:
#
#   fallback     configuration names CLAUDE.md as a fallback instruction file
#   no-fallback  configuration names no fallback, so tools/CLAUDE.md states nothing
#
#   tests/guidelines-check.sh [--self-test] [path/to/SKILL.md]
#
# --self-test makes no model call. It replays the assertions against each scenario's
# control, observed from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at
# effort high per ~/.codex/config.toml; the run was ephemeral, so no rollout confirms them.
# The control must pass, as must the same control with every location as a bare path, and
# one mutation per predicate, generated from that control by changing one value to
# something the predicate must reject, must fail with its own predicate id. Needs the
# codex CLI signed in otherwise. stdin is closed on the codex call because codex exec
# waits on it when run from a pipe.
#
# Cases, each a changed Python file:
#   src/app.py         calls print(); banned by docs/review.md, which the root AGENTS.md
#                      references for the whole repository      -> finding, both scenarios
#   tools/run.py       no shebang; required by tools/CLAUDE.md   -> finding only with fallback
#   lib/test_x.py      uses unittest.TestCase; lib/AGENTS.md bans it, but
#                      lib/AGENTS.override.md withdraws the ban  -> no finding
#   src/api/handler.py four-space indent; root says tabs, src/api/AGENTS.md says four
#                      spaces and is deeper                      -> no finding
#
# Predicates, one printed line each, per scenario:
#   cites-rule          a file a finding is expected on has one citing the expected rule
#                       file, the rule id, and a phrase of the rule's own text
#   no-other-rule       that file has no finding citing another rule or paraphrasing it
#   line-exists         a line cited in the changed file exists
#   rule-line-holds-id  a cited rule line exists and holds the rule id
#   no-finding-lib      lib/test_x.py has no finding
#   no-finding-api      src/api/handler.py has no finding
#   no-finding-tools    tools/run.py has no finding (no-fallback scenario only)
#   no-extra-file       no finding on a file outside the four
#
# Exit codes: 0 every predicate held, 1 a predicate failed, 2 the check could not run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

self_test_mode=0
[ "${1:-}" = "--self-test" ] && { self_test_mode=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review-guidelines/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }

make_tmp

# The fixture is built before the self-test so the assertions can check cited lines
# against real files in both modes.
cd "$fixture"
git init -q
git config user.email check@example.invalid
git config user.name check
mkdir -p docs lib tools src/api

cat > AGENTS.md <<'EOT'
# Project rules

Every rule in docs/review.md applies to the whole repository.

Rule R4: indent Python files with tabs.
EOT
cat > docs/review.md <<'EOT'
Rule R1: Python files under src/ must not call print(). Use logging.getLogger instead.
EOT
cat > lib/AGENTS.md <<'EOT'
Rule R2: test files in lib/ must not use unittest.TestCase. Write pytest functions.
EOT
cat > lib/AGENTS.override.md <<'EOT'
This file replaces lib/AGENTS.md. Rule R2 is withdrawn: unittest.TestCase is allowed in lib/.
EOT
cat > tools/CLAUDE.md <<'EOT'
Rule R3: every Python file in tools/ starts with a `#!/usr/bin/env python3` line.
EOT
cat > src/api/AGENTS.md <<'EOT'
Rule R4 differs here: Python files under src/api/ are indented with four spaces, not tabs.
EOT
git add -A && git commit -q -m "instruction files"

printf 'def main():\n\tprint("hello")\n' > src/app.py
printf 'import sys\nprint(sys.argv)\n' > tools/run.py
printf 'import unittest\n\n\nclass T(unittest.TestCase):\n\tdef test_a(self):\n\t\tself.assertTrue(True)\n' > lib/test_x.py
printf 'def handle():\n    return 1\n' > src/api/handler.py
git add -A && git commit -q -m "code"

# The predicates and the mutations share one table of what each file may cite, so a
# mutation is derived from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

# changed file -> rule file, rule id, a phrase of the rule's own text
RULES = {
    "src/app.py": ("docs/review.md", "R1", "must not call print()"),
    "tools/run.py": ("tools/CLAUDE.md", "R3", "#!/usr/bin/env python3"),
}
# a rule that applies to no changed file below src/api/, for findings that must not exist
ROOT_RULE = ("AGENTS.md:5", "Rule R4: indent Python files with tabs.")
# changed file that must draw no finding -> predicate id, the rule a wrong finding cites
CLEAN = {
    "lib/test_x.py": ("no-finding-lib", "lib/AGENTS.md:1",
                      "Rule R2: test files in lib/ must not use unittest.TestCase. Write pytest functions."),
    "src/api/handler.py": ("no-finding-api",) + ROOT_RULE,
    "tools/run.py": ("no-finding-tools", "tools/CLAUDE.md:1",
                     "Rule R3: every Python file in tools/ starts with a `#!/usr/bin/env python3` line."),
}

split = lambda p: re.match(r"^(.*?)(?::(\d+)(?:-\d+)?)?$", p.strip().lstrip("./")).groups()
loc = lambda p: split(p)[0]


def scenario(fallback):
    expected = {"src/app.py": RULES["src/app.py"]}
    clean = ["lib/test_x.py", "src/api/handler.py"]
    if fallback:
        expected["tools/run.py"] = RULES["tools/run.py"]
    else:
        clean.append("tools/run.py")
    return expected, clean


def lines(root, path):
    full = os.path.join(root, path)
    return open(full).read().splitlines() if os.path.isfile(full) else None


def check(doc, fallback, root):
    findings = doc["findings"]
    expected, clean = scenario(fallback)
    bad = 0

    def report(ok, pid, msg):
        nonlocal bad
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")

    def line_ok(where, must_hold=None):
        path, n = split(where)
        if n is None:
            return True
        text = lines(root, path)
        if text is None or not 1 <= int(n) <= len(text):
            return False
        return must_hold is None or must_hold in text[int(n) - 1]

    for f in findings:
        print(f"  finding: {f['file']}  <- {f['rule_file']}: {f['rule'][:70]}")

    for path, (rule_file, rule_id, phrase) in expected.items():
        hits = [f for f in findings if loc(f["file"]) == path]
        good = [f for f in hits
                if loc(f["rule_file"]).endswith(rule_file) and rule_id in f["rule"] and phrase in f["rule"]]
        report(bool(good), "cites-rule",
               f"{path} has a finding citing {rule_file} rule {rule_id} with its text quoted")
        report(len(hits) == len(good), "no-other-rule",
               f"{path} has no finding citing another rule or paraphrasing it")
        report(all(line_ok(f["file"]) for f in hits), "line-exists",
               f"{path} findings cite a line that exists")
        report(all(line_ok(f["rule_file"], rule_id) for f in good), "rule-line-holds-id",
               f"{path} findings cite a rule line that holds {rule_id}")
    for path in clean:
        report(not any(loc(f["file"]) == path for f in findings), CLEAN[path][0],
               f"{path} has no finding")
    known = set(expected) | set(clean)
    extra = sorted({loc(f["file"]) for f in findings if loc(f["file"]) not in known})
    report(not extra, "no-extra-file",
           f"no finding on any other file{': ' + ', '.join(extra) if extra else ''}")
    return 1 if bad else 0


def mutate(control, fallback, root, dest):
    """One file per predicate, each the control with one value the predicate rejects."""
    expected, clean = scenario(fallback)
    path, (rule_file, rule_id, phrase) = next(iter(expected.items()))
    made = []

    def target(doc):
        for f in doc["findings"]:
            if loc(f["file"]) == path:
                return f
        raise ValueError(f"control has no finding on {path}")

    def write(pid, doc):
        json.dump(doc, open(os.path.join(dest, pid + ".json"), "w"), indent=2)
        made.append(pid)

    doc = copy.deepcopy(control)  # the rule sentence no longer carries the rule's text
    f = target(doc)
    f["rule"] = f["rule"].replace(phrase, "may do as it likes")
    write("cites-rule", doc)

    doc = copy.deepcopy(control)  # a second finding on the file, citing a rule of its own
    f = copy.deepcopy(target(doc))
    f["rule_file"], f["rule"] = ROOT_RULE
    f["reason"] = "cites a rule that does not apply to this file"
    doc["findings"].append(f)
    write("no-other-rule", doc)

    doc = copy.deepcopy(control)  # a line one past the end of the changed file
    f = target(doc)
    f["file"] = f"{path}:{len(lines(root, path)) + 1}"
    write("line-exists", doc)

    doc = copy.deepcopy(control)  # a rule line that does not hold the rule id
    f = target(doc)
    text = lines(root, rule_file)
    off = next((i + 1 for i, t in enumerate(text) if rule_id not in t), len(text) + 1)
    f["rule_file"] = f"{rule_file}:{off}"
    write("rule-line-holds-id", doc)

    for other in clean:  # a finding on a file the skill must leave alone
        pid, cited_file, cited_rule = CLEAN[other]
        doc = copy.deepcopy(control)
        doc["findings"].append({"file": other, "rule_file": cited_file, "rule": cited_rule,
                                "reason": "the rule does not apply to this file"})
        write(pid, doc)

    doc = copy.deepcopy(control)  # a finding on a file the commit did not change
    doc["findings"].append({"file": "unmodified.py", "rule_file": ROOT_RULE[0],
                            "rule": ROOT_RULE[1], "reason": "the file is not in the diff"})
    write("no-extra-file", doc)

    print(f"  mutations: {', '.join(made)}")
    return 0


def bare(control, dest):
    """The control with every location as a bare path; the model returns that form too."""
    doc = copy.deepcopy(control)
    for f in doc["findings"]:
        f["file"], f["rule_file"] = loc(f["file"]), loc(f["rule_file"])
    json.dump(doc, open(dest, "w"), indent=2)
    return 0


def main(argv):
    mode = argv[0]
    if mode == "check":
        return check(json.load(open(argv[1])), argv[2] == "1", argv[3])
    if mode == "mutate":
        return mutate(json.load(open(argv[1])), argv[2] == "1", argv[3], argv[4])
    if mode == "bare":
        return bare(json.load(open(argv[1])), argv[2])
    raise ValueError(f"unknown mode {mode}")


try:
    code = main(sys.argv[1:])
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
    code = 2
sys.exit(code)
PY

# assert <findings.json> <fallback:1|0>. Locations may be `path` or `path:line`. A
# finding passes for its file only when it cites the expected rule file, the rule id,
# and a phrase from the rule's own text; a cited line, when given, must exist in the
# file, and a cited rule line must hold the rule id.
assert() {
  python3 "$out/predicates.py" check "$1" "$2" "$fixture"
}

# self_test_scenario <name> <fallback:1|0>. Derives the mutations from the scenario's
# control, replays the assertions over both, then checks the control once more with every
# location as a bare path, the other form the model returns. That is a second control, not
# a mutation: it must pass.
self_test_scenario() {
  local name=$1 fb=$2
  local control=$out/control-$name.json
  local dir=$out/mutations-$name bare=$out/control-$name-bare.json
  local rc=0 bare_rc=0 bare_out
  mkdir -p "$dir"
  echo "== self-test: $name"
  python3 "$out/predicates.py" mutate "$control" "$fb" "$fixture" "$dir"
  self_test assert "$control" "$dir" "$fb" || rc=$?
  python3 "$out/predicates.py" bare "$control" "$bare"
  bare_out=$(assert "$bare" "$fb" 2>&1) || bare_rc=$?
  if [ "$bare_rc" = 0 ]; then
    echo "self-test PASS control $name bare paths"
  else
    echo "self-test FAIL control $name bare paths (exit $bare_rc)"
    printf '%s\n' "$bare_out"
    [ "$bare_rc" -gt "$rc" ] && rc=$bare_rc
  fi
  return "$rc"
}

if [ "$self_test_mode" = 1 ]; then
  # Observed live outputs. If a later run disagrees with one, report the difference
  # rather than editing the control to match it.
  cat > "$out/control-fallback.json" <<'EOT'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Rule R1: Python files under src/ must not call print(). Use logging.getLogger instead.","reason":"src/app.py:2 calls print()"},{"file":"tools/run.py:1","rule_file":"tools/CLAUDE.md:1","rule":"Rule R3: every Python file in tools/ starts with a #!/usr/bin/env python3 line.","reason":"tools/run.py:1 starts with import sys"}]}
EOT
  cat > "$out/control-no-fallback.json" <<'EOT'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Rule R1: Python files under src/ must not call print().","reason":"calls print()"}]}
EOT
  st1=0; self_test_scenario fallback 1 || st1=$?
  st2=0; self_test_scenario no-fallback 0 || st2=$?
  [ "$st1" -gt "$st2" ] && exit "$st1"
  exit "$st2"
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
          "file": { "type": "string", "description": "changed file as path:line" },
          "rule_file": { "type": "string", "description": "file that states the rule, as path:line" },
          "rule": { "type": "string", "description": "the rule sentence quoted verbatim from rule_file" },
          "reason": { "type": "string", "description": "how the changed file breaks the rule" }
        },
        "required": ["file", "rule_file", "rule", "reason"],
        "additionalProperties": false
      }
    }
  },
  "required": ["findings"],
  "additionalProperties": false
}
EOT

# run <name> <config-value> <prompt-sentence> <fallback:1|0>
run() {
  local name=$1 cfg=$2 sentence=$3 fb=$4
  local prompt="You are the review subagent for the skill at $skill. Read that file and follow it exactly. The change under review is the diff of HEAD against HEAD~1 in this repository: four added Python files. $sentence Return every finding the skill produces: the changed file as path:line, the rule's file as path:line, the rule sentence quoted verbatim from that file, and in reason how the file breaks it. Return no finding for a changed file that breaks no applicable rule."
  echo "== scenario: $name"
  codex_json_run "$fixture" "$(dirname "$skill")" "$out/schema.json" "$out/$name.json" \
    "$out/$name.log" "$prompt" --ephemeral -c "project_doc_fallback_filenames=$cfg" || return 2
  assert "$out/$name.json" "$fb"
}

rc1=0
run fallback '["CLAUDE.md"]' 'The caller confirms the Codex configuration sets project_doc_fallback_filenames = ["CLAUDE.md"].' 1 || rc1=$?
rc2=0
run no-fallback '[]' 'The caller confirms the Codex configuration sets project_doc_fallback_filenames = [], so no fallback instruction file is configured.' 0 || rc2=$?
[ "$rc1" -gt "$rc2" ] && exit "$rc1"
exit "$rc2"
