<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18139: Pulse 2 repository campaigns and swarm-aware execution

## Pre-flight

- [x] Memory recall: `Pulse 2 campaigns semantic compaction swarm` → 0 hits — no relevant retained lessons.
- [x] Discovery pass: 1 recent commit / 0 related merged PRs / 0 related open PRs touched the target surface; `b90d4c079` changed dispatch recovery already present at HEAD and does not implement campaigns.
- [x] File refs verified: 12 references checked, all existing paths present at HEAD; new-file parent directories verified.
- [x] Tier: `tier:thinking` — novel orchestration design spans shell, JavaScript, plugin, state projection, tests, and operator documentation.
- [x] Seeded draft PR decision recorded: skipped — this issue-started interactive session owns implementation and must verify the design before opening its final draft PR.

## Origin

- **Created:** 2026-07-16
- **Session:** OpenCode interactive session for GH#27939
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none; this is a leaf implementation issue.
- **Blocked by:** none.
- **Conversation context:** The user requested a first production-ready Pulse 2 slice and explicitly authorized full-loop merge, patch release, and incremental deployment after all gates pass.

## What

Add an opt-in repository-campaign projection above the existing deterministic Pulse dispatcher. Each Pulse-enabled repository gets one renewable local campaign checkpoint built from a complete open-issue snapshot and the exact legacy-ready candidate set. The checkpoint must expose an oldest-ready frontier (default 10), semantic categories, composite runner/device identities, fitness-aware non-overlapping lanes, and bounded historical evidence. OpenCode compaction restores the matching repository campaign as historical operational data. The legacy dispatcher remains authoritative in shadow mode and is the unconditional fallback.

## Why

Pulse currently ranks individual issues across repositories but has no durable repository-level view of the rolling objective, completed evidence, newly discovered work, blocked work, or multi-device capacity. Context compaction and same-login runners can therefore lose planning continuity or conflate independent devices. A rebuildable shadow projection provides campaign continuity and measurable swarm planning without weakening GitHub claims, trust gates, or established dispatch behavior.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** More than four files and a new compatibility pattern are required. The implementation must coordinate source completeness, atomic checkpoint renewal, mixed-version rollback, prompt-injection-safe compaction, and multi-runner lane allocation.

## PR Conventions

This is a leaf issue. The final PR uses `Resolves #27939`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The primary interactive session is implementing directly; opening a seed before focused tests would create an unverified anchor.
- **Status:** `not-created`
- **Freshness evidence:** Memory, duplicate, recent-commit, open-PR, and file-reference discovery completed against current `origin/main`.
- **Verification run:** Pre-edit and discovery checks only; implementation tests are not yet run.
- **Stale-assumption warning:** Recheck the candidate-builder call and compaction path after any rebase touching the target files.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-repo-meta.sh:220-361`, `.agents/scripts/pulse-dispatch-engine.sh:282-425`, and `.agents/plugins/opencode-aidevops/compaction.mjs:146-261` — these define the snapshot, dispatch, and compaction boundaries.
- **Load only if:** `.agents/reference/cross-runner-coordination.md:545-699` when claim/override behavior is changed; `.agents/reference/task-coordinator-architecture.md:182-199,265-289` when canonical-state ownership is unclear.
- **Why:** Campaign state must remain a derived local projection; GitHub/git and fenced claim evidence remain canonical.
- **Stop when:** the exact legacy-ready set, repository scope key, checkpoint contract, and fallback path are identified.

### Worker Quick-Start

```bash
# Existing deterministic candidate source and ordering:
rg -n 'list_dispatchable_issue_candidates_json|build_ranked_dispatch_candidates_json' .agents/scripts/pulse-repo-meta.sh .agents/scripts/pulse-dispatch-engine.sh

# Existing stable device identity and peer observations:
rg -n '_resolve_device_id|device=|discover_and_observe|_apply_hysteresis' .agents/scripts/dispatch-claim-helper.sh .agents/scripts/peer-productivity-monitor.sh

