#!/usr/bin/env bash
# Behavioral check for the code-review orchestrator skill. Builds one throwaway repository
# from tests/fixtures/eval1.sh and tests/fixtures/eval4.sh, whose paths are disjoint: main
# holds both bases, and the branch `feature` off main holds the eval 1 change ("paginate
# the list endpoint") and then the eval 4 change ("return userId and require an upload
# bucket"). HEAD stays on feature and the review target is the branch against main. One
# scenario, one model call in the main thread, which fans out to one subagent per
# sub-review skill and one more to verify the merged findings:
#
#   tests/code-review-check.sh [--self-test] [path/to/SKILL.md]
#
# The branch holds three defects two different sub-reviews find, so the orchestrator has
# to merge them without reporting either twice:
#   app/list.py      floor division drops the last partial page  -> correctness
#   service/handler.py  the response field user_id becomes userId, which
#                    worker/consumer.py indexes by name          -> breaking changes
#   service/config.py  UPLOAD_BUCKET is read at import with no default, and
#                    .github/workflows/deploy.yml does not supply it -> breaking changes
# and two things it must leave alone: the pre-existing bug in app/legacy.py (unchanged)
# and the unused import the repository's ruff config already flags.
#
# Predicates, one printed line each:
#   confirmed-pagination  a confirmed entry on the pages or guard line whose demonstration
#                         has items_count not a multiple of size, expected_count above 0,
#                         actual_count 0, so the dropped page is shown rather than asserted
#   confirmed-rename      a confirmed entry on the rename line, category break, failure
#                         exception, breaks_who naming worker/consumer.py
#   confirmed-environ     a confirmed entry on the environ line, category break, failure
#                         startup_failure
#   dedup                 each of those three defects is confirmed at most once. An entry
#                         counts as that defect when it carries the fact that identifies it,
#                         whatever line or category it is filed under, or when it sits on
#                         the defect's line and says something fails. The second half of
#                         that is why the failure is read: the testing pass reports its own
#                         finding, that the same line has no regression test, and a finding
#                         about a different problem at the same line is not a duplicate
#   no-legacy             no confirmed or unconfirmed entry on app/legacy.py
#   coverage              reviewed and skipped together name exactly the files `git diff
#                         --name-only main...feature` reports, and nothing is skipped
#   refuted-locations     every refuted entry's disproving_location is a file and line that
#                         exist in the repository
#   git-oracle            `git for-each-ref`, `git symbolic-ref HEAD`, `git write-tree`,
#                         `git stash list` and `git status --porcelain`, captured before and
#                         after the run, are identical and the status is empty
#   spawn-args            every spawn_agent call asked for xhigh reasoning and a fresh
#                         context (fork_turns "none" or fork_context false), and there were
#                         at least six of them
#   child-effort          every child thread of this run ran at xhigh in its own turn context
#   children-complete     a child thread ran each of the five sub-reviews and the
#                         verification pass, matched by the name the skill gives it:
#                         its agent_path ends in correctness, guidelines, testing,
#                         breaking-changes, change-size or verification. spawn-args reads
#                         the calls, this reads what came of them, so a pass that was
#                         refused for the concurrency cap and never respawned is caught
#
# The lines the first three accept come from eval1_anchors and eval4_anchors, read out of
# the fixture with grep, so editing a fixture moves them.
#
# Where the spawn evidence comes from. The --json stream reports the collaboration tool
# calls as `item.completed` records of type `collab_tool_call` with no arguments, so the
# parameters are only in the session rollout. A probe run on 2026-09-18 with codex-cli
# 0.155.0 (one `codex exec --json -s read-only` in /tmp, no --ephemeral, asking for one
# fresh-context subagent at xhigh reasoning) showed every record shape this check needs:
#   ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread-id>.jsonl, the thread id being
#     the one in the stream's first event, {"type":"thread.started","thread_id":...}
#   a `response_item` record whose `payload` has type `function_call`, name `spawn_agent`,
#     namespace `collaboration`, and `arguments`: a JSON string holding `task_name`,
#     `fork_turns` and `reasoning_effort`. The probe's arguments carried no `fork_context`,
#     so the check accepts either field
#   the matching `function_call_output`, whose output is `{"task_name":"/root/<name>"}` and
#     names no child thread id, so children are found from their own first record instead
#   the child rollout's `session_meta` payload, holding `id`, `parent_thread_id`,
#     `agent_path`, `thread_source` "subagent" and `source.subagent.thread_spawn` with
#     `parent_thread_id`, `depth` and `agent_path`
#   `turn_context` payloads holding `model` and `effort`: the parent's read high, the CLI
#     default from config.toml, and the child's own read xhigh. The probe's child wrote one
#     such record and other children on this machine wrote two or three, the first
#     inherited from the parent, so the check reads the last one
# Nothing the check needs was missing. `--ephemeral` skips the rollout, so this check runs
# without it. $out/spawns.json holds what was read out of the rollout, a list of spawn
# arguments and a list of child efforts, so the assertions read only files and the
# self-test can replay a canned one. A rollout that cannot be found at all prints
# `spawn parameters: unverified` and exits 3; values that are present and wrong are a FAIL.
#
# --self-test makes no model call. It replays the assertions against the control, observed
# from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at effort high read
# from that run's own turn_context in the rollout (the run is not ephemeral, so the rollout
# is the source, not config.toml). The control must pass, and one mutation per fact a
# predicate reads, generated from that control by moving that fact alone outside what the
# predicate accepts, must fail with its predicate's id; a predicate that stopped reading
# one of its facts would leave that fact's mutation passing. The file is named
# `<predicate-id>.json` for the first fact and `<predicate-id>.<fact>.json` for the rest,
# which self_test reads up to the first dot. The git snapshots are taken from the fixture
# the self-test builds, since no model output goes into them. Needs the codex CLI signed in
# otherwise. stdin is closed on the codex call because codex exec waits on it when run from
# a pipe.
#
# Exit codes: 0 every predicate held, 1 a predicate failed, 2 the check could not run,
# 3 the run's rollout or its child rollouts could not be found.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
. "$here/fixtures/eval1.sh"
. "$here/fixtures/eval4.sh"

