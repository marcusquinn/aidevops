---
id: "m-20260710-11431d"
title: "Optimise multi-repository linting resource use"
status: completed
mode: full
repo: "aidevops"
created: "2026-07-10"
started: "2026-07-10T03:55:55Z"
completed: "2026-07-10T16:02:50Z"

budget:
  time_hours: 4
  money_usd: 100
  token_limit: 0
  alert_threshold_pct: 80

model_routing:
  orchestrator: thinking
  workers: standard
  research: economy
  validation: standard

preferences:
  tech_stack: [bash, shellcheck, node, eslint, turbo, pnpm]
  deploy_target: "existing local environments and existing CI"
  test_framework: "repository-native focused tests and bounded benchmarks"
  ci_provider: "existing providers only"
  coding_style: "follow each target repository's AGENTS.md; preserve privacy aliases in public artefacts"
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Optimise multi-repository linting resource use

> Produce evidence-backed, independently revertible linting improvements that reduce runaway CPU or memory risk without reducing security or quality coverage.

## Origin

- **Created:** 2026-07-10
- **Created by:** Marcus Quinn and AI DevOps
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Context:** The user reported occasions where linting appeared to saturate CPU before laptop crashes or reboots and requested a privacy-first review of the framework plus two locally available target repositories.

## Scope

**Goal:** Establish whether lint execution correlates with the reported instability, bound future runs safely, and retain only changes that preserve coverage while materially improving speed, peak memory, process count, or duplicate traversal.

**Success criteria:**

- Recent session and system evidence is summarised locally without publishing raw logs, sensitive paths, repository names, or source content.
- Resource-intensive benchmarks are serialized, bounded by timeout, and terminate their complete process tree.
- Each target has a before/after coverage boundary, with an explicit unavailable baseline when no executable boundary existed, plus a resource decision classified as accepted, rejected, or inconclusive.
- Security and quality coverage remains unchanged; timeouts never become false success.
- Accepted changes are delivered incrementally with independent rollback instructions.

**Mode:** full

**Non-goals:**

- Do not deliberately reproduce a crash or continue the same route after thermal, memory, timeout, or instability signals; preserve the objective and resume through a safer route.
- Do not weaken secret scanning, security checks, authoritative full linting, or negative fixtures to gain speed.
- Do not add dependencies, credentials, services, or infrastructure.
- Do not publish private target names, local paths, raw session records, or raw system logs.
- Do not assume cache contention, duplicate traversal, or crash causation without measured evidence.

**Constraints:**

- Four-hour wall-clock budget and moderate cost ceiling of $100; time is the binding constraint.
- Existing/local infrastructure only; local benchmark concurrency starts at 1 and never exceeds 2.
- Suggested bounds: 5 minutes for changed/affected checks, 12 minutes for full checks, and 3 minutes for overlay integration.
- Stop on non-normal thermal pressure, available memory below 15%, swap growth above 1 GiB during a run, timeout, signal termination, orphaned descendants, reboot, or instability.
- Kill the process tree, do not retry an unsafe profile unchanged, preserve the checkpoint and remaining acceptance criteria, and resume through a smaller or prerequisite-complete route.
- Retain an optimisation only with unchanged coverage plus at least one of: 15% lower wall time, 15% lower peak RSS, or 25% fewer duplicate traversals. Other metrics must not regress by more than 10%.

## Milestones

### Milestone 1: Safe evidence baseline

**Status:** done
**Estimate:** ~30m
**Validation:** A privacy-safe evidence matrix and bounded baseline exist; timeout cleanup leaves no descendants; observations are labelled confirmed, correlated, or hypothetical.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | F1 — Establish privacy-safe forensics and bounded measurement controls `[parallel-group:evidence]` | t18071 | done | ~30m | interactive | #26918 |

### Milestone 2: Evidence-backed repository optimisation

**Status:** done
**Estimate:** ~2h10m
**Validation:** Every target has a defined before/after boundary or an explicit unavailable baseline, unchanged retained coverage, and either a threshold-meeting improvement, safety-only decision, or explicitly rejected hypothesis. Conceptual analysis may parallelise, but benchmark phases remain serialized.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | F2 — Fix changed-file coverage, deduplicate discovery, and harden timeouts `[depends:F1] [parallel-group:repo-audit]` | t18072 | done | ~45m | interactive | #26925 |
| 2.2 | F3 — Bound Target B lint execution profiles `[depends:F1] [parallel-group:repo-audit]` | t18073 | done | ~55m | interactive | target-local |
| 2.3 | F4 — Validate Target C integration without duplicate broad linting `[depends:F1] [parallel-group:repo-audit]` | t18074 | done | ~30m | interactive | target-local |

### Milestone 3: Polish, docs, and deploy