# Existing repo-scoped compaction pattern:
rg -n 'getScopedCheckpointPath|getCheckpointState|compactingHook' .agents/plugins/opencode-aidevops/compaction.mjs
```

### Files to Modify

- `NEW: .agents/scripts/pulse-campaign-coordinator.mjs` — validate snapshots, build deterministic campaign projections, renew atomic checkpoints, and allocate composite runner/device lanes.
- `NEW: .agents/scripts/pulse-campaign-shadow.sh` — default-off Pulse adapter that gathers inputs, invokes the coordinator, records diagnostics, and always returns legacy candidates.
- `EDIT: .agents/scripts/pulse-repo-meta.sh:220-361` — optionally persist the exact raw open-issue snapshot used to derive candidates without adding another GitHub query.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh:37-135,349-425` — source the adapter and route candidate collection through it without changing returned ordering.
- `EDIT: .agents/scripts/pulse-wrapper-config.sh:165-300` — define and validate the shadow gate, frontier horizon, and checkpoint TTL defaults.
- `EDIT: .agents/scripts/peer-productivity-monitor.sh:163-294,488-547` — retain per-repository observation metrics as bounded fitness inputs while preserving existing honour/ignore behavior.
- `EDIT: .agents/plugins/opencode-aidevops/compaction.mjs:146-261` — inject only the matching repository campaign checkpoint, render bounded semantic categories, and label all issue-derived text as untrusted historical data.
- `NEW: .agents/scripts/tests/test-pulse-campaign-coordinator.mjs` — pure/CLI campaign, compaction, renewal, truncation, and lane fixtures.
- `NEW: .agents/scripts/tests/test-pulse-campaign-shadow.sh` — default-off, no-order-change, failure-fallback, and raw-snapshot wiring coverage.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-compaction-checkpoint-scope.mjs:1-82` — campaign scope, malformed/stale checkpoint, and injection-boundary coverage.
- `EDIT: tests/test-peer-productivity-monitor.sh:1-535` — per-repository fitness persistence regression coverage.
- `NEW: .agents/reference/repository-campaigns.md` — checkpoint contract, enabling, diagnostics, canonical authority, mixed-version behavior, and rollback.
- `EDIT: README.md` — add a concise operator-facing pointer for the new default-off capability.

### Complete Write Surface

- **Callers/readers:** `pulse-dispatch-engine.sh` reads candidate output; `pulse-campaign-shadow.sh` calls the new coordinator; `compaction.mjs` reads repository-scoped checkpoints; operators read the reference and Pulse logs.
- **Writers/mutation paths:** only `pulse-campaign-coordinator.mjs` writes campaign checkpoints under `${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/repository-campaigns/`; `peer-productivity-monitor.sh` continues atomically writing its existing private state file.
- **Tests/fixtures:** `.agents/scripts/tests/test-pulse-campaign-coordinator.mjs`, `.agents/scripts/tests/test-pulse-campaign-shadow.sh`, the compaction scope test, and `tests/test-peer-productivity-monitor.sh` cover the new behavior; existing Pulse worker-detection ordering fixtures remain unchanged.
- **Schemas/config:** campaign checkpoint schema v1; existing `repos.json` may optionally provide `pulse_campaign.runners`; environment defaults are validated by `pulse-wrapper-config.sh`.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/scripts/` and the OpenCode plugin incrementally after release; no generated source is committed.
- **Migrations/backfills:** N/A because campaign checkpoints are disposable local projections; missing, malformed, foreign, or old checkpoints are ignored and rebuilt from GitHub on the next enabled shadow cycle.
- **Cleanup/rollback paths:** disabling `AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED` immediately restores the pre-feature path; checkpoint deletion is safe because projections are rebuildable.

### Implementation Steps

1. Implement a pure campaign builder with strict input bounds. Use the exact filtered-ready set for eligibility, sort oldest by `createdAt` then issue number, and select the first `horizon` entries. Store `frontier`, `completedEvidence`, `discoveries`, `active`, `blocked`, and `remaining` separately.
2. Derive a private scope key from the repository Git common directory, not its public/private slug or worktree path. Write schema-v1 JSON with generation, `generatedAt`, `renewAfter`, `expiresAt`, source hash/completeness, and explicit `canonicalAuthority: github+git` using temp-file plus rename and mode `0600`.
3. Normalize runner identity as `(lowercase login, stable device_id)`. Merge explicit per-repository runners, local device/ledger evidence, and peer-monitor observations. Keep same-login devices distinct, clamp fitness/capacity, and assign each frontier issue to at most one lane. Claims remain authoritative and are never created or released by the planner.
4. Add a shell shadow adapter. When disabled, call the legacy candidate function directly with no checkpoint or extra API work. When enabled, capture the raw snapshot and exact candidates, invoke the coordinator, log a bounded comparison, ignore planner output for dispatch ordering, and return legacy candidates even on timeout/error.
5. Extend peer state additively with per-repository counts/fitness. Do not change established vote/hysteresis or generated override semantics.
6. Extend compaction to locate the campaign checkpoint by the same Git-common-dir scope, validate schema/scope/size, and render bounded semantic categories. Treat strings from issue/peer inputs as untrusted historical data, never active instructions.
7. Document the opt-in gate, horizon 10, checkpoint location/permissions, diagnostics, canonical authority, rollback, and limitations. Run focused tests, make a WIP commit, then run changed-file quality gates.

### Hazards and Compatibility

- **Concurrency/atomicity:** concurrent Pulse cycles may target one checkpoint; write complete JSON to a private sibling temp file and atomically rename. A reader must observe either the old complete generation or the new complete generation.
- **Migration/rollback:** checkpoint schema is local and rebuildable. Unsupported versions fail open to legacy dispatch and are rebuilt only while shadow is enabled; disabling the flag performs instant rollback.
- **Mixed-version/backward compatibility:** old runners ignore checkpoints. New runners honor existing GitHub claims and existing peer overrides. No issue labels, comments, assignments, PRs, or candidate order change in this slice.
- **Idempotency/retry:** fixed input plus fixed time yields the same frontier/lanes/source hash. Repeated cycles only advance generation and renewal timestamps. Failed writes leave the prior generation intact.
- **Partial failure/recovery:** snapshot, peer-state, coordinator, and checkpoint errors are diagnostic-only; the exact legacy candidate JSON is returned. Truncated snapshots are marked incomplete and cannot be described as a complete frontier.

### Complexity Impact

- **Target function:** `build_ranked_dispatch_candidates_json` in `.agents/scripts/pulse-dispatch-engine.sh`
- **Current line count:** 78 lines (threshold: 100 lines)
- **Estimated growth:** +3 lines by routing through an extracted adapter
- **Projected post-change:** 81 lines (81% of threshold)
- **Action required:** Keep all campaign logic in `pulse-campaign-shadow.sh`; do not inline it into the dispatch engine.

### Verification Before Dispatch

```bash
node --test .agents/scripts/tests/test-pulse-campaign-coordinator.mjs
bash .agents/scripts/tests/test-pulse-campaign-shadow.sh
bash .agents/scripts/tests/test-dependency-readiness-normalization.sh
node --test .agents/plugins/opencode-aidevops/tests/test-compaction-checkpoint-scope.mjs
bash tests/test-peer-productivity-monitor.sh
bash .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
shellcheck .agents/scripts/pulse-campaign-shadow.sh .agents/scripts/pulse-repo-meta.sh .agents/scripts/pulse-dispatch-engine.sh .agents/scripts/pulse-wrapper-config.sh .agents/scripts/peer-productivity-monitor.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** coordinator tests cover deterministic frontier, source integrity/freshness, owner-safe locking, retention, renewal, scope, and lanes; shadow tests cover disabled/no-order-change/fallback; dependency-readiness tests cover exact snapshot provenance and normalized field shapes; compaction tests cover semantic restore and injection isolation; peer tests cover additive fitness data; worker-detection tests protect legacy ranking.
- **Baseline exception:** worker-detection has six failures reproduced identically at archived baseline `17c230f57`; the campaign shadow test and standalone Pulse canary pass.
- **Broad verification trigger:** shared Pulse dispatch, runtime plugin, and release deployment surfaces change, so repository preflight/release gates are required after focused tests.
- **Broad verification command:** `.agents/scripts/linters-local.sh --full`

### Recoverability Checkpoint

- [x] Focused tests pass: the first four commands above.
- [x] WIP commit created before broad gates: `wip: add Pulse repository campaign shadow`.
- [x] Independent defect/security review reached `READY` after source-integrity, scope-binding, concurrency-lock, symlink, deterministic-runner, and stale-input remediations.
- [x] Qlty new-file and regression gates pass with zero new smells.
- [x] Evidence-triggered broad verification passes: `.agents/scripts/linters-local.sh --full`; embedded canary timeout `143` is advisory and the standalone canary passes.

### Safety-Stop Recovery

- **Original objective:** Ship the first production-ready Pulse 2 repository campaign, semantic compaction, and swarm-aware execution slice.
- **Preserved user directions:** complete full-loop through merge, patch release, incremental deployment, and cleanup.
- **Trigger and evidence:** not triggered.
- **Completed and verified:** discovery, linked-worktree safety, implementation, focused tests, independent review, Qlty gates, changed-file gates, and broad repository gates through commit `7ecdbf068`.
- **Remaining acceptance criteria:** PR, merge, release, deployment, and cleanup.
- **Unsafe route not to repeat:** none.
- **Next safe route:** open the linked pull request and monitor required review/CI gates.
- **Resume condition:** continue from the latest verified branch commit and full-loop lifecycle state.
- **Owner and status:** primary interactive session; not-triggered.

### Files Scope

- `.agents/scripts/pulse-campaign-coordinator.mjs`
- `.agents/scripts/pulse-campaign-checkpoint.mjs`
- `.agents/scripts/pulse-campaign-history.mjs`
- `.agents/scripts/pulse-campaign-issues.mjs`
- `.agents/scripts/pulse-campaign-planner.mjs`
- `.agents/scripts/pulse-campaign-runners.mjs`
- `.agents/scripts/pulse-campaign-values.mjs`
- `.agents/scripts/pulse-campaign-shadow.sh`
- `.agents/scripts/pulse-repo-meta.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/pulse-wrapper-config.sh`
- `.agents/scripts/peer-productivity-monitor.sh`
- `.agents/scripts/tests/test-pulse-campaign-coordinator.mjs`
- `.agents/scripts/tests/test-pulse-campaign-shadow.sh`
- `.agents/scripts/tests/test-dependency-readiness-normalization.sh`
- `.agents/plugins/opencode-aidevops/compaction.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-compaction-checkpoint-scope.mjs`
- `.agents/reference/repository-campaigns.md`
- `.agents/reference/plist-env-overrides.md`
- `tests/test-peer-productivity-monitor.sh`
- `README.md`
- `todo/tasks/t18139-brief.md`

## Acceptance Criteria

- [x] One enabled shadow cycle creates exactly one schema-v1 campaign checkpoint per Git-common-dir repository scope with a default oldest-ready frontier of 10 and a complete/incomplete source marker.
- [x] Semantic compaction preserves bounded completed evidence, discoveries, active work, blocked work, frontier, and remaining work for the active repository only.
- [x] Two runners sharing one login but carrying different stable device IDs remain distinct and receive non-overlapping lane assignments; zero-fitness/capacity runners receive none.
- [x] With the gate unset/false, or when the planner/checkpoint fails, Pulse returns byte-equivalent legacy candidate JSON and performs no campaign write or additional GitHub query.
- [x] Campaign planning never mutates GitHub issue/claim state and never overrides existing deterministic dedup, trust, merge, release, or authority gates.
- [x] Focused campaign, compaction, peer-monitor, Pulse dispatch, Node, ShellCheck, changed-file, Qlty, and broad repository quality gates pass; the documented worker-detection baseline exception is unchanged.

## Context & Decisions

- GitHub and git remain canonical; campaign checkpoints are private, rebuildable projections.
- This slice is shadow-only and default-off. It measures and preserves planning context but does not reorder or dispatch issues.
- One leaf issue remains one implementation PR. Repository campaigns group planning continuity, not merge/release authority.
- The initial rolling horizon is 10 and selects the complete oldest ready set before existing cross-repository priority scoring.
- Composite `(login, device_id)` identity avoids conflating devices that authenticate as the same GitHub user; GitHub claim fencing remains the safety kernel.
- Repository checkpoint locks are local-filesystem-only, owner-token fenced, and atomically published before serialized renewal.
- The task-coordinator database is not expanded because campaign state is derived and disposable rather than task identity or canonical operation evidence.

## Relevant Files

- `.agents/scripts/pulse-repo-meta.sh:236-328` — exact raw open snapshot and eligibility filter.
- `.agents/scripts/pulse-dispatch-engine.sh:289-425` — deterministic scoring and cross-repository output.
- `.agents/scripts/dispatch-claim-helper.sh:179-195,292-327` — stable device ID and claim marker contract.
- `.agents/scripts/dispatch-lease-claims.jq:1-43` — existing device-aware lease parsing.
- `.agents/scripts/peer-productivity-monitor.sh:163-294,300-392` — repository observations and hysteresis.
- `.agents/plugins/opencode-aidevops/compaction.mjs:231-312` — bounded repository-scoped campaign checkpoint validation and injection.
- `.agents/reference/task-coordinator-architecture.md:182-199,265-289` — canonical authority and derived projection boundary.

## Dependencies

- **Blocked by:** none.
- **Blocks:** future opt-in enforcement, adaptive campaign dispatch, and richer campaign observability.
- **External:** existing local Node, Git, jq, GitHub CLI, and ShellCheck; no new dependency or secret.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Existing Pulse, claims, peer state, compaction, and coordinator contracts |
| Implementation | 3h | Coordinator, adapter, fitness projection, compaction, docs |
| Testing | 1.5h | Focused fixtures, changed-file lint, full-loop gates |
| **Total** | **5h 15m** | Includes release/deployment verification |
