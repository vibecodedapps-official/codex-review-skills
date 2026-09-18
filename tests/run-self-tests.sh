#!/usr/bin/env bash
# Runs every tests/*-check.sh with --self-test: the assertions alone, over each check's
# control and mutation files, with no model call. Prints one line per check and exits
# nonzero if any check failed or if there is no check to run.
#
#   tests/run-self-tests.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0
ran=0
for script in "$here"/*-check.sh; do
  [ -f "$script" ] || continue
  name=$(basename "$script")
  ran=$((ran + 1))
  echo "== $name --self-test"
  rc=0
  "$script" --self-test || rc=$?
  if [ "$rc" = 0 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (exit $rc)"
    fail=1
  fi
done
if [ "$ran" = 0 ]; then
  echo "FAIL: no *-check.sh in $here"
  fail=1
fi
exit $fail
