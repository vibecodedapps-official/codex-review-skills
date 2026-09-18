#!/usr/bin/env bash
# Fixture content for eval 1 (correctness, pagination). Writes files into a directory and
# nothing else: no git, no cd, so the check script owns the repository and another check
# can source this file and build a repository of its own. Source it; running it does
# nothing.
#
#   write_eval1_base <dir>    app/list.py returns every item and validates size with a
#                             guard and a raise; app/legacy.py holds a pre-existing bug in
#                             clamp; app/util.py; ruff.toml selects F401
#   write_eval1_change <dir>  "paginate the list endpoint": list.py counts pages with
#                             floor division and returns [] from the last partial page, so
#                             its items are dropped; util.py gains an unused `import os`
#                             and the helper list.py calls, written with no defect
#   eval1_anchors <dir>       prints `name=path:line` for the lines the assertions accept:
#                             pages and guard (the planted defect), size_guard and
#                             size_raise (the validation a false claim would deny). Each
#                             is found by grep in the written file, so editing the fixture
#                             moves the anchor instead of silently stranding it.

# _eval1_emit <name> <dir> <file> <ere>: one `name=file:line` line per match, or an error
# and a nonzero return when the pattern matches nothing.
_eval1_emit() {
  local name=$1 dir=$2 file=$3 pattern=$4 found=0 line
  while IFS=: read -r line _; do
    found=1
    printf '%s=%s:%s\n' "$name" "$file" "$line"
  done < <(grep -nE -- "$pattern" "$dir/$file")
  [ "$found" = 1 ] || { echo "eval1_anchors: nothing matches /$pattern/ in $dir/$file" >&2; return 1; }
}

write_eval1_base() {
  local dir=$1
  mkdir -p "$dir/app"
  cat > "$dir/app/list.py" <<'EOT'
def list_items(items, page, size):
    """Return the items on one page. Pages are numbered from 0."""
    if size <= 0:
        raise ValueError("size must be greater than 0")
    return list(items)
EOT
  cat > "$dir/app/legacy.py" <<'EOT'
def clamp(x, lo, hi):
    """Return x limited to the range lo..hi."""
    return max(lo, min(x, lo))
EOT
  cat > "$dir/app/util.py" <<'EOT'
def slug(text):
    return text.strip().lower().replace(" ", "-")
EOT
  cat > "$dir/ruff.toml" <<'EOT'
[lint]
select = ["F401"]
EOT
}

write_eval1_change() {
  local dir=$1
  mkdir -p "$dir/app"
  cat > "$dir/app/list.py" <<'EOT'
from app.util import start_index


def list_items(items, page, size):
    """Return the items on one page. Pages are numbered from 0."""
    if size <= 0:
        raise ValueError("size must be greater than 0")
    pages = len(items) // size
    if page >= pages:
        return []
    start = start_index(page, size)
    return list(items[start:start + size])
EOT
  cat > "$dir/app/util.py" <<'EOT'
import os


def slug(text):
    return text.strip().lower().replace(" ", "-")


def start_index(page, size):
    """Index of the first item on a page."""
    return page * size
EOT
}

# Reads the change: the pagination lines exist only there.
eval1_anchors() {
  local dir=$1 file=app/list.py
  _eval1_emit pages "$dir" "$file" '^ +pages = len\(items\) // size$' || return 1
  _eval1_emit guard "$dir" "$file" '^ +if page >= pages:$' || return 1
  _eval1_emit size_guard "$dir" "$file" '^ +if size <= 0:$' || return 1
  _eval1_emit size_raise "$dir" "$file" '^ +raise ValueError\(' || return 1
}
