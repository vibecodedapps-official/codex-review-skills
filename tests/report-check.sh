#!/usr/bin/env bash
# Behavioral check for the Report section of the code-review skill. Builds a throwaway
# repository from tests/fixtures/eval1.sh with two commits and asks Codex to act as the
# orchestrator at its Report step over supplied merged findings, coverage totals and one
# pass that was not run, so the report itself is the only thing under test. One scenario,
# one model call, and the answer is raw Markdown, not JSON:
#
#   tests/report-check.sh [--self-test] [path/to/SKILL.md]
#
# The five supplied findings are what the Report rules have to sort, partition and carry:
#   f1  confirmed, high, the dropped last page, on the pages and the guard line (a merged
#       duplicate, so both locations must survive)
#   f2  confirmed, low, the unused import at app/util.py:1
#   f3  confirmed, medium, no test covers the last partial page, at the guard line again,
#       a distinct defect one line away from f1's second location
#   f4  unconfirmed, low, a caller passes a negative page, with what would settle it
#   f5  refuted, high, size is never validated, disproved at the size guard
# They are supplied in the order f2, f5, f4, f1, f3, so the sort by severity and the
# partition into confirmed, unconfirmed and refuted are the model's work. f4 is low, not
# medium, so no two findings share both a location and a severity: identity below rests on
# those two cues, the only ones a report copies rather than paraphrases.
#
# Predicates, one printed line each:
#   confirmed            f1, f3 and f2 in three numbered entries, in that severity order,
#                        each stating its own severity
#   confirmed-locations  every supplied location of f1, f2 and f3 cited, and no location
#                        the inputs never gave
#   unconfirmed          f4 once, unnumbered, under a heading of its own after the
#                        confirmed entries, with its location and what would settle it
#   refuted              f5 once, last, one line, with the disproving line
#   not-run              the change-size pass stated as not run, with a reason, before the
#                        coverage totals
#   coverage             the totals: files changed, reviewed, skipped, with the skipped
#                        file and its reason
#   no-tooling           no pass, model or tooling named outside the not-run statement
#
# The Report section fixes no heading wording, no wording for the not-run reason and no
# layout for the totals, so the predicates read only what it does fix. A finding is read
# as an entry: a start line, the locations and the severity word it copies, and the body
# under it, whether that body is indented, a paragraph of its own or a bullet list. The
# not-run statement and the totals are read anywhere outside the entries, since the
# section says only that the statement comes before the totals.
#
# The locations the findings carry come from eval1_anchors, read out of the fixture with
# grep, so editing the fixture moves them. The changed count comes from
# `git diff --name-only HEAD~1` in the fixture, so the coverage totals are read against
# the repository rather than against a number written here.
#
# --self-test makes no model call. It replays the assertions against the control, observed
# from a live run on 2026-09-18, codex-cli 0.155.0, model gpt-6-astra at effort high per
# ~/.codex/config.toml; the run was ephemeral, so no rollout confirms it. It also replays
# eight hand-written faithful reports, one per layout the Report section allows; each must
# pass every predicate, since a layout the section permits that a predicate rejects is a
# parser defect, not a report defect. Then one mutation per fact a predicate checks,
# generated from the control by moving that fact alone outside what it accepts, must fail
# with its predicate's id; a predicate that stopped reading one of its facts would leave
# that fact's mutation passing. The file is named `<predicate-id>.<fact>.json`, which
# self_test reads up to the first dot. A mutation may also fail another predicate, as when
# an invented location replaces f4's own; self_test asks only that a mutation fail its own
# predicate. Needs the codex CLI signed in otherwise. stdin is closed on the codex call
# because codex exec waits on it when run from a pipe.
#
# Exit codes: 0 every predicate held, 1 a predicate, a layout or a mutation did not, 2 the
# check could not run.
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

# The fixture is built before the self-test so both modes read the same anchors and the
# same changed count. ruff.toml is changed as well as the two Python files, so the
# coverage totals have a third file to skip.
cd "$fixture"
git init -q
git config user.email check@example.invalid
git config user.name check
write_eval1_base "$fixture"
git add -A && git commit -q -m "items"
write_eval1_change "$fixture"
printf 'line-length = 100\n' >> "$fixture/ruff.toml"
git add -A && git commit -q -m "paginate the list endpoint"
git diff --name-only HEAD~1 > "$out/changed.txt"

# `name=path:line` per line; word-split where it is passed, none of them holds a space.
anchor_args=$(eval1_anchors "$fixture")
anchor() { printf '%s\n' "$anchor_args" | sed -n "s/^$1=//p"; }
pages=$(anchor pages)
guard=$(anchor guard)
size_guard=$(anchor size_guard)
inputs="$anchor_args
changed=$(grep -c . "$out/changed.txt")"

# The predicates and the mutations share one table of what the report must hold, so a
# mutation is derived from the predicate it must break rather than written by hand.
cat > "$out/predicates.py" <<'PY'
import copy, json, os, re, sys

IDS = ("f1", "f2", "f3", "f4", "f5")
CONFIRMED = (0, 1, 2)  # f1, f2 and f3, whatever order a report files them in
UNCONFIRMED = 3
REFUTED = 4
RANK = {"high": 3, "medium": 2, "low": 1}
# a path:line or path:line-line anywhere in a line, so a location with a note beside it
# still reads
TOKEN = re.compile(r"([A-Za-z0-9_./-]+):(\d+)(?:-(\d+))?")
HEADING = re.compile(r"^ {0,3}#+\s")
MARKER = re.compile(r"^ {0,3}(?:\d+[.)]|[-*+])\s")
NUMBER = re.compile(r"^ {0,3}\d+[.)]\s")
NUMBER_HEADING = re.compile(r"^ {0,3}#+\s+\d+[.)]")
BULLET = re.compile(r"^( {0,3})[-*+](\s+)")
TABLE_LINE = re.compile(r"^ *\|")
SEPARATOR = re.compile(r"^[\s|:-]+$")
PASS_LINE = re.compile(r"change[- ]size", re.I)
KEYWORD = re.compile(r"\b(?:changed|reviewed|skipped)\b", re.I)
TOTAL = re.compile(r"(?:\d+)\s+(?:files?\s+)?(?:changed|reviewed|skipped)\b"
                   r"|\b(?:changed|reviewed|skipped)\W{0,3}\d+", re.I)
# words that state that the pass did not happen; "refused" is not one of them, it says why
STATUS = re.compile(r"not run|did not (?:run|complete|start|finish)|was not run|could not"
                    r"|couldn't|never ran|skipped|omitted|unable", re.I)
COMPLETION = re.compile(r"completed|complete|finished|succeeded|executed|ran\b", re.I)
PASS_NAME = re.compile(r"(?:the\s+)?(?:code-review-)?change[- ]size"
                       r"(?:\s+(?:pass|review|skill|agent|subagent))?", re.I)
