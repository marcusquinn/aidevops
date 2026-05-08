---
id: "m-20260508-0e27c3"
title: "Make awardsapp issue solving converge to green merged PRs"
status: active
mode: full
repo: "/Users/marcusquinn/Git/aidevops"
created: "2026-05-08"
started: "2026-05-08"
completed: ""

budget:
  time_hours: 336
  money_usd: 500
  token_limit: 0
  alert_threshold_pct: 80

model_routing:
  orchestrator: opus
  workers: sonnet
  research: haiku
  validation: sonnet

preferences:
  tech_stack: [bash, github-actions, typescript, turbo, pnpm]
  deploy_target: "aidevops local deployment plus awardsapp GitHub CI"
  test_framework: "ShellCheck, aidevops script tests, awardsapp CI"
  ci_provider: "GitHub Actions"
  coding_style: "Follow aidevops AGENTS.md and awardsapp AGENTS.md per repo"
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Make awardsapp issue solving converge to green merged PRs

> Keep improving aidevops and awardsapp until open awardsapp issues can be solved by workers as green PRs that merge, with duplicate/red PR churn systematically reduced.

## Origin

- **Created:** 2026-05-08
- **Created by:** Marcus Quinn
- **Session:** OpenCode interactive session
- **Context:** After aidevops v3.14.97 restored breaker-held issue retries, awardsapp workers produced useful PRs but many issues still had multiple sibling PRs and red CI. The observed blockers are a mix of aidevops orchestration gaps and awardsapp CI/repo policy gaps.

## Scope

**Goal:** awardsapp open issues should steadily converge to one healthy candidate PR per issue, required checks should distinguish code failures from infrastructure/advisory failures, aidevops should avoid duplicate worker churn, and green approved PRs should merge and close issues with evidence.

**Success criteria:**

- Aidevops classifies CI timeouts/kills and advisory E2E failures distinctly from PR-specific code failures.
- Aidevops suppresses duplicate dispatch when an approved or healthiest PR already exists for the same issue.
- Aidevops can consolidate/supersede sibling PRs against the verified newest/healthiest candidate.
- awardsapp CI exposes required vs advisory outcomes clearly enough for workers and merge automation.
- awardsapp affected lint/typecheck no longer routinely dies by timeout/kill without actionable error output.
- Open awardsapp worker issues trend toward green merged PRs, verified by PR/issue metrics and sampled check evidence.

**Mode:** full

**Non-goals:**

- Do not bypass security checks or merge untrusted code.
- Do not hide genuine PR-specific code failures behind advisory labels.
- Do not force-push or destructively rewrite user work.
- Do not expose private repo/local paths in public GitHub comments.

**Constraints:**

- Use worktree + PR flow for aidevops and awardsapp code changes.
- Release/deploy aidevops changes after merge before relying on them operationally.
- Confirm terminal failed checks before repair feedback; pending CI is not failure.
- Budget: 2 weeks / $500 cap, pause new dispatch if budget reaches 80%.

## Milestones

### Milestone 1: Establish blocker taxonomy and live dashboard

**Status:** active
**Estimate:** ~6h
**Validation:** A repeatable report groups awardsapp open PRs/issues by blocker class: duplicate PR, pending CI, code failure, timeout/kill, advisory E2E, approved merge candidate, needs maintainer/security gate.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | Capture current awardsapp PR/issue blocker inventory and baseline metrics | pending | active | ~1h | interactive | |
| 1.2 | Add or improve aidevops reporting for duplicate PR groups and CI blocker classes | pending | active | ~3h | interactive | |
| 1.3 | Publish mission status summaries with evidence and next recommended action | pending | pending | ~2h | interactive | |

### Milestone 2: Aidevops orchestration fixes

**Status:** pending
**Estimate:** ~18h
**Validation:** aidevops no longer treats known CI infra/advisory failures as worker-code failures, avoids duplicate redispatch where a healthy candidate exists, and can close superseded sibling PRs safely.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | Classify CI timeout/kill results such as 143/124/137 as infra-timeout, not implementation failure | pending | active | ~4h | interactive | |
| 2.2 | Model E2E-only shard failures as advisory/quarantine when repo policy marks core gates green | pending | active | ~4h | interactive | |
| 2.3 | Deduplicate dispatch against existing approved/mergeable sibling PRs for the same issue | pending | pending | ~5h | worker | |
| 2.4 | Add safe superseded-PR consolidation against the newest/healthiest verified candidate | pending | pending | ~5h | worker | |

### Milestone 3: awardsapp CI and repo policy fixes

**Status:** pending
**Estimate:** ~24h
**Validation:** awardsapp PR checks provide actionable failures, affected lint/typecheck complete reliably, and E2E advisory/required policy is explicit in CI summaries and branch protection behaviour.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 3.1 | Split awardsapp required core checks from advisory/quarantined E2E with clear CI summary output | pending | pending | ~8h | worker | |
| 3.2 | Reduce affected turbo lint/typecheck timeout deaths with narrower package/path routing or higher targeted timeout | pending | pending | ~8h | worker | |
| 3.3 | Add CI failure summaries that distinguish code error, timeout, infrastructure, and advisory E2E | pending | pending | ~5h | worker | |
| 3.4 | Document awardsapp worker merge policy for approved PRs with core gates green and advisory E2E red | pending | pending | ~3h | worker | |

### Milestone 4: Consolidate current awardsapp backlog

