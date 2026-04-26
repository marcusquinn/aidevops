<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2897: pulse — per-runner zero-attempt failure circuit breaker triggers update check

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse version check auto-update` → 0 hits; `alex-solovyev worker failing` → 5 hits — t2076 (PR #19023, ps axwwo fix), t2190 (PR #19871, branch protection on worker PRs), t2394 (CLAIM_VOID gap on fast-fail), t2788 (`launch_recovery:no_worker_process` on alex-solovyev runner across cascade tiers). All four converge on "stale or broken alex-solovyev runner wastes worker dispatches that newer code already fixed".
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch `pulse-wrapper.sh` runner-health surface in last 14 days. `auto-update-helper.sh` exists since at least t2706, last touched in `t2398: post-release hot-deploy trigger`. No prior art on per-runner consecutive-failure tracking.
- [x] File refs verified: `pulse-wrapper.sh`, `auto-update-helper.sh`, `dispatch-claim-helper.sh`, `pulse-stats.json`, `~/.aidevops/cache/`, `.agents/configs/self-hosting-files.conf` all present at HEAD.
- [x] Tier: `tier:thinking` — design choices on threshold, window, signal definition, pause/resume mechanics. Brief specifies the constraints; the implementer designs the state machine.

## Origin

- **Created:** 2026-04-26
- **Session:** OpenCode (interactive)
- **Created by:** marcusquinn (human, AI-assisted refinement)
- **Parent task:** none (peer of t2898)
- **Conversation context:** Maintainer raised that one runner (alex-solovyev) repeatedly fails workers, generating comment noise and burning issues, when the fixes for the underlying causes have already shipped to `main`. Discussion clarified that the right signal is "10 consecutive zero-attempt dispatches" (workers that never got off the ground), since workers that tried-and-failed are usually brief/tier issues, not version skew. Pulse-internal SHA pulling was rejected as a tautology trap (broken update path bricks all runners simultaneously); calling the existing `aidevops update` mechanism on demand is safe because t2579 restart-on-update naturally refreshes code on the next cycle.

## What

A per-runner circuit breaker that watches dispatched workers for the "zero-attempt" signature. When N consecutive zero-attempt dispatches occur within a rolling time window, the breaker:

1. Pauses dispatch on this runner (sets a local flag the next pulse cycle reads before evaluating any issue).
2. Synchronously runs `aidevops update`.
3. If the update changed the deployed VERSION, the existing t2579 hook restarts the pulse — the next cycle picks up new code and the counter resets on first successful dispatch.
4. If the update reports no change (already on latest), the runner has a real local problem (broken install, gh auth, MCP failures, network). Stay paused. Post a single advisory file to `~/.aidevops/advisories/` and a single comment to the most recent failed claim's issue (so peers and the operator can see the runner is degraded without turning it into per-issue noise). Resume requires manual intervention or a peer-runner takeover.

The deliverable is a new helper (`pulse-runner-health-helper.sh`) plus three integration points in `pulse-wrapper.sh`: post-dispatch classification of worker outcomes, pre-dispatch breaker check, and breaker-state surface in `pulse-stats.json`.

## Why

One runner running stale or broken code wastes worker dispatches across the entire fleet. Documented incidents: t2076/PR #19023 (alex-solovyev's pre-`ps axwwo` runner kill-looped workers within 35s of dispatch — 19 call sites broken until upgrade), t2190 (cross-runner DISPATCH_CLAIM coordination starvation when one runner fast-failed 5x in 3h), t2788 (7 cascade dispatches all hit `launch_recovery:no_worker_process` on the same runner — interactive takeover succeeded in 15min, runner was the problem). The existing `DISPATCH_CLAIM_MIN_VERSION` filter only protects the OTHER runner (it ignores stale claims); it does nothing for the stale runner itself, which keeps burning workers until a human notices.

The maintainer cannot be expected to notice this — the failure mode is invisible to interactive users on healthy runners. The runner has to detect its own degradation and either heal (call the existing update path) or stop wasting dispatches.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? **No** — touches pulse-wrapper.sh + new helper + tests + stats schema (4-5 files).
- [ ] Every target file under 500 lines? **No** — pulse-wrapper.sh is large.
- [ ] Exact `oldString`/`newString` for every edit? **No** — integration points are described, not pre-written; new helper is novel logic.
- [ ] No judgment or design decisions? **No** — threshold, window, exact zero-attempt signal definition all need design.
- [ ] No error handling or fallback logic to design? **No** — pause/resume state machine, advisory dedup, peer-runner takeover semantics.
- [ ] No cross-package or cross-module changes? Yes (single repo).
- [ ] Estimate 1h or less? **No** (~4-6h with tests).
- [ ] 4 or fewer acceptance criteria? **No** — 7 below.
- [x] Dispatch-path classification (t2821): YES — `pulse-wrapper.sh` is in `.agents/configs/self-hosting-files.conf`. Use `no-auto-dispatch` + `origin:interactive`.

**Selected tier:** `tier:thinking`

**Tier rationale:** Six unchecked items. The state machine for pause/resume, the threshold tuning, and the zero-attempt signal definition all involve design decisions a Sonnet worker would either guess at or punt back. Opus reasoning is also warranted by the dispatch-path classification — failures here cascade across all runners.

## PR Conventions

Leaf task. PR body uses `Resolves #NNN` linking to the GitHub issue created from this brief.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/pulse-runner-health-helper.sh` — single-purpose helper with `record-outcome`, `is-paused`, `pause`, `resume`, `status` subcommands. Persists state to `~/.aidevops/cache/runner-health.json`. Model on `dispatch-claim-helper.sh` for state-file conventions, ISO-8601 timestamps, `safe_grep_count` usage.
- `EDIT: .agents/scripts/pulse-wrapper.sh` — three integration points:
  1. **Pre-dispatch gate:** before evaluating issues for dispatch, check `pulse-runner-health-helper.sh is-paused`. If paused, log once per cycle and skip dispatch entirely. Place upstream of the per-issue dedup chain so paused runners do zero dispatch work.
  2. **Post-worker classification:** when a worker finishes (success, failure, or watchdog kill), classify the outcome and call `pulse-runner-health-helper.sh record-outcome <signal>`. Hook point: wherever `worker-lifecycle-common.sh` reports completion back to the pulse cycle. The four zero-attempt signals are listed below.
  3. **Stats surface:** add `runner_health` block to the existing `pulse-stats.json` writer so the breaker state is visible in dashboards.
- `EDIT: .agents/scripts/auto-update-helper.sh` — add a callable function `auto_update_helper_run_once_sync` (or expose `check` to be sourced) that the breaker can invoke synchronously without spawning a separate process. Return code 0 if a new version was deployed, 1 if already current, 2 if update path failed.
- `NEW: .agents/scripts/tests/test-pulse-runner-health-helper.sh` — unit tests for the helper (counter increments, window expiry, pause/resume idempotency, advisory dedup).
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-*.sh` — add at least one integration test that simulates 10 consecutive `no_worker_process` outcomes and asserts the breaker fires.

### Implementation Steps

**1. Define the four zero-attempt signals.** A worker outcome counts as "zero-attempt" if ANY of the following:

- `launch_recovery:no_worker_process` was emitted (worker process never spawned — already a known signal in `worker-lifecycle-common.sh`).
- No git branch was created in the target repo for this issue (the worker dispatched but never opened a workspace).
- Worker token usage at exit was below `ZERO_ATTEMPT_TOKEN_FLOOR` (default 5000 — covers reading the issue body but no implementation work).
- Worker watchdog killed the worker before any commit was authored to the worktree (`worker-activity-watchdog.sh` already tracks this).

A worker outcome that produces a commit, opens a PR, or burns >5000 tokens is a real attempt — even if it failed, the failure is brief/tier/codebase, not version skew. Do NOT count those.

**2. State file shape (`~/.aidevops/cache/runner-health.json`):**

```json
{
  "version": 1,
  "self_login": "marcusquinn",
  "consecutive_zero_attempts": 0,
  "window_started_at": "2026-04-26T00:00:00Z",
  "last_outcomes": [
    {"issue": "owner/repo#NNN", "signal": "no_worker_process", "ts": "..."}
  ],
  "circuit_breaker": {
    "state": "closed",
    "tripped_at": null,
    "last_update_attempt_at": null,
    "last_update_outcome": null
  }
}
```

Cap `last_outcomes` at 20 entries (rolling). The `consecutive_zero_attempts` counter resets on the first non-zero-attempt outcome (worker that produced any real attempt).

**3. Threshold and window (defaults — make env-overridable):**

- `RUNNER_HEALTH_FAILURE_THRESHOLD=10` (consecutive zero-attempts to trip)
- `RUNNER_HEALTH_WINDOW_HOURS=6` (counter resets if oldest counted outcome older than this)
- `RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE=true` (auto-resume if update changed VERSION)
- `RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS=24` (after a fruitless update, stay paused this long before a human-prompted retry)

**4. Pause-cycle behaviour.** When `is-paused` returns true:
- `pulse-wrapper.sh` logs ONE line per cycle (`pulse: dispatch paused — runner-health breaker tripped at <ts>, last update <ts>, see <advisory-path>`) and returns from the cycle without evaluating any issue.
- Other pulse stages (cleanup, merge, scan-stale) STILL run — only dispatch is paused. The runner remains useful for housekeeping.
- Cross-runner: peers see no `DISPATCH_CLAIM` from this runner, so they take over naturally. No active signalling needed.

**5. Advisory dedup.** Posting an advisory for every cycle while paused is noise. Use a stamp file (`~/.aidevops/cache/runner-health-advisory.stamp`) — only post a new advisory when (a) the breaker first trips, (b) `aidevops update` outcome changes, or (c) >24h since last advisory.

**6. Resume paths:**
- Auto-resume: `aidevops update` returned exit 0 (new version deployed) AND t2579 restart-pulse fired. The next pulse cycle starts fresh, sees `circuit_breaker.state=closed` (set during update success), proceeds normally.
- Manual resume: `pulse-runner-health-helper.sh resume --reason "fixed manually"` clears the breaker. Logged in stats and advisory.
- Peer takeover: explicit out-of-scope for this task — stays paused until manual resume.

### Complexity Impact

- **Target function:** `pulse-wrapper.sh` main cycle loop (need to identify exact name during implementation — likely `_run_pulse_cycle` or similar).
- **Estimated growth:** +15-25 lines (3 hook calls, 2 if-branches around them).
- **Action required:** Watch — the additions are lean (delegation to the new helper). If the wrapping function is already near 80 lines, extract the breaker-check block into a helper (`_check_runner_health_breaker`) per the t2803 pattern.

### Verification

```bash
# Unit tests
.agents/scripts/tests/test-pulse-runner-health-helper.sh

# Integration test
.agents/scripts/tests/test-pulse-wrapper-runner-health.sh

# Manual smoke test (dry-run mode):
PULSE_DRY_RUN=1 RUNNER_HEALTH_FAILURE_THRESHOLD=2 ./pulse-wrapper.sh
# Then simulate two no_worker_process outcomes:
pulse-runner-health-helper.sh record-outcome no_worker_process owner/repo#1
pulse-runner-health-helper.sh record-outcome no_worker_process owner/repo#2
pulse-runner-health-helper.sh status
# Expect: state=tripped, advisory-path printed.

# Lint
shellcheck .agents/scripts/pulse-runner-health-helper.sh
markdownlint-cli2 todo/tasks/t2897-brief.md
```

### Files Scope

- `.agents/scripts/pulse-runner-health-helper.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/auto-update-helper.sh`
- `.agents/scripts/tests/test-pulse-runner-health-helper.sh`
- `.agents/scripts/tests/test-pulse-wrapper-runner-health.sh`
- `todo/tasks/t2897-brief.md`
- `TODO.md`

## Acceptance Criteria

- [ ] `pulse-runner-health-helper.sh` exists with `record-outcome`, `is-paused`, `pause`, `resume`, `status` subcommands. ShellCheck clean.
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/pulse-runner-health-helper.sh && shellcheck .agents/scripts/pulse-runner-health-helper.sh"
  ```