FILLER = re.compile(r"\b(?:the|was|is|because|since|as|and|so|it)\b", re.I)
REASON_LINE = re.compile(r"^\s*Reason\b", re.I)
WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9'-]*")
NEGATORS = frozenset(("neither", "no", "not", "never", "without"))
TOOLING = re.compile(r"subagent|orchestrat|gpt|codex|astra|SKILL\.md|/Users/", re.I)
PASS_NAMES = re.compile(r"\b(?:correctness|guidelines?|testing|breaking[- ]changes?"
                        r"|change[- ]size|verification)\b[ -]+"
                        r"(?:pass|review|subagent|skill|agent)\b", re.I)
SKILL_NAMES = re.compile(r"code-review-[a-z]+|\$code-review")


def findings(inputs):
    """The five supplied findings in id order: the locations and the severity word, the
    only things a report copies. Nothing else is read for identity."""
    return [
        (IDS[0], [inputs["pages"], inputs["guard"]], "high"),
        (IDS[1], ["app/util.py:1"], "low"),
        (IDS[2], [inputs["guard"]], "medium"),
        (IDS[3], [inputs["guard"]], "low"),
        (IDS[4], [inputs["pages"], inputs["size_guard"]], "high"),
    ]


def supplied(inputs):
    return sorted({inputs["pages"], inputs["guard"], "app/util.py:1", inputs["size_guard"]})


def cites(text, accepted):
    """True when a location in <text> names one of the accepted lines, or a range holding
    it."""
    for path, start, end in TOKEN.findall(text):
        path = path.lstrip("./")
        for anchor in accepted:
            want, line = anchor.rsplit(":", 1)
            if path == want and int(start) <= int(line) <= int(end or start):
                return True
    return False


def score(text, finding):
    """Two points per supplied location cited, one for the supplied severity word."""
    _, locations, severity = finding
    points = 2 * sum(1 for loc in locations if cites(text, [loc]))
    if re.search(r"\b" + severity + r"\b", text, re.I):
        points += 1
    return points


def kind_of(line):
    if HEADING.match(line):
        return "heading"
    if MARKER.match(line):
        return "marker"
    if TABLE_LINE.match(line):
        return "table"
    return "paragraph"


def pass_line(lines):
    """The first line that names the pass. It starts the not-run statement, and it is no
    entry's body."""
    for i, line in enumerate(lines):
        if PASS_LINE.search(line):
            return i
    return None


def total_lines(lines):
    """Every line that reads as totals: a number beside a coverage keyword the way the
    totals are read ("3 files changed", "changed: 3"), emphasis aside, or a table row
    holding a keyword. Such a line starts an extent of its own and is no entry's body, so
    totals filed right after the last finding are not swallowed into it, while a finding's
    "Changed code: app/list.py:8" stays in its entry."""
    return [i for i, line in enumerate(lines)
            if (TABLE_LINE.match(line) and KEYWORD.search(line))
            or TOTAL.search(re.sub(r"[*_`]", "", line))]


def start_lines(lines, extra):
    """A heading, a top-level marker, an unindented line after a blank one, the first line
    of a table, the line that names the pass, a line of totals and the coverage start each
    begin an extent. An indented line and a nested marker never do, so a nested
    "- Locations: ..." belongs to the entry above it."""
    found = set()
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        if HEADING.match(line) or MARKER.match(line):
            found.add(i)
        elif TABLE_LINE.match(line):
            if i == 0 or not TABLE_LINE.match(lines[i - 1]):
                found.add(i)
        elif not line[:1].isspace() and (i == 0 or not lines[i - 1].strip()):
            found.add(i)
    named = pass_line(lines)
    if named is not None:
        found.add(named)
    found.update(total_lines(lines))
    if extra is not None:
        found.add(extra)
    return sorted(found)


def extent_at(lines, start, stop, finds):
    while stop > start and not lines[stop].strip():
        stop -= 1
    text = "\n".join(lines[start:stop + 1])
    return {"start": start, "end": stop, "text": text, "kind": kind_of(lines[start]),
            "numbered": bool(NUMBER.match(lines[start])
                             or NUMBER_HEADING.match(lines[start])),
            "scores": [score(text, f) for f in finds]}


def strict_top(extent):
    """The finding an extent points at on its own, or None when it ties or names none."""
    best = max(extent["scores"])
    if best < 1 or extent["scores"].count(best) > 1:
        return None
    return extent["scores"].index(best)


def extents(lines, starts, finds, protect):
    """One extent per start, running to the line before the next start, trailing blank
    lines trimmed; then what follows an entry, with only blank lines between them, is
    merged into it, since that is the entry's body. An entry is a numbered start, or one
    that points at a finding on its own: the contract leaves the unconfirmed entry
    unnumbered, and it fixes no shape for a body, which a report writes as indented lines,
    as paragraphs of its own, or as bullets. What follows stays separate when it is a
    heading or a numbered start, which are entries themselves, when it points at another
    finding on its own, and when it begins the not-run statement or the coverage totals,
    which are no entry's body."""
    out = []
    for n, start in enumerate(starts):
        stop = starts[n + 1] - 1 if n + 1 < len(starts) else len(lines) - 1
        got = extent_at(lines, start, stop, finds)
        prev = out[-1] if out else None
        if (prev and got["kind"] != "heading" and not got["numbered"]
                and start not in protect
                and (prev["numbered"] or strict_top(prev) is not None)):
            tops = (strict_top(prev), strict_top(got))
            if None in tops or tops[0] == tops[1]:
                out[-1] = extent_at(lines, prev["start"], got["end"], finds)
                out[-1]["numbered"] = prev["numbered"]
                out[-1]["kind"] = prev["kind"]
                continue
        out.append(got)
    return out


def assign(extents_):
    """One-to-one and greedy: every (extent, finding, score) triple scoring at least one
    point, by score descending, then extent position, then finding index; a triple is
    taken when neither its extent nor its finding is taken yet."""
    triples = sorted((-e["scores"][idx], pos, idx)
                     for pos, e in enumerate(extents_)
                     for idx in range(len(IDS)) if e["scores"][idx] >= 1)
    by_extent, by_finding = {}, {}
    for _, pos, idx in triples:
        if pos in by_extent or idx in by_finding:
            continue
        by_extent[pos] = idx
        by_finding[idx] = pos
    return by_extent, by_finding


def duplicates(extents_, by_extent):
    """An extent left unassigned that still cites a supplied location: the entry it
    repeats is its highest-scoring finding."""
    out = []
    for pos, e in enumerate(extents_):
        if pos in by_extent:
            continue
        best = max(e["scores"])
        if best >= 2:
            out.append((pos, e["scores"].index(best)))
    return out


def sentence_spans(text):
    """Text up to a period followed by whitespace, or to the end of the block."""
    spans, at = [], 0
    for m in re.finditer(r"\.(?=\s|$)", text):
        spans.append((at, m.end()))
        at = m.end()
    if text[at:].strip():
        spans.append((at, len(text)))
    return [(a, b) for a, b in spans if text[a:b].strip()]


