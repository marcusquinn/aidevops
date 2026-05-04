---
id: "m-20260504-1e325d"
title: "Restore pulse and worker reliability"
status: active
mode: full
repo: "/Users/marcusquinn/Git/aidevops-feature-auto-20260504-031114"
created: "2026-05-04"
started: "2026-05-04"
completed: ""

budget:
  time_hours: 168
  money_usd: 500
  token_limit: 0
  alert_threshold_pct: 80

model_routing:
  orchestrator: opus
  workers: sonnet
  research: haiku
  validation: sonnet

preferences:
  tech_stack: [bash, python, github-actions, opencode, claude-code]
  deploy_target: "aidevops release via version-manager"
  test_framework: "shell tests and linters-local"
  ci_provider: "github-actions"
  coding_style: ".agents/AGENTS.md framework rules; keep always-loaded guidance small"
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Restore pulse and worker reliability

> Pulse and workers should safely use available concurrency and close suitable issues mostly on first attempt, with failed attempts producing actionable systemic fixes instead of repeated stalls.

## Origin

- **Created:** 2026-05-04
- **Created by:** interactive OpenCode mission session
- **Session:** OpenCode mission:restore-pulse-worker-reliability
- **Context:** User reported that pulse/workers previously solved issues mostly first-attempt, but recent attempts fail too often. A recent AGENTS.md harness refactor reduced always-loaded guidance and shifted detail into progressive context loading; the mission must verify whether workers know what context to load, when, why, and how.

## Scope

**Goal:** Restore autonomous issue-solving reliability so pulse can continuously and safely utilise worker concurrency, workers complete appropriate backlog issues with first-attempt success as the common case, and failures feed durable framework fixes, merged PRs, releases, and monitoring evidence.

**Mode:** full

**Classification:** enhancement + infrastructure reliability.

**Success criteria:**

- Worker terminal success rate is materially higher than the baseline captured at mission start: `worker-activity-helper.sh summary` reported 151 successes out of 241 events in 24h, with 75 rate-limit outcomes and 15 other failures.
- Repeated issue retries have explicit root-cause buckets, owners, fixes, or safe backoff rules.
- Failed worker session excerpts identify missing brief/context categories and trigger either better brief generation, progressive-loading guidance, or deterministic pre-dispatch validators.
- Local verification passes for changed scripts/docs, followed by full-loop PRs, merge, release, and post-release monitoring.
- Progress survives compaction through this mission file, TODO entries, checkpoint notes, and appended progress log entries.

**Non-goals:**

- Do not weaken security, trust-boundary, prompt-injection, or collaborator-scope rules to increase throughput.
- Do not add large always-loaded AGENTS.md content unless a short pointer cannot solve the failure; prefer reference docs, workflow docs, scripts, hooks, and validators.
- Do not perform destructive cleanup of worker worktrees, issues, labels, or releases without explicit verification.
- Do not edit the canonical main checkout directly. Use linked worktrees for changes.

**Constraints:**

- Canonical repo `/Users/marcusquinn/Git/aidevops` is protected on `main`; pre-edit check required a linked worktree and created `/Users/marcusquinn/Git/aidevops-feature-auto-20260504-031114`.
- User requested no branch switching in canonical main; implementation work must happen from worktrees.
- Deployment to other users requires PR merge and release so auto-update can pick up fixes.
- Budget helper feasibility: $500/168h supports roughly 105 moderate Sonnet/Opus tasks or 800 Haiku tasks; budget is sufficient for the full mission.

## Risk probes

1. **Pre-mortem:** The mission fails if we optimise for dispatch volume before classifying why workers fail, causing rate-limit churn, repeated retries, or unsafe partial fixes.
2. **Rollback plan:** Every code change ships as an isolated worktree PR with tests; revert by PR/release rollback if post-release monitoring shows lower success or unsafe behaviour.
3. **Non-negotiables:** Worker briefs must contain enough task, file, verification, trust-boundary, and progressive-context-loading guidance to solve the issue without relying on hidden interactive context.

## Baseline evidence

Captured 2026-05-04 from the mission worktree:

