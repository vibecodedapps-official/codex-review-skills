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
# --self-test runs the assertion code alone against canned findings (observed passes,
# with bare paths and with path:line locations, and forged sets that must fail: wrong
# rules and an unchanged file, the right rule id with inverted text, a line that does
# not exist) and makes no model call. Needs the codex CLI signed in otherwise. stdin is
# closed on the codex call because codex exec waits on it when run from a pipe.
#
# Cases, each a changed Python file:
#   src/app.py         calls print(); banned by docs/review.md, which the root AGENTS.md
#                      references for the whole repository      -> finding, both scenarios
#   tools/run.py       no shebang; required by tools/CLAUDE.md   -> finding only with fallback
#   lib/test_x.py      uses unittest.TestCase; lib/AGENTS.md bans it, but
#                      lib/AGENTS.override.md withdraws the ban  -> no finding
#   src/api/handler.py four-space indent; root says tabs, src/api/AGENTS.md says four
#                      spaces and is deeper                      -> no finding
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
self_test=0
[ "${1:-}" = "--self-test" ] && { self_test=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review-guidelines/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/guidelines-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# The fixture is built before the self-test so the assertions can check cited lines
# against real files in both modes.
cd "$tmp"
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

# assert <findings.json> <fallback:1|0>. Locations may be `path` or `path:line`. A
# finding passes for its file only when it cites the expected rule file, the rule id,
# and a phrase from the rule's own text; a cited line, when given, must exist in the
# file, and a cited rule line must hold the rule id.
assert() {
python3 - "$1" "$2" "$tmp" <<'PY'
import json, os, re, sys
findings = json.load(open(sys.argv[1]))["findings"]
fallback = sys.argv[2] == "1"
root = sys.argv[3]
split = lambda p: re.match(r"^(.*?)(?::(\d+)(?:-\d+)?)?$", p.strip().lstrip("./")).groups()
loc = lambda p: split(p)[0]
for f in findings:
    print(f"  finding: {f['file']}  <- {f['rule_file']}: {f['rule'][:70]}")

expected = {"src/app.py": ("docs/review.md", "R1", "must not call print()")}
none_expected = ["lib/test_x.py", "src/api/handler.py"]
if fallback:
    expected["tools/run.py"] = ("tools/CLAUDE.md", "R3", "#!/usr/bin/env python3")
else:
    none_expected.append("tools/run.py")

bad = 0
def report(ok, msg):
    global bad
    bad += not ok
    print(f"{'PASS' if ok else 'FAIL'}: {msg}")

def lines(path):
    full = os.path.join(root, path)
    return open(full).read().splitlines() if os.path.isfile(full) else None

def line_ok(where, must_hold=None):
    path, n = split(where)
    if n is None:
        return True
    text = lines(path)
    if text is None or not 1 <= int(n) <= len(text):
        return False
    return must_hold is None or must_hold in text[int(n) - 1]

for path, (rule_file, rule_id, phrase) in expected.items():
    hits = [f for f in findings if loc(f["file"]) == path]
    good = [f for f in hits
            if loc(f["rule_file"]).endswith(rule_file) and rule_id in f["rule"] and phrase in f["rule"]]
    report(bool(good), f"{path} has a finding citing {rule_file} rule {rule_id} with its text quoted")
    report(len(hits) == len(good), f"{path} has no finding citing another rule or paraphrasing it")
    report(all(line_ok(f["file"]) for f in hits), f"{path} findings cite a line that exists")
    report(all(line_ok(f["rule_file"], rule_id) for f in good), f"{path} findings cite a rule line that holds {rule_id}")
for path in none_expected:
    report(not any(loc(f["file"]) == path for f in findings), f"{path} has no finding")
known = set(expected) | set(none_expected)
extra = sorted({loc(f["file"]) for f in findings if loc(f["file"]) not in known})
report(not extra, f"no finding on any other file{': ' + ', '.join(extra) if extra else ''}")
sys.exit(1 if bad else 0)
PY
}

if [ "$self_test" = 1 ]; then
  fail=0
  expect_pass() { echo "== self-test: $1 (expect pass)"; assert "$2" "$3" || fail=1; }
  expect_fail() {
    echo "== self-test: $1 (expect fail)"
    if assert "$2" "$3"; then echo "FAIL: forged findings were accepted"; fail=1; else echo "PASS: forged findings rejected"; fi
  }
  cat > "$tmp/a.json" <<'EOT'
{"findings":[{"file":"src/app.py","rule_file":"docs/review.md","rule":"Rule R1: Python files under src/ must not call print(). Use logging.getLogger instead.","reason":"calls print()"},{"file":"tools/run.py","rule_file":"tools/CLAUDE.md","rule":"Rule R3: every Python file in tools/ starts with a `#!/usr/bin/env python3` line.","reason":"no shebang"}]}
EOT
  expect_pass "observed output, bare paths" "$tmp/a.json" 1
  cat > "$tmp/b.json" <<'EOT'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Rule R1: Python files under src/ must not call print(). Use logging.getLogger instead.","reason":"src/app.py:2 calls print()"},{"file":"tools/run.py:1","rule_file":"tools/CLAUDE.md:1","rule":"Rule R3: every Python file in tools/ starts with a #!/usr/bin/env python3 line.","reason":"tools/run.py:1 starts with import sys"}]}
EOT
  expect_pass "observed output, path:line locations" "$tmp/b.json" 1
  cat > "$tmp/c.json" <<'EOT'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Rule R1: Python files under src/ must not call print().","reason":"calls print()"}]}
EOT
  expect_pass "no-fallback scenario with only the imported rule" "$tmp/c.json" 0
  cat > "$tmp/d.json" <<'EOT'
{"findings":[{"file":"src/app.py","rule_file":"AGENTS.md","rule":"Rule R4: indent Python files with tabs.","reason":"x"},{"file":"tools/run.py","rule_file":"lib/AGENTS.md","rule":"Rule R2: test files in lib/ must not use unittest.TestCase.","reason":"x"},{"file":"unmodified.py","rule_file":"AGENTS.md","rule":"Rule R4: indent Python files with tabs.","reason":"x"}]}
EOT
  expect_fail "forged findings citing wrong rules and an unchanged file" "$tmp/d.json" 1
  cat > "$tmp/e.json" <<'EOT'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Rule R1: print() is required.","reason":"x"},{"file":"tools/run.py:1","rule_file":"tools/CLAUDE.md:1","rule":"Rule R3: shebang","reason":"x"}]}
EOT
  expect_fail "right rule ids with inverted or paraphrased text" "$tmp/e.json" 1
  cat > "$tmp/f.json" <<'EOT'
{"findings":[{"file":"src/app.py:999999","rule_file":"docs/review.md:1","rule":"Rule R1: Python files under src/ must not call print().","reason":"x"},{"file":"tools/run.py:1","rule_file":"tools/CLAUDE.md:7","rule":"Rule R3: every Python file in tools/ starts with a `#!/usr/bin/env python3` line.","reason":"x"}]}
EOT
  expect_fail "right rules at lines that do not exist" "$tmp/f.json" 1
  exit $fail
fi

cat > "$tmp/schema.json" <<'EOT'
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
  codex exec --cd "$tmp" --add-dir "$(dirname "$skill")" -s read-only --ephemeral \
    -c "project_doc_fallback_filenames=$cfg" \
    --output-schema "$tmp/schema.json" -o "$tmp/$name.json" "$prompt" </dev/null >"$tmp/$name.log" 2>&1 \
    || { echo "codex exec failed:"; tail -20 "$tmp/$name.log"; return 2; }
  assert "$tmp/$name.json" "$fb"
}

fail=0
run fallback '["CLAUDE.md"]' 'The caller confirms the Codex configuration sets project_doc_fallback_filenames = ["CLAUDE.md"].' 1 || fail=1
run no-fallback '[]' 'The caller confirms the Codex configuration sets project_doc_fallback_filenames = [], so no fallback instruction file is configured.' 0 || fail=1
exit $fail
