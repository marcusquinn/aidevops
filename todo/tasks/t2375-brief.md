<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2375 — Harden cross-runner guard in `_normalize_stale_should_skip_reset`

- **Session origin:** interactive follow-up to GH#19831 comment thread
- **Parent/related:** #19831 (analysis), PR #19838 / t2372 (tightened outer filter from 1h → 10min, surfacing the gaps below)
- **Tier:** `tier:standard` — judgment about cross-runner model, test authoring, multi-function refactor

## What

Harden the t1933 cross-runner guard in `_normalize_stale_should_skip_reset`
(`.agents/scripts/pulse-issue-reconcile.sh`) so the proactive stale-worker
recovery sweep cannot incorrectly reset a genuine cross-machine worker's
assignment:

1. Parse `**Runner**: <login>` from the dispatch comment alongside `**Worker PID**`.
2. Gate Check 2 on **runner identity** (`dispatch_runner != self_login`) rather
   than on local PID presence (`ps -p`). PID collisions across machines are
   meaningless; runner login is the authoritative cross-machine signal.
3. Fail-CLOSED on `gh api` error when fetching dispatch info — match the
   reactive-path behaviour in `_is_stale_assignment`
   (`dispatch-dedup-stale.sh:401-405`).
4. Fail-CLOSED on legacy dispatch comments that have a PID but no Runner line —
   we cannot verify ownership, so skip reset rather than potentially steal an
   active cross-machine worker's assignment.

## Why

t2372 lowered the outer `updatedAt` filter in `_normalize_unassign_stale` from
3600s (1h) to 600s (10 min). The proactive stale sweep now exercises the inner
safeguards **6× more often per cycle**. The sole cross-machine protection in
`_normalize_stale_should_skip_reset` is Check 2 (t1933 cross-runner guard),
which has three failure modes that the 6× amplification makes materially more
likely to fire against genuine active workers on other machines:

**Gap 1 — PID collision.** `ps -p $dispatch_pid` succeeds when the PID (from
another machine's runner) happens to match any local process (a system daemon,
a shell, a browser — PIDs below ~5000 collide often on Linux/macOS). The code
then exits the cross-runner branch and falls through to Check 3 (local log),
which cannot see cross-machine logs and reports not-recent, so **reset fires
against an active cross-machine worker**.

**Gap 2 — `gh api` fail-open.** `_normalize_stale_get_dispatch_info` swallows
errors with `|| true` and returns an empty PID. Check 2 doesn't fire, Check 3
fails, **reset fires**. This is the opposite stance from the reactive path
(`_is_stale_assignment` in `dispatch-dedup-stale.sh` explicitly fails CLOSED
on gh error).

**Gap 3 — legacy dispatch comments without Worker PID line.** Small population,
self-resolves over time, but same reset-fires outcome.

The dispatch comment already records the owning runner
(`pulse-dispatch-worker-launch.sh:468` emits `- **Runner**: ${self_login}`),
so the fix is a reader-side change only — no new data to produce, no migration.

## How

### Edit 1 — `_normalize_stale_get_dispatch_info` (pulse-issue-reconcile.sh:137-166)

- Extend the `jq` capture to also emit the `**Runner**: <login>` value.
- Output **three** lines to stdout (pid, created_at, runner) — each possibly
  empty if the field is missing.
- Capture `gh api` exit code separately; return non-zero on failure so the
  caller can fail-CLOSED. Drop the `|| true` swallow.

### Edit 2 — `_normalize_stale_should_skip_reset` (pulse-issue-reconcile.sh:186-241)

- Accept a new `self_login` 5th argument.
- Call the dispatch-info helper; on helper non-zero return, log
  `Stale assignment skip (gh-api fail-closed)` and `return 0`.
- Parse the new `dispatch_runner` line.
- Replace the Check 2 `ps -p` gate with:
  - **Cross-machine branch** (`dispatch_runner` non-empty AND
    `dispatch_runner != self_login`): skip `ps -p` entirely (PID collisions
    across machines are meaningless), apply time-based expiry — skip if
    comment age < `cross_runner_max_runtime`, else log `cross-runner expired`
    and fall through.
  - **Local branch** (`dispatch_runner == self_login`): retain the existing
    `ps -p` check against local processes.
  - **Legacy branch** (`dispatch_runner` empty AND `dispatch_pid` non-empty):
    log `fail-closed legacy format`, `return 0`.
- Check 3 (local worker log) applies only when the dispatch is local; cross-
  machine workers have no local log, so falling through to Check 3 is a no-op.

### Edit 3 — `_normalize_unassign_stale` (pulse-issue-reconcile.sh:283-339)

- Pass `$runner_user` through to `_normalize_stale_should_skip_reset` as the
  new 5th argument.

### Edit 4 — tests/test-issue-reconcile.sh (add Parts 11-14)

- **Part 11** — cross-machine dispatch (runner=other-machine), comment age <
  `WORKER_MAX_RUNTIME` → skipped even when PID matches a local process (stub
  gh to emit PID=1).
- **Part 12** — cross-machine dispatch (runner=other-machine), comment age ≥
  `WORKER_MAX_RUNTIME` → reset fires (time-based expiry still works).
- **Part 13** — legacy format (runner empty, PID present) → fail-closed,
  skipped.
- **Part 14** — `gh api` returns non-zero → fail-closed, skipped.

## Acceptance criteria

- [x] `_normalize_stale_get_dispatch_info` returns runner login alongside PID
      and timestamp; signals gh-api failure via exit code.
- [x] `_normalize_stale_should_skip_reset` gates Check 2 on runner identity,
      not local PID presence.
- [x] gh-api failure and legacy-format paths both return 0 (skip reset) with
      logged `fail-closed` reasons.
- [x] `_normalize_unassign_stale` passes `self_login` through as the 5th arg.
- [x] Four new test cases pass (cross-machine fresh, cross-machine expired,
      legacy format, gh-api failure).
- [x] All existing Parts 1-10 still pass.
- [x] `shellcheck` clean on both modified files.

## Context

- Dispatch comment emission:
  [`pulse-dispatch-worker-launch.sh:463-470`](../../.agents/scripts/pulse-dispatch-worker-launch.sh).
- Reactive path (fail-closed-on-gh-error reference):
  [`dispatch-dedup-stale.sh:401-405`](../../.agents/scripts/dispatch-dedup-stale.sh).
- t1933 docstring that captured the original intent (this fix completes it):
  [`pulse-issue-reconcile.sh:269-273`](../../.agents/scripts/pulse-issue-reconcile.sh).
- Multi-runner model:
  [`reference/cross-runner-coordination.md`](../../.agents/reference/cross-runner-coordination.md).
- Full analysis: [GH#19831](https://github.com/marcusquinn/aidevops/issues/19831).
