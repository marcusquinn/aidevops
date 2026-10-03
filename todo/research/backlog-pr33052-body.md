## Summary

Resolves #33048

Decompose Pulse issue reconciliation without changing stage ordering, trust
checks, per-repository/cycle caps, or the 360-second budget. Original commits
are preserved; recovery merges current main without rewriting history.

## Files and reference pattern

- `.agents/scripts/pulse-issue-reconcile.sh`: focused slug, row, stage, ledger,
  backfill-gate and closeout helpers, with caller-owned Bash dynamic scope.
- `.agents/scripts/tests/test-reconcile-budget-isolation.sh`: exercise the actual
  helper chain for consuming-stage ordering, caps, cached trust, counter reset
  and inner-budget propagation.
- Reference: existing reconciliation action helpers and Bash 3.2 contracts.

## Verification

- Original cited functions, scanner lines: labelless **110 → 65**, per-issue
  label action **163 → 84**, single-pass orchestration **381 → 52**.
- Oversized functions in the file: **3 → 0**. Six newly extracted single-pass
  helpers are 42, 59, 23, 29, 73 and 28 lines. No threshold or guard changes.
- Syntax, ShellCheck, normal unbound-variable CLI, changed-file lint and
  complexity gate pass. Seven existing reconciliation suites pass, including
  cached-authority, parent-graph, stale-PR and budget behavior.
- Budget/runtime suite also passes on macOS Bash 3.2. Existing file-wide shfmt
  differences remain advisory; no formatting gate was changed.
- Exact reviewed head: `acbc2c70c6c944a5c3e0fd265681a211e62cbd71`.
- Parent independently reviewed the complete branch bundle:
  `73587666493650a2890d5ed8a62beaa67746535ca88e89c4b35ae68fcbe074ca`.

## Runtime Testing

- **Risk level:** High
- **Verification:** runtime-verified — the production reconciliation helper
  chain runs twice with isolated action recording, proving stage order, bounded
  caps, dynamic counters, cached trust fields and fresh per-call state; the inner
  time-budget abort reaches its cycle owner. No live forge mutations are used
  for verification.

<!-- aidevops:origin:worker -->
