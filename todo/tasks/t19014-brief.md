<!-- aidevops:brief-schema=v2 -->

# t19014: perf(ci-wait): resolve required check contexts once per wait, not every poll

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (t19011 / GH#38388 session)
- **Issue:** GH#38404
- **Conversation context:** t19011 (PR #38390) moves workers from immediate post-PR handoff to bounded in-session `full-loop-helper.sh wait-checks` calls (up to 8 x 200 s). While measuring that wait on PR #38390, the REST core quota hit 0/5000 and the governed merge was deferred by read admission. The local API log showed `gh-checks-wait-helper.sh` making about 135 REST attempts over 6 wait calls (about 22 per 200 s call), dominated by `repos-pulls` (67) and `repos-other` (62).

## What

`wait_for_checks` in `.agents/scripts/gh-checks-wait-helper.sh` resolves the base branch's configured required contexts once per wait invocation (first successful read), not on every poll. Failed reads are not cached, so a transient error retries on the next poll.

## Why

`classify_state` (`gh-checks-wait-helper.sh:434`) calls `configured_required_contexts` (`:342`) on every poll. That function makes 3 REST reads: `repos/{repo}/pulls/{n}` (base ref), `branches/{base}/protection/required_status_checks`, and `rules/branches/{base}`. None of them change during a wait. The per-poll check fetch itself (`gh_pr_checks_observed_json`) is 1 REST identity read plus GraphQL pages, so these 3 reads are about 75% of the waiter's REST cost per poll. With t19011, each waiting worker spends them on every poll for up to about 27 minutes; several concurrent waiters compete with merges and Pulse for the same 5000/hour core quota. When admission defers a read, the wait returns exit 2 and the worker hands off, so REST spent on invariant reads directly shortens in-session ownership.

`classify_state` runs inside a command substitution (`:741`), so a global memo inside it would not persist; resolve in the loop body and pass the result in.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One helper, one function boundary, existing fixture suite; behaviour stays identical except for fewer repeated reads.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/gh-checks-wait-helper.sh:696-750` — add `resolve_configured_contexts_once` (sets `_GCW_CONFIGURED_RC` / `_GCW_CONFIGURED_CONTEXTS`, caches only on exit 0); `wait_for_checks` resets the cache at wait start and calls it before `classify_state`, outside the command substitution.
- `EDIT: .agents/scripts/gh-checks-wait-helper.sh:434-457` — `classify_state` accepts optional args 7 (read exit code) and 8 (contexts); when absent, it keeps the direct call.

### Implementation Steps

1. Add the optional parameters to `classify_state`; keep the current fallback when they are omitted.
2. Resolve once in `wait_for_checks` outside the `$(classify_state ...)` substitution and pass both values.
3. Keep the zero-job (`zero_job_runs`) path unchanged; it runs only when contexts are missing after the settle window.

### Verification

```bash
bash .agents/scripts/tests/test-gh-checks-wait-helper.sh
shellcheck .agents/scripts/gh-checks-wait-helper.sh
# Live: one wait on an open PR with pending checks, then count this caller's REST routes
# in ~/.aidevops/logs/gh-api-calls.log for the wait window; `repos-other` should be 2 per wait, not 2 per poll.
```

### Files Scope

- `.agents/scripts/gh-checks-wait-helper.sh`
- `TODO.md`
- `todo/tasks/t19014-brief.md`

## Acceptance Criteria

- [x] `test-gh-checks-wait-helper.sh` passes unchanged (116/116).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-gh-checks-wait-helper.sh"
  ```

- [x] A wait of 3+ polls makes at most one `configured_required_contexts` read set (1 base read + protection + ruleset) per wait invocation.
- [x] A transient failure of the contexts read is retried on the next poll, not cached.

### Verification evidence

Controlled run with the suite's stub `gh` (call-logging prefix), `GH_TEST_MODE=required-protection`, `--timeout 2`, no sleep:

| Helper | GraphQL polls | Base reads | Protection reads | Ruleset reads |
|--------|---------------|------------|------------------|---------------|
| Before (`057a953903`) | 3-4 | 3-4 (one per poll) | 3-4 | 3-4 |
| After | 4 | 1 | 1 | 1 |

`GH_TEST_MODE=protection-error`, same settings, after: 5 polls, 5 protection reads (failure retried each poll), exit 8 (non-clear).

A live comparison on an open PR was attempted but other concurrent waiters on the same login shared the REST log, so route counts were not attributable per invocation; the stub run above is the acceptance evidence.

## Context & Decisions

- Per-invocation scope only. Caching across the 8 contract calls (file cache keyed by repo and base branch) is a possible later step; not needed for the main saving.
- A stale contexts answer cannot bypass a gate: GitHub branch protection still decides at merge time; the waiter only decides when to retry the merge.
- Related: t19011 / GH#38388 (bounded worker wait), GH#37888 (same-login REST drain attribution).