self_test_mode=0
[ "${1:-}" = "--self-test" ] && { self_test_mode=1; shift; }
skill=${1:-$here/../plugins/codex-review-skills/skills/code-review/SKILL.md}
skill="$(cd "$(dirname "$skill")" && pwd)/$(basename "$skill")"
[ -f "$skill" ] || { echo "No skill at $skill" >&2; exit 2; }
# The sub-reviews are sibling directories of the orchestrator's, one SKILL.md each; the
# whole directory is the add_dir so every one of them is readable.
skills_root=$(dirname "$(dirname "$skill")")

make_tmp

# The fixture is built before the self-test so both modes read the same anchors, the same
# changed-file set, and a real repository for the locations a refuted entry may name.
cd "$fixture"
git init -q -b main
git config user.email check@example.invalid
git config user.name check
write_eval1_base "$fixture"
write_eval4_base "$fixture"
git add -A && git commit -q -m "list endpoint, profile service, worker and shared client"
git checkout -q -b feature
write_eval1_change "$fixture"
git add -A && git commit -q -m "paginate the list endpoint"
write_eval4_change "$fixture"
git add -A && git commit -q -m "return userId and require an upload bucket"

# `name=path:line` per line; word-split where it is passed, none of them holds a space.
eval1_anchors "$fixture" > "$out/anchors.txt"
eval4_anchors "$fixture" >> "$out/anchors.txt"
anchor_args=$(cat "$out/anchors.txt")
git diff --name-only main...feature > "$out/changed.txt"

# git_snapshot <file>: the repository state the review must leave alone. The status section
# is last so the assertions can read it back out of the file.
git_snapshot() {
  {
    echo "== for-each-ref"
    git for-each-ref
    echo "== symbolic-ref HEAD"
    git symbolic-ref HEAD
    echo "== write-tree"
    git write-tree
    echo "== stash list"
    git stash list
    echo "== status --porcelain"
    git status --porcelain
  } > "$1"
}

# Reads the spawn parameters out of the session rollouts. Kept apart from the assertions so
# that what the check reads is a file either way.
cat > "$out/rollout.py" <<'PY'
import glob, json, os, sys

SPAWN = "spawn_agent"