def entry_lines(rep):
    """The line range of every entry, in document order."""
    return [(rep["extents"][pos]["start"], rep["extents"][pos]["end"])
            for pos in sorted(rep["by_extent"])]


def outside_entries(rep):
    """The line ranges no entry covers. The contract fixes no place for the not-run
    statement or the totals, so a report may file them above the findings, below them or
    between two of their sections; what an entry itself says is read as a finding and never
    as a total."""
    out, at = [], 0
    for first, last in entry_lines(rep):
        if at <= first - 1:
            out.append((at, first - 1))
        at = last + 1
    if at <= len(rep["lines"]) - 1:
        out.append((at, len(rep["lines"]) - 1))
    return out


def blocks(lines, first, last):
    """Each line with the lines that continue it: an indented line, or one that starts with
    Reason."""
    out, i = [], first
    while i <= last:
        if not lines[i].strip():
            i += 1
            continue
        j = i + 1
        while j <= last and lines[j].strip() and (lines[j][:1].isspace()
                                                  or REASON_LINE.match(lines[j])):
            j += 1
        out.append((i, j))
        i = j
    return out


def statement(rep):
    """The first sentence outside the findings region that names the pass, with the reason
    wherever the report breaks it off: a following sentence, line or paragraph that starts
    with Reason belongs to the statement, as do the lines that continue it."""
    lines, offsets = rep["lines"], rep["offsets"]
    for first, last in outside_entries(rep):
        found = blocks(lines, first, last)
        for n, (i, j) in enumerate(found):
            block = "\n".join(lines[i:j])
            spans = sentence_spans(block)
            for at, (a, b) in enumerate(spans):
                if not PASS_LINE.search(block[a:b]):
                    continue
                for c, d in spans[at + 1:]:
                    if not REASON_LINE.match(block[c:d]):
                        break
                    b = d
                start, end = offsets[i] + a, offsets[i] + b
                line = i
                while line + 1 < j and offsets[line + 1] <= end - 1:
                    line += 1
                tail = offsets[j - 1] + len(lines[j - 1])
                if line < j - 1:
                    end = tail
                for k, stop in found[n + 1:]:
                    if end != tail or not REASON_LINE.match(lines[k]):
                        break
                    end = tail = offsets[stop - 1] + len(lines[stop - 1])
                return {"text": rep["md"][start:end], "start": start, "end": end}
    return None


def negated(text, at):
    return bool(NEGATORS.intersection(w.lower() for w in WORD.findall(text[:at])[-3:]))


def gap(one, other):
    return max(0, one[0] - other[1], other[0] - one[1])


def pass_status(rep):
    """The pass's status is the status or completion match nearest the pass name, by
    character distance; a completion overlapping a status, or negated within three words
    before it, does not count."""
    st = rep["statement"]
    if not st:
        return None
    text = st["text"]
    name = PASS_NAME.search(text)
    if not name:
        return None
    stops = [(m.span(), "status") for m in STATUS.finditer(text)]
    for m in COMPLETION.finditer(text):
        if any(a < m.end() and m.start() < b for (a, b), _ in stops):
            continue
        if negated(text, m.start()):
            continue
        stops.append((m.span(), "completion"))
    if not stops:
        return None
    span, kind = min(stops, key=lambda stop: (gap(name.span(), stop[0]), stop[0][0]))
    return {"kind": kind, "text": text[span[0]:span[1]],
            "span": (st["start"] + span[0], st["start"] + span[1])}


def coverage_keyword(rep):
    """The first coverage keyword outside the entries and outside the not-run statement:
    its line starts the coverage region, its offset places the statement."""
    st = rep["statement"]
    for first, last in outside_entries(rep):
        for i in range(first, last + 1):
            for m in KEYWORD.finditer(rep["lines"][i]):
                at = rep["offsets"][i] + m.start()
                if st and st["start"] <= at < st["end"]:
                    continue
                return i, at
    return None


def coverage_chars(rep):
    """The coverage region: the line the first keyword sits on to the end of the document,
    the statement's own characters and the entries' lines excluded, so the statement and
    the totals may share a line and no finding is read as a total. Emphasis is stripped,
    and the document offset of every character is kept for the mutations."""
    md, st = rep["md"], rep["statement"]
    entries = [(rep["offsets"][first], rep["offsets"][last] + len(rep["lines"][last]))
               for first, last in entry_lines(rep)]
    keep = []
    for at in range(rep["offsets"][rep["coverage"][0]], len(md)):
        if st and st["start"] <= at < st["end"]:
            continue
        if any(first <= at <= last for first, last in entries):
            continue
        if md[at] in "*_`":
            continue
        keep.append(at)
    return "".join(md[at] for at in keep), keep


def cells(line, at):
    """The cells of a table row, each with its offset, without the outer pipes."""
    out, pos = [], 0
    for part in line.split("|"):
        out.append((part, at + pos))
        pos += len(part) + 1
    out = out[1:]
    if out and not out[-1][0].strip():
        out = out[:-1]
    return out


def table_run(rows, keyword):
    """The number in the data-row cell under the header cell holding the keyword."""
    if len(rows) < 3 or not SEPARATOR.match(rows[1][0]):
        return None
    header, data = cells(*rows[0]), cells(*rows[2])
    for n, (name, _) in enumerate(header):
        if not re.search(r"\b" + keyword + r"\b", name, re.I):
            continue
        if n >= len(data):
            return None
        m = re.search(r"\d+", data[n][0])
        return (int(m.group()), data[n][1] + m.start(), data[n][1] + m.end()) if m else None
    return None


def table_number(text, keyword):
    rows, at = [], 0
    for line in text.split("\n"):
        if TABLE_LINE.match(line):
            rows.append((line, at))
        else:
            hit = table_run(rows, keyword)
            if hit:
                return hit
            rows = []
        at += len(line) + 1
    return table_run(rows, keyword)


def line_number(text, keyword):
    """On one line of the region, whichever reading is adjacent: number first, else label
    first."""
    at = 0
    for line in text.split("\n"):
        for pattern in (r"(\d+)\s+(?:files?\s+)?" + keyword, keyword + r"\W{0,3}(\d+)"):
            m = re.search(pattern, line, re.I)
            if m:
                return int(m.group(1)), at + m.start(1), at + m.end(1)
        at += len(line) + 1
    return None


def totals(rep):
    """keyword -> the number and where its digits sit in the document."""
    text, keep = rep["chars"]
    out = {}
    for keyword in ("changed", "reviewed", "skipped"):
        hit = table_number(text, keyword) or line_number(text, keyword)
        if hit:
            out[keyword] = (hit[0], keep[hit[1]], keep[hit[2] - 1] + 1)
    return out


