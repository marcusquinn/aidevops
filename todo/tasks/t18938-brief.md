## What

Make the pulse dead-stamp reaper (`interactive-session-helper.sh reap-dead-stamps`) reach every interactive claim stamp, not only the first `AIDEVOPS_DEAD_STAMP_REAP_LIMIT` (default 100) in glob order. Persist a rotation cursor so each bounded cycle resumes after the last examined stamp and wraps around.

## Why (evidence)

- `_isc_scan_dead_stamps_phase` (`.agents/scripts/interactive-session-helper-scan.sh:468-554`) iterates `"$CLAIM_STAMP_DIR"/*.json` in sorted order and `break`s after `stamp_limit` stamps (`:484-486`). `_isc_cmd_reap_dead_stamps` (`:559-568`) passes the 100 cap on every pulse cycle (GH#28211 added the cap to bound per-cycle cost).
- With more than 100 stamps, the same first 100 are examined every cycle and the rest never are. Observed locally: 394 stamps across 5 owner prefixes. The first 100 cover two owners entirely and 30 of 256 stamps of a third. The remaining 294 stamps (including every stamp for the framework repository's owner after the first 30, and all of a fourth owner's 67) are never reaped.
- Effect on dispatch: dead claims stay self-assigned and block `auto-dispatch` work with `dedup_active_claim_unverified`. Example: two `origin:interactive` + `status:claimed` issues claimed 2026-10-29 by an owner PID that no longer exists, with the claim worktree removed. They were blocked every cycle for 12 days, while the pulse ran 0 of 20 worker slots. The stampless pass (`pulse-issue-reconcile.sh:948-1035`) skips them because a stamp exists (`:994-998`), so only the reaper can release them.
- The reaper logs `No releasable stale claims for 7 dead stamp(s)` every cycle, which reads as healthy while about 75% of stamps go unexamined.

## How

### Files to modify

- EDIT: `.agents/scripts/interactive-session-helper-scan.sh`
  - Extract the per-stamp body of the `_isc_scan_dead_stamps_phase` loop into a helper. This keeps the coordinator under the 100-line function gate.
  - When `stamp_limit > 0`, read a cursor (basename of the last examined stamp) from `${CLAIM_STAMP_DIR}/.reap-cursor`. Examine stamps sorted after the cursor first, then wrap to the start. Stop at the limit.
  - When the cap stops the scan, write the last examined basename. When a full pass completes under the cap, remove the cursor.
  - Cursor I/O failures are non-fatal: an unreadable cursor restarts from the beginning, the previous behaviour. The dotfile is invisible to the `*.json` enumerators (`:482`, `interactive-session-helper-commands.sh:919`).
  - Unbounded calls (`scan-stale`, `stamp_limit=0`) ignore and never write the cursor.
  - Safety gates (hostname, PID/argv, recoverable progress, lockdown, lookup failure) are unchanged.

### Files Scope

- `.agents/scripts/interactive-session-helper-scan.sh`
- `.agents/scripts/tests/test-scan-stale-auto-release.sh`

### Reference pattern

- Existing Test 18 in `.agents/scripts/tests/test-scan-stale-auto-release.sh:564-578` (per-cycle cap).

## Acceptance criteria

- With limit N and M > N dead releasable stamps, every stamp is examined within ceil(M/N) consecutive calls.
- The per-cycle cap still holds: Test 18 passes unchanged.
- `scan-stale` (unbounded) behaviour is unchanged.
- No new GitHub API calls per cycle.

## Verification

- `shellcheck .agents/scripts/interactive-session-helper-scan.sh`
- `bash .agents/scripts/tests/test-scan-stale-auto-release.sh`. Extend Test 18 with a second call that must release the stamp after the cursor. A fairness regression fails silently in production, so this case is the cheapest proof.
- After deploy: the reaper summary shows stamps beyond the first 100 being examined, and the two 12-day-old dead claims release within 4 cycles.
