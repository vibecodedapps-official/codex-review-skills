#!/usr/bin/env bash
# Helpers shared by the tests/*-check.sh scripts. Source it; running it does nothing.
#
#   make_tmp
#     Sets $tmp (removed on exit), $fixture ($tmp/fixture, the throwaway repository) and
#     $out ($tmp/out, schema, model output, logs and self-test files). With
#     CHECK_KEEP_TMP=1 the directory is kept and its path printed, so a live run's output
#     can be copied into a script as its control.
#
#   codex_json_run <cwd> <add_dir> <schema> <out_json> <log> <prompt> [codex args...]
#     One `codex exec` call that writes its last message to <out_json> under <schema>.
#     Extra codex arguments (--ephemeral, -c key=value) are forwarded as an array, so a
#     value with spaces stays one argument. stdin is closed because codex exec waits on
#     it when run from a pipe. stdout and stderr go to <log>; on failure the last 20 log
#     lines are printed and codex's exit code is returned.
#
#   self_test <assert_fn> <control.json> <mutations_dir> [assert args...]
#     Replays the assertions with no model call: <control.json> (an output observed from
#     a live run) must exit 0, and every <mutations_dir>/<predicate-id>[.<variant>].json
#     must exit 1 with a `FAIL: <predicate-id>` line, so a failing predicate is proven to
#     fail rather than assumed to. Prints one line per case; returns 0 only if every case
#     behaved.

make_tmp() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/$(basename "$0" .sh).XXXXXX")
  if [ "${CHECK_KEEP_TMP:-0}" = 1 ]; then
    echo "keeping $tmp" >&2
  else
    trap 'rm -rf "$tmp"' EXIT
  fi
  fixture=$tmp/fixture
  out=$tmp/out
  mkdir -p "$fixture" "$out"
}

codex_json_run() {
  local cwd=$1 add_dir=$2 schema=$3 out_json=$4 log=$5 prompt=$6 rc=0
  shift 6
  codex exec --cd "$cwd" --add-dir "$add_dir" -s read-only \
    --output-schema "$schema" -o "$out_json" --json "$@" "$prompt" \
    </dev/null >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "codex exec failed (exit $rc), last 20 lines of $log:" >&2
    tail -20 "$log" >&2
  fi
  return "$rc"
}

self_test() {
  local assert_fn=$1 control=$2 mutations=$3
  shift 3
  local bad=0 rc=0 output id pid mutation
  output=$("$assert_fn" "$control" "$@" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    echo "self-test PASS control $(basename "$control") (exit 0)"
  else
    bad=1
    echo "self-test FAIL control $(basename "$control") (exit $rc, expected 0)"
    printf '%s\n' "$output"
  fi
  for mutation in "$mutations"/*.json; do
    if [ ! -f "$mutation" ]; then
      echo "self-test FAIL no mutation files in $mutations"
      return 1
    fi
    id=$(basename "$mutation" .json)
    pid=${id%%.*}
    rc=0
    output=$("$assert_fn" "$mutation" "$@" 2>&1) || rc=$?
    if [ "$rc" = 1 ] && printf '%s\n' "$output" | grep -Eq "^FAIL: $pid( |\$)"; then
      echo "self-test PASS mutation $id (exit 1, FAIL: $pid)"
    else
      bad=1
      echo "self-test FAIL mutation $id (exit $rc, expected 1 with FAIL: $pid)"
      printf '%s\n' "$output"
    fi
  done
  return "$bad"
}
