<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2153: Age-floor guard for stale-recovery on fresh issues

**Origin:** Interactive session investigating why workers were "having trouble" with #19414 (t2151 Phase B).

## What

Add an age-floor guard to `_is_stale_assignment` in `.agents/scripts/dispatch-dedup-stale.sh` so that a freshly-created GitHub issue cannot be marked "stale" by the dispatch dedup subsystem if the issue itself is younger than the effective staleness threshold.

## Why

**Production failure (#19414, GH#19424):**

```
23:09:29Z  Issue #19414 created via issue-sync from a TODO entry,
           marcusquinn auto-assigned, labels: origin:interactive +
           status:queued + tier:thinking. Zero comments.
23:14:22Z  stale-recovery-tick:1 posted (4 min 53 s after creation).
23:14:30Z  WORKER_SUPERSEDED, reason: "no dispatch claim comment found,
           no recent activity (threshold=7200s, interactive=true)".
23:14:34Z  DISPATCH_CLAIM nonce — fresh worker grabbed the now-orphaned
           issue. Worker exited 4 min later without a PR.
```

The 7200 s interactive threshold was correctly resolved but **never compared against issue age** — only against (non-existent) comment timestamps. When `last_dispatch_ts` and `last_activity_ts` are both empty (the case for any issue with zero comments), the inner activity-age check is skipped and execution falls through to `_recover_stale_assignment` immediately.

This is the systemic vector: every freshly-created issue with auto-assignment is vulnerable during its first `effective_threshold` seconds. Most issues escape because pulse posts a `DISPATCH_CLAIM` comment within seconds; but issues created through the issue-sync path (TODO → GitHub) have no such guarantee.

## How

**File:** `.agents/scripts/dispatch-dedup-stale.sh`

1. Extend `_resolve_stale_threshold` to also fetch and emit `issue.createdAt`:
   - Change `--json labels` to `--json labels,createdAt` (single API call, no extra round-trip).
   - Emit three lines of stdout instead of two: `is_interactive\nthreshold\ncreatedAt`.

2. In `_is_stale_assignment`, after parsing the three lines, add an early-return guard:

   ```bash
   if [[ -n "$issue_created_at" ]]; then
       local issue_created_epoch issue_age
       issue_created_epoch=$(_ts_to_epoch "$issue_created_at")
       if [[ "$issue_created_epoch" -gt 0 ]]; then
           issue_age=$((now_epoch - issue_created_epoch))
           if [[ "$issue_age" -lt "$effective_threshold" ]]; then
               return 1   # not stale — too young
           fi
       fi
   fi
   ```

3. Fail-open on missing/unparseable `createdAt` — the existing fail-CLOSED stance on transient `gh` failures already protects the assignment.

**File:** `.agents/scripts/tests/test-stale-recovery-age-floor.sh` (new, 257 lines)

Six assertions, all using the public `is-assigned` subcommand (real production call path):

1. Fresh interactive (60 s old, threshold 7200 s) → ASSIGNED, no WORKER_SUPERSEDED comment posted.
2. Negative assertion that no WORKER_SUPERSEDED comment was posted in #1.
3. Old interactive (3 h old, no comments) → still stale-recovered (regression guard — fix didn't disable existing recovery).
4. Fresh worker-tier (60 s old, threshold 600 s) → ASSIGNED.
5. Old worker-tier (15 min old, no comments) → still stale-recovered.
6. Missing `createdAt` (defensive) → falls through to existing logic.

## Acceptance criteria

- [ ] `bash .agents/scripts/tests/test-stale-recovery-age-floor.sh` exits 0 with all 6 tests passing.
- [ ] `bash .agents/scripts/tests/test-stale-recovery-escalation.sh` still exits 0 (11 tests pass — no regression).
- [ ] `bash .agents/scripts/tests/test-dispatch-dedup-fail-closed.sh` still exits 0 (7 tests pass — no regression).
- [ ] Reverting the `dispatch-dedup-stale.sh` edit causes 3 of the 6 new test assertions to FAIL (proves test catches the bug).
- [ ] `shellcheck .agents/scripts/dispatch-dedup-stale.sh .agents/scripts/tests/test-stale-recovery-age-floor.sh` clean.
- [ ] Bash 3.2 compatible (no `[[ -v var ]]`, no associative arrays).

## Context

**Related prior work:**

- t2132 / PR #19237 (merged 2026-04-16): "fix interactive claims broken by stale-recovery + auto-claim conflation" — added `INTERACTIVE_STALE_THRESHOLD_SECONDS=7200` and the "Interactive session claimed" sentinel-pattern match. Addressed staleness during ACTIVE interactive sessions but did not cover the brand-new-issue case where no comments exist at all (this task).
- t2008 / PR #18462 (merged 2026-04-12): stale-recovery escalation system — counts ticks, applies `needs-maintainer-review` after threshold. The fix here prevents fresh issues from triggering tick-1 in the first place.
- GH#18816: comments API failure → fail-CLOSED. The `_is_stale_assignment` guard inherits this defensive default for transient gh failures.

**Worker token cost recovered:** #19414 burned ~4 min on opus-4-6 (tier:thinking) before exiting without producing a PR. Without the fix, every new auto-dispatch issue is vulnerable to the same waste. The fix prevents an unbounded class of failures.

**Companion issues spawned by this investigation:**

- #19414 (t2151 Phase B) — still open; the worker's foundational edits (label definition + env defaults) are preserved in `~/Git/aidevops-feature-auto-20260417-001454-gh19414/`. After this fix lands, the next pulse cycle should pick up #19414 cleanly.
- #19415 (t2152) — separate `needs-simplification` label flap (different bug class, follow-up).