def layout(md, lines, finds, extra):
    offsets, at = [], 0
    for line in lines:
        offsets.append(at)
        at += len(line) + 1
    starts = start_lines(lines, extra)
    protect = {line for line in (pass_line(lines), extra) if line is not None}
    protect.update(total_lines(lines))
    found = extents(lines, starts, finds, protect)
    by_extent, by_finding = assign(found)
    positions = sorted(by_extent)
    rep = {"md": md, "lines": lines, "offsets": offsets, "starts": starts,
           "finds": finds, "extents": found, "by_extent": by_extent,
           "by_finding": by_finding, "duplicates": duplicates(found, by_extent),
           "region": (found[positions[0]]["start"], found[positions[-1]]["end"])
                     if positions else None}
    rep["statement"] = statement(rep)
    rep["status"] = pass_status(rep)
    return rep


CACHE = {}


def read(doc, inputs):
    """The document as the Report contract reads it. Cached on the Markdown, since every
    fact and every break asks for it again."""
    md = doc["markdown"]
    key = (md, tuple(sorted(inputs.items())))
    if key not in CACHE:
        lines = md.split("\n")
        finds = findings(inputs)
        rep = layout(md, lines, finds, None)
        found = coverage_keyword(rep)
        if found and found[0] not in rep["starts"]:
            rep = layout(md, lines, finds, found[0])
            found = coverage_keyword(rep)
        rep["coverage"] = found
        rep["chars"] = coverage_chars(rep) if found else ("", [])
        rep["totals"] = totals(rep)
        CACHE[key] = rep
    return CACHE[key]


def extent_for(rep, idx):
    pos = rep["by_finding"].get(idx)
    return None if pos is None else rep["extents"][pos]


def region_text(rep):
    first, last = rep["region"]
    return "\n".join(rep["lines"][first:last + 1])


def outside_pass(rep):
    """The document with the not-run statement's own characters left out, and nothing
    else: a sentence that follows it on the same line is still read."""
    st = rep["statement"]
    if not st:
        return rep["md"]
    return rep["md"][:st["start"]] + rep["md"][st["end"]:]


def after_statement(doc, rep, text):
    """A break that names a pass right after the not-run statement, on its line."""
    st = rep["statement"]
    doc["markdown"] = rep["md"][:st["end"]] + " " + text + rep["md"][st["end"]:]


def reason_words(rep):
    text = rep["statement"]["text"]
    for pattern in (PASS_NAME, STATUS, FILLER):
        text = pattern.sub(" ", text)
    return WORD.findall(text)


def fact(inputs, test):
    """A fact reads the parsed report, so every fact and every break shares one parse."""
    return lambda doc: test(read(doc, inputs))


def edit(inputs, apply):
    return lambda doc: apply(doc, read(doc, inputs))


def put(doc, lines):
    doc["markdown"] = "\n".join(lines)


def in_extent(doc, extent, pattern, replacement):
    lines = doc["markdown"].split("\n")
    for i in range(extent["start"], extent["end"] + 1):
        lines[i] = re.sub(pattern, replacement, lines[i])
    put(doc, lines)


def append_to_extent(doc, extent, text):
    lines = doc["markdown"].split("\n")
    for i in range(extent["end"], extent["start"] - 1, -1):
        if lines[i].strip():
            lines[i] = lines[i].rstrip() + " " + text
            break
    put(doc, lines)


def drop_extent(doc, rep, idx):
    """A break that leaves a supplied finding out of the report."""
    e = extent_for(rep, idx)
    lines = list(rep["lines"])
    del lines[e["start"]:e["end"] + 1]
    put(doc, lines)


def copy_extent(doc, rep, idx):
    """A break that files the same finding twice, in a section of its own: a repetition
    directly below an entry is that entry's body, whatever shape it takes."""
    e = extent_for(rep, idx)
    lines = list(rep["lines"])
    block = lines[e["start"]:e["end"] + 1]
    lines[e["end"] + 1:e["end"] + 1] = ["", "## Reported again", ""] + block
    put(doc, lines)


def swap_extents(doc, rep, one, other):
    """A break that files two confirmed findings out of severity order."""
    first, second = sorted((extent_for(rep, one), extent_for(rep, other)),
                           key=lambda e: e["start"])
    lines = list(rep["lines"])
    head = lines[first["start"]:first["end"] + 1]
    tail = lines[second["start"]:second["end"] + 1]
    lines[second["start"]:second["end"] + 1] = head
    lines[first["start"]:first["end"] + 1] = tail
    put(doc, lines)


def move_before(doc, rep, idx, other):
    """A break that files the refuted finding above the unconfirmed one."""
    e, ahead = extent_for(rep, idx), extent_for(rep, other)
    lines = list(rep["lines"])
    block = lines[e["start"]:e["end"] + 1]
    del lines[e["start"]:e["end"] + 1]
    lines[ahead["start"]:ahead["start"]] = block + [""]
    put(doc, lines)


def number_start(doc, rep, idx):
    """A break that numbers an entry the contract leaves unnumbered."""
    e = extent_for(rep, idx)
    lines = list(rep["lines"])
    line = lines[e["start"]]
    if BULLET.match(line):
        lines[e["start"]] = BULLET.sub(r"\g<1>4.\g<2>", line, count=1)
    elif HEADING.match(line):
        lines[e["start"]] = re.sub(r"^( {0,3}#+\s+)", r"\g<1>4. ", line, count=1)
    else:
        lines[e["start"]] = "4. " + line
    put(doc, lines)


