## Task


The pulse failure-enrichment pre-pass (`dispatch_enrichment_workers` → `_enrichment_run_worker`) must launch a headless worker that actually reaches the model. That worker then appends a `## Worker Guidance` section to the failed issue. The worker must run in a dispatcher-owned linked worktree, not the canonical checkout. When it fails, its output must remain inspectable.

## Done when

- [ ] The enrichment worker launch passes the issue-worker env contract and reaches model selection.
- [ ] A failed enrichment run logs the tail of the worker output instead of discarding it.
- [ ] Negative: the enrichment worker never uses the canonical checkout as `--dir`, and the env-contract validator is unchanged.
- [ ] `shellcheck` is clean, and `test-worker-outcome-routing.sh` plus `test-pulse-wrapper-worker-count.sh` pass.

<details>
<summary>Worker implementation contract</summary>

## Worker Guidance


### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-quality-debt.sh:333-493` — the full enrichment flow.
- **Read first:** `.agents/scripts/headless-runtime-launch.sh:720-806` — the contract and its validation (dir must equal `WORKER_WORKTREE_PATH`; origin slug must match `WORKER_REPO_SLUG`).
- **Load only if:** a worktree helper is needed — the worktree creation used by `.agents/scripts/pulse-dispatch-worker-launch.sh` (around line 1706, `WORKER_WORKTREE_PATH="$worker_worktree_path"`) and `.agents/scripts/dispatch-single-issue-helper.sh:588`.
- **Stop when:** you know how a dispatcher-owned worktree is created and released for a worker session.

### Files to Modify

- `EDIT: .agents/scripts/pulse-quality-debt.sh:350-388` — in `_enrichment_run_worker`:
  - create or reuse a dispatcher-owned linked worktree for the repo;
  - export `WORKER_ISSUE_NUMBER`, `WORKER_REPO_SLUG` and `WORKER_WORKTREE_PATH` (model on `.agents/scripts/pulse-ancillary-dispatch.sh:1054-1068`);
  - pass `--dir` set to that worktree;
  - on non-zero exit, append a bounded tail of the worker output to `$LOGFILE` before cleanup;
  - release the worktree afterwards.
- `EDIT: .agents/scripts/pulse-quality-debt.sh:166-179` — `_enrichment_resolve_repo_path` keeps returning the canonical path, used only as the worktree source.

### Complete Write Surface

- **Callers/readers:** `dispatch_enrichment_workers` (`pulse-quality-debt.sh:403`), called from `.agents/scripts/pulse-dispatch-lib-candidates.sh:147` and `.agents/scripts/pulse-wrapper.sh:845`.
- **Writers/mutation paths:** the GitHub issue body, edited by the worker via `gh_issue_edit_safe`; the fast-fail state via `_ff_mark_enrichment_done` (`pulse-fast-fail.sh:976`).
- **Existing verification/tests:** `.agents/scripts/tests/test-worker-outcome-routing.sh:114-148` (stubs `dispatch_enrichment_workers`); `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh:1013-1175`.
- **Schemas/config:** the fast-fail state JSON (`~/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json`) is unchanged.
- **Generated/deployed mirrors:** deployed copy `~/.aidevops/agents/scripts/` via `setup.sh`.
- **Migrations/backfills:** none. Entries already marked `enrichment_done` are not retried. This is acceptable.
- **Cleanup/rollback paths:** the `push_cleanup` / `_run_cleanups` RETURN trap in `_enrichment_run_worker` (`.agents/scripts/pulse-quality-debt.sh:357-363`) must release the enrichment worktree and delete the output file on every path. Rollback: revert the PR; no state to undo, because `fast-fail-counter.json` keys are unchanged.

### Implementation Steps

1. Choose the worktree mechanism used by pulse worker launch (reuse, do not invent). Record the choice in the PR body.
2. Wrap the `headless-runtime-helper.sh run` call with the env contract and the worktree `--dir`.
3. Keep the output file until after logging: on `enrichment_exit != 0`, log `tail -n 20` of it, with secrets already redacted by the runtime, to `$LOGFILE`.
4. Ensure that the worktree is released on every return path (existing `push_cleanup` pattern at lines 357-363).
5. Run `shellcheck .agents/scripts/pulse-quality-debt.sh`.

### Hazards and Compatibility

- **Concurrency/atomicity:** the enrichment run is synchronous inside the dispatch pre-pass. The worktree name must be unique per issue/session (for example `enrichment-<issue>`) so it cannot collide with an implementation worker worktree for the same issue.
- **Migration/rollback:** a code-only revert.
- **Mixed-version/backward compatibility:** none. Single-process change.
- **Idempotency/retry:** each issue is enriched once (`_ff_mark_enrichment_done`). This is unchanged.
- **Partial failure/recovery:** if worktree creation fails, log it and skip, without marking enrichment done, so the next cycle retries.

### Complexity Impact

- **Target function:** `_enrichment_run_worker` in `.agents/scripts/pulse-quality-debt.sh`
- **Current line count:** 39 lines
- **Estimated growth:** +25 lines
- **Projected post-change:** ~64 lines
- **Action required:** Watch. Extract `_enrichment_prepare_worktree` if the function grows past 80 lines.

### Verification Before Dispatch

```bash
# Reproduce the contract abort before the fix (expect fatal) and after (expect no fatal; the canary runs):
~/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key enrichment-999999 --dir "$PWD" --title "Enrichment analysis: Issue #999999" --prompt noop
shellcheck .agents/scripts/pulse-quality-debt.sh
bash .agents/scripts/tests/test-worker-outcome-routing.sh
bash .agents/scripts/tests/test-pulse-wrapper-worker-count.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the repro proves the contract path. The tests prove that slot accounting is unchanged. In production, the next `Enrichment:` log line no longer shows `exit=1`.
- **Broad verification trigger:** Not required.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-worker-outcome-routing.sh`
- [ ] WIP commit created before broad gates: `wip: enrichment worker env contract`
- [ ] Evidence-triggered broad verification then run: not required — single pulse module