**Status:** done
**Estimate:** ~1h20m maximum
**Validation:** Tier-selected changes deploy sequentially, focused checks and terminal CI pass, retained changes meet the measurement contract, and each target can be rolled back independently.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 3.1 | F5 — Apply evidence-gated Target B cache or traversal optimisation `[depends:F3] [parallel-group:conditional-polish]` | t18075 | done-falsified | ~30m | interactive | none |
| 3.2 | F6 — Consolidate proven duplicate framework CI work `[depends:F2] [parallel-group:conditional-polish]` | t18076 | done-falsified | ~30m | interactive | none |
| 3.3 | F7 — Publish evidence, rollback guidance, and staged rollout `[depends:F2] [depends:F3] [depends:F4]` | t18077 | done | ~20m | interactive | this change |

## Budget Tiers

- **Tier 1 — guaranteed:** F1-F4 and F7, approximately 3h plus 1h contingency.
- **Tier 2 — likely:** Add F5 if Target B contention or repeated traversal is measured.
- **Tier 3 — conditional:** Add F6 only when F2 proves a remaining CI job is semantically duplicate; no such duplicate was proven.

## Resources

| Name | Type | Purpose | Status | Notes |
|------|------|---------|--------|-------|
| Existing local repositories | infrastructure | Static inspection and bounded profiling | configured | Public artefacts use Target B and Target C aliases |
| Existing CI | infrastructure | Terminal verification after each retained change | configured | Pending checks are not failures |
| OpenCode session history | dependency | Correlation evidence | local-only | Summaries only; raw records remain local |
| macOS diagnostics | dependency | Thermal, memory, shutdown, and process evidence | local-only | No raw log publication |

## Budget Tracking

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | 4h | 12h | 0h | 300% |
| Money (USD) | $100 | $0 | $100 | 0% |
| Tokens | unlimited within cost cap | tracked | n/a | n/a |

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| 2026-07-10 | time | planning | Interview, inventory, budget analysis, and decomposition | 1 |
| 2026-07-10 | time | 2.5h | F1 evidence/profiler and F2 changed-mode implementation | 1-2 |
| 2026-07-10 | time | 9.5h | Cross-target recovery, implementation, terminal CI, and publication | 2-3 |

## Decision Log

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | 2026-07-10 | Use Full mode and incremental per-target changes | Cross-repository quality infrastructure needs reviewable, independently revertible evidence | POC; coordinated redesign |
| 2 | 2026-07-10 | Preserve private targets as Target B and Target C in public artefacts | The user explicitly prioritised privacy and public planning files must not reveal private repository details | Persist real names and paths |
| 3 | 2026-07-10 | Treat crash attribution as unproven until corroborated | Stale logs or high CPU observations alone do not establish causation | Assume lint caused the reboots |
| 4 | 2026-07-10 | Serialize benchmarks and start concurrency at 1 | Parallel profiling could recreate the resource pressure under investigation | Run repository benchmarks concurrently |
| 5 | 2026-07-10 | Fall back from Opus decomposition to the local planning specialist | Anthropic authentication was unavailable and the mission forbids adding credentials | Block planning; request credentials |
| 6 | 2026-07-10 | Accept one prepared changed inventory and fail broad timeouts closed | Repeated per-gate Git discovery fell to zero after preparation, untracked coverage expanded, and status 124 can no longer become success | Keep repeated discovery and advisory timeout success |
| 7 | 2026-07-10 | Stop the Target B affected route after exit 137 without repeating it | The resource fuse made that route incomplete and unsafe to retry unchanged, but did not cancel the objective | Retry warm; increase to concurrency 2; abandon the objective |
| 8 | 2026-07-10 | Resume Target B through 37 serial package checkpoints and retain a concurrency-1 local guardrail | Every shard and the unchanged full task graph completed; the guardrail is not presented as a performance improvement against an incomplete baseline | Keep local default 4; claim a comparison against the terminated run |
| 9 | 2026-07-10 | Reuse canonical downstream lint for Target C | Positive, invalid, and stalled fixtures closed the validation gap without creating another broad pipeline | Add an independent broad linter; retain no executable validation |
| 10 | 2026-07-10 | Close F5 and F6 as falsified conditional premises | No Target B cache/traversal hotspot or remaining framework CI duplicate met the evidence gates | Speculative cache redesign; remove intentionally independent CI gates |

## Mission Agents

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| interactive | Cross-repository orchestration, recovery, and verification | session-local | no |

