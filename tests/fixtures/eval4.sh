#!/usr/bin/env bash
# Fixture content for eval 4, breaking changes. Sourced by tests/breaking-changes-check.sh
# and by tests/code-review-check.sh, which own the git repository; these functions only
# write files, and never run git or change directory.
#
#   write_eval4_base <dir>    the state before the change
#   write_eval4_change <dir>  the change under review, written over the base
#   eval4_anchors <dir>       prints `name=path:line` for each line the assertions accept,
#                             read out of the files with grep so a rewrite moves them:
#                               rename   the renamed response field in service/handler.py
#                               environ  the os.environ["UPLOAD_BUCKET"] read in service/config.py
#                               bump     the version line in packages/shared-client/pyproject.toml
#
# The change renames a response field a worker in the same repository indexes by name,
# reads a new variable at import time that .github/workflows/deploy.yml does not supply,
# and bumps the shared client's version with no other change in that package.

write_eval4_base() {
  local d=$1
  mkdir -p "$d/service" "$d/worker" "$d/.github/workflows" \
    "$d/packages/shared-client/shared_client"

  cat > "$d/service/handler.py" <<'EOT'
import json


def handle(request):
    user = fetch_user(request["token"])
    body = {"user_id": user["id"], "plan": user["plan"]}
    return {"status": 200, "body": json.dumps(body)}


def fetch_user(token):
    return {"id": token.split(":")[0], "plan": "standard"}
EOT

  cat > "$d/service/config.py" <<'EOT'
import os

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://localhost/app")
QUEUE_NAME = os.environ.get("QUEUE_NAME", "profiles")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info")
EOT

  cat > "$d/service/main.py" <<'EOT'
from service import config
from service.handler import handle


def start(request):
    if config.LOG_LEVEL == "debug":
        print(request)
    return handle(request)
EOT

  cat > "$d/worker/consumer.py" <<'EOT'
import json
import urllib.request


def fetch_profile(base_url, token):
    with urllib.request.urlopen(f"{base_url}/profile?token={token}") as response:
        resp = json.loads(response.read())
    return resp["user_id"], resp["plan"]
EOT

  cat > "$d/.github/workflows/deploy.yml" <<'EOT'
name: deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Start the service
        run: python -m service.main
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
          QUEUE_NAME: profiles
          LOG_LEVEL: info
EOT

  cat > "$d/packages/shared-client/pyproject.toml" <<'EOT'
[project]
name = "shared-client"
version = "1.2.0"
description = "HTTP helpers shared by the service and the worker"
requires-python = ">=3.11"
EOT

  cat > "$d/packages/shared-client/shared_client/__init__.py" <<'EOT'
import json
import urllib.request

DEFAULT_TIMEOUT = 10


def get_json(url, timeout=DEFAULT_TIMEOUT):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read())
EOT
}

write_eval4_change() {
  local d=$1

  cat > "$d/service/handler.py" <<'EOT'
import json


def handle(request):
    user = fetch_user(request["token"])
    body = {"userId": user["id"], "plan": user["plan"]}
    return {"status": 200, "body": json.dumps(body)}


def fetch_user(token):
    return {"id": token.split(":")[0], "plan": "standard"}
EOT

  cat > "$d/service/config.py" <<'EOT'
import os

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://localhost/app")
QUEUE_NAME = os.environ.get("QUEUE_NAME", "profiles")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info")
UPLOAD_BUCKET = os.environ["UPLOAD_BUCKET"]
EOT

  cat > "$d/packages/shared-client/pyproject.toml" <<'EOT'
[project]
name = "shared-client"
version = "1.2.1"
description = "HTTP helpers shared by the service and the worker"
requires-python = ">=3.11"
EOT
}

eval4_anchors() {
  local d=$1
  _eval4_anchor rename "$d" service/handler.py userId
  _eval4_anchor environ "$d" service/config.py UPLOAD_BUCKET
  _eval4_anchor bump "$d" packages/shared-client/pyproject.toml '^version = '
}

# _eval4_anchor <name> <dir> <path> <pattern>. Fails rather than printing an empty line
# when the pattern stops matching exactly one line, so a fixture edit cannot silently
# leave the assertions pointing nowhere.
_eval4_anchor() {
  local name=$1 d=$2 path=$3 pattern=$4 found count
  found=$(grep -n -e "$pattern" "$d/$path" | cut -d: -f1) || true
  count=$(printf '%s\n' "$found" | grep -c . || true)
  if [ "$count" != 1 ]; then
    echo "eval4_anchors: $name matched $count lines of $path" >&2
    return 1
  fi
  printf '%s=%s:%s\n' "$name" "$path" "$found"
}
