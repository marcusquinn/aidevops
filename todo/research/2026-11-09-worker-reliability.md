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
- [ ] Complete operator-owned approval-key provisioning through the trusted
  approval workflow. `aidevops approve status` reports no approval public key;
  `NO_KEY` cannot verify an existing signed grant. Do not replace an issuer's
  key or treat Git commit-signing configuration as approval authority.
- [ ] Repair interrupted-removal recovery when native Git removal has deleted
  `.git` and the process census lacks the original worktree age evidence.
  Preserve fail-closed behavior and the private tree until age is provable.

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
