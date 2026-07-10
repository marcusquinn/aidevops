---
id: "m-20260710-11431d"
title: "Optimise multi-repository linting resource use"
status: active
mode: full
repo: "aidevops"
created: "2026-07-10"
started: "2026-07-10T03:55:55Z"
completed: ""

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
- Each target has a before/after coverage digest and resource decision classified as accepted, rejected, or inconclusive.
- Security and quality coverage remains unchanged; timeouts never become false success.
- Accepted changes are delivered incrementally with independent rollback instructions.

**Mode:** full

**Non-goals:**

- Do not deliberately reproduce a crash or continue after thermal, memory, timeout, or instability signals.
- Do not weaken secret scanning, security checks, authoritative full linting, or negative fixtures to gain speed.
- Do not add dependencies, credentials, services, or infrastructure.
- Do not publish private target names, local paths, raw session records, or raw system logs.
- Do not assume cache contention, duplicate traversal, or crash causation without measured evidence.

**Constraints:**

- Four-hour wall-clock budget and moderate cost ceiling of $100; time is the binding constraint.
- Existing/local infrastructure only; local benchmark concurrency starts at 1 and never exceeds 2.
- Suggested bounds: 5 minutes for changed/affected checks, 12 minutes for full checks, and 3 minutes for overlay integration.
- Stop on non-normal thermal pressure, available memory below 15%, swap growth above 1 GiB during a run, timeout, signal termination, orphaned descendants, reboot, or instability.
- Kill the process tree, do not retry an unsafe profile, roll back the candidate, and classify the result as inconclusive.
- Retain an optimisation only with unchanged coverage plus at least one of: 15% lower wall time, 15% lower peak RSS, or 25% fewer duplicate traversals. Other metrics must not regress by more than 10%.

## Milestones

### Milestone 1: Safe evidence baseline

**Status:** active
**Estimate:** ~30m
**Validation:** A privacy-safe evidence matrix and bounded baseline exist; timeout cleanup leaves no descendants; observations are labelled confirmed, correlated, or hypothetical.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | F1 — Establish privacy-safe forensics and bounded measurement controls `[parallel-group:evidence]` | t18071 | active | ~30m | interactive | |

### Milestone 2: Evidence-backed repository optimisation

**Status:** pending
**Estimate:** ~2h10m
**Validation:** Every target has comparable before/after evidence, unchanged coverage, and either a threshold-meeting improvement or an explicitly rejected or rolled-back hypothesis. Conceptual analysis may parallelise, but benchmark phases remain serialized.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | F2 — Fix changed-file coverage, deduplicate discovery, and harden timeouts `[depends:F1] [parallel-group:repo-audit]` | t18072 | pending | ~45m | | |
| 2.2 | F3 — Bound Target B lint execution profiles `[depends:F1] [parallel-group:repo-audit]` | t18073 | pending | ~55m | | |
| 2.3 | F4 — Validate Target C integration without duplicate broad linting `[depends:F1] [parallel-group:repo-audit]` | t18074 | pending | ~30m | | |

### Milestone 3: Polish, docs, and deploy

**Status:** pending
**Estimate:** ~1h20m maximum
**Validation:** Tier-selected changes deploy sequentially, focused checks and terminal CI pass, retained changes meet the measurement contract, and each target can be rolled back independently.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 3.1 | F5 — Apply evidence-gated Target B cache or traversal optimisation `[depends:F3] [parallel-group:conditional-polish]` | t18075 | pending | ~30m | | |
| 3.2 | F6 — Consolidate proven duplicate framework CI work `[depends:F2] [parallel-group:conditional-polish]` | t18076 | pending | ~30m | | |
| 3.3 | F7 — Publish evidence, rollback guidance, and staged rollout `[depends:F2] [depends:F3] [depends:F4]` | t18077 | pending | ~20m | | |

## Budget Tiers

- **Tier 1 — guaranteed:** F1-F4 and F7, approximately 3h plus 1h contingency.
- **Tier 2 — likely:** Add F5 if Target B contention or repeated traversal is measured.
- **Tier 3 — stretch:** Add F6 only if elapsed time after F5 is below 3h10m and no safety trigger has fired.

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
| Time (hours) | 4h | 0h | 4h | 0% |
| Money (USD) | $100 | $0 | $100 | 0% |
| Tokens | unlimited within cost cap | tracked | n/a | 0% |

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| 2026-07-10 | time | planning | Interview, inventory, budget analysis, and decomposition | 1 |

## Decision Log

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | 2026-07-10 | Use Full mode and incremental per-target changes | Cross-repository quality infrastructure needs reviewable, independently revertible evidence | POC; coordinated redesign |
| 2 | 2026-07-10 | Preserve private targets as Target B and Target C in public artefacts | The user explicitly prioritised privacy and public planning files must not reveal private repository details | Persist real names and paths |
| 3 | 2026-07-10 | Treat crash attribution as unproven until corroborated | Stale logs or high CPU observations alone do not establish causation | Assume lint caused the reboots |
| 4 | 2026-07-10 | Serialize benchmarks and start concurrency at 1 | Parallel profiling could recreate the resource pressure under investigation | Run repository benchmarks concurrently |
| 5 | 2026-07-10 | Fall back from Opus decomposition to the local planning specialist | Anthropic authentication was unavailable and the mission forbids adding credentials | Block planning; request credentials |

## Mission Agents

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | | pending |

## Research

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| Initial framework inventory | Changed/full modes, caching, strict broad gates, modular gates, and ratchet timeouts already exist; duplicate discovery remains a measurement hypothesis. | Local static inspection | 2026-07-10 |
| Confirmed changed-file coverage gap | An unstaged changed-mode run scanned 1 tracked file, while the same work represented in a temporary index scanned all 9 intended files. Untracked non-ignored files are omitted before staging, including from secret scanning. | Two bounded local validation runs | 2026-07-10 |
| Initial Target B inventory | Existing affected mode, explicit concurrency defaults, lint/format caches, and changed-file grouping must be preserved and measured rather than replaced by assumption. | Local static inspection; details redacted | 2026-07-10 |
| Initial Target C inventory | Overlay integration currently has no broad duplicate lint pipeline; bounded downstream validation is preferred unless evidence shows a gap. | Local static inspection; details redacted | 2026-07-10 |

## Progress Log

| Timestamp | Event | Details |
|-----------|-------|---------|
| 2026-07-10T00:00:00Z | Mission created | Approved Full-mode, four-hour, privacy-first lint resource optimisation mission. |
| 2026-07-10T03:55:55Z | Mission launched | Activated F1 as the only unblocked feature and created issue #26914; F2-F4 remain blocked on its safe baseline. |

## Retrospective

_Completed after mission finishes._

- **Outcomes:** pending
- **Lessons learned:** pending
- **Framework improvements:** pending

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | 4h | | |
| Money | $100 | | |
| Tokens | cost-capped | | |

### Skill Learning

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |
