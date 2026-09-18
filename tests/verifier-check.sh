#!/usr/bin/env bash
# Behavioral check for the verification pass of the code-review skill. Builds a throwaway
# repository from tests/fixtures/eval1.sh with two commits and asks Codex to act as the
# verification subagent the skill's Verification section describes, over three supplied
# candidates and nothing else. One scenario, one model call:
#
#   tests/verifier-check.sh [--self-test] [path/to/SKILL.md]
#
# The candidates are what the verdict rules have to tell apart:
#   c1  the planted pagination defect, on the pages and guard lines
#                                                      -> confirmed, the line reads as claimed
#   c2  "list_items never validates size", which the guard and the raise above it deny
#                                                      -> refuted, at one of those two lines
#   c3  "a caller passes a negative page". Its behavior claim is true, so no line denies
#       it; the caller it rests on exists nowhere in the repository, so nothing confirms
#       it either                                      -> unconfirmed, with what would settle it
#
# c3 carries the one claim that can be neither read nor denied, so its example must stay
# true: an example the code contradicts would be refutable, and the verdict would turn on
# the candidate's arithmetic rather than on the missing caller.
#
# Predicates, one printed line each:
#   partition       ids c1, c2 and c3 each appear exactly once, and no other id
#   c1-confirmed    c1's verdict is confirmed
#   c2-refuted      c2's verdict is refuted
#   c2-location     c2's disproving_location names the size guard or the raise line
#   c3-unconfirmed  c3's verdict is unconfirmed
#   c3-settles      c3 says what would settle it
#
# The lines the candidates carry and the lines c2-location accepts come from eval1_anchors,
# read out of the fixture with grep, so editing the fixture moves them.
#
# --self-test makes no model call. It replays the assertions against the control, observed
# from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at effort high per
# ~/.codex/config.toml; the run was ephemeral, so no rollout confirms them. The control
# must pass, and one mutation per fact a predicate checks, generated from that control by
# moving that fact's value outside what it accepts, must fail with its predicate's id; a
# predicate that stopped reading one of its facts would leave that fact's mutation
# passing. The file is named `<predicate-id>.<fact>.json`, which self_test reads up to the
# first dot. The partition mutation that drops c2 also fails c2-refuted and c2-location,
# which each need their verdict present; self_test asks only that a mutation fail its own
# predicate. Needs the codex CLI signed in otherwise. stdin is closed on the codex call
# because codex exec waits on it when run from a pipe.
#
# Exit codes: 0 every predicate held, 1 a predicate failed, 2 the check could not run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
. "$here/fixtures/eval1.sh"

self_test_mode=0
[ "${1:-}" = "--self-test" ] && { self_test_mode=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }

make_tmp

# The fixture is built before the self-test so both modes read the same anchors.
cd "$fixture"
git init -q
git config user.email check@example.invalid
git config user.name check
write_eval1_base "$fixture"
git add -A && git commit -q -m "items"
write_eval1_change "$fixture"
git add -A && git commit -q -m "paginate the list endpoint"

# `name=path:line` per line; word-split where it is passed, none of them holds a space.
anchor_args=$(eval1_anchors "$fixture")
anchor() { printf '%s\n' "$anchor_args" | sed -n "s/^$1=//p"; }
pages=$(anchor pages)
guard=$(anchor guard)

# The predicates and the mutations share one table of what the verdicts must hold, so a
# mutation is derived from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

IDS = ("c1", "c2", "c3")
EXTRA = "d4"  # an id no candidate was supplied under
# a path:line or path:line-line anywhere in a field, so a location with a note beside it
# still reads
TOKEN = re.compile(r"([A-Za-z0-9_./-]+):(\d+)(?:-(\d+))?")


def entries(doc, cid):
    return [v for v in doc["verdicts"] if v["id"].strip() == cid]


def cites(text, accepted):
    """True when a location in <text> names one of the accepted lines, or a range holding it."""
    for path, start, end in TOKEN.findall(text):
        path = path.lstrip("./")
        for anchor in accepted:
            want, line = anchor.rsplit(":", 1)
            if path == want and int(start) <= int(line) <= int(end or start):
                return True
    return False


def once(cid):
    return lambda doc: len(entries(doc, cid)) == 1


def duplicated(cid):
    """A break that returns the same verdict twice."""
    def apply(doc):
        doc["verdicts"].append(copy.deepcopy(entries(doc, cid)[0]))
    return apply


def dropped(cid):
    """A break that leaves a supplied candidate unanswered."""
    def apply(doc):
        doc["verdicts"] = [v for v in doc["verdicts"] if v["id"].strip() != cid]
    return apply