- `~/.aidevops/agents/scripts/worker-activity-helper.sh summary`: 241 worker events in 24h; 151 successes; 75 rate-limit; 7 provider errors; 2 local errors; 2 watchdog stall-killed; 1 premature exit; 1 auth error.
- `~/.aidevops/agents/scripts/worker-activity-helper.sh providers --since 24h`: all 241 events used `openai/openai/gpt-5.5`; one OpenAI account available; recent samples mixed successes with rate-limit outcomes.
- `~/.aidevops/agents/scripts/pulse-diagnose-helper.sh cycle-health --window 24h --json`: pulse stages generally not degraded, but output is large and includes high-volume dispatch-candidate loops and one `preflight_ownership_reconcile` timeout.
- `~/.aidevops/agents/scripts/budget-analysis-helper.sh analyse --budget 500 --hours 168 --json`: mission budget sufficient.

## Milestones

Milestones are sequential; features within each milestone are parallelisable. Each feature becomes a TODO/GitHub issue before worker dispatch.

### Milestone 1: Establish failure taxonomy and live baseline

**Status:** active
**Estimate:** ~8h
**Validation:** A reproducible report identifies top issue/session failure modes, frequency, examples, and first systemic fix candidates.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | Build bounded worker outcome taxonomy from metrics, failure excerpts, issue labels, and recent PR outcomes `[parallel-group:a]` | pending | implemented-local | ~2h | interactive | |
| 1.2 | Correlate repeated attempts per issue with pulse dispatch decisions and retry/backoff state `[parallel-group:a]` | pending | pending | ~2h | | |
| 1.3 | Sample failed worker sessions for missing context, wrong model/account routing, premature exits, and tool-use mistakes `[parallel-group:a]` | pending | pending | ~3h | | |
| 1.4 | Produce mission baseline dashboard/checkpoint with metrics to compare every release cycle `[depends:1.1,1.2,1.3]` | pending | pending | ~1h | | |

### Milestone 2: Fix context-loading and brief quality gaps

**Status:** active
**Estimate:** ~12h
**Validation:** Workers receive concise always-loaded pointers plus task-specific references; regression fixtures prove generated briefs include context-loading instructions when needed.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | Audit progressive context references in `.agents/AGENTS.md`, worker briefs, headless launch prompts, and domain routing docs `[parallel-group:b]` | pending | pending | ~2h | | |
| 2.2 | Add minimal always-loaded pointer clarifying what/when/why/how to load progressive context, without ratchet regression `[depends:2.1]` | pending | implemented-local | ~2h | interactive | |
| 2.3 | Improve worker brief generation so issue workers receive file targets, reference patterns, verification, trust boundary, and relevant docs `[depends:1.3,2.1]` | pending | pending | ~4h | | |
| 2.4 | Add tests/validators for brief completeness and progressive-loading triggers `[depends:2.3]` | pending | partial-local | ~4h | interactive | |

### Milestone 3: Fix dispatch, retry, rate-limit, and concurrency controls

**Status:** active
**Estimate:** ~16h
**Validation:** Pulse dispatches within safe capacity, avoids repeated doomed retries, and records clear recovery reasons for non-success outcomes.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 3.1 | Diagnose rate-limit classification and account-pool routing so 75/241 rate-limit outcomes become actionable capacity signals `[parallel-group:c]` | pending | implemented-local | ~4h | interactive | |
| 3.2 | Add/adjust backoff and retry budgets for repeated issue attempts, preserving fast recovery after transient failures `[depends:3.1]` | pending | implemented-local | ~4h | interactive | |
| 3.3 | Strengthen worker launch and watchdog diagnostics for premature exit, local errors, and stall-killed sessions `[parallel-group:c]` | pending | pending | ~4h | | |
| 3.4 | Add pulse capacity/current-state guardrails that prioritise solvable issues over raw concurrency `[depends:3.1,3.2,3.3]` | pending | pending | ~4h | | |

### Milestone 4: Local dogfood loop and release pipeline

**Status:** pending
**Estimate:** ~10h
**Validation:** Fix PRs are merged, release created, local setup updated, and worker metrics improve in the next monitoring window.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 4.1 | Run local linters/tests and targeted pulse/worker diagnostic smoke tests for each fix PR `[depends:2.*,3.*]` | pending | pending | ~3h | | |
| 4.2 | Full-loop fixes through PR creation, review handling, merge, and post-merge healing `[depends:4.1]` | pending | pending | ~3h | | |
| 4.3 | Release patched aidevops version and verify setup/update path for user adoption `[depends:4.2]` | pending | pending | ~2h | | |
| 4.4 | Monitor post-release worker success, rate-limit, retry, and solved:worker rates; append evidence to mission log `[depends:4.3]` | pending | pending | ~2h | | |

