#!/usr/bin/env bash
# Behavioral check for the code-review-breaking-changes skill. Builds a throwaway
# repository from tests/fixtures/eval4.sh with two commits and asks Codex to review the
# second against the first. One scenario, one model call:
#
#   tests/breaking-changes-check.sh [--self-test] [path/to/SKILL.md]
#
# The change under review holds three things the skill must tell apart:
#   service/handler.py   renames the response field user_id to userId, which
#                        worker/consumer.py indexes by name    -> a caller fails outright
#   service/config.py    reads os.environ["UPLOAD_BUCKET"] at import with no default,
#                        and .github/workflows/deploy.yml, which supplies the service's
#                        variables, is untouched               -> the service fails to start
#   packages/shared-client  version 1.2.0 -> 1.2.1, nothing else in the package
#                                                              -> at most a low finding
#
# Predicates, one printed line each:
#   rename-finding  a finding on the renamed field's line, severity high, breaks_who
#                   naming worker/consumer.py, failure exception, exception_name KeyError,
#                   has_migration_path false
#   env-finding     a finding on the os.environ line, severity high, breaks_who or
#                   evidence naming deploy.yml, failure startup_failure
#   bump-low        every finding on packages/shared-client has severity low
#
# The lines the first two accept come from eval4_anchors, read out of the fixture with
# grep, so editing the fixture moves them.
#
# --self-test makes no model call. It replays the assertions against the control, observed
# from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at effort high per
# ~/.codex/config.toml; the run was ephemeral, so no rollout confirms them. The control
# must pass, and one mutation per fact a predicate checks, generated from that control by
# moving that fact's value outside what it accepts, must fail with its predicate's id; a
# predicate that stopped reading one of its facts would leave that fact's mutation
# passing. The file is named `<predicate-id>.<fact>.json`, which self_test reads up to the
# first dot. Needs the codex CLI signed in otherwise. stdin is closed on the codex call
# because codex exec waits on it when run from a pipe.
#
# Exit codes: 0 every predicate held, 1 a predicate failed, 2 the check could not run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
. "$here/fixtures/eval4.sh"

self_test_mode=0
[ "${1:-}" = "--self-test" ] && { self_test_mode=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review-breaking-changes/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }

make_tmp

# The fixture is built before the self-test so both modes read the same anchors.
cd "$fixture"
git init -q
git config user.email check@example.invalid
git config user.name check
write_eval4_base "$fixture"
git add -A && git commit -q -m "profile service, worker and shared client"
write_eval4_change "$fixture"
git add -A && git commit -q -m "return userId and require an upload bucket"

# `name=path:line` per line; word-split where it is passed, none of them holds a space.
anchor_args=$(eval4_anchors "$fixture")

# The predicates and the mutations share one table of what each finding must hold, so a
# mutation is derived from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

SHARED = "packages/shared-client"

split = lambda p: re.match(r"^(.*?)(?::(\d+)(?:-(\d+))?)?$", p.strip().lstrip("./")).groups()


def covers(finding, anchor):
    """True when a location names the anchor's line, or a range that holds it."""
    want, line = anchor.rsplit(":", 1)
    for where in finding["locations"]:
        path, start, end = split(where)
        if path == want and start is not None and int(start) <= int(line) <= int(end or start):
            return True
    return False


def on_shared(finding):
    return any(split(w)[0].startswith(SHARED) for w in finding["locations"])


def named(finding, text):
    return text in " ".join(finding["breaks_who"]) + " " + finding["evidence"]


def setting(field, value):
    """A break that puts one value the fact rejects in the finding."""
    return lambda f: f.update({field: value})


def unnamed(text, instead, evidence=None):
    """A break that stops the finding naming <text>, in breaks_who and, for a fact that
    reads it too, in evidence."""
    def apply(f):
        f["breaks_who"] = [w for w in f["breaks_who"] if text not in w] or [instead]
        if evidence is not None:
            f["evidence"] = evidence
    return apply


def anchored(anchors):
    """predicate id -> the line a finding must sit on, the fact whose mutation keeps the
    plain file name, and the facts it must hold: a key, the wording, the test, and the
    break one mutation applies to prove the test is still run."""
    return {
        "rename-finding": (anchors["rename"], "severity", [
            ("severity", "severity high",
             lambda f: f["severity"] == "high", setting("severity", "medium")),
            ("breaks_who", "breaks_who names worker/consumer.py",
             lambda f: any("worker/consumer.py" in w for w in f["breaks_who"]),
             unnamed("worker/consumer.py", "an unnamed consumer")),
            ("failure", "failure exception",
             lambda f: f["failure"] == "exception", setting("failure", "graceful")),
            ("exception_name", "exception_name KeyError",
             lambda f: "KeyError" in f["exception_name"], setting("exception_name", "")),
            ("has_migration_path", "has_migration_path false",
             lambda f: f["has_migration_path"] is False, setting("has_migration_path", True)),
        ]),
        "env-finding": (anchors["environ"], "failure", [
            ("severity", "severity high",
             lambda f: f["severity"] == "high", setting("severity", "medium")),
            ("named", "deploy.yml in breaks_who or evidence",
             lambda f: named(f, "deploy.yml"),
             unnamed("deploy.yml", "the deployed service",
                     evidence="the variable is read at import with no default")),
            ("failure", "failure startup_failure",
             lambda f: f["failure"] == "startup_failure", setting("failure", "graceful")),
        ]),
    }


def check(doc, anchors):
    findings = doc["findings"]
    bad = 0

    def report(ok, pid, msg):
        nonlocal bad
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")

    for f in findings:
        print(f"  finding: {', '.join(f['locations'])} severity={f['severity']} "
              f"failure={f['failure']}({f['exception_name'] or '-'}) "
              f"migration={f['has_migration_path']} breaks={', '.join(f['breaks_who']) or '-'} "
              f"| {f['claim'][:70]}")

    for pid, (anchor, _, facts) in anchored(anchors).items():
        near = [f for f in findings if covers(f, anchor)]
        missed = min(([w for _, w, holds, _ in facts if not holds(f)] for f in near),
                     key=len, default=None)
        ok = bool(near) and not missed
        short = "" if ok else (f"; no finding there" if not near
                               else f"; the closest lacks {', '.join(missed)}")
        report(ok, pid, f"a finding at {anchor} with "
               + ", ".join(w for _, w, _, _ in facts) + short)

    loud = sorted({f["severity"] for f in findings if on_shared(f) and f["severity"] != "low"})
    report(not loud, "bump-low",
           f"no finding on {SHARED} above low severity" + (f"; found {', '.join(loud)}" if loud else ""))
    return 1 if bad else 0


def mutate(control, dest, anchors):
    """One file per fact, each the control with that fact's value moved outside what the
    predicate accepts, so every fact is proven to be read."""
    made = []

    def write(name, doc):
        json.dump(doc, open(os.path.join(dest, name + ".json"), "w"), indent=2)
        made.append(name)

    def broken(pid, key):
        """The control with the <key> fact of <pid> broken on every finding it accepts."""
        doc = copy.deepcopy(control)
        anchor, _, facts = anchored(anchors)[pid]
        good = [f for f in doc["findings"]
                if covers(f, anchor) and all(holds(f) for _, _, holds, _ in facts)]
        if not good:
            raise ValueError(f"control has no finding at {anchor} that {pid} accepts")
        break_it = next(b for k, _, _, b in facts if k == key)
        for f in good:
            break_it(f)
        return doc

    for pid, (_, plain, facts) in anchored(anchors).items():
        for key, _, _, _ in facts:
            write(pid if key == plain else f"{pid}.{key}", broken(pid, key))

    doc = copy.deepcopy(control)  # the version bump is reported above low
    shared = [f for f in doc["findings"] if on_shared(f)]
    if shared:
        for f in shared:
            f["severity"] = "medium"
    else:
        doc["findings"].append({
            "locations": [anchors["bump"]], "severity": "medium",
            "claim": "the shared client version moves from 1.2.0 to 1.2.1",
            "evidence": f"{anchors['bump']} is the only change in the package",
            "fix": "hold the version until the public API changes",
            "breaks_who": ["every consumer of shared-client"], "failure": "none",
            "exception_name": "", "has_migration_path": True,
            "migration_path": "none needed",
        })
    write("bump-low", doc)

    print(f"  mutations: {', '.join(made)}")
    return 0


def main(argv):
    mode, rest = argv[0], argv[1:]
    if mode == "check":
        return check(json.load(open(rest[0])), dict(a.split("=", 1) for a in rest[1:]))
    if mode == "mutate":
        return mutate(json.load(open(rest[0])), rest[1], dict(a.split("=", 1) for a in rest[2:]))
    raise ValueError(f"unknown mode {mode}")


try:
    code = main(sys.argv[1:])
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
    code = 2
