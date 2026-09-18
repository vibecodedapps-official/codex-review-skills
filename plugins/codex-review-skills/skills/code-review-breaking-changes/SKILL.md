---
name: code-review-breaking-changes
description: "Find changes that break something another party depends on: API contracts, schemas, data mappings, configuration, pipelines, packages, CLIs, stored data, extension manifests, or the logs alarms match on. Run by code-review, or alone when the user asks what a change might break or whether it is backward compatible."
---

Search for breaking changes on every surface another party depends on:

- Request and response contracts (HTTP, RPC, functions, webhooks). Shapes, required
  fields, status codes, error shapes, pagination, auth requirements, CORS, and any
  health payload a deploy asserts on. A tightened validator, a new required field, or a
  change to what create-or-update treats as the same record breaks callers that were
  passing yesterday and can duplicate or overwrite rows.
- Database schema and policies. A migration that drops or renames a column, tightens a
  constraint, changes a row-level security policy, or bumps a schema version breaks rows
  already stored, services on the previous build, ORM mappings, and generated types.
  Check that it is additive or ships a backfill, has a rollback, and that mappings and
  generated types were regenerated.
- Data transformations and field mappings (import, export, migration, sync). A changed
  mapping, default, or key match rewrites records already processed on the next run; a
  changed type or null rule breaks downstream consumers of the target table. Say what
  happens to data processed under the old mapping.
- Runtime and gateway configuration for deployed functions and services. Handler entry
  point, runtime version, memory and timeout, environment variables, permissions, routes
  and stages, and event source mappings.
- Environment and configuration. A new required variable, a renamed key, a changed
  default, or a config file whose old shape no longer loads. Every deploy target,
  pipeline variable group, and CI workflow that supplies it must be updated in the same
  change.
- Pipelines and deploys. Workflow and pipeline inputs, secrets, service connections,
  agent pools and runner names, stage order, ports, and the rollback path.
- Shared packages. The public API of a shared library or client package, and its
  version.
- CLI. A removed or renamed command, flag, or exit code, or a stdout format a script
  parses.
- Stored user data. Settings files, local databases, caches, and on-disk formats a
  previous version wrote. The new version must read the old form or migrate it.
- Extension manifest and messaging. Permissions, host patterns, and message names
  between content, background, and page scripts.
- Logs and metrics. A log line, metric name, or dimension that an alarm or dashboard
  matches on.

Do not stop after finding one issue; analyze all possible ways breaking changes can
happen.

## Report

One finding per break, at the `path:line` that introduces it. Severity high when data
is lost or a caller fails outright, medium when behavior changes but degrades
gracefully, low when only a version or doc needs to follow. Say what it breaks, who
depends on it, and whether the change ships a migration path: a backfill, a fallback, a
versioned contract, or a rollback. If it ships none, say what one would be.