### Milestone 5: Perpetual reliability loop

**Status:** pending
**Estimate:** ongoing
**Validation:** Mission remains active until pulse/workers reliably drain open auto-dispatchable backlog with safe concurrency and repeated failures automatically become scoped tasks.

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 5.1 | Add compaction-safe mission checkpoint routine covering current metrics, active PRs, releases, blockers, and next actions `[parallel-group:d]` | pending | pending | ~2h | | |
| 5.2 | Convert new recurrent failure buckets into worker-dispatchable tasks with evidence and verification context `[parallel-group:d]` | pending | pending | ongoing | | |
| 5.3 | Repeat diagnose → fix → PR → release → monitor until success criteria hold across sustained windows `[depends:5.1,5.2]` | pending | pending | ongoing | | |

## Resources

| Name | Type | Purpose | Status | Notes |
|------|------|---------|--------|-------|
| GitHub CLI auth | credential | Read issues/PRs and create worker tasks/PRs | configured | Use existing `gh`; never expose tokens |
| OAuth account pool | infrastructure | Worker provider capacity and rate-limit balancing | constrained | Baseline shows one OpenAI account active |
| OpenCode session DB | dependency | Failed-session analysis | available locally | Use documented runtime DB lookup; extract facts only |
| Local linked worktrees | infrastructure | Safe implementation isolation | active | Current mission worktree path above |

## Budget Tracking

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | 168h | 0h | 168h | 0% |
| Money (USD)  | $500 | $0 | $500 | 0% |
| Tokens       | unlimited | unknown | unlimited | 0% |

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| 2026-05-04 | Time | initial planning | Mission scoped and baseline commands run | 1 |

## Decision Log

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | 2026-05-04 | Classify as full-mode enhancement/infrastructure mission | Existing framework reliability problem needs worktrees, PRs, release, and monitoring | POC/research-only would not deploy fixes |
| 2 | 2026-05-04 | Keep AGENTS.md additions minimal unless evidence proves an always-loaded gap | Progressive disclosure is intentional; durable fixes should prefer targeted docs, brief generation, and validators | Re-expand AGENTS.md broadly, risking context/ratchet regression |
| 3 | 2026-05-04 | Start with evidence taxonomy before raising concurrency | Baseline shows mixed successes and high rate-limit outcomes; raw concurrency may amplify failures | Immediately increase workers/backlog dispatch |

## Mission Agents

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | | pending |

## Research

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| Worker baseline | 151/241 recent events succeeded; 75 rate-limit; all OpenAI gpt-5.5; one OpenAI account available | `worker-activity-helper.sh summary/providers --since 24h` | 2026-05-04 |
| Pulse cycle health | Stages mostly not degraded; large candidate loops and ownership reconcile timeout need deeper inspection | `pulse-diagnose-helper.sh cycle-health --window 24h --json` | 2026-05-04 |
| Failure taxonomy research | Dominant non-success bucket is provider/rate-limit classification, but classifier may be polluted by broad tail scanning; structured provenance needed | Task `ses_20f3c32adffeSyivA7KaMu2xxV` | 2026-05-04 |
| Progressive context audit | Headless contract and brief template need explicit Progressive Context Plan while keeping AGENTS.md small | Task `ses_20f3c329affejWwD7FQkWo33hU` | 2026-05-04 |
| Dispatch retry audit | Provider-wide rate-limit pressure should reduce dispatch concurrency; current backoff is mostly per-issue/GraphQL scoped | Task `ses_20f3c3279ffeSU8Sq1taGeS3eX` | 2026-05-04 |

## Progress Log

