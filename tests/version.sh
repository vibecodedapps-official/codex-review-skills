#!/usr/bin/env bash
# Checks that the plugin manifest's `version` and the newest CHANGELOG.md entry name the
# same release, so a skill change cannot ship without its entry. No model call:
#
#   tests/version.sh              compares this repository's manifest and changelog
#   tests/version.sh --self-test  runs the comparison over temp-file pairs, reading no
#                                 repository file, and prints one line per case
#
# Both versions are printed either way; the exit code is 0 when they match and 1 when
# they do not, including when the changelog has no version heading yet.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
fail=0

# The one comparison both modes use: manifest path, changelog path.
compare_versions() {
  local manifest=$1 changelog=$2 manifest_version changelog_version
  manifest_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$manifest")
  changelog_version=$(sed -n -E '/^## \[?[0-9]+\.[0-9]+\.[0-9]+\]?/{s/^## \[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p;q;}' "$changelog")
  echo "plugin.json:  ${manifest_version:-none}"
  echo "CHANGELOG.md: ${changelog_version:-none}"
  if [ -n "$changelog_version" ] && [ "$manifest_version" = "$changelog_version" ]; then
    return 0
  fi
  echo "FAIL: the manifest version and the newest changelog entry differ"
  return 1
}

# Writes a manifest holding $version and a changelog holding $heading_block, which may be
# several lines and may hold no version heading at all.
write_pair() {
  local dir=$1 version=$2 heading_block=$3
  mkdir -p "$dir"
  printf '{\n  "name": "codex-review-skills",\n  "version": "%s"\n}\n' "$version" >"$dir/plugin.json"
  {
    echo "# Changelog"
    echo
    if [ -n "$heading_block" ]; then
      printf '%s\n\n' "$heading_block"
    fi
    echo "- an entry"
  } >"$dir/CHANGELOG.md"
}

# Runs the comparison over one pair and checks the exit code, then that the output holds
# every remaining argument.
check_case() {
  local name=$1 dir=$2 want_rc=$3 rc=0 ok=1 output want
  shift 3
  output=$(compare_versions "$dir/plugin.json" "$dir/CHANGELOG.md" 2>&1) || rc=$?
  [ "$rc" = "$want_rc" ] || ok=0
  for want in "$@"; do
    case $output in
      *"$want"*) ;;
      *) ok=0 ;;
    esac
  done
  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (exit $rc, wanted $want_rc)"
    printf '%s\n' "$output"
    fail=1
  fi
}

self_test() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/version.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT

  write_pair "$tmp/bracketed" 0.3.0 '## [0.3.0] - 2026-09-18'
  check_case bracketed "$tmp/bracketed" 0 0.3.0

  write_pair "$tmp/bare" 1.2.3 '## 1.2.3 - 2026-09-18'
  check_case bare "$tmp/bare" 0 1.2.3

  write_pair "$tmp/mismatch" 0.3.0 '## [0.2.0] - 2026-09-18'
  check_case mismatch "$tmp/mismatch" 1 0.3.0 0.2.0

  write_pair "$tmp/no-heading" 0.3.0 ''
  check_case no-heading "$tmp/no-heading" 1 0.3.0 none

  exit $fail
}

if [ "${1:-}" = --self-test ]; then
  self_test
fi

compare_versions "$root/plugins/codex-review-skills/.codex-plugin/plugin.json" \
  "$root/CHANGELOG.md"