def split_line(doc, rep, idx):
    """A break that spills a one-line entry onto a second, indented, line."""
    e = extent_for(rep, idx)
    lines = list(rep["lines"])
    line = lines[e["start"]]
    spaces = [n for n, ch in enumerate(line) if ch == " "]
    at = min(spaces, key=lambda n: abs(n - len(line) // 2))
    lines[e["start"]:e["start"] + 1] = [line[:at], "    " + line[at + 1:]]
    put(doc, lines)


def drop_heading_above(doc, rep, idx):
    """A break that leaves the unconfirmed entry with no heading of its own."""
    e = extent_for(rep, idx)
    last = max(pos for pos, taken in rep["by_extent"].items()
               if taken in CONFIRMED and rep["extents"][pos]["numbered"])
    lines = list(rep["lines"])
    for i in range(rep["extents"][last]["end"] + 1, e["start"]):
        if HEADING.match(lines[i]) and not NUMBER_HEADING.match(lines[i]):
            del lines[i]
            break
    put(doc, lines)


def set_total(doc, rep, keyword, value):
    """A break that reports a total the repository contradicts."""
    _, start, end = rep["totals"][keyword]
    doc["markdown"] = rep["md"][:start] + str(value) + rep["md"][end:]


def drop_in_coverage(doc, rep, pattern):
    """A break that drops what the coverage totals say about the skipped file."""
    at = rep["offsets"][rep["coverage"][0]]
    doc["markdown"] = rep["md"][:at] + re.sub(pattern, "", rep["md"][at:], flags=re.I)


def replace_statement(doc, rep, text):
    st = rep["statement"]
    doc["markdown"] = rep["md"][:st["start"]] + text + rep["md"][st["end"]:]


def replace_status(doc, rep, text):
    """A break that reports the pass as having run. The explanation's own words are
    untouched, and none of them is a status word."""
    start, end = rep["status"]["span"]
    doc["markdown"] = rep["md"][:start] + text + rep["md"][end:]


def move_statement_last(doc, rep):
    """A break that files the not-run statement after the coverage totals. What followed
    the statement on its line moves up to the line start, since an indented line would
    read as the line above continuing."""
    st = rep["statement"]
    head, tail = rep["md"][:st["start"]], rep["md"][st["end"]:]
    if head.endswith("\n") or not head:
        tail = tail.lstrip(" \t")
    doc["markdown"] = (head + tail).rstrip("\n") + "\n\n" + st["text"].strip() + "\n"


def table(inputs):
    """predicate id -> what the whole predicate says, the fact whose mutation keeps the
    plain file name, and the facts it holds: a key, the wording, the test over the parsed
    report, and the break one mutation applies to prove the test is still run. A fact
    about an extent that is absent holds vacuously; absence is caught by partition, one or
    stated, which their own mutations prove are read."""
    finds = findings(inputs)
    changed = int(inputs["changed"])

    def cited(idx, location):
        return fact(inputs, lambda rep: extent_for(rep, idx) is None
                    or cites(extent_for(rep, idx)["text"], [location]))

    def states(idx, word):
        return fact(inputs, lambda rep: extent_for(rep, idx) is None
                    or bool(re.search(r"\b" + word + r"\b",
                                      extent_for(rep, idx)["text"], re.I)))

    def once(idx):
        return fact(inputs, lambda rep: idx in rep["by_finding"]
                    and not any(taken == idx for _, taken in rep["duplicates"]))

    def partition(rep):
        numbered = [pos for pos, e in enumerate(rep["extents"]) if e["numbered"]]
        if len(numbered) != len(CONFIRMED):
            return False
        if sorted(rep["by_extent"].get(pos, -1) for pos in numbered) != list(CONFIRMED):
            return False
        return not any(taken in CONFIRMED for _, taken in rep["duplicates"])

    def order(rep):
        ranks = [RANK[finds[rep["by_extent"][pos]][2]] for pos in sorted(rep["by_extent"])
                 if rep["by_extent"][pos] in CONFIRMED]
        return all(one >= other for one, other in zip(ranks, ranks[1:]))

    def no_invented(rep):
        if not rep["region"]:
            return True
        accepted = supplied(inputs)
        return all(cites(m.group(), accepted) for m in TOKEN.finditer(region_text(rep)))

    def own_heading(rep):
        e = extent_for(rep, UNCONFIRMED)
        above = [pos for pos, taken in rep["by_extent"].items()
                 if taken in CONFIRMED and rep["extents"][pos]["numbered"]]
        if e is None or not above:
            return True
        last = rep["extents"][max(above)]
        return any(HEADING.match(line) and not NUMBER_HEADING.match(line)
                   for line in rep["lines"][last["end"] + 1:e["start"]])

    def last_extent(rep):
        e = extent_for(rep, REFUTED)
        if e is None:
            return True
        ahead = extent_for(rep, UNCONFIRMED)
        if ahead is not None and e["start"] < ahead["start"]:
            return False
        return not any(rep["extents"][pos]["start"] > e["start"] for pos in rep["by_extent"])

    def one_line(rep):
        e = extent_for(rep, REFUTED)
        return e is None or len([line for line in e["text"].split("\n") if line.strip()]) == 1

    def total_is(keyword, value):
        return fact(inputs, lambda rep: rep["totals"].get(keyword, (None,))[0] == value)

    def in_coverage(pattern):
        return fact(inputs, lambda rep: bool(re.search(pattern, rep["chars"][0], re.I)))

    return {
        "confirmed": ("f1, f3 and f2 numbered, in that order, each with its severity",
                      "partition", [
                          ("partition", "three numbered entries for f1, f2 and f3",
                           fact(inputs, partition), edit(inputs, lambda doc, rep:
                                                         drop_extent(doc, rep, 2))),
                          ("order", "severity not rising down the entries",
                           fact(inputs, order), edit(inputs, lambda doc, rep:
                                                     swap_extents(doc, rep, 2, 1))),
                          ("severity-f1", "f1 high", states(0, "high"),
                           edit(inputs, lambda doc, rep:
                                in_extent(doc, extent_for(rep, 0), r"(?i)high", "medium"))),
                          ("severity-f2", "f2 low", states(1, "low"),
                           edit(inputs, lambda doc, rep:
                                in_extent(doc, extent_for(rep, 1), r"(?i)low", "high"))),
                          ("severity-f3", "f3 medium", states(2, "medium"),
                           edit(inputs, lambda doc, rep:
                                in_extent(doc, extent_for(rep, 2), r"(?i)medium", "high"))),
                      ]),
        "confirmed-locations": ("every supplied location of f1, f2 and f3, and no other",
                                "f1-pages", [
                                    ("f1-pages", "f1 cites " + inputs["pages"],
                                     cited(0, inputs["pages"]),
                                     edit(inputs, lambda doc, rep:
                                          in_extent(doc, extent_for(rep, 0), TOKEN,
                                                    inputs["guard"]))),
                                    ("f1-guard", "f1 cites " + inputs["guard"],
                                     cited(0, inputs["guard"]),
                                     edit(inputs, lambda doc, rep:
                                          in_extent(doc, extent_for(rep, 0), TOKEN,
                                                    inputs["pages"]))),
                                    ("f2", "f2 cites app/util.py:1",
                                     cited(1, "app/util.py:1"),
                                     edit(inputs, lambda doc, rep:
                                          in_extent(doc, extent_for(rep, 1),
                                                    r"app/util\.py:1", ""))),
                                    ("f3", "f3 cites " + inputs["guard"],
                                     cited(2, inputs["guard"]),
                                     edit(inputs, lambda doc, rep:
                                          in_extent(doc, extent_for(rep, 2),
                                                    re.escape(inputs["guard"]), ""))),
                                    ("no-invented", "no location the inputs never gave",
                                     fact(inputs, no_invented),
                                     edit(inputs, lambda doc, rep:
                                          append_to_extent(doc, extent_for(rep, 0),
                                                           "app/list.py:3"))),
                                ]),
        "unconfirmed": ("f4 once, unnumbered, under its own heading, with its location and "
                        "what would settle it", "one", [
                            ("one", "f4 once", once(UNCONFIRMED),
                             edit(inputs, lambda doc, rep:
                                  copy_extent(doc, rep, UNCONFIRMED))),
                            ("own-heading", "a heading of its own above it",
                             fact(inputs, own_heading),
                             edit(inputs, lambda doc, rep:
                                  drop_heading_above(doc, rep, UNCONFIRMED))),
                            ("unnumbered", "not numbered",
                             fact(inputs, lambda rep: extent_for(rep, UNCONFIRMED) is None
                                  or not extent_for(rep, UNCONFIRMED)["numbered"]),
                             edit(inputs, lambda doc, rep:
                                  number_start(doc, rep, UNCONFIRMED))),
                            ("location", "cites " + inputs["guard"],
                             cited(UNCONFIRMED, inputs["guard"]),
                             edit(inputs, lambda doc, rep:
                                  in_extent(doc, extent_for(rep, UNCONFIRMED),
                                            re.escape(inputs["guard"]), "app/list.py:3"))),
                            ("settles", "says the caller that would settle it",
                             fact(inputs, lambda rep: extent_for(rep, UNCONFIRMED) is None
                                  or (re.search(r"caller", extent_for(rep, UNCONFIRMED)["text"], re.I)
                                      and re.search(r"forward|request|parameter",
                                                    extent_for(rep, UNCONFIRMED)["text"], re.I))),
                             edit(inputs, lambda doc, rep:
                                  in_extent(doc, extent_for(rep, UNCONFIRMED),
                                            r"(?i)caller|forward\w*|request\w*|parameter\w*",
                                            ""))),
                        ]),
        "refuted": ("f5 once, last, one line, with the disproving line", "one", [
            ("one", "f5 once", once(REFUTED),
             edit(inputs, lambda doc, rep: copy_extent(doc, rep, REFUTED))),
            ("last", "after f4 and after every other entry", fact(inputs, last_extent),
             edit(inputs, lambda doc, rep: move_before(doc, rep, REFUTED, UNCONFIRMED))),
            ("one-line", "one line", fact(inputs, one_line),
             edit(inputs, lambda doc, rep: split_line(doc, rep, REFUTED))),
            ("location", "cites " + inputs["size_guard"],
             cited(REFUTED, inputs["size_guard"]),
             edit(inputs, lambda doc, rep:
                  in_extent(doc, extent_for(rep, REFUTED),
                            re.escape(inputs["size_guard"]), "app/list.py:3"))),
        ]),
        "not-run": ("the change-size pass stated as not run, with a reason, before the "
                    "totals", "stated", [
                        ("stated", "stated as not run",
                         fact(inputs, lambda rep: bool(rep["status"])
                              and rep["status"]["kind"] == "status"),
                         edit(inputs, lambda doc, rep:
                              replace_status(doc, rep, "completed"))),
                        ("reason", "a reason beyond the name and the status",
                         fact(inputs, lambda rep: not rep["statement"]
                              or len(reason_words(rep)) >= 2),
                         edit(inputs, lambda doc, rep:
                              replace_statement(doc, rep,
                                                "The change-size pass was not run."))),
                        ("placement", "before the first coverage keyword",
                         fact(inputs, lambda rep: not rep["statement"] or not rep["coverage"]
                              or rep["statement"]["start"] < rep["coverage"][1]),
                         edit(inputs, move_statement_last)),
                    ]),
        "coverage": ("the totals the correctness pass gave, with the skipped file and its "
                     "reason", "changed", [
                         ("changed", "changed " + str(changed),
                          total_is("changed", changed),
                          edit(inputs, lambda doc, rep:
                               set_total(doc, rep, "changed", changed + 1))),
                         ("reviewed", "reviewed 2", total_is("reviewed", 2),
                          edit(inputs, lambda doc, rep:
                               set_total(doc, rep, "reviewed", 3))),
                         ("skipped", "skipped 1", total_is("skipped", 1),
                          edit(inputs, lambda doc, rep:
                               set_total(doc, rep, "skipped", 0))),
                         ("skipped-file", "names ruff.toml", in_coverage(r"ruff\.toml"),
                          edit(inputs, lambda doc, rep:
                               drop_in_coverage(doc, rep, r"ruff\.toml"))),
                         ("skipped-reason", "says why it was skipped",
                          in_coverage(r"linter|config"),
                          edit(inputs, lambda doc, rep:
                               drop_in_coverage(doc, rep, r"linter\w*|config\w*"))),
                     ]),
        "no-tooling": ("no pass, model or tooling named outside the not-run statement",
                       "tokens", [
                           ("tokens", "no model or tooling named",
                            fact(inputs, lambda rep: not TOOLING.search(rep["md"])),
                            edit(inputs, lambda doc, rep:
                                 append_to_extent(doc, extent_for(rep, 0), "subagent"))),
                           ("pass-names", "no review pass named",
                            fact(inputs, lambda rep: not PASS_NAMES.search(outside_pass(rep))),
                            edit(inputs, lambda doc, rep:
                                 after_statement(doc, rep,
                                                 "The correctness pass found this defect."))),
                           ("skill-names", "no skill named",
                            fact(inputs, lambda rep: not SKILL_NAMES.search(outside_pass(rep))),
                            edit(inputs, lambda doc, rep:
                                 append_to_extent(doc, extent_for(rep, 0),
                                                  "Source: code-review-correctness."))),
                       ]),
    }


def describe(rep):
    for pos, e in enumerate(rep["extents"]):
        taken = rep["by_extent"].get(pos)
        print(f"  line {e['start'] + 1} {'numbered' if e['numbered'] else e['kind']}"
              f" -> {IDS[taken] if taken is not None else '-'} scores={e['scores']}")
    for pos, taken in rep["duplicates"]:
        print(f"  duplicate line {rep['extents'][pos]['start'] + 1} -> {IDS[taken]}")
    st, status = rep["statement"], rep["status"]
    print(f"  not run: {st['text'].strip() if st else '-'}")
    print(f"    status: {status['kind'] + ' ' + repr(status['text']) if status else '-'}")
    print("  totals: " + (", ".join(f"{k} {v[0]}" for k, v in rep["totals"].items()) or "-"))


def check(doc, inputs):
    bad = 0

    def report(ok, pid, msg):
        nonlocal bad
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {pid} {msg}")

    describe(read(doc, inputs))
    for pid, (says, _, facts) in table(inputs).items():
        missed = [word for _, word, holds, _ in facts if not holds(doc)]
        report(not missed, pid, says + ("" if not missed else "; missing " + ", ".join(missed)))
    return 1 if bad else 0


def mutate(control, dest, inputs):
    """One file per fact, each the control with that fact alone moved outside what the
    predicate accepts, so every fact is proven to be read. Isolation is checked here
    rather than trusted: a break that also moves a sibling fact of the same predicate
    would leave that fact's own mutation passing for the wrong reason."""
    made = []
    for pid, (_, plain, facts) in table(inputs).items():
        for key, _, holds, break_it in facts:
            if not holds(control):
                raise ValueError(f"control already fails {pid}: {key}")
            doc = copy.deepcopy(control)
            break_it(doc)
            if holds(doc):
                raise ValueError(f"the break for {pid}: {key} leaves the fact holding")
            for other, _, sibling, _ in facts:
                if other != key and not sibling(doc):
                    raise ValueError(f"the break for {pid}: {key} also fails {pid}: {other}")
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

# wrap <report.md> <report.json>: the report as {"markdown": ...}, so the self_test
# contract over *.json files holds for a Markdown answer too.
wrap() {
  python3 -c 'import json, sys
json.dump({"markdown": open(sys.argv[1]).read()}, open(sys.argv[2], "w"), indent=2)' "$1" "$2"
}

# assert <report.json>. The anchors and the changed count are what the locations and the
# coverage totals are read against.
assert() {
  python3 "$out/predicates.py" check "$1" $inputs
}

if [ "$self_test_mode" = 1 ]; then
  mkdir -p "$out/layouts" "$out/mutations"

  # Faithful reports, one per layout the Report section allows, since it fixes no heading
  # wording, no heading for the refuted findings, no shape for an entry's body and no
  # place or layout for the totals. Each carries the five findings with the fixture's own
  # anchors and must pass every predicate: a layout that fails is a parser defect, not a
  # report defect.
  cat > "$out/layouts/list.md" <<EOT
# Code review

1. High. The last partial page is dropped ($pages, $guard). With 5 items and size 2 the count is 2, so page 2 returns [] instead of [5]. Count the pages so the final partial page is returned.
2. Medium. No test covers the last partial page ($guard). Add a case with 5 items, size 2 and page 2.
3. Low. app/util.py:1 adds an unused import os. Remove it.

## Unconfirmed

- Low. A caller passes a negative page ($guard). What would settle it: the caller that forwards the request's page parameter unchecked.

## Refuted

- High. Size is never validated ($pages): disproved at $size_guard.

The change-size pass was not run: the spawn was refused twice for the concurrency cap.

Files changed: 3, reviewed: 2, skipped: 1 (ruff.toml, linter configuration, no code).
EOT

  cat > "$out/layouts/headings.md" <<EOT
# Review of the pagination change

### 1. High: the last partial page is dropped ($pages, $guard)

Floor division counts the pages, so with 5 items and size 2 the count is 2 and page 2
returns [] instead of [5]. Count the pages so the final partial page is returned.

### 2. Medium: no test covers the last partial page

The last partial page at $guard is uncovered: no case asks for a page that is not full.

### 3. Low: app/util.py:1 adds an unused import

import os is never used, and the repository's linter selects F401.

## Unconfirmed

Low: a caller passes a negative page at $guard. What would settle it: the caller that
forwards the request's page parameter without checking it.

## Refuted

High: size is never validated ($pages), disproved at $size_guard.

The change-size pass could not be run; the spawn was refused twice for the concurrency cap.

- Files changed: 3
- Files reviewed: 2
- Files skipped: 1, ruff.toml (linter configuration, no code)
EOT

  cat > "$out/layouts/nested.md" <<EOT
1. High. The last partial page is dropped.
    - Locations: $pages, $guard
    - With 5 items and size 2 the page count is 2, so page 2 returns [] instead of [5].
    - Count the pages so the final partial page is returned.
2. Medium. No test covers the last partial page.
    - Locations: $guard
    - No case asks for a last page that is not full.
3. Low. An unused import.
    - Locations: app/util.py:1
    - import os is never used.

## Unconfirmed

- Low. A caller passes a negative page.
    - Locations: $guard
    - What would settle it: the caller that forwards the request's page parameter unchecked.

Refuted: high, size is never validated at $pages, disproved at $size_guard.

## Coverage

The change-size pass was not run, since the spawn was refused twice for the concurrency cap.

| Changed | Reviewed | Skipped |
| --- | --- | --- |
| 3 | 2 | 1 |

Skipped: ruff.toml, linter configuration, no code.
EOT

  cat > "$out/layouts/twoline.md" <<EOT
1) High. The last partial page is dropped at $pages and $guard: with 5 items and size 2 the count is 2, so page 2 returns [] instead of [5].
2) Medium. No test covers the last partial page at $guard.
3) Low. app/util.py:1 adds an unused import os.

