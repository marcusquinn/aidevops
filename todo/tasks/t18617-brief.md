## Task


Add explicit `timeout-minutes` to the GitHub-hosted CI jobs that hung, so a stalled job
fails fast and can be retried instead of holding a PR check open for GitHub's 360-minute default.

## Done when

- [ ] `model-replay-linux` and `code-review-monitoring` jobs declare `timeout-minutes`.
- [ ] Regression guard: the PR's own `Code Quality Analysis` and `Code Review Monitoring` runs complete successfully, and the replay job still runs the Bubblewrap boundary suite (`test-model-replay-benchmark.mjs`). Workflow YAML stays valid, so no `startup_failure` occurs.

<details>
<summary>Worker implementation contract</summary>

## Worker Guidance


### Files to Modify

- EDIT: `.github/workflows/code-quality.yml`: in job `model-replay-linux` (search `model-replay-linux:`), add `timeout-minutes: 20` at job level. Also add `timeout-minutes: 8` on the `Install Bubblewrap` step so an apt mirror stall fails inside the step.
- EDIT: `.github/workflows/code-review-monitoring.yml`: in job `code-review-monitoring` (search `name: 🤖 Monitor & Auto-Fix Code Quality`), add a job-level `timeout-minutes` sized from recent successful durations. Check them with `gh run list -w code-review-monitoring.yml -L 20 --json databaseId,createdAt,updatedAt,conclusion`, use about 3x p95, and keep it at 30 or below.

Optional, in scope only if trivial: give other jobs in the same two files a generous job-level timeout when they currently have none. Base each value on observed durations.

### Files Scope

- `.github/workflows/code-quality.yml`
- `.github/workflows/code-review-monitoring.yml`

</details>

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

## Origin

Interactive triage on 2026-10-07 of open PRs that looked stuck. Two PRs (#33941, #33945) had
GitHub-hosted jobs hung for ~4.5 hours with no step progress. They needed a manual force-cancel and rerun.

## What

Add explicit `timeout-minutes` to the GitHub-hosted CI jobs that hung, so a stalled job
fails fast and can be retried instead of holding a PR check open for GitHub's 360-minute default.

## Why

Evidence (all on `ubuntu-22.04` / `ubuntu-latest` GitHub-hosted runners, not self-hosted):

- Run 37671140471 (`Code Quality Analysis`, PR #33945): job `Model replay verifier boundary (ubuntu-22.04)` started 18:49Z/19:00Z and stayed `in_progress` in step `Install Bubblewrap` (`apt-get update`/`install`) for ~4.5 h.
- Run 37669642222 (`Code Quality Analysis`, PR #33941): same job and step.
- Run 37669642160 (`Code Review Monitoring`, PR #33941): job `Monitor & Auto-Fix Code Quality` stuck `in_progress` for ~4.7 h.
- A normal `gh run cancel` did not take effect. Only `POST .../force-cancel` worked. After a rerun, both replay jobs passed in minutes.

Neither job sets `timeout-minutes` (`rg -n 'timeout-minutes' .github/workflows/code-quality.yml .github/workflows/code-review-monitoring.yml` returns nothing).

## Tier

tier:simple: two YAML files with mechanical additions and no logic changes.

## Context & Decisions

The timeout values are deliberately generous. The goal is to bound hangs, not to tighten normal runtime.
Do not move these jobs to self-hosted runners. That is out of scope.

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.29 plugin for [OpenCode](https://opencode.ai) v1.18.35 with claude-opus-5-5 spent 12m and 16,170 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVu8QYg",
  "title": "t18617: ci: add timeout-minutes to hung-prone GitHub-hosted jobs (model-replay-linux, code-review-monitoring)",
  "updatedAt": "2026-10-09T02:55:36Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/33986",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18617",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "33986",
  "captured_at": "2026-10-09T21:16:06Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
