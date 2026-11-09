<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Worker reliability investigation — 2026-11-09

Delivery: PR #37343. This records partial recovery, not restored worker throughput.

## Verified repairs

- Systemd-managed Pulse drains young leased cycles across runtime activation.
- Watchdog revival queues a non-blocking start instead of waiting for a oneshot.
- Async-housekeeping ownership uses the shared portable file-mtime helper.
- Cleanup recognizes predating OpenSSH `sshd-session` tasks without relaxing
  exact-name, age, or readable-reference checks.
- A fresh headless worker canary, with `CANARY_CACHE_TTL_SECONDS=0`, returned 0.
  This proves a model health probe, not issue ownership or task delivery.

## Remaining work

- [ ] Restore and verify real worker delivery. Pulse remains live but sampled
  candidates are held by ownership, permission, and draft-checkpoint gates.
  Inspect fresh `pulse-current-state-helper.sh --window 5m --json` evidence;
  do not clear a claim solely because the local active-worker count is zero.
- [ ] Reconcile permission-held issues using current, trusted authorization.
  The sampled grant expired on 2026-11-08 at 06:39 UTC; its embedded key did
  not match the issuer's advertised GitHub SSH signing keys when checked.
  Installing a key would not make that expired grant usable. Approval-key
  provisioning is not a prerequisite for ordinary worker dispatch. Do not
  replace an issuer's key or treat commit signing as approval authority.
- [ ] Repair interrupted-removal recovery when native Git removal has deleted
  `.git` and the process census lacks the original worktree age evidence.
  Preserve fail-closed behavior and the private tree until age is provable.

## Worker pickup and incomplete review attempt

- Workers resumed issue pickup: #37358 produced PR #37359, and #37246 produced
  draft PR #37361. This is delivery evidence, not sustained-throughput proof.
- At 14:05 UTC, the current-state helper reported a completed, progressed Pulse
  cycle, a heartbeat age of 20 seconds, one dispatch in the preceding 15 minutes,
  and zero active worker processes. Ownership, draft-checkpoint, permission,
  and policy holds remained. Incomplete GitHub reads prevent treating every
  apparent idle slot as safely dispatchable.
- The review-response attempt for #37359, launched at 13:36:36 UTC, was recorded
  at 13:38:31 as `worker_noop_zero_output`. That classification contradicts its
  saved stream: the worker edited the retry helper and tests, then ran the
  existing claim-release suite with `pass=33 fail=0`. It did not complete its
  commit/push/thread handoff. The reason for the early exit remains unknown.
- Its uncommitted edits remain preserved in the original linked worktree. A
  later remote commit, `d2433cd80`, already fixes the same batch-starvation
  behavior on PR #37359. Do not overwrite that newer head or blindly replay
  the abandoned edits.
- Investigate `.agents/scripts/headless-runtime-failure.sh` exit classification
  and the review scanner's attempt evidence. The classifier can fall back from
  an unavailable isolated database to the shared database. This is a candidate
  explanation, not a demonstrated cause of this attempt's early termination.
  Reference `test-worker-exit-classifier.sh` and
  `test-headless-runtime-failure-classification.sh`; preserve signal/watchdog
  precedence and never classify missing evidence as successful delivery.

## PR verification follow-up

PR #37343's terminal `ShellCheck (ubuntu-latest)` failure was actually its Bash
3.2 parse step: the inline `case` in a command substitution in
`test-pulse-lifecycle-helper.sh` failed at line 1590. Replacing that mock branch
with equivalent `if`/`elif` checks passes the same digest-pinned Bash 3.2 image
used by CI, local ShellCheck, modern Bash syntax, and all 82 lifecycle assertions.
Published as `ff49bf6de`; its CI finished with no failed checks observed.

## Review-worker cgroup repair

The review scanner launched workers with `setsid nohup`, which changes session
and process-group ownership but does not leave the parent systemd cgroup. The
host's merge unit is `Type=oneshot` with `KillMode=control-group`. Its journal
records cycle completion at 13:38:33 UTC, close to the incomplete attempt above.
This demonstrates an unsafe launch topology; it does not identify the exact
signal sender or prove this was that attempt's sole termination cause.

The scanner now delegates launch to `pr-review-thread-response-launch.sh`, which
reuses `systemd-scope-launch.sh` when the user manager is available. It preserves
PID-based capacity activation, existing ownership fences, and the non-systemd
detached path. A scope launch is attempted once: failure or unconfirmed scope
membership never triggers a duplicate detached launch. If scope admission is
unavailable inside a managed unit, launch fails closed.

Verification: all four new launch assertions pass (confirmed scope, unconfirmed
scope without duplicate fallback, failed scope without duplicate fallback, and
managed-unit refusal). A bounded live probe returned `systemd_scope`, confirming
actual cgroup membership through the shared launcher on this host. The modified
launch module and dispatch tests parse under the CI-pinned Bash 3.2 image;
ShellCheck and whitespace checks pass.

The full scanner suite reports 114 assertions, three failures. Unmodified
upstream reports 110 assertions and the same three failures on this host:

- `dispatch bootstraps and removes a linked fetch context`
- `new head SHA resets repeated-fingerprint escalation attempts`
- `dispatch-pr preserves indeterminate young lock for age fallback`

These require separate diagnosis in the scanner worktree/lock helpers and
existing fixture modules. Preserve unknown-owner refusal; do not relax the
ownership or Git-context checks to make the tests pass.

At 15:05 UTC the runtime was current and Pulse had a heartbeat age of 19 seconds,
but zero active workers and four consecutive no-progress cycles. The sampled
prelaunch blocker was `dedup_active_claim_unverified`. Cgroup repair verification
is not sustained-delivery evidence; check fresh state before any dispatch retry.

## Cleanup follow-up evidence and verification

The legacy-cleanup suite passed 44 tests and failed
`LegacyCleanupContract.test_interrupted_removal_resumes_after_git_deleted_its_link`.
The exact test also fails with the original daemon allowlist, retaining the
private tree with `proc-observation-unavailable`.

Target `.agents/worker-lifecycle/worker_lifecycle/legacy_proc.py` and the existing
interrupted-removal journal/recovery implementation; inspect callers before
choosing a safe age-evidence source. Reference the existing predating-daemon
contract and interrupted-removal tests in
`.agents/worker-lifecycle/tests/test_legacy_cleanup.py`.

Acceptance: the existing interrupted-removal test passes without accepting
unknown/recent processes or inventing timestamps. Run the existing cleanup suite,
Ruff, and package mypy checks. Do not add a fallback that skips process observation.