### Scope Boundaries

**Hard boundaries:** do not relax `_run_requires_issue_env_contract` or `_validate_issue_worker_env_contract`. The contract is a deliberate safety gate (t3500). Do not run the worker in the canonical checkout.

**AI brief owner:** interactive maintainer session that filed this issue.

**Recovery:** preserve the current PR and use the structured runtime request in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-quality-debt.sh`
- `.agents/scripts/tests/test-worker-outcome-routing.sh`

</details>

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

<!-- aidevops:brief-schema=v2 -->


## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse enrichment` → 0 hits — no relevant lessons
- [x] Discovery pass: 10 recent commits touch the target files (none about enrichment) / 0 merged PRs about enrichment launch / 0 open related PRs
- [x] File refs verified: 8 refs checked, all present at HEAD `90631c51d`
- [x] Tier: `tier:thinking` — dispatch-path change (headless worker launch contract, `self-hosting-files.conf`) plus worktree-ownership design choice
- [x] Seeded draft PR decision recorded: skipped — worktree lifecycle choice must be made by the implementer

## Origin

- **Created:** 2026-10-07
- **Session:** opencode:unknown-2026-10-07
- **Created by:** ai-interactive
- **Conversation context:** User reported that pulse enrichment does not work. Investigation of `pulse.log` and archives showed zero successful enrichment runs.

## What

The pulse failure-enrichment pre-pass (`dispatch_enrichment_workers` → `_enrichment_run_worker`) must launch a headless worker that actually reaches the model. That worker then appends a `## Worker Guidance` section to the failed issue. The worker must run in a dispatcher-owned linked worktree, not the canonical checkout. When it fails, its output must remain inspectable.

## Why

Every enrichment run since the issue-worker env contract (t3500 / #22438) was added aborts before model launch:

- `.agents/scripts/pulse-quality-debt.sh:366-372` runs `headless-runtime-helper.sh run --role worker --title "Enrichment analysis: Issue #N"` with `--dir <canonical repo path>`. It sets no `WORKER_ISSUE_NUMBER`, `WORKER_REPO_SLUG` or `WORKER_WORKTREE_PATH`.
- `.agents/scripts/headless-runtime-launch.sh:720-741` (`_run_requires_issue_env_contract`) matches `Issue #N` in the title (line 733) **and** `issue #N` in the prompt (line 736). So `_validate_issue_worker_env_contract` (line 745) aborts with exit 1.
- Reproduced locally (aborts before canary/model, no side effects):

```text
$ headless-runtime-helper.sh run --role worker --session-key enrichment-999999 --dir <tmp> --title "Enrichment analysis" --prompt "A worker attempted to implement issue #999999 but failed."
[ERROR] [fatal] WORKER_ISSUE_NUMBER unset — issue worker env contract missing; aborting before model launch
```

- Runtime evidence: across 4 archived pulse logs plus the current one, there are 29 `Enrichment: worker ran (exit=1) but no Worker Guidance found` lines. The single "successfully" line is a false positive (tracked separately).
- `_enrichment_run_worker` writes the worker output to a `mktemp` file that is deleted unconditionally (lines 361-363), so the fatal message never reached any log.

Without enrichment, failed issues are redispatched with the same brief, which wastes worker cycles.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No: worktree creation/cleanup choice remains.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** Worktree ownership and cleanup policy remain open.
- [ ] **Bounded, reversible, low-consequence impact?** Worker launch path.
- [ ] **No stateful coordination to invent?** Worktree lifecycle.
- [x] **Focused verification and rollback are explicit?**
- [ ] **No dispatch-path risk override?** `headless-runtime-*` is listed in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:thinking`

**Tier rationale:** The change touches the worker launch contract on the self-hosting dispatch path and needs a worktree ownership decision.

## PR Conventions

Leaf task: the PR body uses a closing keyword for this issue.

## Context & Decisions

- Relaxing the contract matcher (for example exempting `enrichment-*` session keys) was ruled out. The contract exists so that workers never run without a dispatcher-owned worktree.
- Renaming the title alone does not help, because the prompt also matches `[Ii]ssue[[:space:]]*#?[0-9]+` (verified).
- Related findings are tracked separately: worker-side fast-fail never flags enrichment, and the success check gives a false positive.

## Relevant Files

- `.agents/scripts/pulse-quality-debt.sh:350` — `_enrichment_run_worker`
- `.agents/scripts/headless-runtime-launch.sh:720` — contract matcher
- `.agents/scripts/pulse-ancillary-dispatch.sh:1054` — reference: env contract passed to `headless-runtime-helper.sh run`

## Dependencies

- **Blocked by:** none
- **Blocks:** meaningful verification of the sibling enrichment tasks
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | enrichment flow and worker worktree creation |
| Implementation | 1h | env contract, worktree, output logging |
| Verification | 30m | repro and existing tests |
| **Total** | **2h** | |

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
[aidevops.sh](https://aidevops.sh) v3.38.23 plugin for [OpenCode](https://opencode.ai) v1.18.34 with claude-opus-5-5 spent 1h 54m and 30,972 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVjzMtQ",
  "title": "t18607: fix(pulse): enrichment worker always aborts on the issue-worker env contract",
  "updatedAt": "2026-10-07T08:22:26Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/33877",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18607",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "33877",
  "captured_at": "2026-10-07T08:27:53Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