**Status:** pending
**Estimate:** ~24h
**Validation:** existing duplicate PR groups are reduced to one active candidate per issue, obsolete siblings are closed with evidence, and ready candidates are merged or converted into actionable follow-up tasks.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 4.1 | Consolidate duplicate PR groups for issues with multiple sibling PRs | pending | pending | ~8h | interactive/worker | |
| 4.2 | Repair top red PRs whose failures are PR-specific and actionable | pending | pending | ~10h | worker | |
| 4.3 | Rerun/escalate CI-only timeout/advisory blockers instead of redispatching new code workers | pending | pending | ~4h | interactive/automation | |
| 4.4 | Merge approved green candidates and verify linked issues close | pending | pending | ~2h | pulse/interactive | |

### Milestone 5: Monitor convergence and iterate

**Status:** pending
**Estimate:** ~16h
**Validation:** dashboard shows decreasing duplicate groups/red PRs, increasing merged worker PRs, and fewer worker failures caused by timeout/rate-limit/no-work loops.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 5.1 | Monitor worker starts, PR creation, CI outcomes, merges, and issue closures after each release/deploy | pending | pending | ~6h | interactive | |
| 5.2 | Store lessons and update aidevops worker discipline/configs from observed failure modes | pending | pending | ~4h | interactive/worker | |
| 5.3 | Repeat release/deploy/monitor loop until remaining blockers are maintainer/security/business decisions | pending | pending | ~6h | interactive | |

## Resources

| Name | Type | Purpose | Status | Notes |
|------|------|---------|--------|-------|
| GitHub CLI access | credential | Read/write PRs/issues/checks in aidevops and awardsapp | configured | Use gh wrappers/signature discipline for writes |
| aidevops release pipeline | infrastructure | Ship systemic orchestration fixes | configured | version-manager release patch/hotfix after merge |
| awardsapp CI | infrastructure | Validate worker PRs and classify blockers | active | GitHub Actions |

## Budget Tracking

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | 336h | 0h | 336h | 0% |
| Money (USD)  | $500 | $0 | $500 | 0% |
| Tokens       | unlimited | tracked per session | unlimited | n/a |

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| 2026-05-08 | time | initial | Mission created and scoped from current awardsapp/aidevops evidence | 1 |

## Decision Log

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | 2026-05-08 | Treat this as a mixed aidevops + awardsapp mission | Evidence shows both orchestration duplicate/red-PR churn and awardsapp CI timeout/advisory ambiguity | Only fix aidevops; only fix awardsapp |
| 2 | 2026-05-08 | Prioritize required/advisory CI clarity before broad worker redispatch | Duplicate workers burn tokens when the existing PR is approved but blocked by CI semantics | Continue redispatching until one PR happens to pass |
| 3 | 2026-05-08 | First aidevops change should stop CI repair redispatch for infra/advisory failures | `pulse-merge-feedback.sh` routed advisory/non-required and timed-out/cancelled checks as CI repair feedback, which closes PRs and requeues duplicate workers | Start with awardsapp CI changes only |
| 4 | 2026-05-08 | Add failed-log inspection for required-check failures | awardsapp PR #4595 reported Lint/Typecheck as `failure`, but failed logs show `Process completed with exit code 143` and `Killed timeout --kill-after`, so check conclusion alone is insufficient | Treat all `failure` conclusions as code-fix redispatch |

## Mission Agents

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | | pending |

## Research

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| awardsapp PR blocker sample | Multiple issues have sibling PRs; many failures are E2E shard or timeout/kill rather than code errors. Examples include PRs #4594/#4595 timeout/kill and #4596 merging after core gates passed. | gh PR/check queries in current session | 2026-05-08 |
| current open PR sample | Open approved/mergeable PRs include #4594, #4595, #4599, #4584 and others; several have Lint/Typecheck pending while prior logs showed timeout/kill symptoms. | `gh pr view/list` in current session | 2026-05-08 |
| required-check timeout sample | awardsapp PR #4595 Lint failed after 22m45s and log ended with `Killed timeout --kill-after` plus exit `143`; this is CI budget/infra timeout evidence, not an actionable source lint error. | `gh run view 25530590843 --job 74936343694 --log-failed` | 2026-05-08 |

## Progress Log

| Timestamp | Event | Details |
|-----------|-------|---------|
| 2026-05-08T00:00:00Z | Mission created | Goal: keep improving aidevops and awardsapp until open issues converge to green merged PRs. |
| 2026-05-08T01:10:00Z | First systemic fix implemented locally | Updated `pulse-merge-feedback.sh` so CI repair feedback only re-dispatches actionable failed required checks; timed_out/cancelled/advisory-only failures now skip CI repair routing. Verified with `test-pulse-merge-ci-repair-routing.sh` and ShellCheck. |
| 2026-05-08T01:45:00Z | Second systemic fix implemented locally | Added GitHub Actions failed-log inspection so required checks with failure conclusions but timeout/kill signatures such as exit 143 are classified as infra-timeout and skipped for code redispatch. Verified with `test-pulse-merge-ci-repair-routing.sh` and ShellCheck. |

## Retrospective

_Completed after mission finishes._

- **Outcomes:** pending
- **Lessons learned:** pending
- **Framework improvements:** pending

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | 336h | | |
| Money | $500 | | |
| Tokens | unlimited | | |

### Skill Learning

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |
