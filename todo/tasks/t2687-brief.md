---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2687: fix health-dashboard dedup under rate-limit pressure

## Pre-flight

- [x] Memory recall: `duplicate supervisor issue dedup` / `issue tag label inconsistent` → 0 hits — no prior lesson, first incident of this class
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch `stats-health-dashboard.sh` in last 48h. Recent relevant work: t2574/t2580 (REST fallback for CREATE/EDIT paths — this incident exposes the asymmetric READ-path gap)
- [x] File refs verified: `.agents/scripts/stats-health-dashboard.sh` (1419 lines, deployed matches source), `.agents/scripts/shared-gh-wrappers-rest-fallback.sh` (present), `~/.aidevops/logs/stats.log` (84 rate-limit failures, 19 creation failures today)
- [x] Tier: `tier:standard` — multi-file fix with bash logic changes and test harness, not a one-line config tweak; no novel architecture required (pattern already established by `_find_health_issue` dedup logic itself)

## Origin

- **Created:** 2026-04-21
- **Session:** opencode:interactive
- **Created by:** ai-interactive (marcusquinn directed investigation)
- **Parent task:** none
- **Conversation context:** User noticed duplicate `[Supervisor:*]` issues on `marcusquinn/aidevops` (and later `awardsapp/awardsapp`). Investigation traced the incident to a GraphQL rate-limit window on 2026-04-21 04:00-13:30 UTC during which `_find_health_issue` silently treated query failures as "not found" and created duplicates.

## What

Harden `_find_health_issue` in `stats-health-dashboard.sh` so that `gh` query errors (rate limit, network timeout, connection reset) never cascade into duplicate issue creation. Add a one-shot migration to close the 19 orphaned duplicates across the fleet. File follow-up issues for the broader systemic gaps (framework-wide read-path REST fallback, pulse-level rate-limit circuit breaker).

After this change:

- A pulse cycle that encounters GraphQL rate-limit errors during cache validation or label/title dedup lookup preserves the cache and skips creation for that cycle, instead of silently creating a duplicate.
- Even on cache hits, the label-based dedup scan runs at least once per hour per repo, so duplicates that slipped in during past rate-limit windows get closed automatically.
- Existing 19 duplicate supervisor issues are closed via one-shot migration script with explanatory comments.

## Why

- **Signal integrity:** Duplicate supervisor issues corrupt pin slots, confuse human monitoring, and create noise in per-runner dashboards. Multiple open `[Supervisor:marcusquinn]` and `[Supervisor:alex-solovyev]` issues actively mislead.
- **Regression surface from t2574/t2580:** The REST fallback for CREATE/EDIT operations made this latent bug actively harmful. Pre-t2574, CREATE would also fail under rate limit → no duplicate. Post-t2574, CREATE succeeds via REST while the READ-side lookup silently returns empty → duplicate created. We must either mirror the fallback on READ (bigger change, follow-up) or teach `_find_health_issue` to refuse-on-error (this PR).
- **Fleet impact:** 19 duplicates across 7 repos today. Will recur on every GraphQL exhaustion window until fixed.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? **NO** — 3 files (helper script, test, migration)
- [x] Every target file under 500 lines? **NO** — `stats-health-dashboard.sh` is 1419 lines
- [x] Exact `oldString`/`newString` for every edit? **NO** — new function-level logic
- [x] No judgment or design decisions? **NO** — error discrimination policy is a design choice
- [x] No error handling or fallback logic to design? **NO** — that's literally the point
- [x] No cross-package changes? yes — all in `.agents/scripts/`
- [x] Estimate 1h or less? **NO** — ~2h including tests and migration
- [x] 4 or fewer acceptance criteria? marginal

Any unchecked → **`tier:standard`**.

**Selected tier:** `tier:standard` — implementing interactively, self-dispatched.

**Tier rationale:** Multi-file bash logic change with explicit error-handling semantics. Pattern already exists (the existing dedup logic at `:82-95`) so no novel architecture, but the error-classification policy is a design decision that requires judgment.

## PR Conventions

Leaf (non-parent) issue — PR body will use `Resolves #{NNN}` where NNN is the t2687 issue number.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/stats-health-dashboard.sh:42-114` — rewrite `_find_health_issue` to classify `gh` command errors (success-empty vs. query-failure) and return a sentinel on failure that callers honour.
- `EDIT: .agents/scripts/stats-health-dashboard.sh:207-231` — update `_resolve_health_issue_number` to treat the failure sentinel as "skip cycle", never fall through to `_create_health_issue`.
- `EDIT: .agents/scripts/stats-health-dashboard.sh:1088-1128` — add periodic dedup scan in `_update_health_issue_for_repo` (run once per hour per repo even on cache hits).
- `NEW: .agents/scripts/tests/test-find-health-issue-rate-limit.sh` — unit test using stubbed `gh` command that returns rate-limit errors; asserts cache preserved and no duplicate created.
- `NEW: .agents/scripts/migrate-health-issue-duplicates-t2687.sh` — one-shot migration that closes duplicates per (repo, runner, role). Marker file: `~/.aidevops/logs/.migrated-health-issue-duplicates-t2687`.
- `EDIT: TODO.md` — task entry updated with `ref:GH#NNN`.

### Implementation Steps

1. **Error classification helper.** Add a helper that runs a `gh` command and returns distinct outputs: the payload, the rc, and stderr. Use for both view and list calls. Pattern:

```bash
# _gh_query_with_rc: run gh command, capture payload + rc + stderr
# Output (on stdout): <rc>\n<stderr_first_line>\n<payload>
_gh_query_with_rc() {
    local out rc=0
    local stderr_file
    stderr_file=$(mktemp)
    out=$("$@" 2>"$stderr_file") || rc=$?
    local stderr_first
    stderr_first=$(head -1 "$stderr_file" 2>/dev/null || echo "")
    rm -f "$stderr_file"
    printf '%s\n%s\n%s' "$rc" "$stderr_first" "$out"
}
```

2. **Cache validation fail-safe.** In `_find_health_issue`, replace the `|| echo ""` pattern on `gh issue view` with rc-aware logic:
   - rc=0, state==OPEN → keep cache
   - rc=0, state==CLOSED → remove cache (current behaviour)
   - rc≠0 OR empty state → log query-failure warning, KEEP cache, return cached number. Do NOT `rm` the cache file.

3. **Label/title search fail-safe.** Same treatment: if rc≠0 on the dedup lookups, return a sentinel `__QUERY_FAILED__` so `_resolve_health_issue_number` can refuse to create. Caller contract: empty string = confirmed-not-found (safe to create); `__QUERY_FAILED__` = abstain this cycle.

4. **Periodic dedup on cache hits.** Track last-dedup-scan time per repo in `~/.aidevops/logs/health-dedup-last-scan-<slug_safe>`. On each `_update_health_issue_for_repo` call, if > 1 hour since last scan, run the label-based dedup scan even if cache is valid. Close duplicates per the existing `:82-95` logic.

5. **Migration script.** Iterate all repos with `pulse: true`, group supervisor/contributor health issues by (runner_user, role_label), keep newest by created_at, close older ones with comment template `Closing duplicate ${role} health issue — superseded by #${newest}. Root cause: GraphQL rate-limit window 2026-04-21 (GH#{issue_num}).`. Write marker file to prevent re-runs.