| Timestamp | Event | Details |
|-----------|-------|---------|
| 2026-05-04T03:11Z | Mission created | Worktree `/Users/marcusquinn/Git/aidevops-feature-auto-20260504-031114`; mission id `m-20260504-1e325d` |
| 2026-05-04T03:12Z | Baseline captured | Worker activity and provider summaries run; pulse cycle-health command run |
| 2026-05-04T03:20Z | Initial diagnostics launched | Three research agents returned findings for taxonomy, progressive context, and dispatch/retry controls |
| 2026-05-04T03:45Z | Progressive context fix implemented locally | Updated headless contract to V9 with Progressive context loading rules; added `### Progressive Context Plan` to brief template and workflow pointer; tests passed: `test-headless-runtime-helper.sh`, `test-brief-inline-classifier.sh`, `shellcheck` on changed shell files |
| 2026-05-04T03:52Z | Broader lint attempted | `.agents/scripts/linters-local.sh` passed Sonar, secretlint, Markdown, TOON, skill frontmatter, secret policy, pulse canary, layout; timed out after reporting pre-existing Bash 3.2 compatibility violations in unrelated scripts |
| 2026-05-04T04:15Z | Classifier provenance and provider pressure throttle implemented locally | Metrics now carry `classification_pattern`; worker activity groups expose it; dispatch backoff now blocks provider/model-wide rate-limit storms. Targeted tests passed: `test-headless-runtime-helper.sh`, `test-brief-inline-classifier.sh`, `test-worker-activity-helper.sh`, `test-dispatch-backoff-helper.sh`, and `shellcheck` on changed shell files |

## Next actions

1. Refresh worktree against `origin/main` without losing local mission changes, then run scoped diff review.
2. Run broader quality gate again or document pre-existing unrelated failures with evidence.
3. Create PR for the combined local fixes, merge, release, and verify setup/update path.
4. Monitor worker productivity (`worker-activity-helper.sh summary --since 24h --json`, solved:worker rate, repeated comments/attempts per issue). Convert any remaining comment-thread loops into systemic fixes.

## Perpetual Todo / Compaction Checkpoint

This mission continues until pulse and workers are fully productive: open issues should be solvable by workers doing real implementation work, comment-thread loops should turn into systemic fixes, and repeated failures should become scoped tasks rather than unresolved churn.

- [x] Create mission state and baseline evidence.
- [x] Capture first failure taxonomy, progressive context, and dispatch retry audits.
- [x] Implement local Progressive Context Plan guidance for headless workers and briefs.
- [ ] Refresh worktree against `origin/main` without losing local mission changes.
- [ ] Create/merge/release the combined progressive-context, classifier-provenance, and provider-pressure throttle fix.
- [x] Add structured classifier provenance so rate-limit/provider/local/watchdog classifications cite source, matched pattern, exit code, and kill reason.
- [x] Add provider/model-wide rate-limit pressure throttle so pulse does not launch many workers into one constrained account/model.
- [ ] Add diagnostics for comment threads and repeated worker comments that fail to move issues toward closure; convert recurring patterns into framework tasks.
- [ ] Run local tests/linters, full-loop PR(s), merge, release, and setup/update verification.
- [ ] Monitor `worker-activity-helper.sh summary --since 24h --json`, solved:worker closure rate, repeated attempts per issue, and pulse capacity until the success criteria hold across sustained windows.

Compaction resume facts:

- Worktree: `/Users/marcusquinn/Git/aidevops-feature-auto-20260504-031114`.
- Active files already changed locally: `.agents/scripts/headless-runtime-lib.sh`, `.agents/scripts/headless-runtime-helper.sh`, `.agents/scripts/worker-activity-helper.sh`, `.agents/scripts/dispatch-backoff-helper.sh`, `.agents/templates/brief-template.md`, `.agents/workflows/brief.md`, `.agents/scripts/tests/test-headless-runtime-helper.sh`, `.agents/scripts/tests/test-brief-inline-classifier.sh`, `.agents/scripts/tests/test-worker-activity-helper.sh`, `.agents/scripts/tests/test-dispatch-backoff-helper.sh`, and this mission file.
- Verified local tests: `bash .agents/scripts/tests/test-headless-runtime-helper.sh && bash .agents/scripts/tests/test-brief-inline-classifier.sh && bash .agents/scripts/tests/test-worker-activity-helper.sh && bash .agents/scripts/tests/test-dispatch-backoff-helper.sh`, and targeted `shellcheck` passed.
- Broader `linters-local.sh` timed out after pre-existing unrelated Bash 3.2 findings; do not claim full lint success until rerun or scoped exception is justified.
- Never edit canonical `/Users/marcusquinn/Git/aidevops` on `main`; continue from linked worktrees.

## Retrospective

_Completed after mission finishes._

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | 168h | | |
| Money | $500 | | |
| Tokens | unlimited | | |

### Skill Learning

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |
