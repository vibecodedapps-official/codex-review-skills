---
name: code-review-testing
description: "Check that every behavior change has a test that fails without it, in the repository's own suite, and that the test asserts behavior rather than implementation. Run by code-review, or alone when the user asks whether a change is tested well enough or what tests to add."
---

Every behavior change needs a check that fails without it, in the suite the repository
already has. Find that suite first from the repository's own configuration and scripts
(package manifest, test project, task runner, CI workflow) and use its runner rather
than assuming one. A behavior change with no failing check is a finding.

Prefer the narrowest test that runs the real code path:

- A service endpoint change (new route, changed payload, create-or-update semantics,
  validation rule, error shape) gets an integration test that sends the request and
  asserts the response and the stored result. A unit test of the handler alone does not
  cover it. Where the repository keeps an API integration suite beside its unit tests,
  the scenario belongs there.
- A database change (migration, schema version bump, policy, trigger, database
  function) needs a test against a running database, not a mocked client: the rows it
  makes visible or hides, the constraint it adds, and that data written by the previous
  schema version still loads. When no harness runs a database function directly, an
  existing integration scenario counts if it runs the changed function against a real
  database and asserts the stored result; name that scenario. A run promised after
  deploy is not coverage.
- A data transformation or field-mapping change (import, export, migration, sync) needs
  a test with a representative source record and the exact expected output, including
  nulls, empty strings, legacy sentinel values, and a record that already exists in the
  target (a rerun must not duplicate or clobber it). A mapping without a fixture that
  exercises the changed field is a finding.
- A function or event handler gets a test that invokes it with the real event shape
  (gateway request, queue message, webhook payload), not a call to an inner function.
- A browser extension change to messaging, permissions, or content-script injection
  needs a test in the extension's own suite. A manifest change needs the live test rerun.
- UI logic goes in a unit test. A routing, session, or upload flow gets an end-to-end
  test only when a unit test cannot reach it.
- A CLI or pipeline script change gets a test that invokes it and checks stdout, exit
  code, and files written.

Reject test-only hooks in production code: a function, flag, export, public setter,
visibility grant, or environment check that exists only so a test can reach in. Use
the existing helpers, fixtures, and step definitions; point at one when a new test
rewrites what a helper already does.

Check the test asserts behavior, not implementation. A test that still passes with the
change reverted, or that only asserts a mock was called, is a finding. So is a test
that asserts on a log line as a stand-in for checking the result the change was meant
to produce. When the log line is itself the behavior under test (a warning that
monitoring consumes, an audit entry a policy requires), asserting on the logger, level,
and message is the right test, and it should also assert the return value or state the
change preserves.

Do not stop after finding one issue; list every behavior change and say which check
covers it.

## Report

One finding per behavior change without a covering check, or per test that asserts the
wrong thing, at the `path:line` of the changed code or test. Severity high when a
change to data, auth, or money has no failing check, medium for other uncovered
behavior, low for a test that could be narrower or reuse a helper. Say which existing
suite and runner the check belongs in and what it must assert.