## Research

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| Initial framework inventory | Changed/full modes, caching, strict broad gates, modular gates, and ratchet timeouts already exist; duplicate discovery remains a measurement hypothesis. | Local static inspection | 2026-07-10 |
| Confirmed changed-file coverage gap | An unstaged changed-mode run scanned 1 tracked file, while the same work represented in a temporary index scanned all 9 intended files. Untracked non-ignored files are omitted before staging, including from secret scanning. | Two bounded local validation runs | 2026-07-10 |
| Initial Target B inventory | Existing affected mode, explicit concurrency defaults, lint/format caches, and changed-file grouping must be preserved and measured rather than replaced by assumption. | Local static inspection; details redacted | 2026-07-10 |
| Initial Target C inventory | Overlay integration currently has no broad duplicate lint pipeline; bounded downstream validation is preferred unless evidence shows a gap. | Local static inspection; details redacted | 2026-07-10 |
| F1 safe baseline | Kernel zone-map exhaustion is confirmed while lint causation remains unproven; serialized profiler and cleanup controls passed. | `research/resource-baseline.md` | 2026-07-10 |
| F2 framework result | Changed mode includes untracked non-ignored files, removes repeated per-gate discovery, invalidates cache on content, and fails timeouts closed. | `research/framework-changed-mode.md` | 2026-07-10 |
| F3 Target B initial route | A fixed 37-task graph exited 137 at concurrency 1 after 45 seconds and 5,593,600 KiB aggregate peak RSS; the route stopped and the objective remained open for recovery. | `research/target-b-resource-evidence.md` | 2026-07-10 |
| F3 Target B recovery | All 37 package lint shards passed serially; the unchanged full graph supported a concurrency-1 local safety default while performance effect remained inconclusive. | `research/target-b-resource-evidence.md` | 2026-07-10 |
| F4 Target C result | Bounded canonical downstream lint passed 196 changed source files; invalid and stalled fixtures failed closed without a duplicate broad pipeline. | `research/target-c-integration-evidence.md` | 2026-07-10 |
| Final synthesis | Three independent retained changes passed focused and terminal verification; conditional F5/F6 premises were falsified. | `research/final-report.md` | 2026-07-10 |

## Progress Log

| Timestamp | Event | Details |
|-----------|-------|---------|
| 2026-07-10T00:00:00Z | Mission created | Approved Full-mode, four-hour, privacy-first lint resource optimisation mission. |
| 2026-07-10T03:55:55Z | Mission launched | Activated F1 as the only unblocked feature and created issue #26914; F2-F4 remain blocked on its safe baseline. |
| 2026-07-10T04:34:23Z | F1 entered review | Confirmed a kernel zone-map exhaustion panic while keeping lint causation unproven; bounded profiler, cleanup fixtures, and aggregate evidence passed locally in PR #26918. |
| 2026-07-10T05:15:51Z | F1 completed | PR #26918 merged with all required checks passing and closed issue #26914. |
| 2026-07-10T05:25:35Z | F2 broad profile passed | Expanded changed coverage completed in 19s with 115.3 MiB peak RSS, zero swap, normal thermal state, and no safety stop. |
| 2026-07-10T05:30:33Z | F2 entered review | PR #26925 opened with expanded untracked coverage, zero repeated per-gate discovery scans, and fail-closed timeout semantics. |
| 2026-07-10T10:01:32Z | F3 stopped safely | The valid Target B concurrency-1 profile exited 137 after 45 seconds; concurrency 2 and retries were skipped, and no target configuration changed. |
| 2026-07-10T14:57:22Z | Safety recovery contract implemented | A resource or timeout fuse was formalised as a recoverability checkpoint that preserves the objective and remaining acceptance criteria. |
| 2026-07-10T15:22:00Z | F3 recovered | All 37 Target B lint-package shards passed serially, the complete task digest remained unchanged, and a concurrency-1 local guardrail entered terminal CI. |
| 2026-07-10T15:25:38Z | F4 completed | Target C bounded positive, invalid, and stalled validation merged after terminal checks. |
| 2026-07-10T15:51:00Z | F3 completed | Target B local guardrail merged after terminal lint, format, typecheck, test, security, and review checks. |
| 2026-07-10T16:02:50Z | Mission completed | F5 and F6 were re-evaluated and falsified on evidence; F7 published redacted metrics, rollback, reusable guidance, and passed bounded changed-mode verification. |

## Retrospective

- **Outcomes:** Framework changed mode now covers untracked files and performs zero repeated per-gate discovery; Target B defaults local lint to concurrency 1 with unchanged task coverage; Target C has bounded canonical downstream validation with positive and fail-closed fixtures.
- **Lessons learned:** A killed aggregate route may conceal independently completable shards. Coverage digests and package checkpoints separate unsafe execution shape from the user objective. Similar CI jobs must be mapped to platform and trust-boundary purposes before calling them duplicates.
- **Framework improvements:** Added a general safety-stop recovery contract and reusable linter resource guidance. Generic nested sandbox process-group cleanup remains a separate follow-up because this mission hardened only the profiler and target validator boundaries.

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | 4h | 12h | +8h |
| Money | $100 | $0 | -$100 |
| Tokens | cost-capped | within cap | n/a |

### Skill Learning

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| Bounded linter profiling and recovery | reference | 5/5 | `.agents/reference/linter-resource-safety.md` | Promoted after three repository boundaries and multiple safety-stop recoveries |