def no_extra(doc):
    return all(v["id"].strip() in IDS for v in doc["verdicts"])


def add_extra(doc):
    """A break that verifies a candidate nobody supplied."""
    doc["verdicts"].append({
        "id": EXTRA, "verdict": "unconfirmed", "disproving_location": "",
        "settles": "a caller of slug() that relies on the stripped value",
        "reason": "app/util.py gained an unused import os, which no candidate covers",
    })


def verdict_is(cid, want):
    return lambda doc: bool(entries(doc, cid)) and all(v["verdict"] == want
                                                       for v in entries(doc, cid))


def stated(cid, field):
    return lambda doc: bool(entries(doc, cid)) and all(v[field].strip()
                                                       for v in entries(doc, cid))


def set_field(cid, field, value):
    """A break that puts one value the fact rejects in every verdict for <cid>."""
    def apply(doc):
        for v in entries(doc, cid):
            v[field] = value
    return apply


def table(anchors):
    """predicate id -> what the whole predicate says, the fact whose mutation keeps the
    plain file name, and the facts it holds: a key, the wording, the test over the
    returned document, and the break one mutation applies to prove the test is still run."""
    disproving = sorted({anchors["size_guard"], anchors["size_raise"]})
    return {
        "partition": ("one verdict for each of " + ", ".join(IDS) + " and no other id",
                      "c1-once", [
                          ("c1-once", "c1 once", once("c1"), duplicated("c1")),
                          ("c2-once", "c2 once", once("c2"), dropped("c2")),
                          ("c3-once", "c3 once", once("c3"), duplicated("c3")),
                          ("no-extra", "no id beyond them", no_extra, add_extra),
                      ]),
        "c1-confirmed": ("c1, the dropped last page, is confirmed", "verdict", [
            ("verdict", "verdict confirmed", verdict_is("c1", "confirmed"),
             set_field("c1", "verdict", "unconfirmed")),
        ]),
        "c2-refuted": ("c2, size never validated, is refuted", "verdict", [
            ("verdict", "verdict refuted", verdict_is("c2", "refuted"),
             set_field("c2", "verdict", "confirmed")),
        ]),
        "c2-location": ("c2's disproving_location is one of " + ", ".join(disproving),
                        "location", [
                            ("location", "a disproving location on the validation",
                             lambda doc: bool(entries(doc, "c2"))
                             and all(cites(v["disproving_location"], disproving)
                                     for v in entries(doc, "c2")),
                             # the line the claim is about, which does not deny it
                             set_field("c2", "disproving_location", anchors["pages"])),
                        ]),
        "c3-unconfirmed": ("c3, a negative page from a caller that does not exist, is "
                           "unconfirmed", "verdict", [
                               ("verdict", "verdict unconfirmed",
                                verdict_is("c3", "unconfirmed"),
                                set_field("c3", "verdict", "confirmed")),
                           ]),
        "c3-settles": ("c3 says what would settle it", "settles", [
            ("settles", "settles stated", stated("c3", "settles"),
             set_field("c3", "settles", "")),
        ]),
    }


def check(doc, anchors):
    bad = 0

    def report(ok, pid, msg):
        nonlocal bad
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")

    for v in doc["verdicts"]:
        print(f"  verdict: {v['id']} {v['verdict']} "
              f"disproving={v['disproving_location'] or '-'} settles={v['settles'] or '-'}")
        print(f"    reason: {v['reason']}")

    for pid, (says, _, facts) in table(anchors).items():
        missed = [w for _, w, holds, _ in facts if not holds(doc)]
        report(not missed, pid, says + ("" if not missed else "; missing " + ", ".join(missed)))
    return 1 if bad else 0


def mutate(control, dest, anchors):
    """One file per fact, each the control with that fact's value moved outside what the
    predicate accepts, so every fact is proven to be read."""
    made = []
    for pid, (_, plain, facts) in table(anchors).items():
        for key, _, holds, break_it in facts:
            if not holds(control):
                raise ValueError(f"control already fails {pid}: {key}")
            doc = copy.deepcopy(control)
            break_it(doc)
            if holds(doc):
                raise ValueError(f"the break for {pid}: {key} leaves the fact holding")
            name = pid if key == plain else f"{pid}.{key}"
            json.dump(doc, open(os.path.join(dest, name + ".json"), "w"), indent=2)
            made.append(name)
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

# assert <verdicts.json>. A disproving_location may be `path:line` or `path:line-line`;
# c2-location needs a line, because a bare file name does not say what denies the claim.
assert() {
  python3 "$out/predicates.py" check "$1" $anchor_args
}

