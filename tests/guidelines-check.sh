#!/usr/bin/env bash
# Behavioral check for the code-review-guidelines skill. Builds a throwaway repository
# whose instruction files exercise the resolution rules the skill states, asks Codex to
# apply the skill to the repository's second commit, and asserts which changed files
# receive a finding and which rule each cites. Runs two scenarios, one model call each:
#
#   fallback     configuration names CLAUDE.md as a fallback instruction file
#   no-fallback  configuration names no fallback, so tools/CLAUDE.md states nothing
#
#   tests/guidelines-check.sh [--self-test] [path/to/SKILL.md]
#
# --self-test runs the assertion code alone against canned findings (an observed pass,
# an observed pass with path:line locations, and a forged set that must fail) and makes
# no model call. Needs the codex CLI signed in otherwise. stdin is closed on the codex
# call because codex exec waits on it when run from a pipe.
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

# assert <findings.json> <fallback:1|0>. Locations may be `path` or `path:line`; the
# line is stripped before matching, since the skill reports path:line and the cases are
# defined per file.
assert() {
python3 - "$1" "$2" <<'PY'
import json, re, sys
findings = json.load(open(sys.argv[1]))["findings"]
fallback = sys.argv[2] == "1"
loc = lambda p: re.sub(r":\d+(-\d+)?$", "", p.strip().lstrip("./"))
for f in findings:
    print(f"  finding: {f['file']}  <- {f['rule_file']}: {f['rule'][:70]}")

expected = {"src/app.py": ("docs/review.md", "R1")}
none_expected = ["lib/test_x.py", "src/api/handler.py"]
if fallback:
    expected["tools/run.py"] = ("tools/CLAUDE.md", "R3")
else:
    none_expected.append("tools/run.py")

bad = 0
def report(ok, msg):
    global bad
    bad += not ok
    print(f"{'PASS' if ok else 'FAIL'}: {msg}")

for path, (rule_file, rule_id) in expected.items():
    hits = [f for f in findings if loc(f["file"]) == path]
    good = [f for f in hits if loc(f["rule_file"]).endswith(rule_file) and rule_id in f["rule"]]
    report(bool(good), f"{path} has a finding citing {rule_file} rule {rule_id}")
    report(len(hits) == len(good), f"{path} has no finding citing another rule")
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
  echo "== self-test: observed output, bare paths (expect pass)"
  cat > "$tmp/a.json" <<'EOF'
{"findings":[{"file":"src/app.py","rule_file":"docs/review.md","rule":"Rule R1: no print()"},{"file":"tools/run.py","rule_file":"tools/CLAUDE.md","rule":"Rule R3: shebang"}]}
EOF
  assert "$tmp/a.json" 1 || fail=1
  echo "== self-test: observed output, path:line locations (expect pass)"
  cat > "$tmp/b.json" <<'EOF'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Low severity — src/app.py:2 calls print(), violating Rule R1"},{"file":"tools/run.py:1","rule_file":"tools/CLAUDE.md:1","rule":"Medium severity — tools/run.py:1 starts with import sys, violating Rule R3"}]}
EOF
  assert "$tmp/b.json" 1 || fail=1
  echo "== self-test: no-fallback scenario with only the imported rule (expect pass)"
  cat > "$tmp/c.json" <<'EOF'
{"findings":[{"file":"src/app.py:2","rule_file":"docs/review.md:1","rule":"Rule R1"}]}
EOF
  assert "$tmp/c.json" 0 || fail=1
  echo "== self-test: forged findings citing wrong rules and an unchanged file (expect fail)"
  cat > "$tmp/d.json" <<'EOF'
{"findings":[{"file":"src/app.py","rule_file":"AGENTS.md","rule":"Rule R4"},{"file":"tools/run.py","rule_file":"lib/AGENTS.md","rule":"Rule R2"},{"file":"unmodified.py","rule_file":"AGENTS.md","rule":"Rule R4"}]}
EOF
  if assert "$tmp/d.json" 1; then echo "FAIL: forged findings were accepted"; fail=1; else echo "PASS: forged findings rejected"; fi
  exit $fail
fi

cd "$tmp"
git init -q
git config user.email check@example.invalid
git config user.name check
mkdir -p docs lib tools src/api

cat > AGENTS.md <<'EOF'
# Project rules

Every rule in docs/review.md applies to the whole repository.

Rule R4: indent Python files with tabs.
EOF
cat > docs/review.md <<'EOF'
Rule R1: Python files under src/ must not call print(). Use logging.getLogger instead.
EOF
cat > lib/AGENTS.md <<'EOF'
Rule R2: test files in lib/ must not use unittest.TestCase. Write pytest functions.
EOF
cat > lib/AGENTS.override.md <<'EOF'
This file replaces lib/AGENTS.md. Rule R2 is withdrawn: unittest.TestCase is allowed in lib/.
EOF
cat > tools/CLAUDE.md <<'EOF'
Rule R3: every Python file in tools/ starts with a `#!/usr/bin/env python3` line.
EOF
cat > src/api/AGENTS.md <<'EOF'
Rule R4 differs here: Python files under src/api/ are indented with four spaces, not tabs.
EOF
git add -A && git commit -q -m "instruction files"

printf 'def main():\n\tprint("hello")\n' > src/app.py
printf 'import sys\nprint(sys.argv)\n' > tools/run.py
printf 'import unittest\n\n\nclass T(unittest.TestCase):\n\tdef test_a(self):\n\t\tself.assertTrue(True)\n' > lib/test_x.py
printf 'def handle():\n    return 1\n' > src/api/handler.py
git add -A && git commit -q -m "code"

cat > "$tmp/schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "file": { "type": "string" },
          "rule_file": { "type": "string" },
          "rule": { "type": "string" }
        },
        "required": ["file", "rule_file", "rule"],
        "additionalProperties": false
      }
    }
  },
  "required": ["findings"],
  "additionalProperties": false
}
EOF

# run <name> <config-value> <prompt-sentence> <fallback:1|0>
run() {
  local name=$1 cfg=$2 sentence=$3 fb=$4
  local prompt="You are the review subagent for the skill at $skill. Read that file and follow it exactly. The change under review is the diff of HEAD against HEAD~1 in this repository: four added Python files. $sentence Return every finding the skill produces, with the changed file location, the location of the rule, and the rule quoted. Return no finding for a changed file that breaks no applicable rule."
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