6. **Tag normalization.** Migration also backfills `origin:worker` on any `source:health-dashboard` issue missing it (#20298 specifically) via `gh issue edit --add-label origin:worker`.

7. **Test harness.** Use the existing `tests/helpers/gh-stub.sh` pattern (or create a minimal inline stub). Test scenarios: (a) rate-limit on view → cache preserved; (b) rate-limit on list → no create; (c) rate-limit on title search → no create; (d) two existing issues + stale cache → both discovered, older closed.

### Verification

```bash
# Lint
shellcheck .agents/scripts/stats-health-dashboard.sh
shellcheck .agents/scripts/tests/test-find-health-issue-rate-limit.sh
shellcheck .agents/scripts/migrate-health-issue-duplicates-t2687.sh

# Unit test
bash .agents/scripts/tests/test-find-health-issue-rate-limit.sh

# Migration dry-run
bash .agents/scripts/migrate-health-issue-duplicates-t2687.sh --dry-run

# Post-merge: verify no supervisor duplicates per (repo, runner)
for slug in $(jq -r '.initialized_repos[] | select(.pulse == true) | .slug' ~/.config/aidevops/repos.json); do
  gh issue list --repo "$slug" --state open --search "Supervisor in:title" --limit 30 --json title | \
    jq -r 'group_by(.title[0:30]) | map(select(length>1)) | length' | \
    xargs -I{} test {} -eq 0 || echo "DUPES STILL IN $slug"
done
```

### Files Scope

- `.agents/scripts/stats-health-dashboard.sh`
- `.agents/scripts/tests/test-find-health-issue-rate-limit.sh`
- `.agents/scripts/migrate-health-issue-duplicates-t2687.sh`
- `TODO.md`
- `todo/tasks/t2687-brief.md`

## Acceptance Criteria

- [ ] `_find_health_issue` preserves the cache file when `gh issue view` returns non-zero (simulated rate limit). No `rm -f "$health_issue_file"`.
- [ ] `_find_health_issue` returns the `__QUERY_FAILED__` sentinel when both label and title lookups return non-zero, and `_resolve_health_issue_number` treats this as "skip cycle" (no create).
- [ ] `_update_health_issue_for_repo` runs the label-based dedup scan at least once per hour per repo, even on cache hits. Scan closes all but the newest per (repo, runner, role) tuple.
- [ ] Migration script closes the 19 currently-orphaned duplicate supervisor/contributor issues across the fleet with explanatory comments referencing GH#NNN.
- [ ] Migration script backfills `origin:worker` on any `source:health-dashboard` issue missing it.
- [ ] Test harness passes all 4 scenarios: rate-limit-on-view, rate-limit-on-list, rate-limit-on-title-search, stale-cache-with-two-existing.
- [ ] `shellcheck` zero violations on all modified files.
- [ ] Post-merge fleet scan shows zero duplicate supervisor issues per (repo, runner).

## Context & Decisions

- **Scope boundary (important):** this PR does NOT extend the t2574 REST fallback to READ operations (`gh issue view`, `gh issue list`). That is the correct framework-wide fix and will be filed as follow-up issue. This PR is the surgical fix that prevents the *duplicate creation* consequence.
- **Why not fix in `_create_health_issue`?** We could check for existing duplicates inside `_create_health_issue` as a last-line defence, but that doubles the GraphQL load exactly when the API is struggling. Better to teach `_find_health_issue` to refuse-on-error.
- **Circuit breaker at pulse-entry level?** Considered and rejected for this PR (Layer 4 in the analysis). A pulse-level rate-limit circuit breaker would stop ALL health-dashboard operations during exhaustion windows, including legitimate updates on already-found issues. This PR's finer-grained approach — preserve cache, abstain on create — keeps the dashboard working where it can.
- **1-hour periodic dedup interval:** Short enough that duplicates from a rate-limit window close within one cycle after the window ends. Long enough that we don't waste a list call every pulse cycle (pulse runs every ~5min → 12 calls/hour currently; this reduces dedup scan to 1/hour which is 12× lower cost).
- **`__QUERY_FAILED__` sentinel vs return code:** chose sentinel so the existing `echo $number / return 0` pattern stays; return codes would require refactoring all call sites.

## Relevant Files

- `.agents/scripts/stats-health-dashboard.sh:42-114` — `_find_health_issue` (core fix target)
- `.agents/scripts/stats-health-dashboard.sh:130-188` — `_create_health_issue` (unchanged, but called less often after fix)
- `.agents/scripts/stats-health-dashboard.sh:207-231` — `_resolve_health_issue_number` (needs sentinel handling)
- `.agents/scripts/stats-health-dashboard.sh:1068-1164` — `_update_health_issue_for_repo` (periodic dedup added here)
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh` — pattern reference for future Layer 3 follow-up
- `~/.aidevops/logs/stats.log` — evidence trail

## Dependencies

- **Blocked by:** none
- **Blocks:** follow-up issues for Layers 3 (read-path REST fallback) and 4 (pulse-level rate-limit circuit breaker) — I will file these after this PR merges so they carry a `blocked-by: t2687` reference
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | done | investigation already complete |
| Implementation | 1.5h | Layer 1 + Layer 2 + migration |
| Testing | 30m | stub-based test, migration dry-run |
| **Total** | **~2h** | |
