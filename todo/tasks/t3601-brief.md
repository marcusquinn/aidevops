---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3601: Design pulse GitHub API boot and cooldown pacing

## Pre-flight

- [x] Memory recall: `review issue pr worker-ready brief dispatch tier thinking issue 24855` → 0 hits — no relevant lessons found.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs found for `pulse GitHub API pacing cooldown startup prefetch list` against the target files since GH#24855 was filed.
- [x] File refs verified: 7 target files and 6 current line-range anchors checked at HEAD.
- [x] Tier: `tier:thinking` — this spans pulse orchestration, wrapper/cooldown semantics, cache reuse, request-velocity policy, and dispatch freshness trade-offs.
- [x] Seeded draft PR decision recorded: skipped — this is a design/investigation brief; a seeded implementation would anchor workers to an unmeasured pacing policy.

## Origin

- **Created:** 2026-06-15
- **Session:** OpenCode interactive review of GH#24855
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** GH#24855 reported repeated GitHub secondary-rate-limit cooldown shortly after host boot and again shortly after cooldown expiry, while primary REST/GraphQL quotas remained healthy. The review accepted the issue and recommended a thinking-tier design task before splitting implementation.

## What

Design and implement the first safe slice of pulse/supervisor GitHub API pacing so cold start and post-cooldown recovery do not immediately resume a bursty list/cache/prefetch pattern that can retrigger GitHub secondary-rate-limit protection.

The deliverable must produce a measurable pacing contract, not scattered sleeps. It should either add the minimal shared guard/instrumentation needed for the first implementation slice or leave a documented, verified phase plan with child tasks if the design proves too broad for one PR.

## Why

GH#24855 includes sanitized evidence of cooldown loops beginning ~94 seconds after boot and ~58 seconds after the prior cooldown expired, with per-minute bursts dominated by repeated issue/PR list, snapshot-cache, and prefetch calls. Existing cooldown handling reacts after GitHub returns limiting responses; it does not appear to provide pre-emptive boot/recovery ramp-up across independent pulse stages.

Without this, pulse may fail closed repeatedly under secondary cooldown, making dispatch, review scanning, state refresh, and dashboard freshness unreliable even when hourly primary quotas remain available.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — likely touches wrapper/cooldown/instrumentation plus pulse prefetch/candidate paths and tests.
- [ ] **Every target file under 500 lines?** No — `shared-gh-wrappers.sh` and `pulse-prefetch-fetch.sh` exceed 500 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — the worker must choose the pacing contract after measurement.
- [ ] **No judgment or design decisions?** No — freshness, dispatch latency, critical reads, and API safety must be balanced.
- [ ] **No error handling or fallback logic to design?** No — cooldown, ramp-up, cache stale/fallback, and critical-read bypass semantics are central.
- [ ] **No cross-package or cross-module changes?** No — wrappers, pulse stages, prefetch, instrumentation, and tests are affected.
- [ ] **Estimate 1h or less?** No.
- [ ] **4 or fewer acceptance criteria?** No.
- [x] **Dispatch-path classification (t2821/t2920):** The scope includes `pulse-wrapper.sh`/pulse orchestration paths; keep `tier:thinking` and rely on the dispatch-path detector to elevate model selection if auto-dispatched.

**Selected tier:** `tier:thinking`

**Tier rationale:** The issue is architectural and reliability-sensitive. The correct fix must prevent aggregate request-velocity bursts before cooldown while preserving existing fail-closed cooldown and trust/dispatch freshness invariants.

## PR Conventions