## Unconfirmed

- Low. A caller passes a negative page at $guard. What would settle it: the caller that forwards the request's page parameter unchecked.

## Refuted

- High. Size is never validated at $pages, disproved at $size_guard.

The code-review-change-size pass was not run.
Reason: the spawn was refused twice for the concurrency cap.

Files changed: 3, files reviewed: 2, files skipped: 1 (ruff.toml, linter configuration, no code).
EOT

  cat > "$out/layouts/bullets.md" <<EOT
## Confirmed findings

1. **high**: $pages, $guard
   - What is wrong: the last partial page is dropped whenever the number of items is not a multiple of size.
   - Why it matters: with 5 items and size 2 the count is 2, so page 2 returns [] instead of [5].
   - What the code must do: count the pages so the final partial page is still returned.

2. **medium**: $guard
   - What is wrong: no test covers the last partial page.
   - Why it matters: no case asks for a page that is not full, so the dropped tail would go unnoticed.
   - What the code must do: add a case with 5 items, size 2 and page 2.

3. **low**: app/util.py:1
   - What is wrong: the file adds an unused import os.
   - Why it matters: nothing in the file uses os, and the linter config selects F401.
   - What the code must do: drop the import.

## Unconfirmed findings

**low**: $guard

- What is wrong: a caller passes a negative page to list_items, and the page guard lets it through.
- Why it matters: with 5 items and size 2 the guard is false for page -2, so the slice returns items from the end of the list instead of an empty page.
- What the code must do: reject a page below 0 before slicing.
- What would settle it: the caller that forwards the request's page parameter unchecked.

