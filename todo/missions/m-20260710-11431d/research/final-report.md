<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Linter resource mission final report

## Outcome

The mission retained three independent changes: a framework changed-file
coverage and traversal fix, a lower-risk Target B local concurrency default,
and a bounded Target C downstream validation boundary. Each change passed its
focused checks and terminal CI before the next target advanced.

The confirmed laptop reboot cause was kernel zone-map exhaustion. Lint
causation remains unproven. The retained changes reduce avoidable local
parallelism and improve fail-closed coverage without presenting correlation as
causation.

## Evidence matrix

| Target | Before | After | Coverage evidence | Decision and confidence |
|--------|--------|-------|-------------------|-------------------------|
| Framework | Changed gates repeated up to three Git traversals each; new non-ignored files were absent before staging | One prepared inventory; zero repeated per-gate discovery; 19s, 115.3 MiB peak RSS, 11 processes | Expanded inventory digest `6c1a52953e197b93ef63d91e2e980a88e70042723816e29a26cbb86eaad06c2d` | Accepted with high confidence: 100% duplicate-discovery reduction and broader coverage |
| Target B | Local default 4; affected concurrency-1 route exited 137 in 45s at 5,593,600 KiB peak RSS | Local default 1; all 37 package shards passed serially in 492s; warm full run passed in 4s | Before/after full graph digest `541589c15e5253a1af87bac6a490399ab5a258b178274bbb933842cf1b64503d` | Safety guardrail accepted; performance effect inconclusive because the baseline did not complete |
| Target C | No executable overlay lint boundary, so runtime and memory were not measurable | 196 changed sources passed in 9s at 2,722,096 KiB peak RSS; invalid input failed in 6s | Changed-source digest `5bf51485c50adef6a26bec261299bbeb1751f5996316966dbe4a355c7e8fed13` | Reliability coverage accepted with high confidence; no broad duplicate pipeline added |

## Rejected and falsified hypotheses

- The available evidence does not prove that linting caused the kernel panic.
- Target B cache contention or duplicate traversal did not meet the threshold
  for an additional F5 change. A stale local generated cache was repaired as a
  recovery prerequisite, not generalized into a cache redesign.
- F2 proved and removed local repeated discovery. It did not prove any
  remaining framework CI jobs were semantically duplicate. F6 therefore made
  no change and preserved platform and security independence.
- No wall-time improvement is claimed between profiles with different coverage
  or between a completed route and a terminated route.

## Rollback order

1. Framework: revert the changed-inventory and timeout change to restore the
   prior implementation. This would also reopen the confirmed untracked-file
   coverage gap and advisory-timeout defect.
2. Target B: restore the two local default concurrency literals from `1` to
   `4`. Required CI, filtering, caches, and the task graph are unchanged.
3. Target C: revert the target-local validator change. The downstream
   authoritative lint pipeline remains untouched.

The changes are independent. Revert only the latest failing target and retain
earlier terminally verified changes.

## Staged verification

| Stage | Focused evidence | Terminal evidence | Result |
|-------|------------------|-------------------|--------|
| Framework | Inventory, cache, timeout, process-tree, and changed-mode fixtures passed | Required framework quality, security, portability, and review checks passed | retained |
| Target B | 37/37 serial shards, identical full graph digest, warm full run | Required target lint, format, typecheck, unit, end-to-end, security, and review checks passed | retained |
| Target C | Positive, invalid, and stalled fixtures passed | Required target quality, security, and review checks passed | retained |
| Publication | Privacy scans passed for every changed report and brief; changed-mode checks passed in 31s at 104,144 KiB peak RSS and 11 processes | Publication PR uses the existing required framework gates | ready |

## Safety-stop recovery

Resource and timeout fuses were treated as recoverability checkpoints. The
unsafe route stopped, its evidence and remaining criteria were preserved, and
the objective resumed through a smaller or prerequisite-complete route. No
feature was terminally classified merely because a fuse fired.

Reusable guidance is recorded in
`.agents/reference/linter-resource-safety.md` and the general recovery contract
is recorded in `.agents/reference/safety-stop-recovery.md`.

## Privacy

This report uses only Target B and Target C aliases. It contains no private
repository name, private path, source content, raw session record, raw system
log, or command transcript.
