# Planning & Tasks — Detail Reference

Loaded on-demand when working with tasks, TODO.md, or the supervisor dispatch system.
Core rules are in `AGENTS.md`. Full planning docs: `workflows/plans.md`, `tools/task-management/beads.md`.

## Key Commands

`/new-task`, `/save-todo`, `/ready`, `/sync-beads`, `/plan-status`, `/create-prd`, `/generate-tasks`

Use `/save-todo` after planning. Auto-detects complexity:
- **Simple** → TODO.md only
- **Complex** → PLANS.md + TODO.md reference

## Task Format

`- [ ] t001 Description @owner #tag ~4h (ai:2h test:1h) started:ISO blocked-by:t002`

Dependencies: `blocked-by:t001`, `blocks:t002`, `t001.1` (subtask).

## Auto-Dispatch

Add `#auto-dispatch` to tasks that can run autonomously (clear spec, bounded scope, no user input needed). Default to including it — only omit when a specific exclusion applies. See `workflows/plans.md` "Auto-Dispatch Tagging" for full criteria. The supervisor's Phase 0 picks these up automatically every 2 minutes and auto-creates batches (`auto-YYYYMMDD-HHMMSS`, concurrency = cores/2, min 2) when no active batch exists.

**Interactive claim guard** (t1062): When working interactively on a task tagged `#auto-dispatch`, immediately add `assignee:` or `started:` in the TODO entry before pushing — the supervisor skips tasks with these fields to prevent race conditions.

## Lifecycle Status Tags

The supervisor updates a `status:` tag on each task's TODO.md line at every decision point. This gives users real-time visibility into what the supervisor is doing with each task. Tags are updated by the AI lifecycle engine (`ai-lifecycle.sh`) and batch-committed once per pulse.

**Lifecycle states** (progressive — task moves through these):

| Tag | Meaning |
|-----|---------|
| `status:dispatched` | Worker session launched |
| `status:running` | Worker actively coding |
| `status:evaluating` | Checking worker output |
| `status:pr-open` | PR created, awaiting CI |
| `status:ci-running` | CI checks in progress |
| `status:ci-passed` | CI green, ready to merge |
| `status:merging` | Merge in progress |
| `status:merged` | PR merged to main |
| `status:deploying` | Running deploy/setup |
| `status:deployed` | Live on main, awaiting verification |
| `status:verified` | Post-merge verification passed |

**Action states** (transient — what the supervisor is doing right now):

| Tag | Meaning |
|-----|---------|
| `status:updating-branch` | Updating PR branch via GitHub API |
| `status:rebasing` | Git rebase onto main |
| `status:resolving-conflicts` | AI resolving merge conflicts |
| `status:reviewing-threads` | Triaging PR review comments |

**Problem states** (visible to user — needs attention or patience):

| Tag | Meaning |
|-----|---------|
| `status:behind-main` | PR needs update, supervisor will handle |
| `status:has-conflicts` | Merge conflicts, AI attempting resolution |
| `status:ci-failed` | CI checks failed, investigating |
| `status:changes-requested` | Human reviewer requested changes |
| `status:blocked:<reason>` | Cannot proceed, reason given |

The AI lifecycle engine (`SUPERVISOR_AI_LIFECYCLE=true`, default) replaces hardcoded bash heuristics with intelligence-first decision making. For each active task, it gathers real-world state (DB, GitHub PR, CI, git), decides the next action, executes it, and updates the status tag. Set `SUPERVISOR_AI_LIFECYCLE=false` to fall back to the legacy `cmd_pr_lifecycle` bash heuristics.

## Blocker Statuses

Add these tags to tasks that need human action before they can proceed. The supervisor's eligibility assessment detects them and skips dispatch: `account-needed`, `hosting-needed`, `login-needed`, `api-key-needed`, `clarification-needed`, `resources-needed`, `payment-needed`, `approval-needed`, `decision-needed`, `design-needed`, `content-needed`, `dns-needed`, `domain-needed`, `testing-needed`.

## Auto-Subtasking

(t1188.2): Tasks with estimates >4h that have no existing subtasks are flagged as `needs-subtasking` in the eligibility assessment. The AI reasoner uses `create_subtasks` to break them into dispatchable units (~30m-4h each) before attempting dispatch. Tasks that already have subtasks are flagged as `has-subtasks` — the supervisor dispatches the subtasks instead.

## Cross-Repo Concurrency Fairness

(t1188.2): When multiple repos have queued tasks, each repo gets at least 1 dispatch slot, then remaining slots are distributed proportionally by queued task count. This prevents one repo's large backlog from starving other repos.

## Stale-Claim Auto-Recovery