if [ "$self_test_mode" = 1 ]; then
  # Observed live output. If a later run disagrees with it, report the difference rather
  # than editing the control to match it.
  cat > "$out/control.json" <<'EOT'
{
  "verdicts": [
    {
      "id": "c1",
      "verdict": "confirmed",
      "disproving_location": "",
      "settles": "",
      "reason": "app/list.py:8 uses floor division to count pages, and app/list.py:9-10 returns an empty list when page reaches that count. A read-only Python check confirmed that list_items([1, 2, 3, 4, 5], 2, 2) returns [] instead of [5]. The final partial page is inaccessible."
    },
    {
      "id": "c2",
      "verdict": "refuted",
      "disproving_location": "app/list.py:6",
      "settles": "",
      "reason": "app/list.py:6-7 checks size <= 0 and raises ValueError before the division at line 8. Read-only Python checks confirmed that both size 0 and size -1 raise ValueError with the message \"size must be greater than 0\"."
    },
    {
      "id": "c3",
      "verdict": "unconfirmed",
      "disproving_location": "",
      "settles": "Provide the claimed request caller and its validation path to establish that a negative page reaches list_items unchecked, plus evidence for the claimed cross-user data exposure.",
      "reason": "app/list.py:9 does not reject negative pages, and app/util.py:10 multiplies page by size. A direct Python check confirmed that list_items([1, 2, 3, 4, 5], -2, 2) returns [2, 3]. However, repository inspection found no caller of list_items or request-handling code. The supplied candidate's claims that a caller forwards an unchecked request parameter and serves somebody else's items therefore cannot be established or disproved."
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
    "verdicts": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string", "description": "the id of the candidate this verdict answers" },
          "verdict": {
            "type": "string",
            "enum": ["confirmed", "refuted", "unconfirmed"],
            "description": "the verdict the skill's Verification section defines"
          },
          "disproving_location": {
            "type": "string",
            "description": "path:line that disproves the candidate, empty unless the verdict is refuted"
          },
          "settles": {
            "type": "string",
            "description": "what would settle the candidate, empty unless the verdict is unconfirmed"
          },
          "reason": {
            "type": "string",
            "description": "what was read in the repository that gives this verdict"
          }
        },
        "required": ["id", "verdict", "disproving_location", "settles", "reason"],
        "additionalProperties": false
      }
    }
  },
  "required": ["verdicts"],
  "additionalProperties": false
}
EOT

# Written out rather than built inline: a here-document inside $( ) is still lexed for
# quotes, so an apostrophe in the candidates would break the script.
cat > "$out/prompt.txt" <<EOT
The code review skill is at $skill. Read that file. Act as the verification subagent
described under Verification in that skill. Verify only the supplied candidates under the
Verification verdict rules; do not orchestrate review passes or add new candidates.

The comparison is the diff of HEAD~1 against HEAD in this repository. The stated intent is
the commit message of HEAD: "paginate the list endpoint". The review is read-only: it
changes no file, branch, index, or stash.

Three candidates were merged from the review passes, each in the finding format the skill
gives its subagents. Return one verdict for each, under its id.

c1
$pages, $guard
severity: high
What is wrong: the last page is dropped whenever the number of items is not a multiple of
size.
Why it matters: pages = len(items) // size floors, so for 5 items with size 2 pages is 2
and list_items(items, 2, 2) returns [] instead of the fifth item. Every list whose length
is not a multiple of the page size loses its tail.
What the code must do: count the pages so the final partial page is still returned, for
example with ceiling division.

c2
$pages
severity: high
What is wrong: list_items never validates size, so it accepts 0 and negative sizes.
Why it matters: len(items) // size divides by size with nothing checking it first, so a
request with size 0 raises ZeroDivisionError out of the endpoint.
What the code must do: reject a size of 0 or less with a ValueError before counting pages.

c3
$guard
severity: medium
What is wrong: a caller passes a negative page to list_items, and the page guard lets it
through.
Why it matters: that caller forwards the request's page parameter without checking it, so
a request for page -2 reaches list_items and is served. With 5 items and size 2 the guard
page >= pages is false for -2, start_index returns -4, and the slice returns [2, 3] from
the end of the list instead of an empty page, so the request is answered with somebody
else's items.
What the code must do: reject a page below 0 before slicing.

Presentation only: return the report's content as JSON matching the schema instead of
Markdown; every other instruction in the skill stands.
EOT
prompt=$(cat "$out/prompt.txt")

codex_json_run "$fixture" "$(dirname "$skill")" "$out/schema.json" "$out/verdicts.json" \
  "$out/verdicts.log" "$prompt" --ephemeral || exit 2
assert "$out/verdicts.json"