- [ ] Unit tests cover counter increment, counter reset on real-attempt, window expiry, pause idempotency, advisory dedup. All pass.
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-pulse-runner-health-helper.sh"
  ```
- [ ] `pulse-wrapper.sh` calls the breaker check before dispatch evaluation. Verified by integration test that simulates a tripped breaker and asserts no DISPATCH_CLAIM is posted.
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-pulse-wrapper-runner-health.sh"
  ```
- [ ] Tripping the breaker calls `aidevops update` once, NOT once per cycle. Verified by counting update invocations across 5 simulated post-trip cycles.
- [ ] `pulse-stats.json` writer includes a `runner_health` block with the current state, last outcome timestamps, and counter.
  ```yaml
  verify:
    method: codebase
    pattern: "runner_health"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Advisory dedup: 5 simulated cycles after trip produce exactly 1 advisory file.
- [ ] When `aidevops update` returns "no change" after a trip, the breaker stays open for `RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS` and posts an advisory naming the runner as degraded with manual-investigation hint.

## Context & Decisions

- **Pulse-internal SHA pull rejected.** A pulse cycle pulling and re-deploying its own code mid-cycle is the canonical t2821 tautology trap. Calling the existing `aidevops update` mechanism (which runs out-of-process, completes, and triggers the t2579 restart hook) is safe because the running pulse process exits naturally; the next cycle gets fresh code.
- **"Zero attempt" vs "any failure".** Maintainer correction: counting all failures conflates real bugs (brief/tier issues) with version skew. Only zero-attempt dispatches are evidence of broken local install — they're the signal we want.
- **Per-runner not per-issue.** The pulse already has per-issue stuck detection (t2008) and per-tier token budgets (t2007). What's missing is "this RUNNER is the problem, not the issues." Per-runner state is the new dimension.
- **No peer-runner active signalling.** Tempting to have the runner post "I'm degraded, please take over my issues" comments. Rejected — the existing `DISPATCH_CLAIM_MIN_VERSION` + assignee dedup already handles peer takeover passively. Adding active signalling would create a new coordination protocol and surface area.
- **Threshold of 10 / window of 6h.** Chosen to be slow enough that intermittent flakes don't trip it, fast enough that a genuinely broken runner doesn't burn a full 24h of workers. Tunable via env var.

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh` — main cycle, dispatch evaluation, stats writer.
- `.agents/scripts/auto-update-helper.sh:430-509` — `_cmd_check_stale_agent_redeploy` for the deploy/SHA drift handling pattern.
- `.agents/scripts/dispatch-claim-helper.sh:55-110` — claim-state file conventions, ISO-8601 timestamps, version field handling.
- `.agents/scripts/worker-lifecycle-common.sh` — where worker outcomes are reported. Hook point for `record-outcome`.
- `.agents/scripts/worker-activity-watchdog.sh` — watchdog kill signal. Source for the "killed before first commit" zero-attempt signal.
- `.agents/reference/cross-runner-coordination.md:268-292` — §4.4 documents this exact failure mode by name. Reference for design rationale.
- `.agents/configs/self-hosting-files.conf` — confirms pulse-wrapper.sh is dispatch-path; drives the `no-auto-dispatch` + `origin:interactive` classification.

## Dependencies

- **Blocked by:** none.
- **Blocks:** t2898 (auto-update daemon health verifier) is a peer; either can land first. Together they close the gap.
- **External:** none.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | pulse-wrapper.sh main cycle, worker-lifecycle-common.sh outcome reporting, auto-update-helper.sh entry points. |
| Implementation | 3h | New helper (~250 lines), three pulse-wrapper hook integrations, stats writer extension. |
| Testing | 1.5h | Unit tests (~150 lines), integration test (~80 lines). |
| **Total** | **~5h** | Tier:thinking warranted by design surface and dispatch-path classification. |
