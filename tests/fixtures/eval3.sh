#!/usr/bin/env bash
# Fixture content for eval 3, the code-review-testing skill: an import pipeline whose
# pytest suite reads its records from tests/fixtures, a change to the key the duplicate
# match uses, and a new test that asserts only that a mock store was called. Sourced by
# tests/testing-check.sh; these functions write files and nothing else, so the check
# script owns git and the working directory.
#
#   write_eval3_base <dir>    the repository as it is committed: pytest configuration,
#                             tests/conftest.py loading tests/fixtures/records.json,
#                             tests/test_import.py using that fixture against the
#                             unchanged importer.normalize.to_row, and find_existing
#                             matching a stored record on email
#   write_eval3_change <dir>  the uncommitted change: find_existing matches on
#                             (email, source_id), and tests/test_dedupe.py is added with
#                             store.find.assert_called_once() as its only assertion
#   eval3_anchors <dir>       prints name=path:line for the lines the assertions talk
#                             about, read from the files with grep -n:
#                               match           the changed key-match line
#                               mock_assert     the mock-only assertion
#                               unchanged_test  a test the change leaves alone

write_eval3_base() {
  local dir=$1
  mkdir -p "$dir/importer" "$dir/tests/fixtures"

  cat > "$dir/pyproject.toml" <<'EOT'
[project]
name = "importer"
version = "0.1.0"

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]
EOT

  : > "$dir/importer/__init__.py"

  cat > "$dir/importer/normalize.py" <<'EOT'
"""Mapping from a source record to the columns the store keeps."""


def to_row(record):
    return {
        "email": record["email"].strip().lower(),
        "source_id": record["source_id"],
        "name": record["name"],
        "signed_up": record["signed_up"],
    }
EOT

  cat > "$dir/importer/dedupe.py" <<'EOT'
"""Duplicate detection for imported records."""


def find_existing(record, store):
    """Return the record already stored for this import record, or None."""
    for candidate in store.find(record["email"]):
        if candidate["email"] == record["email"]:
            return candidate
    return None
EOT

  cat > "$dir/tests/conftest.py" <<'EOT'
import json
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def source_records():
    return json.loads((FIXTURES / "records.json").read_text())
EOT

  cat > "$dir/tests/fixtures/records.json" <<'EOT'
[
  {
    "email": "ana@example.com",
    "source_id": "crm-1001",
    "name": "Ana Diaz",
    "signed_up": "2024-03-01"
  },
  {
    "email": "  Bo@Example.com ",
    "source_id": "crm-1002",
    "name": "Bo Kim",
    "signed_up": "2024-05-14"
  }
]
EOT

  cat > "$dir/tests/test_import.py" <<'EOT'
from importer.normalize import to_row


def test_to_row_maps_every_column(source_records):
    assert to_row(source_records[0]) == {
        "email": "ana@example.com",
        "source_id": "crm-1001",
        "name": "Ana Diaz",
        "signed_up": "2024-03-01",
    }


def test_to_row_normalises_the_email(source_records):
    assert to_row(source_records[1])["email"] == "bo@example.com"
EOT
}

write_eval3_change() {
  local dir=$1

  cat > "$dir/importer/dedupe.py" <<'EOT'
"""Duplicate detection for imported records."""


def find_existing(record, store):
    """Return the record already stored for this import record, or None."""
    key = (record["email"], record["source_id"])
    for candidate in store.find(record["email"]):
        if (candidate["email"], candidate["source_id"]) == key:
            return candidate
    return None
EOT

  cat > "$dir/tests/test_dedupe.py" <<'EOT'
from unittest.mock import Mock

from importer.dedupe import find_existing


def test_find_existing_looks_up_the_store():
    store = Mock()
    store.find.return_value = []
    find_existing({"email": "ana@example.com", "source_id": "crm-1001"}, store)
    store.find.assert_called_once()
EOT
}

# _eval3_anchor <dir> <name> <path> <text>. Prints name=path:line for the first line of
# path holding text, and fails when no line does, so a renamed line breaks the check
# rather than passing an anchor nothing stands on.
_eval3_anchor() {
  local dir=$1 name=$2 path=$3 text=$4 line
  line=$(grep -nF -m1 -e "$text" "$dir/$path" | cut -d: -f1) || line=
  [ -n "$line" ] || { echo "eval3_anchors: no line in $path holds: $text" >&2; return 1; }
  echo "$name=$path:$line"
}

eval3_anchors() {
  local dir=$1
  _eval3_anchor "$dir" match importer/dedupe.py 'candidate["source_id"]) == key' &&
    _eval3_anchor "$dir" mock_assert tests/test_dedupe.py 'store.find.assert_called_once()' &&
    _eval3_anchor "$dir" unchanged_test tests/test_import.py 'def test_to_row_maps_every_column('
}
