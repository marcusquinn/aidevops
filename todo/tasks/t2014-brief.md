<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2014: cut TRIAGE_MAX_RETRIES default 3→1 to eliminate lock/unlock churn on failing triage

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive (conversation about repeated lock/unlock on gated issues)
- **Parent task:** none
- **Conversation context:** User observed repeated lock/unlock cycles on needs-maintainer-review issues in the pulse log and asked to "save cycles from the repeat lock and unlock". Investigation traced the cause to `dispatch_triage_reviews` in `pulse-ancillary-dispatch.sh` burning up to 3 full opus agent invocations on deterministically-failing triage content before the existing `TRIAGE_MAX_RETRIES` cap (GH#17827) finally caches the hash.

## What

Change the default value of `TRIAGE_MAX_RETRIES` in `pulse-wrapper.sh` from `3` to `1`. One line. Also update the comment block immediately above it so the reasoning matches the new default.

## Why

Observed, measured waste. For each triage that deterministically fails the format-validation safety filter (`"had no review header (## *Review*)"`), the current mechanism performs:

- **3 × `gh issue lock` + 3 × `gh issue unlock` API calls** per content version
- **3 × full triage agent invocations** (~90 seconds wall-clock each, ~100K characters of output per run) before the cap caches the hash
- **3 × timeline pollution events** (lock/unlock audit entries on the issue's GitHub timeline)

Concrete evidence from `~/.aidevops/logs/pulse.log` for `#18439` (one observed cycle):

```text
129593: Locked #18439 ... during worker execution (t1934)
129595: Triage review for #18439 had no review header — suppressed (123252 chars)
129596: Added triage-failed label to #18439
129597: Unlocked #18439 ... after worker completion
129598: Skipping triage cache for #18439 — review not posted, will retry on next cycle
129673: Locked #18439 ... (second attempt)
129675: ... had no review header — suppressed (97887 chars)
129676: Added triage-failed label
129677: Unlocked #18439
129678: Skipping triage cache ... will retry on next cycle
129790: Locked #18439 ... (third attempt)
129792: ... had no review header — suppressed (157690 chars)
129793: Added triage-failed label
129794: Unlocked #18439
129795: Triage retry cap reached for #18439 — caching hash to stop lock/unlock loop (GH#17827)
```

Same pattern observed for `#18428` (cap reached at 23:33) and `#18429` (cap reached at 23:17) on the same pulse day.

### Why MAX=1 is correct, not too aggressive

1. **The current failures aren't transient.** All three observed cases produced the same "no review header" format-validation failure on all three retries. These are deterministic agent output format problems (root cause tracked separately — see Non-goals).
2. **The model rotation pool already handles transient model failures.** If opus is rate-limited or unavailable, `headless-runtime-helper.sh select --role worker` falls through to sonnet. The triage-level retry doesn't add a fallback the model layer doesn't already provide.
3. **Genuine transients (gh API hiccup, network blip) fail before the agent runs.** The `gh issue view`/`gh api comments` calls at the top of the triage loop fail and the issue is skipped before reaching `lock_issue_for_worker`.
4. **The `triage-failed` label remains visible** — maintainers can still identify stuck issues in the GitHub UI without scrolling past 6 lock/unlock events per issue.

### Effect

- **67% fewer lock/unlock cycles** per failing triage (3 → 1)
- **~$0.30–$1.00 saved per failing issue** at opus pricing (67% reduction on 100K-character agent outputs that get discarded)
- **~3 minutes less wall-clock churn** per failing issue (2 × ~90s retry invocations eliminated)
- **Cleaner issue timelines** — one lock/unlock pair per content version instead of three

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — 1 file (`pulse-wrapper.sh`)
- [x] **Complete code blocks for every edit?** Yes — the diff is a single-character change plus comment updates, fully specified below
- [x] **No judgment or design decisions?** Yes — the value change is deterministic; the reasoning is captured in this brief
- [x] **No error handling or fallback logic to design?** Yes — no new branches, no new state
- [x] **Estimate 1h or less?** Yes — ~5 minutes
- [x] **4 or fewer acceptance criteria?** Yes — 3

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file, single-line value change. The existing `_triage_increment_failure` mechanism handles the new value correctly with no code-flow changes (at MAX=1, the first call increments to 1, sees `1 >= 1`, returns 0 → caches hash → loop terminates). Perfect Haiku territory.

## How (Approach)

### Files to modify

- `EDIT: .agents/scripts/pulse-wrapper.sh:702-716` — update the comment block and drop the default from 3 to 1.

### Implementation

Replace the existing block at `pulse-wrapper.sh:702-716`:

```bash
#######################################
# GH#17827: Triage failure retry cap.
#
# When triage fails (no review posted), the GH#17873 fix intentionally
# skips caching the content hash so the next cycle retries. But if the
# failure is persistent (e.g., model quota, formatting issues), this
# creates an infinite lock→agent→fail→unlock loop that pollutes the
# issue timeline with dozens of lock/unlock events.
#
# Solution: track failure count per issue+hash. After TRIAGE_MAX_RETRIES
# failures on the same content hash, cache it anyway to break the loop.
# The triage-failed label remains so maintainers can identify these.
# A new human comment changes the hash, resetting the counter.
#######################################
TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-3}"
```

With:

```bash
#######################################
# GH#17827, t2014: Triage failure retry cap (default 1 — single attempt).
#
# When triage fails (no review posted), the GH#17873 fix intentionally
# skips caching the content hash so the next cycle retries. But failing
# triages are overwhelmingly deterministic (format-validation rejections,
# not transient model quota) — three retries per content version burn
# three full opus agent invocations (~100K chars each) and three
# lock/unlock pairs on the issue timeline, all to reach the same outcome.
#
# Solution: cap retries at 1. The FIRST failure increments the counter
# to 1, sees 1 >= TRIAGE_MAX_RETRIES, caches the hash, and marks the
# issue with triage-failed. Subsequent cycles skip via the content-hash
# cache — zero lock/unlock, zero agent invocations. A new human comment
# changes the hash and resets the counter, giving another attempt.
#
# Transient failures (network, gh API, model rate-limit) are caught
# earlier in the dispatch loop (before lock_issue_for_worker) or
# handled by the model rotation pool, so the retry budget here adds no
# value for transients — only cost for deterministic failures.
#
# Maintainers can force a re-triage by removing the triage-failed label
# and the corresponding .failures/.hash files in TRIAGE_CACHE_DIR.
#######################################
TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-1}"
```

No other code changes are needed. `_triage_increment_failure` in `pulse-triage.sh:95-123` uses `[[ "$current_count" -ge "$TRIAGE_MAX_RETRIES" ]]` which works correctly at both 3 and 1.

### Verification

```bash
# 1. Shellcheck clean on the modified file
shellcheck .agents/scripts/pulse-wrapper.sh

# 2. Verify the constant value
grep -E '^TRIAGE_MAX_RETRIES=' .agents/scripts/pulse-wrapper.sh
# Expected: TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-1}"

# 3. Verify _triage_increment_failure still compiles cleanly
shellcheck .agents/scripts/pulse-triage.sh

# 4. Dry-run the logic: at MAX=1, the first failure should hit the cap
#    (this is the behaviour described in the updated comment block — no
#    test harness change needed, the existing arithmetic handles both
#    values identically)
```

## Acceptance Criteria

- [ ] `TRIAGE_MAX_RETRIES` default value in `pulse-wrapper.sh` is `1`
  ```yaml
  verify:
    method: codebase
    pattern: 'TRIAGE_MAX_RETRIES="\$\{TRIAGE_MAX_RETRIES:-1\}"'
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Comment block above the constant explains the new reasoning (references t2014, documents the 67% reduction, notes that the model pool handles transients)
  ```yaml
  verify:
    method: codebase
    pattern: "t2014.*single attempt"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] `shellcheck` clean on `pulse-wrapper.sh`
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh"
  ```

## Context & Decisions

- **Why not MAX=0?** Zero would skip the failure counter branch entirely and land in the `else` branch at `pulse-ancillary-dispatch.sh:311`, leaving the hash uncached and creating an infinite loop. MAX=1 is the minimum value that correctly engages the cap-and-cache logic on the first failure.
- **Why not a cooldown instead of reducing retries?** A cooldown still performs the full agent invocation (just less frequently). The observed failures are deterministic, so retrying them at any cadence is wasted work.
- **Why not just skip if `triage-failed` label is present?** That's a viable alternative but requires additional label-state tracking and invalidation logic. The existing content-hash cache already achieves the same result once the hash is cached; reducing MAX to 1 lets the existing mechanism engage on the first cycle.
- **Non-goals:** Fixing the root cause of the triage format-validation failures (why the agent produces 100K chars without a `## Review` header on #18428/18429/18439). That's a separate investigation, tracked as a follow-up task outside this brief.

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:702-716` — constant definition and comment block (site of change)
- `.agents/scripts/pulse-triage.sh:91-123` — `_triage_increment_failure()` (consumer — no change needed, works at MAX=1)
- `.agents/scripts/pulse-ancillary-dispatch.sh:300-313` — triage dispatch loop consuming `_triage_increment_failure` return value
- `~/.aidevops/logs/pulse.log:129593-129795` — observed evidence (3-cycle pattern for #18439)

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 2m | One-line value change + comment block rewrite |
| Shellcheck verification | 1m | `shellcheck pulse-wrapper.sh` |
| Commit + PR | 2m | Conventional commit, PR body with Resolves link |
| **Total** | **~5m** | |