Leaf task: use a closing keyword for GH#24855 only when the implementation is complete enough to resolve the accepted issue. Use `For #24855` for design-only or first-phase PRs that do not yet prevent the burst pattern.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Current-session work verified the review context and file anchors but did not measure pagination/page-count costs or implement a pacing policy. A seeded draft would risk premature design anchoring.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall returned no hits; discovery found 0 recent commits/merged/open PRs for the target pacing keywords; file references below were read from current HEAD.
- **Verification run:** `git log --since='2026-06-15 13:58 UTC' --oneline -- <target files>` returned no commits; `gh pr list --repo marcusquinn/aidevops --state merged/open --search 'pulse GitHub API pacing cooldown startup prefetch list' --limit 5` returned no PRs.
- **Stale-assumption warning:** Re-run recent PR/commit discovery before editing; pulse request routing and cooldown wrappers are moving parts.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/shared-gh-secondary-cooldown.sh:148-221`, `.agents/scripts/shared-gh-wrappers.sh:219-255`, `.agents/scripts/gh-api-instrument.sh:72-145` — establishes current reactive cooldown recording/preflight and call instrumentation.
- **Read next:** `.agents/scripts/pulse-prefetch-fetch.sh:182-268`, `.agents/scripts/pulse-prefetch-fetch.sh:350-403`, `.agents/scripts/pulse-repo-meta.sh:227-247`, `.agents/scripts/shared-gh-wrappers-status.sh:146-184` — establishes the list/cache/prefetch paths highlighted by GH#24855.
- **Load only if:** `.agents/reference/worker-diagnostics.md` or `.agents/reference/gh-command-discipline.md` if changing cooldown comments, diagnostics output, or GitHub write behaviour.
- **Why:** The task touches high-frequency GitHub reads and pulse dispatch freshness. Keep context focused on wrapper-level policy and dominant callers before widening to routine scheduling or dashboard stages.
- **Stop when:** You have a measured pacing/ramp contract, a chosen bypass policy for critical reads/writes, and tests proving cooldown response handling still fails closed.

### Worker Quick-Start

Current anchors from HEAD:

```text
.agents/scripts/shared-gh-secondary-cooldown.sh:148-173  record 403/429/remaining-zero/cooldown responses
.agents/scripts/shared-gh-secondary-cooldown.sh:210-221  preflight skips reads while cooldown is active
.agents/scripts/shared-gh-wrappers.sh:219-255            wrapper preflight plus response capture/recording
.agents/scripts/gh-api-instrument.sh:72-145              append-only call instrumentation fields
.agents/scripts/pulse-prefetch-fetch.sh:182-268          PR list/cache/fallback path
.agents/scripts/pulse-prefetch-fetch.sh:350-403          issue delta fetch fallback-to-full path
.agents/scripts/pulse-repo-meta.sh:227-247               dispatch candidate issue list failure path
.agents/scripts/shared-gh-wrappers-status.sh:146-184     short-TTL PR list snapshot cache
```

The reporter's dominant callers were `_rest_issue_list`, `gh_pr_list_cache`, `_rest_pr_list`, `gh_pr_list`, and `pulse_pr_list_provider_cache`; do not optimize an unrelated path first unless fresh instrumentation disproves that mix.

### Files to Modify

- `EDIT: .agents/scripts/shared-gh-secondary-cooldown.sh:148-221` — preserve response-based cooldown recording and add/read any recovery-phase state only if it belongs with cooldown state.
- `EDIT: .agents/scripts/shared-gh-wrappers.sh:219-255` — preferred location for shared read-budget/ramp preflight so stages do not scatter sleeps.
- `EDIT: .agents/scripts/gh-api-instrument.sh:72-145` — add page-count/logical-operation/cache-phase fields only if needed to measure the pacing contract; keep hot-path overhead minimal.
- `EDIT: .agents/scripts/pulse-prefetch-fetch.sh:182-268,350-403` — make list/prefetch paths respect the shared ramp budget and avoid delta-failure full sweeps during constrained recovery unless explicitly critical.
- `EDIT: .agents/scripts/pulse-repo-meta.sh:227-247` — ensure dispatch candidate listing handles ramp deferral distinctly from hard failure, so diagnostics do not misreport a cooldown/API fault.
- `EDIT: .agents/scripts/shared-gh-wrappers-status.sh:146-184` — evaluate whether the 15-second PR list cache helps or amplifies bursty retry patterns; adjust only with tests.
- `AUDIT: .agents/scripts/pulse-wrapper.sh` — identify boot/cycle stage ordering and whether noncritical stages need phased deferral after boot or cooldown expiry.
- `NEW/EDIT: .agents/scripts/tests/test-*gh*pacing*.sh`, `.agents/scripts/tests/test-*cooldown*.sh`, or the nearest existing wrapper/pulse tests — add focused shell regression coverage.

### Implementation Steps

1. Re-run exact discovery before editing:

```bash
rg -n 'gh_record_call|_gh_secondary_cooldown_preflight|gh_issue_list|gh_pr_list|_rest_issue_list|_rest_pr_list|PULSE_PREFETCH|cooldown' .agents/scripts
git log --since='48 hours ago' --oneline -- .agents/scripts/shared-gh-secondary-cooldown.sh .agents/scripts/shared-gh-wrappers.sh .agents/scripts/gh-api-instrument.sh .agents/scripts/pulse-prefetch-fetch.sh .agents/scripts/pulse-repo-meta.sh .agents/scripts/shared-gh-wrappers-status.sh .agents/scripts/pulse-wrapper.sh
```

2. Measure or expose enough instrumentation to distinguish:
   - logical operation (`prefetch_prs`, `prefetch_issues`, `candidate_list`, `snapshot_get`, `snapshot_put`),
   - endpoint family/pool (REST core, GraphQL, search),
   - page count or requested limit where available,
   - cache hit/miss/stale/full-sweep fallback,
   - phase (`normal`, `boot-ramp`, `cooldown-recovery`, `cooldown-active`).

3. Define a shared pacing contract. Preferred shape: wrapper-level token bucket or ramp state for noncritical reads, with explicit bypass for writes and safety-critical reads that must fail closed rather than silently use stale state.

4. Apply the contract to the dominant read/list paths first. Avoid per-stage `sleep`; prefer returning a distinct deferral code/status that callers can log as `ramp-deferred` and retry next cycle.

5. Preserve existing secondary cooldown behaviour:
   - active cooldown still returns 75 from `.agents/scripts/shared-gh-secondary-cooldown.sh:210-221`,
   - `Retry-After` / `x-ratelimit-reset` handling remains authoritative,
   - writes are not made unsafe by read pacing,
   - primary quota exhaustion and secondary cooldown remain distinguishable.

6. Decide stale-data behaviour per consumer:
   - dispatch candidate enumeration may skip or use bounded cached candidates during ramp only if dedup/claim checks remain live before launch,
   - dashboard freshness can tolerate stale markers,
   - merge/review/trust gates must not auto-act on stale state unless existing code already validates live state before mutation.

7. If the design is too broad for one safe implementation, land a measured instrumentation/ramp-state foundation and file child tasks for snapshot reuse, routine jitter, or stage deferral.

### Complexity Impact

- **Target functions:** `_gh_with_timeout`, `_gh_secondary_cooldown_preflight`, `_prefetch_repo_prs`, `_prefetch_issues_try_delta`, `list_dispatchable_issue_candidates_json`.
- **Current risk:** Several target files are large; adding inline policy blocks can trip function-complexity and make pacing inconsistent.
- **Action required:** Extract small helpers with explicit return codes. Shell functions must use `local var="$1"` style for parameters and explicit `return 0` / `return 1` paths.

### Verification

Run the closest existing targeted tests plus new pacing tests. Minimum expected commands:

```bash
.agents/scripts/tests/test-shared-gh-wrappers.sh
.agents/scripts/tests/test-gh-secondary-cooldown.sh
.agents/scripts/tests/test-pulse-prefetch-cache.sh
.agents/scripts/tests/test-pulse-prefetch-*.sh
.agents/scripts/tests/test-pulse-repo-meta.sh
.agents/scripts/linters-local.sh
```

If exact test filenames differ at implementation time, discover with:

```bash
git ls-files '.agents/scripts/tests/test-*gh*.sh' '.agents/scripts/tests/test-*cooldown*.sh' '.agents/scripts/tests/test-*prefetch*.sh' '.agents/scripts/tests/test-*repo-meta*.sh'
```

### Files Scope

- `.agents/scripts/shared-gh-secondary-cooldown.sh`
- `.agents/scripts/shared-gh-wrappers.sh`
- `.agents/scripts/shared-gh-wrappers-status.sh`
- `.agents/scripts/gh-api-instrument.sh`
- `.agents/scripts/pulse-prefetch-fetch.sh`
- `.agents/scripts/pulse-repo-meta.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/tests/test-*gh*.sh`
- `.agents/scripts/tests/test-*cooldown*.sh`
- `.agents/scripts/tests/test-*prefetch*.sh`
- `.agents/scripts/tests/test-*repo-meta*.sh`

## Acceptance Criteria

- [ ] The implementation documents a shared boot/cooldown-recovery pacing contract and the classes of reads that must respect it.
- [ ] Dominant list/cache/prefetch paths from GH#24855 either respect the shared ramp budget or are explicitly justified as critical live reads.
- [ ] Post-cooldown recovery does not immediately return to unconstrained read fanout; constrained recovery state is visible in diagnostics/logs.
- [ ] Existing fail-closed cooldown semantics for 403/429/`Retry-After`/`x-ratelimit-reset` are preserved.
- [ ] Cache fallback/full-sweep behaviour is bounded during ramp-up so failed deltas do not amplify into bursty full sweeps.
- [ ] Tests cover boot ramp, cooldown-expiry ramp, active cooldown skip, critical bypass/fail-closed behaviour, and normal-mode no-op behaviour.
- [ ] Targeted shell tests and `.agents/scripts/linters-local.sh` pass.

## Context & Decisions

- GH#24855 is intentionally non-prescriptive. Do not blindly implement every consideration; choose the smallest root-cause-oriented policy that reduces aggregate request velocity.
- Related issues #23605 and #24547/#24548 handle cooldown detection/response. Treat them as invariants to preserve, not duplicates.
- Avoid GitHub comment storms while testing rate-limit recovery. Use local fixtures/mocks for regression coverage.
- Prefer feature-flagged/configurable rollout if the pacing policy can affect dispatch latency or dashboard freshness.

## Worker Notes

- This is a `tier:thinking` task. It is acceptable for the first PR to be a measured foundation plus phase plan if it materially improves observability and preserves safety.
- If you change third-party API/error-code mappings, first verify the installed dependency version and local exported symbols/source from package manifests/lockfiles before adding mappings.
- Do not include private repo names, private issue numbers, local paths, or raw cooldown request IDs in public comments, commits, or PR bodies.

## References

- Source issue: GH#24855
- Review comment: GH#24855 issue comment posted 2026-06-15, decision APPROVE, dispatchability missing brief/TODO/task ID.
- Related but not duplicate: GH#23605, GH#24547, GH#24548.