## Refuted findings

- **high**: $pages, size is never validated. Disproved at $size_guard.

The change-size pass was not run: the spawn was refused twice for the concurrency cap.

Coverage: 3 files changed, 2 reviewed, 1 skipped (ruff.toml: linter configuration, no code).
EOT

  cat > "$out/layouts/between.md" <<EOT
## Confirmed findings

1. High: the last partial page is dropped at $pages and $guard. With 5 items and size 2 the count is 2, so page 2 returns [] instead of [5].
2. Medium: no test covers the last partial page at $guard.
3. Low: app/util.py:1 adds an unused import os.

## Unconfirmed findings

- Low: a caller passes a negative page at $guard. What would settle it: the caller that forwards the request's page parameter unchecked.

The change-size pass was not run: the spawn was refused twice for the concurrency cap.

- Files changed: 3
- Files reviewed: 2
- Files skipped: 1, ruff.toml (linter configuration, no code)

## Refuted findings

- High: size is never validated at $pages, disproved at $size_guard.
EOT

  cat > "$out/layouts/trailing.md" <<EOT
The change-size pass was not run: the spawn was refused twice for the concurrency cap.

1. High. The last partial page is dropped. With 5 items and size 2 the count is 2, so page 2 returns [] instead of [5].
   Changed code: $pages, $guard
