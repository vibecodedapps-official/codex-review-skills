#!/usr/bin/env bash
# Fixture content for eval 2 (correctness, intent). Writes files into a directory and
# nothing else: no git, no cd, so the check script owns the repository. Source it; running
# it does nothing.
#
#   write_eval2_base <dir>    client/upload.py: a module docstring stating that every
#                             endpoint rejects a request without an Authorization header,
#                             `_headers()` returning that header, `upload(path,
#                             timeout=30)` and `_head(path)` both using it
#   write_eval2_change <dir>  the described change, "add a retry to the upload client":
#                             three attempts around the request, `except OSError:` with a
#                             bare `raise` on the last attempt so nothing is swallowed;
#                             plus two the description does not mention, the default
#                             timeout from 30 to 10 and `_head` building its own headers
#                             without Authorization
#   eval2_anchors <dir>       prints `name=path:line` for the lines the assertions accept,
#                             read from the change with grep so editing the fixture moves
#                             them: head_headers (the headers lines inside `_head`),
#                             timeout_default (the default timeout line), retry_start and
#                             retry_end (the retry loop's first and last line)

# _eval2_emit <name> <dir> <file> <ere> [first-line]: one `name=file:line` line per match
# at or after first-line, 1 when omitted, or an error and a nonzero return when the
# pattern matches nothing there.
_eval2_emit() {
  local name=$1 dir=$2 file=$3 pattern=$4 first=${5:-1} found=0 line
  while IFS=: read -r line _; do
    [ "$line" -ge "$first" ] || continue
    found=1
    printf '%s=%s:%s\n' "$name" "$file" "$line"
  done < <(grep -nE -- "$pattern" "$dir/$file")
  [ "$found" = 1 ] || { echo "eval2_anchors: nothing matches /$pattern/ in $dir/$file" >&2; return 1; }
}

write_eval2_base() {
  local dir=$1
  mkdir -p "$dir/client"
  cat > "$dir/client/upload.py" <<'EOT'
"""Client for the file service.

Every endpoint of the service rejects a request without an Authorization header.
"""

import os
import urllib.request

BASE_URL = "https://files.example.invalid"


def _headers():
    return {
        "Authorization": "Bearer " + os.environ["UPLOAD_TOKEN"],
        "Content-Type": "application/octet-stream",
    }


def upload(path, timeout=30):
    with open(path, "rb") as handle:
        body = handle.read()
    request = urllib.request.Request(BASE_URL + "/upload", data=body, headers=_headers())
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status


def _head(path):
    request = urllib.request.Request(BASE_URL + "/head/" + path, headers=_headers(), method="HEAD")
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.status
EOT
}

write_eval2_change() {
  local dir=$1
  mkdir -p "$dir/client"
  cat > "$dir/client/upload.py" <<'EOT'
"""Client for the file service.

Every endpoint of the service rejects a request without an Authorization header.
"""

import os
import urllib.request

BASE_URL = "https://files.example.invalid"

ATTEMPTS = 3


def _headers():
    return {
        "Authorization": "Bearer " + os.environ["UPLOAD_TOKEN"],
        "Content-Type": "application/octet-stream",
    }


def upload(path, timeout=10):
    with open(path, "rb") as handle:
        body = handle.read()
    request = urllib.request.Request(BASE_URL + "/upload", data=body, headers=_headers())
    for attempt in range(ATTEMPTS):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status
        except OSError:
            if attempt == ATTEMPTS - 1:
                raise


def _head(path):
    headers = {"Content-Type": "application/octet-stream"}
    request = urllib.request.Request(BASE_URL + "/head/" + path, headers=headers, method="HEAD")
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.status
EOT
}

# Reads the change: the retry loop and the headers built inside _head exist only there.
eval2_anchors() {
  local dir=$1 file=client/upload.py head_line
  head_line=$(grep -nE '^def _head\(' "$dir/$file" | cut -d: -f1)
  [ -n "$head_line" ] || { echo "eval2_anchors: no _head in $dir/$file" >&2; return 1; }
  _eval2_emit head_headers "$dir" "$file" 'headers' "$head_line" || return 1
  _eval2_emit timeout_default "$dir" "$file" '^def upload\(path, timeout=' || return 1
  _eval2_emit retry_start "$dir" "$file" '^ +for attempt in range\(' || return 1
  _eval2_emit retry_end "$dir" "$file" '^ +raise$' || return 1
}
