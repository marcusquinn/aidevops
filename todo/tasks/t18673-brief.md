<!-- aidevops:brief-schema=v2 -->

# fix(pulse): read the exact PR when the prefetch snapshot is stale so worker draft-checkpoint dispatch hints work

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `dispatch negative cache worker draft checkpoint fingerprint prefetch snapshot` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open PRs on the target files; the last change to this hint was #33044 (GH#33034, 2026-09-29)
- [x] File refs verified at origin/main 744fb55df3: `_dispatch_negative_pr_fingerprint` (`.agents/scripts/pulse-dispatch-lib.sh:131`), its record caller (`:237`), its read caller (`:289`) and the prefilter call site that runs before the dispatch ceremony (`:541`)
- [x] Tier: `tier:standard` — two functions in one module plus focused cases in the existing suite
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation. Candidates held by a worker draft checkpoint paid the full dispatch ceremony on every attempt, although a cross-cycle hint exists for exactly this case.

## What

When the last attempt on a candidate was blocked by a worker draft checkpoint, the next attempt inside the existing 30-minute hint window skips the candidate before the dispatch ceremony while the issue and the draft PR are unchanged, whether or not the batch-prefetch PR snapshot is fresh.

## Why

- `_dispatch_negative_pr_fingerprint` takes the PR revision (`updatedAt` + `headRefOid`) only from a complete batch-prefetch snapshot younger than 900s, at both record and read time.
- Prefetch rarely completes: early dispatch runs before `preflight_prefetch_and_scope` and spends the cycle budget (GH#33647, GH#34000). On this runner the PR snapshots completed at 00:42, 10:25, 12:44, 14:58 and 17:11Z on 2026-10-11.
- A hit therefore needs two attempts on the same candidate inside one 15-minute post-prefetch window. Observed re-attempt gaps are 14–413 minutes, so it almost never happens.
- Evidence (this runner, last 45,000 `pulse.log` lines, 2026-10-10T19:08Z–2026-10-11T17:12Z): 134 `WORKER_DRAFT_CHECKPOINT` rediscoveries cost 8,402 candidate-seconds (62.7s each) with zero `cross-cycle ownership block:worker_draft_checkpoint_blocked` hits. The whole retained log has two hint hits, both `terminal_blocker_circuit`.
- Records are written when a snapshot happens to be fresh: 28 `worker_draft_checkpoint_blocked` records exist, the newest written about 15:05–15:12Z, minutes after the 14:58Z prefetch. None was ever read back.
- Replaying the logged attempt times with a fingerprint that is always available and the unchanged 1800s TTL skips 37 of 148 attempts (25%), about 2,300 ceremony-seconds per 22 hours on one runner. One managed private repo accounts for most of them.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a narrow fallback inside one module with a verified mechanism (snapshot age gate versus prefetch cadence) and focused cases in the existing suite. Dispatch-path module, so the change keeps every existing gate and stays skip-only.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:128-144` — keep the prefetch snapshot as the first source. A fresh complete snapshot stays authoritative: a PR missing from it is not open, so no hint and no API call. When the snapshot is missing, stale or incomplete, call the new REST reader.
- `NEW: _dispatch_negative_pr_rest_fingerprint` in the same file — one `timeout_sec`-bounded `gh api repos/{repo}/pulls/{pr}` read that returns `updated_at` + `_` + `head.sha` only for an open draft; any error returns 1. Model the field mapping on `.agents/scripts/pulse-batch-prefetch-helper.sh:395-405` so both sources produce identical fingerprints.
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:287-291` — check the TTL before reading the PR, so an expired hint costs no API call.
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:66-80` — add `_DISPATCH_NEGATIVE_PR_REST_TIMEOUT_SECONDS` (env `AIDEVOPS_DISPATCH_NEGATIVE_PR_REST_TIMEOUT_SECONDS`, default 10, range 1–30).
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:838-841` — the GH#33538 parent-prefilter comment says "no API"; record the one bounded REST read a live worker-draft hint can now make there.
- `EDIT: .agents/scripts/tests/test-pulse-stale-pr-continuation.sh:280-285` — the "stale snapshot cannot suppress dispatch" contract changes. Replace it with stale-snapshot cases for a failed read, an unchanged open draft (record and read), a closed PR and a ready PR, plus "fresh complete snapshot needs no read" and "expired hint costs no read".

### Complete Write Surface

- **Callers/readers:** `_dispatch_negative_pr_fingerprint` has two callers, `_dispatch_negative_cache_record` (`pulse-dispatch-lib.sh:237`) and `_dispatch_negative_cache_reason` (`:289`); `rg -n "_dispatch_negative_pr_fingerprint" .agents/scripts` finds no others. `_dispatch_negative_cache_reason` in turn runs in the parallel loop's parent prefilter (`_dispatch_max_prefilter_cached_block`, `:848`, called at `:798`, serial, before capacity checks) and in each candidate's own prefilter (`_dispatch_prefilter_owned_candidate`, `:307`, called at `:541` by every loop).
- **Writers/mutation paths:** records under `~/.aidevops/logs/dispatch-negative-cache/` keep their format; the fingerprint string is identical from either source.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-stale-pr-continuation.sh`; `.agents/scripts/tests/test-dispatch-max-parallel.sh` exercises `_dispatch_cache_confirmed_block` for other reasons.
- **Schemas/config:** one optional env var (above).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` on release/update; no generated copies.
- **Migrations/backfills:** none; existing records stay valid.
- **Cleanup/rollback paths:** reverting the file restores the snapshot-only behaviour.

### Implementation Steps

1. Add the timeout constant and `_dispatch_negative_pr_rest_fingerprint`.
2. Split `_dispatch_negative_pr_fingerprint` into "fresh complete snapshot → authoritative" and "otherwise → REST reader".
3. In the `worker_draft_checkpoint_blocked` read branch, check the TTL before the fingerprint read.
4. Update the suite, run ShellCheck and the suites below.

### Hazards and Compatibility

- **Safety:** the hint only skips; it never launches, claims or relabels. The issue `updatedAt` match, the 1800s TTL and the exact PR revision match all still apply. Requiring an open draft from REST is stricter than the snapshot path.
- **Time-based transitions:** the GH#34008 expired-claim continuation and Layer 6 stale-assignment recovery change neither fingerprint, so a live hint can delay them by up to the unchanged 30-minute TTL, as designed in GH#33034.
- **API cost:** at most one REST core call per recorded block and per live hint read while the snapshot is stale (tens per cycle at most), versus the ceremony's many calls. The pulse puts the `gh` shim first on `PATH`, and the shim records the call, so the helper does not record it again.
- **Parent wave loop:** the GH#33538 parent prefilter runs serially before capacity checks, so a live worker-draft hint with a stale snapshot now costs one REST read there (typically under a second). This replaces the capacity wait, inter-launch delay and ~63s ceremony a spawned candidate would otherwise pay. Each read is bounded at 10s; a complete API stall costs at most 10s per hinted candidate, when every ceremony would be failing too. Keeping the parent local-only would forfeit the GH#33538 benefit (skip without spending a wave slot) for exactly these candidates.
- **Mixed versions:** older bundles keep reading the same record format.
- **Bash 3.2:** no new constructs.

### Complexity Impact

- **Target function:** `_dispatch_negative_cache_reason` in `.agents/scripts/pulse-dispatch-lib.sh`
- **Current line count:** 55 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +3 lines
- **Projected post-change:** 58 lines (58% of threshold)
- **Action required:** None — the REST read is a separate helper of about 18 lines.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/tests/test-pulse-stale-pr-continuation.sh
bash .agents/scripts/tests/test-pulse-stale-pr-continuation.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
```

- **Surface mapping:** the stale-continuation suite drives the real record and read functions with a stubbed snapshot helper and stubbed `gh`; the max-parallel suite covers the other cached reasons through the same recorder.
- **Live check after release and update:** `rg -c "cross-cycle (ownership )?block:worker_draft_checkpoint_blocked" ~/.aidevops/logs/pulse.log` rises above 0 while repeated `WORKER_DRAFT_CHECKPOINT` rediscoveries for the same issues fall. The parent prefilter logs `cross-cycle block:`; the candidate prefilter logs `cross-cycle ownership block:`.
- **Broad verification trigger:** Not required — one module, no shared contract, root tooling or release infrastructure change.

### Recoverability Checkpoint

- [ ] Focused functional verification passes
- [ ] WIP commit created before broad gates
- [ ] Evidence-triggered broad verification then run: not required — single module

### Scope Boundaries

Initial implementation map. Directly necessary adjacent integration follows
`reference/worker-discipline.md` "Integration scope recovery".

**Hard boundaries:** do not change the TTL, the ownership gates, which reasons are cached, or the prefetch schedule.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request
and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/tests/test-pulse-stale-pr-continuation.sh`
- `TODO.md`
- `todo/tasks/t18673-brief.md`

## Acceptance Criteria

- [ ] A missing, stale or incomplete PR snapshot falls back to one bounded exact-PR REST read.

  ```yaml
  verify:
    method: codebase
    pattern: "_dispatch_negative_pr_rest_fingerprint \"\\$repo\" \"\\$pr\""
    path: ".agents/scripts/pulse-dispatch-lib.sh"
  ```

- [ ] Only an open draft yields a REST fingerprint.

  ```yaml
  verify:
    method: codebase
    pattern: "select\\(.state == \"open\" and .draft == true\\)"
    path: ".agents/scripts/pulse-dispatch-lib.sh"
  ```

- [ ] A fresh complete snapshot stays authoritative and expired hints are rejected before any PR read.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-stale-pr-continuation.sh"
  ```

- [ ] After release and update, the runner logs `cross-cycle block:worker_draft_checkpoint_blocked` (parent prefilter) or `cross-cycle ownership block:worker_draft_checkpoint_blocked` (candidate prefilter) hits.

  ```yaml
  verify:
    method: manual
    prompt: "rg -c 'cross-cycle (ownership )?block:worker_draft_checkpoint_blocked' ~/.aidevops/logs/pulse.log is above 0 after the deploy"
  ```

## Context & Decisions

- **Snapshot first:** free when fresh, and the only cheap proof that a PR is no longer open.
- **REST, not GraphQL:** the REST core budget is separate from the GraphQL budget the ceremony drains (same rationale as `_dispatch_skip_for_issue_body`).
- **TTL unchanged:** replayed hits rise to 82 of 148 at 7200s, but the expired-claim continuation and stale-assignment recovery are time-based and would wait up to the TTL. That trade-off needs its own decision.
- **Not in scope:** prefetch starvation (early dispatch before `preflight_prefetch_and_scope`), which also starves other snapshot consumers.

## Relevant Files

- `.agents/scripts/pulse-dispatch-lib.sh:131` — `_dispatch_negative_pr_fingerprint`
- `.agents/scripts/pulse-dispatch-lib.sh:251` — `_dispatch_negative_cache_reason`
- `.agents/scripts/pulse-dispatch-lib.sh:327` — `_dispatch_cache_confirmed_block` (worker-draft record)
- `.agents/scripts/pulse-batch-prefetch-helper.sh:395` — REST to snapshot field mapping
- `.agents/scripts/tests/test-pulse-stale-pr-continuation.sh:214` — record/read cases

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing directly; reduces wasted dispatch ceremony for every runner
- **External:** none