2. Medium. No test covers the last partial page ($guard).
3. Low. app/util.py:1 adds an unused import os.

## Unconfirmed

- Low. A caller passes a negative page ($guard). What would settle it: the caller that forwards the request's page parameter unchecked.

## Refuted

- High. Size is never validated ($pages): disproved at $size_guard.

Files changed: 3, reviewed: 2, skipped: 1 (ruff.toml, linter configuration, no code).
EOT

  cat > "$out/layouts/oneline.md" <<EOT
1. High. The last partial page is dropped at $pages and $guard: 5 items with size 2 give a count of 2, so page 2 returns [] instead of [5].
2. Medium. No test covers the last partial page at $guard.
3. Low. app/util.py:1 adds an unused import os.

## Unconfirmed

Low. A caller passes a negative page at $guard. What would settle it: the caller that forwards the request's page parameter unchecked.

## Refuted

High. Size is never validated at $pages, disproved at $size_guard.

The change-size pass was not run, since the spawn was refused twice for the concurrency cap. Files changed: **3**, reviewed: **2**, skipped: **1** (ruff.toml, linter configuration, no code).
EOT

  # Observed live output. If a later run disagrees with it, report the difference rather
  # than editing the control to match it.
  cat > "$out/control.md" <<'EOT'
Comparison: `HEAD~1` against `HEAD`.
Stated intent: “paginate the list endpoint”.

Pass not run: change-size. Reason: the spawn was refused twice for the concurrency cap.

Coverage: 3 files changed (`app/list.py`, `app/util.py`, `ruff.toml`); 2 reviewed (`app/list.py` and `app/util.py`); 1 skipped (`ruff.toml`: linter configuration, no code).

## Confirmed findings

1. **f1 — severity: high**  
   `app/list.py:8`, `app/list.py:9`  
   **What is wrong:** the last partial page is dropped whenever the number of items is not a multiple of size.  
   **Why it matters:** the page count floors, so for 5 items with size 2 the count is 2 and page 2 returns [] instead of [5]. Every list whose length is not a multiple of the page size loses its tail.  
   **What the code must do:** count the pages so the final partial page is still returned.

2. **f3 — severity: medium**  
   `app/list.py:9`  
   **What is wrong:** no test covers the last partial page.  
   **Why it matters:** no case asks for a page that is not full, so the dropped tail would not be caught by a run of the suite.  
   **What the code must do:** add a case with 5 items, size 2 and page 2.

3. **f2 — severity: low**  
   `app/util.py:1`  
   **What is wrong:** the file adds an unused import os.  
   **Why it matters:** nothing in the file uses os, and the repository's linter config selects F401.  
   **What the code must do:** drop the import.

## Unconfirmed findings

**f4 — severity: low**  
`app/list.py:9`  
**What is wrong:** a caller passes a negative page to list_items, and the page guard lets it through.  
**Why it matters:** with 5 items and size 2 the guard is false for page -2, so the slice returns items from the end of the list instead of an empty page.  
**What the code must do:** reject a page below 0 before slicing.  
**What would settle it:** the caller that forwards the request's page parameter unchecked.

## Refuted findings

- **f5 — severity: high** — `app/list.py:8`: list_items never validates size. Disproving location: `app/list.py:6`.
EOT

  echo "== layouts"
  bad=0
  for layout in "$out"/layouts/*.md; do
    name=$(basename "$layout" .md)
    wrap "$layout" "$out/layouts/$name.json"
    rc=0
    output=$(assert "$out/layouts/$name.json" 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then
      echo "layout PASS $name (exit 0)"
    else
      bad=1
      echo "layout FAIL $name (exit $rc, expected 0)"
      printf '%s\n' "$output"
    fi
  done

  echo "== self-test"
  wrap "$out/control.md" "$out/control.json"
  python3 "$out/predicates.py" mutate "$out/control.json" "$out/mutations" $inputs
  self_test assert "$out/control.json" "$out/mutations" || bad=$?
  exit "$bad"
fi

# Written out rather than built inline: a here-document inside $( ) is still lexed for
# quotes, so an apostrophe in the findings would break the script.
cat > "$out/prompt.txt" <<EOT
The code review skill is at $skill. Read that file. Act as the orchestrator at its Report
step. Every pass and the verification subagent have already returned; their merged output
follows. Write the report the Report section describes, as raw Markdown, and nothing else.
Do not run any pass, verify, or add, drop, or reword a finding.

The comparison is the diff of HEAD~1 against HEAD in this repository. The stated intent is
the commit message of HEAD: "paginate the list endpoint".

Coverage totals from the correctness pass: 3 files changed (app/list.py, app/util.py,
ruff.toml), 2 reviewed (app/list.py and app/util.py), 1 skipped (ruff.toml: linter
configuration, no code).

Passes not run: one, the change-size pass. Reason: the spawn was refused twice for the
concurrency cap.

Five merged findings with their verdicts follow, each in the finding format the skill
gives its subagents, under its id.

f2
verdict: confirmed
app/util.py:1
severity: low
What is wrong: the file adds an unused import os.
Why it matters: nothing in the file uses os, and the repository's linter config selects
F401.
What the code must do: drop the import.

f5
verdict: refuted
$pages
severity: high
disproving_location: $size_guard
What is wrong: list_items never validates size.
Why it matters: len(items) // size divides by size with nothing checking it first, so a
request with size 0 raises ZeroDivisionError out of the endpoint.
What the code must do: reject a size of 0 or less before counting pages.

f4
verdict: unconfirmed
$guard
severity: low
What would settle it: the caller that forwards the request's page parameter unchecked.
What is wrong: a caller passes a negative page to list_items, and the page guard lets it
through.
Why it matters: with 5 items and size 2 the guard is false for page -2, so the slice
returns items from the end of the list instead of an empty page.
What the code must do: reject a page below 0 before slicing.

f1
verdict: confirmed
$pages, $guard
severity: high
What is wrong: the last partial page is dropped whenever the number of items is not a
multiple of size.
Why it matters: the page count floors, so for 5 items with size 2 the count is 2 and page
2 returns [] instead of [5]. Every list whose length is not a multiple of the page size
loses its tail.
What the code must do: count the pages so the final partial page is still returned.

f3
verdict: confirmed
$guard
severity: medium
What is wrong: no test covers the last partial page.
Why it matters: no case asks for a page that is not full, so the dropped tail would not be
caught by a run of the suite.
What the code must do: add a case with 5 items, size 2 and page 2.
EOT
prompt=$(cat "$out/prompt.txt")

codex_json_run "$fixture" "$(dirname "$skill")" "" "$out/report.md" \
  "$out/report.log" "$prompt" --ephemeral || exit 2
wrap "$out/report.md" "$out/run.json"
assert "$out/run.json"