(t1263): When interactive sessions claim tasks (assignee: + started:) but die or move on without completing them, the tasks become permanently stuck. Phase 0.5e of the pulse cycle detects stale claims: tasks with assignee:/started: that have (1) no active worker in the supervisor DB, (2) no active worktree, and (3) claim age >24h. It auto-unclaims by stripping assignee: and started: fields so auto-pickup can re-dispatch. Respects t1017 assignee ownership: only unclaims tasks assigned to the local user. Configure threshold: `SUPERVISOR_STALE_CLAIM_SECONDS` (default: 86400 = 24h). Manual check: `supervisor-helper.sh stale-claims [--repo path]`.

## Task Completion Rules

CRITICAL — prevents false completion cascade:

### PR Lookup Fallback (t1343)

When verifying whether a merged PR exists for a task, NEVER rely on a single data source. Workers and supervisors may run in different sessions with different local state. Use this fallback chain:

1. **Local DB/memory** — check your own session's record of the PR URL
2. **GitHub search** — if local lookup fails, search GitHub directly:

   ```bash
   gh pr list --repo <owner/repo> --state merged --search "<task_id>" --json number,title,mergedAt --limit 5
   ```

3. **Issue cross-reference** — check the linked issue for PR references in comments:

   ```bash
   gh api repos/<owner/repo>/issues/<issue_number>/timeline --jq '[.[] | select(.event=="cross-referenced") | .source.issue.pull_request.html_url // empty] | unique[]'
   ```

If ANY source confirms a merged PR, treat the task as having PR evidence. The race condition in Issue #2250 occurred because a worker only checked its own DB (source 1), missed the PR created by a different session, and incorrectly flagged the issue as `needs-review`.

- NEVER mark a task `[x]` unless a merged PR exists with real deliverables for that task
- Use `task-complete-helper.sh <task-id> --pr <number>` or `task-complete-helper.sh <task-id> --verified` to mark tasks complete in interactive sessions
- The helper enforces proof-log requirements: every completion MUST have `pr:#NNN` or `verified:YYYY-MM-DD`
- The supervisor `update_todo_on_complete()` enforces the same requirement for autonomous workers
- The pre-commit hook rejects TODO.md commits where `[ ] -> [x]` without proof-log
- Checking that a file exists is NOT sufficient - verify the PR was merged and contains substantive changes
- If a worker completes with `no_pr` or `task_only`, the task stays `[ ]` until a human or the supervisor verifies the deliverable
- The `issue-sync` GitHub Action auto-closes issues when tasks are marked `[x]` - false completions cascade into closed issues
- NEVER close GitHub issues manually with `gh issue close` — let the issue-sync pipeline verify deliverables (`pr:` or `verified:` field) before closing. Manual closure bypasses the proof-log safety check
- **Pre-commit enforcement**: The pre-commit hook checks TODO.md for newly completed tasks (`[ ]` → `[x]`) and warns if no `verified:` field or merged PR evidence exists. This is a warning only (commit proceeds) but serves as a reminder to add completion evidence.

## Planning File Workflow

**After ANY TODO/planning edit** (interactive sessions only, NOT workers): Commit and push immediately. Planning-only files (TODO.md, todo/) go directly to main — no branch, no PR. Mixed changes (planning + non-exception files) use a worktree. NEVER `git checkout -b` in the main repo.

**PR required for ALL non-planning changes** (MANDATORY): Every change to scripts, agents, configs, workflows, or any file outside `TODO.md`, `todo/`, and `VERIFY.md` MUST go through a worktree + PR + CI pipeline — no matter how small. "It's just one line" is not a valid reason to skip CI. The pre-edit-check script enforces this; never bypass it by editing directly on main.

## Task ID Allocation

MANDATORY: Use `/new-task` or `claim-task-id.sh` to allocate task IDs. NEVER manually scan TODO.md with grep to determine the next ID — this causes collisions in parallel sessions. The allocation flow:

1. `/new-task "Task title"` — interactive slash command (preferred in sessions)
2. `planning-commit-helper.sh next-id --title "Task title"` — wrapper function
3. `claim-task-id.sh --title "Task title" --repo-path "$(pwd)"` — direct script

**Atomic counter** (t1047): Task IDs are allocated from `.task-counter` — a single file in the repo root containing the next available integer. The allocation uses a CAS (compare-and-swap) loop: fetch counter from `origin/main`, increment, commit, push. If push fails (another session grabbed an ID), retry from fetch. This guarantees no two sessions can claim the same ID. Batch allocation: `--count N` claims N consecutive IDs in one atomic push. GitHub/GitLab issue creation happens after the ID is secured (optional, non-blocking). Offline fallback reads local `.task-counter` + 100 offset (reconcile when back online). Output format: `task_id=tNNN ref=GH#NNN` (offline: `ref=offline reconcile=true`; batch: adds `task_id_last=tNNN task_count=N`).

**Task ID collision prevention**: The `.task-counter` CAS loop handles this automatically. If push fails, the script retries (up to 10 attempts with backoff). No manual intervention needed.

## Worker TODO.md Restriction

Workers must NEVER edit TODO.md. See `workflows/plans.md` "Worker TODO.md Restriction".