def records(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


def first(path):
    for rec in records(path):
        return rec
    return {}


def rollouts(root):
    return sorted(glob.glob(os.path.join(root, "*", "*", "*", "rollout-*.jsonl")))


def dig(obj, *keys):
    """obj[keys...] while every step is a dict, else {}. The same field is a string in one
    rollout and an object in another (`source` is "exec" on a thread a user started and an
    object on a subagent's), so every step is checked."""
    for key in keys:
        if not isinstance(obj, dict):
            return {}
        obj = obj.get(key)
    return obj if isinstance(obj, dict) else {}


def payload(rec, kind):
    p = rec.get("payload")
    return p if rec.get("type") == kind and isinstance(p, dict) else None


def spawns_of(path):
    """Every spawn_agent call in a rollout, as the arguments it was given. The arguments
    are a JSON string; a `message` field holds the encrypted task and is dropped."""
    out = []
    for rec in records(path):
        p = payload(rec, "response_item")
        if not p or p.get("type") != "function_call" or p.get("name") != SPAWN:
            continue
        try:
            args = json.loads(p.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        out.append({
            "task_name": args.get("task_name", ""),
            "fork_turns": args.get("fork_turns"),
            "fork_context": args.get("fork_context"),
            "reasoning_effort": args.get("reasoning_effort"),
        })
    return out


def own_turn_context(path):
    """The last turn_context in a rollout. A child's first one is inherited from its
    parent and its own comes after, so the last one is the one that ran the child."""
    last = {}
    for rec in records(path):
        p = payload(rec, "turn_context")
        if p:
            last = p
    return last


def children_of(root, thread_id, parent_path):
    """Every rollout whose first record names this thread as its parent. The rollout holds
    no child thread id, so the children are found from their own side. Only the parent's
    day directory and the ones after it are read, since a child starts after its parent."""
    day = os.path.dirname(parent_path)
    found = []
    for path in rollouts(root):
        if os.path.dirname(path) < day:
            continue
        meta = payload(first(path), "session_meta")
        if not meta:
            continue
        spawn = dig(meta, "source", "subagent", "thread_spawn")
        if (meta.get("parent_thread_id") or spawn.get("parent_thread_id")) != thread_id:
            continue
        ctx = own_turn_context(path)
        found.append({
            "thread_id": meta.get("id", ""),
            "agent_path": meta.get("agent_path") or spawn.get("agent_path") or "",
            "model": ctx.get("model"),
            "effort": ctx.get("effort"),
            "rollout": os.path.basename(path),
        })
    return found


def main(thread_id, root, dest):
    hits = [p for p in rollouts(root) if p.endswith(f"-{thread_id}.jsonl")]
    if not hits:
        print(f"no rollout for thread {thread_id} under {root}")
        return 3
    parent = hits[-1]
    children = children_of(root, thread_id, parent)
    if not children:
        print(f"no rollout under {root} names {thread_id} as its parent")
        return 3
    context = own_turn_context(parent)
    doc = {
        "thread_id": thread_id,
        "rollout": os.path.basename(parent),
        "model": context.get("model"),
        "effort": context.get("effort"),
        "spawns": spawns_of(parent),
        "children": children,
    }
    with open(dest, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print(f"  rollout: {doc['rollout']} model={doc['model']} effort={doc['effort']} "
          f"spawns={len(doc['spawns'])} children={len(children)}")
    return 0


try:
    code = main(sys.argv[1], sys.argv[2], sys.argv[3])
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
    code = 2
sys.exit(code)
PY

# The predicates and the mutations share one table of what each entry must hold, so a
# mutation is derived from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

LEGACY = "app/legacy.py"            # the pre-existing bug the review must leave alone
CONSUMER = "worker/consumer.py"     # the caller the renamed field breaks
EFFORT = "xhigh"                    # what the skill asks every subagent to run at
MIN_SPAWNS = 6                      # one per sub-review skill, plus the verification pass
STATUS = "== status --porcelain"    # the last section of a git snapshot
# The skill names each subagent after its skill, and the verification pass "verification",
# so a child thread can be matched to the pass it ran.
CHILDREN = ["correctness", "guidelines", "testing", "breaking-changes", "change-size",
            "verification"]

split = lambda p: re.match(r"^(.*?)(?::(\d+)(?:-(\d+))?)?$", str(p).strip().lstrip("./")).groups()
loc = lambda p: split(p)[0]
paths = lambda e: [loc(p) for p in e["locations"]]


def covers(entry, anchor):
    """True when a location names the anchor's line, or a range that holds it."""
    want, line = anchor.rsplit(":", 1)
    for where in entry["locations"]:
        path, start, end = split(where)
        if path == want and start is not None and int(start) <= int(line) <= int(end or start):
            return True
    return False


def demo(entry):
    return entry["demonstration"]


def drops_a_page(entry):
    """The demonstration shows a page of items returned as empty: the count is not a whole
    number of pages, that page should hold items, and it held none."""
    d = demo(entry)
    return (d["size"] > 0 and d["items_count"] % d["size"] != 0
            and d["expected_count"] > 0 and d["actual_count"] == 0)


def names(entry, text):
    return any(text in who for who in entry["breaks_who"])


def spawned_as(child, name):
    """True when a child thread ran the pass called <name>. Its own name is the last part
    of its agent_path, which the spawn tool builds from the task name, and `_` and `-` are
    the same character there; a task named for the whole skill, code-review-testing, ends
    with the skill's own name just as a task named testing does."""
    return child.get("agent_path", "").strip().lower().replace("_", "-").endswith(name)


# Each defect the branch plants, as the anchors it sits on and the fact that identifies it
# whatever it is called. Used to pick the entries a predicate judges, and to count an
# identity for dedup, where neither the line nor the category may hide a second entry.
IDENTITY = {
    "pagination": (["pages", "guard"], drops_a_page),
    "rename": (["rename"],
               lambda e: e["failure"] == "exception" and names(e, CONSUMER)),
    "environ": (["environ"], lambda e: e["failure"] == "startup_failure"),
}


def lines(anchors, key):
    return [anchors[name] for name in IDENTITY[key][0]]


def files(anchors, key):
    return sorted({loc(a) for a in lines(anchors, key)})


def fails(entry):
    """The entry says something fails: an enumerated failure, or a demonstration of a
    wrong result."""
    return entry["failure"] != "none" or any(demo(entry).values())


def about(entry, anchors, key):
    """True when an entry is about one of the planted defects: it carries the fact that
    identifies that defect, whatever line or category it is filed under, or it sits on the
    defect's own line and says something fails. The first half is what catches a duplicate,
    since two passes that both report the rename both say a caller raises; the second half
    catches one that states the defect more weakly. A finding about a different problem at
    the same line, such as the missing test for that line, says nothing fails and is not
    the defect."""
    return IDENTITY[key][1](entry) or (any(covers(entry, a) for a in lines(anchors, key))
                                       and fails(entry))


def setting(field, value):
    return lambda e: e.update({field: value})


def at_line(where):
    """A break that leaves the entry on its file but off the line the anchor names."""
    return lambda e: e.update(locations=[where])


def demo_setting(field, value_of):
    return lambda e: demo(e).update({field: value_of(demo(e))})


def unnamed(text, instead):
    def apply(entry):
        entry["breaks_who"] = [w for w in entry["breaks_who"] if text not in w] or [instead]
    return apply


def table(anchors):
    """predicate id -> the defect identity it is about and the facts one confirmed entry
    must hold: a key, the wording for the printed line, the test, and the break one
    mutation applies to prove the test is still run. The first fact's mutation keeps the
    plain <predicate-id>.json name."""
    return {
        "confirmed-pagination": ("pagination", [
            ("location", f"a location on {anchors['pages']} or {anchors['guard']}",
             lambda e: covers(e, anchors["pages"]) or covers(e, anchors["guard"]),
             at_line("app/list.py:1")),
            ("items_count", "a demonstration whose items_count is not a multiple of size",
             lambda e: demo(e)["size"] > 0 and demo(e)["items_count"] % demo(e)["size"] != 0,
             demo_setting("items_count", lambda d: d["size"] * 2)),
            ("expected_count", "expected_count above 0",
             lambda e: demo(e)["expected_count"] > 0,
             demo_setting("expected_count", lambda d: 0)),
            ("actual_count", "actual_count 0", lambda e: demo(e)["actual_count"] == 0,
             demo_setting("actual_count", lambda d: max(d["expected_count"], 1))),
        ]),
        "confirmed-rename": ("rename", [
            ("location", f"a location on {anchors['rename']}",
             lambda e: covers(e, anchors["rename"]), at_line("service/handler.py:1")),
            ("category", "category break", lambda e: e["category"] == "break",
             setting("category", "defect")),
            ("failure", "failure exception", lambda e: e["failure"] == "exception",
             setting("failure", "wrong_data")),
            ("breaks_who", f"breaks_who naming {CONSUMER}", lambda e: names(e, CONSUMER),
             unnamed(CONSUMER, "an unnamed consumer")),
        ]),
        "confirmed-environ": ("environ", [
            ("location", f"a location on {anchors['environ']}",
             lambda e: covers(e, anchors["environ"]), at_line("service/config.py:1")),
            ("category", "category break", lambda e: e["category"] == "break",
             setting("category", "defect")),
            ("failure", "failure startup_failure",
             lambda e: e["failure"] == "startup_failure", setting("failure", "graceful")),
        ]),
    }


def fmt_demo(entry):
    d = demo(entry)
    if not any(d.values()):
        return "-"
    return (f"{d['items_count']}/{d['size']}@{d['page']}"
            f"->{d['expected_count']}got{d['actual_count']}")


def existing(repo, where):
    """True when a `path:line` names a line the repository really has."""
    path, start, _ = split(where)
    full = os.path.join(repo, path)
    if not path or start is None or not os.path.isfile(full):
        return False
    with open(full, encoding="utf-8", errors="replace") as fh:
        return 1 <= int(start) <= sum(1 for _ in fh)


def check(doc, changed_file, repo, anchors):
    report_doc, spawns = doc["findings"], doc["spawns"]
    confirmed = report_doc["confirmed"]
    unconfirmed = report_doc["unconfirmed"]
    refuted = report_doc["refuted"]
    coverage = report_doc["coverage"]
    bad = 0

    def report(ok, pid, msg):
        nonlocal bad
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")

    for kind, entries in (("confirmed", confirmed), ("unconfirmed", unconfirmed),
                          ("refuted", refuted)):
        for e in entries:
            print(f"  {kind}: {', '.join(e['locations'])} severity={e['severity']} "
                  f"category={e['category']} failure={e['failure']} demo={fmt_demo(e)} "
                  f"breaks={', '.join(e['breaks_who']) or '-'}"
                  + (f" disproved_at={e['disproving_location'] or '-'}"
                     if kind == "refuted" else "")
                  + f" | {e['claim'][:70]}")
    print(f"  coverage: changed={coverage['changed']} "
          f"reviewed={', '.join(coverage['reviewed']) or '-'} "
          f"skipped={', '.join(s['file'] for s in coverage['skipped']) or '-'}")
    print("  spawns: " + (", ".join(
        f"{s['task_name'] or '?'}({s['reasoning_effort']},"
        f"{s['fork_turns'] if s['fork_turns'] is not None else s['fork_context']})"
        for s in spawns["spawns"]) or "none"))
    print("  children: " + (", ".join(
        f"{c['agent_path'] or c['thread_id']}({c['model']},{c['effort']})"
        for c in spawns["children"]) or "none"))

    for pid, (key, facts) in table(anchors).items():
        near = [e for e in confirmed if any(p in files(anchors, key) for p in paths(e))]
        missed = min(([w for _, w, holds, _ in facts if not holds(e)] for e in near),
                     key=len, default=None)
        ok = bool(near) and not missed
        short = "" if ok else ("; nothing confirmed on " + ", ".join(files(anchors, key))
                               if not near else
                               "; the closest lacks " + ", ".join(missed))
        report(ok, pid, "a confirmed entry with " + ", ".join(w for _, w, _, _ in facts)
               + short)

    twice = {key: len([e for e in confirmed if about(e, anchors, key)]) for key in IDENTITY}
    loud = {key: n for key, n in twice.items() if n > 1}
    report(not loud, "dedup",
           "each defect is confirmed once, whatever line or category it is reported under"
           + ("; " + ", ".join(f"{k} appears {n} times" for k, n in loud.items())
              if loud else ""))

    legacy = [e for e in confirmed + unconfirmed if LEGACY in paths(e)]
    report(not legacy, "no-legacy", f"no confirmed or unconfirmed entry on {LEGACY}"
           + (f"; {len(legacy)} of them there" if legacy else ""))

    changed = {p.strip().lstrip("./") for p in open(changed_file) if p.strip()}
    seen = {loc(p) for p in coverage["reviewed"]} | {loc(s["file"]) for s in coverage["skipped"]}
    skipped = [s["file"] for s in coverage["skipped"]]
    ok = seen == changed and not skipped
    report(ok, "coverage",
           f"reviewed and skipped name the {len(changed)} changed files, nothing skipped"
           + ("" if ok else
              "; missing " + (", ".join(sorted(changed - seen)) or "none")
              + ", not changed " + (", ".join(sorted(seen - changed)) or "none")
              + ", skipped " + (", ".join(skipped) or "none")))

    nowhere = [e["disproving_location"] or "(empty)" for e in refuted
               if not existing(repo, e["disproving_location"])]
    report(not nowhere, "refuted-locations",
           f"every refuted entry names a line that exists ({len(refuted)} refuted)"
           + ("; " + ", ".join(nowhere) if nowhere else ""))

    before = open(doc["git"]["before"], encoding="utf-8").read()
    after = open(doc["git"]["after"], encoding="utf-8").read()
    status = after.split(STATUS, 1)[-1].strip()
    ok = before == after and not status
    report(ok, "git-oracle", "refs, HEAD, tree, stashes and status are what they were"
           + ("" if ok else
              ("; the snapshots differ" if before != after else "")
              + (f"; status holds {status.splitlines()[0]}" if status else "")))

    spawned = spawns["spawns"]
    fresh = [s for s in spawned
             if s.get("fork_turns") == "none" or s.get("fork_context") is False]
    tame = [f"{s['task_name'] or '?'} at {s['reasoning_effort']}" for s in spawned
            if s.get("reasoning_effort") != EFFORT]
    ok = len(spawned) >= MIN_SPAWNS and not tame and len(fresh) == len(spawned)
    report(ok, "spawn-args",
           f"at least {MIN_SPAWNS} spawns, each with a fresh context at {EFFORT}"
           + ("" if ok else f"; {len(spawned)} spawns, "
              f"{len(spawned) - len(fresh)} forked" + ("; " + ", ".join(tame) if tame else "")))

    kids = spawns["children"]
    tame = [f"{c['agent_path'] or c['thread_id']} at {c['effort']}" for c in kids
            if c.get("effort") != EFFORT]
    ok = bool(kids) and not tame
    report(ok, "child-effort",
           f"every child thread ran at {EFFORT} ({len(kids)} of them)"
           + ("" if ok else "; " + (", ".join(tame) or "no child thread")))

    absent = [name for name in CHILDREN
              if not any(spawned_as(c, name) for c in kids)]
    report(not absent, "children-complete",
           "a child thread ran each pass: " + ", ".join(CHILDREN)
           + ("; none ran " + ", ".join(absent) if absent else ""))
    return 1 if bad else 0


def mutate(control, dest, anchors):
    """One file per fact, each the control with that fact's value moved outside what the
    predicate accepts, so every fact is proven to be read. A mutation stays valid against
    the schema the run used."""
    made = []

    def write(name, doc):
        with open(os.path.join(dest, name + ".json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
        made.append(name)

    def entries(doc, key, facts=None):
        """The confirmed entries a predicate accepts, so a mutation breaks what the control
        proved rather than something the control never had."""
        hits = [e for e in doc["findings"]["confirmed"] if about(e, anchors, key)
                and (facts is None or all(holds(e) for _, _, holds, _ in facts))]
        if not hits:
            raise ValueError(f"control confirms no {key} entry the predicate accepts")
        return hits

    for pid, (key, facts) in table(anchors).items():
        for i, (fact, _, _, break_it) in enumerate(facts):
            doc = copy.deepcopy(control)
            for e in entries(doc, key, facts):
                break_it(e)
            write(pid if i == 0 else f"{pid}.{fact}", doc)

    # The same defect confirmed a second time, disguised a different way each time: at
    # another line under another category, at its own line with the fact weakened to
    # something that still fails, and at another line with the fact left intact.
    twins = {
        "pagination": lambda t: t.update(locations=["app/list.py:1"], category="intent"),
        "rename": lambda t: t.update(category="defect", failure="wrong_data", breaks_who=[]),
        "environ": lambda t: t.update(locations=["service/config.py:1"], category="defect"),
    }
    for i, key in enumerate(IDENTITY):
        doc = copy.deepcopy(control)
        twin = copy.deepcopy(entries(doc, key)[0])
        twins[key](twin)
        doc["findings"]["confirmed"].append(twin)
        write("dedup" if i == 0 else f"dedup.{key}", doc)

    doc = copy.deepcopy(control)  # the pre-existing bug reported as a finding
    doc["findings"]["confirmed"][0]["locations"].append(f"{LEGACY}:3")
    write("no-legacy", doc)

    doc = copy.deepcopy(control)  # a changed file accounted for nowhere
    reviewed = doc["findings"]["coverage"]["reviewed"]
    if not reviewed:
        raise ValueError("control reviewed no file")
    reviewed.pop()
    write("coverage", doc)

    doc = copy.deepcopy(control)  # a changed file left unread, with a reason
    coverage = doc["findings"]["coverage"]
    coverage["skipped"].append({"file": coverage["reviewed"].pop(),
                                "reason": "the diff looked mechanical"})
    write("coverage.skipped", doc)

    doc = copy.deepcopy(control)  # a refutation pointing at a line the file does not have
    refuted = doc["findings"]["refuted"]
    if refuted:
        for e in refuted:
            e["disproving_location"] = "app/list.py:9999"
    else:
        refuted.append(dict(doc["findings"]["confirmed"][0], locations=["app/list.py:8"],
                            claim="list_items never validates size",
                            evidence="read the body of list_items",
                            verdict_reason="the guard is right there",
                            settles="", disproving_location="app/list.py:9999"))
    write("refuted-locations", doc)

    doc = copy.deepcopy(control)  # the review left a stash behind
    moved = os.path.join(dest, "git-oracle.after.txt")
    with open(moved, "w", encoding="utf-8") as fh:
        fh.write(open(control["git"]["after"], encoding="utf-8").read().replace(
            "== stash list\n", "== stash list\nstash@{0}: WIP on feature\n"))
    doc["git"]["after"] = moved
    write("git-oracle", doc)

    doc = copy.deepcopy(control)  # a file the review wrote, in both snapshots
    for side in ("before", "after"):
        dirty = os.path.join(dest, f"git-oracle.status.{side}.txt")
        with open(dirty, "w", encoding="utf-8") as fh:
            fh.write(open(control["git"][side], encoding="utf-8").read().rstrip("\n")
                     + "\n?? review-notes.md\n")
        doc["git"][side] = dirty
    write("git-oracle.status", doc)

    spawned, kids = control["spawns"]["spawns"], control["spawns"]["children"]
    if len(spawned) < MIN_SPAWNS or not kids:
        raise ValueError(f"control holds {len(spawned)} spawns and {len(kids)} children")

    def with_spawns(change):
        doc = copy.deepcopy(control)
        change(doc["spawns"])
        return doc

    write("spawn-args", with_spawns(
        lambda s: s["spawns"][0].update(reasoning_effort="high")))
    write("spawn-args.fork_turns", with_spawns(
        lambda s: s["spawns"][0].update(fork_turns="all", fork_context=True)))
    write("spawn-args.count", with_spawns(
        lambda s: s.update(spawns=s["spawns"][:MIN_SPAWNS - 1])))
    write("child-effort", with_spawns(
        lambda s: s["children"][0].update(effort="medium")))

    for i, name in enumerate(CHILDREN):  # one pass that never ran
        doc = copy.deepcopy(control)
        kept = [c for c in doc["spawns"]["children"] if not spawned_as(c, name)]
        if len(kept) == len(doc["spawns"]["children"]):
            raise ValueError(f"control has no child thread for the {name} pass")
        doc["spawns"]["children"] = kept
        write("children-complete" if i == 0 else f"children-complete.{name}", doc)

    print(f"  mutations: {', '.join(made)}")
    return 0


def main(argv):
    mode, rest = argv[0], argv[1:]
    if mode == "check":
        return check(json.load(open(rest[0])), rest[1], rest[2],
                     dict(a.split("=", 1) for a in rest[3:]))
    if mode == "mutate":
        return mutate(json.load(open(rest[0])), rest[1],
                      dict(a.split("=", 1) for a in rest[2:]))
    raise ValueError(f"unknown mode {mode}")


try:
    code = main(sys.argv[1:])
except Exception as exc:
    print(f"ERROR: {type(exc).__name__}: {exc}")
    code = 2
sys.exit(code)
PY

# bundle <dest> <report.json> <spawns.json> <before> <after>. The assertions read one file,
# because self_test replaces that one file per mutation; the git snapshots stay files of
# their own, named from inside it, so a mutation can point at a snapshot of its own.
bundle() {
  python3 - "$@" <<'PY'
import json, sys
dest, report, spawns, before, after = sys.argv[1:6]
with open(dest, "w", encoding="utf-8") as fh:
    json.dump({"findings": json.load(open(report)), "spawns": json.load(open(spawns)),
               "git": {"before": before, "after": after}}, fh, indent=2)
PY
}

# assert <bundle.json>. A location may be `path:line` or `path:line-line`; the anchored
# predicates need a line, because a bare path does not say which defect an entry is about.
assert() {
  python3 "$out/predicates.py" check "$1" "$out/changed.txt" "$fixture" $anchor_args
}

if [ "$self_test_mode" = 1 ]; then
  # Observed live output. If a later run disagrees with it, report the difference rather
  # than editing the control to match it.
  cat > "$out/control-report.json" <<'EOT'
{
  "confirmed": [
    {
      "locations": [
        "service/config.py:6",
        ".github/workflows/deploy.yml:13",
        ".github/workflows/deploy.yml:14",
        "service/main.py:1"
      ],
      "severity": "high",
      "category": "break",
      "claim": "Making UPLOAD_BUCKET mandatory breaks the checked-in deployment startup command under its declared environment.",
      "evidence": "The workflow runs python -m service.main and declares DATABASE_URL, QUEUE_NAME, and LOG_LEVEL, but no UPLOAD_BUCKET. service/main.py immediately imports config. A subprocess check without UPLOAD_BUCKET exited 1 with \"KeyError: 'UPLOAD_BUCKET'\"; setting it made the command exit 0. The base configuration loaded without it.",
      "fix": "Supply the required bucket setting in the deployment workflow when introducing the requirement, or preserve startup compatibility until the setting is rolled out.",
      "verdict_reason": "Confirmed by inspecting the workflow and import path and independently reproducing the startup failure. This establishes failure under the declared environment; external deployment configuration was not inspected.",
      "settles": "",
      "disproving_location": "",
      "demonstration": {
        "items_count": 0,
        "size": 0,
        "page": 0,
        "expected_count": 0,
        "actual_count": 0
      },
      "failure": "startup_failure",
      "breaks_who": [
        ".github/workflows/deploy.yml",
        "service/main.py"
      ]
    },
    {
      "locations": [
        "service/handler.py:6",
        "worker/consumer.py:8"
      ],
      "severity": "high",
      "category": "break",
      "claim": "Renaming the response field to userId breaks the existing worker consumer, which still requires user_id.",
      "evidence": "The changed handler returns {\"userId\": \"alice\", \"plan\": \"standard\"}. Passing its serialized response through mocked urllib.request.urlopen into the real fetch_profile function raised \"KeyError: 'user_id'\" at worker/consumer.py:8. The same consumer returned ('alice', 'standard') with the base handler's response.",
      "fix": "Migrate the worker alongside the producer, or retain the old response field until consumers have migrated.",
      "verdict_reason": "Confirmed by inspecting both sides of the contract and independently reproducing the failure with the real handler and consumer; only transport was mocked.",
      "settles": "",
      "disproving_location": "",
      "demonstration": {
        "items_count": 0,
        "size": 0,
        "page": 0,
        "expected_count": 0,
        "actual_count": 0
      },
      "failure": "exception",
      "breaks_who": [
        "worker/consumer.py"
      ]
    },
    {
      "locations": [
        "service/handler.py:6",
        "service/main.py:5",
        "worker/consumer.py:8"
      ],
      "severity": "high",
      "category": "test_gap",
      "claim": "The response mapping change has no runnable contract check covering the service entry point and its existing consumer.",
      "evidence": "The complete repository inventory contains no tests or test runner. The package configuration contains only project metadata, and the workflow only starts the service. No check asserts the intended response mapping or detects the demonstrated producer-consumer mismatch.",
      "fix": "Add a runnable standard-library check through service.main.start that asserts the status and exact decoded response, then exercises the real worker consumer with mocked transport. Ensure the mapping assertion fails if the rename is reverted and the consumer assertion detects incompatible keys.",
      "verdict_reason": "Confirmed by independently inspecting the repository inventory and both code paths. Adding a regression check is a separate required fix from correcting the runtime mismatch.",
      "settles": "",
      "disproving_location": "",
      "demonstration": {
        "items_count": 0,
        "size": 0,
        "page": 0,
        "expected_count": 0,
        "actual_count": 0
      },
      "failure": "none",
      "breaks_who": []
    },
    {
      "locations": [
        "app/list.py:8",
        "app/list.py:9",
        "app/list.py:10"
      ],
      "severity": "medium",
      "category": "defect",
      "claim": "Floor division excludes the final partial page, including every item when a nonempty collection is smaller than one page.",
      "evidence": "The guard uses len(items) // size as the page limit. list_items([0, 1, 2], 0, 5) returns [] instead of three items, and list_items(list(range(11)), 2, 5) returns [] instead of [10]. Full-page controls returned their expected results.",
      "fix": "Include the partial final page in the page count, or let slicing return the available items while retaining the intended out-of-range behavior.",
      "verdict_reason": "Confirmed from the guard and two independently reproduced wrong-result cases. No concrete downstream caller was found to establish a separate compatibility failure.",
      "settles": "",
      "disproving_location": "",
      "demonstration": {
        "items_count": 3,
        "size": 5,
        "page": 0,
        "expected_count": 3,
        "actual_count": 0
      },
      "failure": "none",
      "breaks_who": []
    },
    {
      "locations": [
        "app/list.py:8",
        "app/list.py:12"
      ],
      "severity": "medium",
      "category": "test_gap",
      "claim": "The new pagination behavior has no runnable regression check.",
      "evidence": "Neither the diff nor the complete repository inventory contains tests. Direct checks exposed incorrect short-input and final-partial-page results. Coverage must also distinguish pagination from the base implementation, which returns every item.",
      "fix": "Add runnable exact-result checks for multiple full pages, a partial final page, a short nonempty input, and an out-of-range page. Include a full-page assertion that fails if pagination is reverted.",
      "verdict_reason": "Confirmed that no covering check exists and that testing full-page results is necessary to detect reversion of the requested behavior.",
      "settles": "",
      "disproving_location": "",
      "demonstration": {
        "items_count": 0,
        "size": 0,
        "page": 0,
        "expected_count": 0,
        "actual_count": 0
      },
      "failure": "none",
      "breaks_who": []
    },
    {
      "locations": [
        "service/config.py:6",
        ".github/workflows/deploy.yml:13"
      ],
      "severity": "medium",
      "category": "test_gap",
      "claim": "The required UPLOAD_BUCKET setting has no runnable startup check for configured and missing-variable environments.",
      "evidence": "No test suite or runner is present. The workflow's module invocation neither supplies UPLOAD_BUCKET nor separately checks its required-variable contract. Subprocess checks exited 1 with \"KeyError: 'UPLOAD_BUCKET'\" when absent and exited 0 when configured.",
      "fix": "Add runnable subprocess checks for startup with and without UPLOAD_BUCKET, asserting the intended exit codes and missing-setting diagnostic. Validate that the deployment environment supplies the required setting.",
      "verdict_reason": "Confirmed from the repository inventory and independent startup checks. Covering both environments verifies successful startup and detects reversion of the new configuration requirement.",
      "settles": "",
      "disproving_location": "",
      "demonstration": {
        "items_count": 0,
        "size": 0,
        "page": 0,
        "expected_count": 0,
        "actual_count": 0
      },
      "failure": "none",
      "breaks_who": []
    }
  ],
  "unconfirmed": [],
  "refuted": [],
  "coverage": {
    "changed": 5,
    "reviewed": [
      "app/list.py",
      "app/util.py",
      "packages/shared-client/pyproject.toml",
      "service/config.py",
      "service/handler.py"
    ],
    "skipped": []
  }
}
EOT
  # Read out of that run's rollout by $out/rollout.py, with the task names left as the
  # model wrote them. Seven spawns for six passes: the first call named the agent
  # `code-review-correctness` and came back `agent_name must use only lowercase letters,
  # digits, and underscores`, so the model spawned it again with underscores, which is why
  # a child is matched with `_` read as `-`. A refused spawn, for the name or for the cap
  # on how many agents run at once, is why the spawn list can be longer than the child
  # list, and why children-complete counts child threads rather than calls.
  cat > "$out/control-spawns.json" <<'EOT'
{
  "thread_id": "01a0b630-54c1-7da2-91a8-c935af9a61d3",
  "rollout": "rollout-2026-09-18T16-23-35-01a0b630-54c1-7da2-91a8-c935af9a61d3.jsonl",
  "model": "gpt-6-astra",
  "effort": "high",
  "spawns": [
    {
      "task_name": "code-review-correctness",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    },
    {
      "task_name": "code_review_correctness",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    },
    {
      "task_name": "code_review_breaking_changes",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    },
    {
      "task_name": "code_review_guidelines",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    },
    {
      "task_name": "code_review_testing",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    },
    {
      "task_name": "code_review_change_size",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    },
    {
      "task_name": "verification",
      "fork_turns": "none",
      "fork_context": null,
      "reasoning_effort": "xhigh"
    }
  ],
  "children": [
    {
      "thread_id": "01a0b631-0229-73a2-ba0a-08428e7f5bce",
      "agent_path": "/root/code_review_correctness",
      "model": "gpt-6-astra",
      "effort": "xhigh",
      "rollout": "rollout-2026-09-18T16-24-20-01a0b631-0229-73a2-ba0a-08428e7f5bce.jsonl"
    },
    {
      "thread_id": "01a0b631-31e2-7901-923d-036b502ee440",
      "agent_path": "/root/code_review_breaking_changes",
      "model": "gpt-6-astra",
      "effort": "xhigh",
      "rollout": "rollout-2026-09-18T16-24-32-01a0b631-31e2-7901-923d-036b502ee440.jsonl"
    },
    {
      "thread_id": "01a0b631-60cc-7773-b43e-9e240d75248d",
      "agent_path": "/root/code_review_guidelines",
      "model": "gpt-6-astra",
      "effort": "xhigh",
      "rollout": "rollout-2026-09-18T16-24-44-01a0b631-60cc-7773-b43e-9e240d75248d.jsonl"
    },
    {
      "thread_id": "01a0b632-7033-7aa0-9ebf-cfd76622f222",
      "agent_path": "/root/code_review_testing",
      "model": "gpt-6-astra",
      "effort": "xhigh",
      "rollout": "rollout-2026-09-18T16-25-54-01a0b632-7033-7aa0-9ebf-cfd76622f222.jsonl"
    },
    {
      "thread_id": "01a0b633-09c2-7a01-9d11-e1aec3b76dd6",
      "agent_path": "/root/code_review_change_size",
      "model": "gpt-6-astra",
      "effort": "xhigh",
      "rollout": "rollout-2026-09-18T16-26-33-01a0b633-09c2-7a01-9d11-e1aec3b76dd6.jsonl"
    },
    {
      "thread_id": "01a0b634-5abc-71a3-b36c-b71ce7d828cd",
      "agent_path": "/root/verification",
      "model": "gpt-6-astra",
      "effort": "xhigh",
      "rollout": "rollout-2026-09-18T16-27-59-01a0b634-5abc-71a3-b36c-b71ce7d828cd.jsonl"
    }
  ]
}
EOT
  # No model output goes into the git oracle, so its control is this fixture, snapshotted
  # twice the way a run that touches nothing leaves it.
  git_snapshot "$out/git-before.txt"
  git_snapshot "$out/git-after.txt"
  bundle "$out/control.json" "$out/control-report.json" "$out/control-spawns.json" \
    "$out/git-before.txt" "$out/git-after.txt"
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
  "$defs": {
    "entry": {
      "type": "object",
      "properties": {
        "locations": {
          "type": "array",
          "items": { "type": "string", "description": "path:line in this repository" },
          "description": "every line the finding is about, the one it anchors to first"
        },
        "severity": { "type": "string", "enum": ["high", "medium", "low"] },
        "category": {
          "type": "string",
          "enum": ["defect", "intent", "test_gap", "guideline", "break", "size"],
          "description": "what kind of finding it is"
        },
        "claim": { "type": "string", "description": "what is wrong, in one sentence" },
        "evidence": { "type": "string", "description": "what in the repository shows it" },
        "fix": { "type": "string", "description": "what the code must do instead" },
        "verdict_reason": {
          "type": "string",
          "description": "why the verification pass reached this verdict"
        },
        "settles": {
          "type": "string",
          "description": "what would settle an unconfirmed finding, empty for the others"
        },
        "disproving_location": {
          "type": "string",
          "description": "path:line that disproves a refuted finding, empty for the others"
        },
        "demonstration": {
          "type": "object",
          "description": "the case that shows a wrong result, all zero when the finding is not about a wrong count",
          "properties": {
            "items_count": { "type": "integer", "description": "how many items were passed in" },
            "size": { "type": "integer", "description": "the page size passed in" },
            "page": { "type": "integer", "description": "the page number passed in" },
            "expected_count": { "type": "integer", "description": "how many items that page should return" },
            "actual_count": { "type": "integer", "description": "how many it returns now" }
          },
          "required": ["items_count", "size", "page", "expected_count", "actual_count"],
          "additionalProperties": false
        },
        "failure": {
          "type": "string",
          "enum": ["exception", "startup_failure", "wrong_data", "graceful", "none"],
          "description": "how a dependent party fails, none when nothing outside this change fails"
        },
        "breaks_who": {
          "type": "array",
          "items": { "type": "string" },
          "description": "each party that depends on what changed, as a path or a name, empty when none does"
        }
      },
      "required": ["locations", "severity", "category", "claim", "evidence", "fix",
                   "verdict_reason", "settles", "disproving_location", "demonstration",
                   "failure", "breaks_who"],
      "additionalProperties": false
    }
  },
  "properties": {
    "confirmed": {
      "type": "array",
      "items": { "$ref": "#/$defs/entry" },
      "description": "the confirmed findings, sorted by severity"
    },
    "unconfirmed": {
      "type": "array",
      "items": { "$ref": "#/$defs/entry" },
      "description": "the findings neither confirmed nor refuted, each with what would settle it"
    },
    "refuted": {
      "type": "array",
      "items": { "$ref": "#/$defs/entry" },
      "description": "the findings disproved, each with the line that disproves it"
    },
    "coverage": {
      "type": "object",
      "properties": {
        "changed": { "type": "integer", "description": "how many files the comparison changes" },
        "reviewed": {
          "type": "array",
          "items": { "type": "string" },
          "description": "every changed file that was reviewed, as a repository-relative path"
        },
        "skipped": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "file": { "type": "string", "description": "the changed file that was not reviewed" },
              "reason": { "type": "string", "description": "why it was not" }
            },
            "required": ["file", "reason"],
            "additionalProperties": false
          }
        }
      },
      "required": ["changed", "reviewed", "skipped"],
      "additionalProperties": false
    }
  },
  "required": ["confirmed", "unconfirmed", "refuted", "coverage"],
  "additionalProperties": false
}
EOT

prompt="You are running the code review orchestrator skill at $skill. Read that file and follow it exactly. The sibling code-review-* skills it fans out to are in the same directory as that skill's own directory, one SKILL.md each, under $skills_root. Review the branch feature against main. The review is read-only, as the skill says: it changes no file, branch, index, or stash. Presentation only: return the report's content as JSON matching the schema instead of Markdown; every other instruction in the skill stands."

git_snapshot "$out/git-before.txt"
codex_json_run "$fixture" "$skills_root" "$out/schema.json" "$out/report.json" \
  "$out/report.log" "$prompt" || exit 2
git_snapshot "$out/git-after.txt"

# The rollout is found by the thread id the --json stream opens with.
thread_id=$(sed -n 's/.*"thread_id":"\([^"]*\)".*/\1/p' "$out/report.log" | head -1)
if [ -z "$thread_id" ]; then
  echo "spawn parameters: unverified"
  echo "no thread_id in $out/report.log" >&2
  exit 3
fi
rc=0
python3 "$out/rollout.py" "$thread_id" "${CODEX_SESSIONS:-$HOME/.codex/sessions}" \
  "$out/spawns.json" || rc=$?
if [ "$rc" = 3 ]; then
  echo "spawn parameters: unverified"
  exit 3
fi
[ "$rc" = 0 ] || exit 2

bundle "$out/run.json" "$out/report.json" "$out/spawns.json" \
  "$out/git-before.txt" "$out/git-after.txt"
assert "$out/run.json"