sys.exit(code)
PY

# assert <findings.json>. A location may be `path:line` or `path:line-line`; the two
# anchored predicates need a line, because a bare path does not say which change the
# finding is about.
assert() {
  python3 "$out/predicates.py" check "$1" $anchor_args
}

if [ "$self_test_mode" = 1 ]; then
  # Observed live output. If a later run disagrees with it, report the difference rather
  # than editing the control to match it.
  cat > "$out/control.json" <<'EOT'
{
  "findings": [
    {
      "locations": ["service/config.py:6"],
      "severity": "high",
      "claim": "Requiring UPLOAD_BUCKET at import time prevents the service from starting with the existing deployment configuration.",
      "evidence": "service/main.py:1 imports config. The deployment workflow at .github/workflows/deploy.yml:13 runs python -m service.main, but its environment at lines 15–17 supplies only DATABASE_URL, QUEUE_NAME, and LOG_LEVEL. Importing service.main with UPLOAD_BUCKET absent reproduced \"KeyError: 'UPLOAD_BUCKET'\".",
      "fix": "Remove the mandatory lookup until the bucket is needed, or supply UPLOAD_BUCKET in every deployment target in the same change and provide compatibility for existing environments.",
      "breaks_who": [
        "service/main.py",
        ".github/workflows/deploy.yml",
        "Existing service environments without UPLOAD_BUCKET"
      ],
      "failure": "startup_failure",
      "exception_name": "KeyError",
      "has_migration_path": false,
      "migration_path": "No fallback or deployment configuration update is included. Provision the variable before making it mandatory, or retain startup compatibility when it is absent."
    },
    {
      "locations": ["service/handler.py:6"],
      "severity": "high",
      "claim": "Renaming the response field from user_id to userId breaks the existing profile consumer.",
      "evidence": "worker/consumer.py:8 still reads resp[\"user_id\"]. Passing the changed handler response through fetch_profile using a mocked HTTP response reproduced \"KeyError: 'user_id'\".",
      "fix": "Preserve user_id in the existing response contract. If userId is needed, add it alongside user_id during migration or expose it through a versioned contract.",
      "breaks_who": ["worker/consumer.py:fetch_profile"],
      "failure": "exception",
      "exception_name": "KeyError",
      "has_migration_path": false,
      "migration_path": "No alias, versioned response, or consumer migration is included. Retain user_id until existing consumers have migrated, or keep the old contract available through a separate API version."
    }
  ]
}
EOT
  mkdir -p "$out/mutations"
  echo "== self-test"
  python3 "$out/predicates.py" mutate "$out/control.json" "$out/mutations" $anchor_args
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
            "items": { "type": "string", "description": "path:line in this repository" },
            "description": "every line that introduces the break, the first one first"
          },
          "severity": { "type": "string", "enum": ["high", "medium", "low"] },
          "claim": { "type": "string", "description": "what the change breaks" },
          "evidence": { "type": "string", "description": "what in the repository shows it" },
          "fix": { "type": "string", "description": "the change that would not break it" },
          "breaks_who": {
            "type": "array",
            "items": { "type": "string" },
            "description": "each party that depends on what changed, as a path or a name"
          },
          "failure": {
            "type": "string",
            "enum": ["exception", "startup_failure", "wrong_data", "graceful", "none"],
            "description": "how the dependent party fails"
          },
          "exception_name": {
            "type": "string",
            "description": "the exception raised, empty when failure is not exception or startup_failure"
          },
          "has_migration_path": {
            "type": "boolean",
            "description": "true when the change itself ships a backfill, fallback, versioned contract or rollback"
          },
          "migration_path": {
            "type": "string",
            "description": "the migration path the change ships, or the one it would need"
          }
        },
        "required": ["locations", "severity", "claim", "evidence", "fix", "breaks_who",
                     "failure", "exception_name", "has_migration_path", "migration_path"],
        "additionalProperties": false
      }
    }
  },
  "required": ["findings"],
  "additionalProperties": false
}
EOT

prompt="You are the review subagent for the skill at $skill. Read that file and follow it exactly. Review the diff of HEAD against HEAD~1. Presentation only: return the report's content as JSON matching the schema instead of Markdown; every other instruction in the skill stands."

codex_json_run "$fixture" "$(dirname "$skill")" "$out/schema.json" "$out/findings.json" \
  "$out/findings.log" "$prompt" --ephemeral || exit 2
assert "$out/findings.json"
