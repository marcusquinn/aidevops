# Supervisor Module Map

Audit of `supervisor-helper.sh` — 155 functions across 14,644 lines.
Produced by t311.1. Use this map to guide modularisation (t311).

## Domain Groups

### 1. Core Infrastructure (core)

Foundation utilities used by nearly every other domain.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `log_info` | 236 | Info-level logging |
| 2 | `log_success` | 237 | Success-level logging |
| 3 | `log_warn` | 238 | Warning-level logging |
| 4 | `log_error` | 239 | Error-level logging |
| 5 | `log_verbose` | 240 | Verbose debug logging |
| 6 | `log_cmd` | 448 | Log stderr from a command to supervisor log |
| 7 | `sql_escape` | 1134 | Escape single quotes for SQL |
| 8 | `db` | 1143 | SQLite wrapper with busy_timeout |
| 9 | `find_project_root` | 1097 | Find directory containing TODO.md |
| 10 | `detect_repo_slug` | 1116 | Detect GitHub owner/repo from git remote |
| 11 | `check_gh_auth` | 398 | Check GitHub CLI authentication |
| 12 | `get_cpu_cores` | 557 | Get CPU core count |
| 13 | `show_usage` | 14268 | Show CLI help text |
| 14 | `main` | 14593 | CLI dispatch entry point |

**Dependants**: Every other domain depends on core.

### 2. Database (database)

Schema management, backup/restore, migration.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `backup_db` | 1152 | Backup supervisor database |
| 2 | `safe_migrate` | 1190 | Schema migration with backup and rollback |
| 3 | `restore_db` | 1231 | Restore database from backup |
| 4 | `ensure_db` | 1280 | Ensure DB directory and file exist |
| 5 | `init_db` | 1653 | Initialize SQLite schema |
| 6 | `validate_transition` | 1770 | Validate state machine transitions |
| 7 | `cmd_init` | 1787 | CLI: `init` |
| 8 | `cmd_backup` | 1803 | CLI: `backup` |
| 9 | `cmd_restore` | 1811 | CLI: `restore` |
| 10 | `cmd_db` | 3361 | CLI: `db` (direct SQLite access) |

**Depends on**: core

### 3. Task Management (task)

CRUD operations for tasks and batches, state transitions, querying.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `cmd_add` | 1819 | CLI: `add` — register a task |
| 2 | `cmd_batch` | 1938 | CLI: `batch` — create/manage batches |
| 3 | `cmd_transition` | 2037 | CLI: `transition` — state machine transitions |
| 4 | `check_batch_completion` | 2345 | Check if all tasks in a batch are done |
| 5 | `cmd_status` | 2417 | CLI: `status` — show task/batch status |
| 6 | `cmd_list` | 2624 | CLI: `list` — list tasks with filters |
| 7 | `cmd_reset` | 2710 | CLI: `reset` — reset task to queued |
| 8 | `cmd_cancel` | 2780 | CLI: `cancel` — cancel task or batch |
| 9 | `cmd_next` | 3408 | CLI: `next` — get next dispatchable tasks |
| 10 | `cmd_running_count` | 3377 | CLI: `running-count` — count active tasks |
| 11 | `check_task_already_done` | 3190 | Pre-dispatch: verify task not already complete |

**Depends on**: core, database

### 4. Task Claiming (claiming)

Ownership assignment via TODO.md `assignee:` field and GitHub Issue sync.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `get_aidevops_identity` | 2925 | Get identity string for claiming |
| 2 | `get_task_assignee` | 2957 | Read assignee: from TODO.md task line |
| 3 | `cmd_claim` | 2986 | CLI: `claim` — claim a task |
| 4 | `cmd_unclaim` | 3101 | CLI: `unclaim` — release a claimed task |
| 5 | `check_task_claimed` | 3272 | Check if task is claimed by another agent |
| 6 | `sync_claim_to_github` | 3319 | Sync claim to GitHub Issue assignee |
| 7 | `ensure_status_labels` | 2874 | Ensure GitHub status labels exist |
| 8 | `find_task_issue_number` | 2894 | Find GitHub issue # from TODO.md |

**Depends on**: core, database, todo-sync (commit_and_push_todo)

### 5. Dispatch (dispatch)

Worker dispatch: model resolution, CLI resolution, command building, worktree creation.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `detect_dispatch_mode` | 3445 | Detect terminal environment |
| 2 | `resolve_ai_cli` | 3468 | Resolve AI CLI tool for dispatch |
| 3 | `resolve_model` | 3497 | Resolve best model for a tier |
| 4 | `resolve_model_from_frontmatter` | 3571 | Read model: from subagent YAML |
| 5 | `classify_task_complexity` | 3630 | Classify task for model routing |
| 6 | `resolve_task_model` | 3798 | Resolve model for a specific task |
| 7 | `get_next_tier` | 3905 | Get next higher model tier for escalation |
| 8 | `check_output_quality` | 3953 | Check worker output quality |
| 9 | `run_quality_gate` | 4058 | Quality gate with auto-escalation |
| 10 | `check_model_health` | 4154 | Pre-dispatch model health probe |
| 11 | `generate_worker_mcp_config` | 4354 | Generate worker MCP config |
| 12 | `build_dispatch_cmd` | 4404 | Build the full dispatch command |
| 13 | `create_task_worktree` | 4635 | Create git worktree for a task |
| 14 | `cmd_dispatch` | 5140 | CLI: `dispatch` — dispatch a single task |
| 15 | `dispatch_decomposition_worker` | 12903 | Dispatch a #plan decomposition worker |

**Depends on**: core, database, task, claiming

### 6. Worker Lifecycle (lifecycle)

Worker monitoring, evaluation, reprompting, process management.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `cmd_worker_status` | 5538 | CLI: `worker-status` — check worker process |
| 2 | `extract_log_tail` | 5628 | Extract last N lines from worker log |
| 3 | `extract_log_metadata` | 5645 | Extract structured outcome from log |
| 4 | `evaluate_worker` | 6261 | Evaluate worker outcome from logs |
| 5 | `_meta_get` | 6356 | Helper: extract key=value from metadata |
| 6 | `evaluate_with_ai` | 6636 | AI-assisted evaluation of ambiguous outcomes |
| 7 | `cmd_reprompt` | 6726 | CLI: `reprompt` — re-prompt a worker |
| 8 | `cmd_evaluate` | 7024 | CLI: `evaluate` — manually evaluate a task |
| 9 | `cleanup_task_worktree` | 4830 | Clean up worktree for completed task |
| 10 | `cleanup_worker_processes` | 4885 | Kill worker process tree |
| 11 | `_kill_descendants` | 4924 | Recursively kill descendant processes |
| 12 | `_list_descendants` | 4943 | List all descendant PIDs |
| 13 | `cmd_kill_workers` | 4960 | CLI: `kill-workers` — emergency cleanup |
| 14 | `cmd_cleanup` | 10334 | CLI: `cleanup` — clean completed worktrees |

**Depends on**: core, database, dispatch (resolve_ai_cli, resolve_model)

### 7. PR Management (pr)

PR discovery, linking, status checking, review triage, merge, rebase.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `validate_pr_belongs_to_task` | 5790 | Validate PR title/branch matches task |
| 2 | `parse_pr_url` | 5860 | Parse PR URL into slug + number |
| 3 | `discover_pr_by_branch` | 5900 | Find PR via branch name lookup |
| 4 | `auto_create_pr_for_task` | 5963 | Auto-create PR for orphaned branch |
| 5 | `link_pr_to_task` | 6086 | Link PR to task (single source of truth) |
| 6 | `check_review_threads` | 7091 | Fetch unresolved review threads (GraphQL) |
| 7 | `triage_review_feedback` | 7179 | Triage review feedback by severity |
| 8 | `dispatch_review_fix_worker` | 7262 | Dispatch worker to fix review feedback |
| 9 | `dismiss_bot_reviews` | 7492 | Dismiss blocking bot reviews |
| 10 | `check_pr_status` | 7550 | Check PR CI and review status |
| 11 | `scan_orphaned_prs` | 7785 | Scan for PRs supervisor missed |
| 12 | `scan_orphaned_pr_for_task` | 7936 | Eager orphan PR scan for one task |
| 13 | `cmd_pr_check` | 8019 | CLI: `pr-check` |
| 14 | `get_sibling_tasks` | 8062 | Get sibling subtasks |
| 15 | `rebase_sibling_pr` | 8105 | Rebase a sibling PR onto main |
| 16 | `rebase_sibling_prs_after_merge` | 8198 | Rebase all sibling PRs after merge |
| 17 | `merge_task_pr` | 8252 | Squash-merge a task's PR |
| 18 | `cmd_pr_merge` | 8357 | CLI: `pr-merge` |
| 19 | `run_postflight_for_task` | 8395 | Run postflight checks after merge |
| 20 | `run_deploy_for_task` | 8424 | Run deploy for aidevops repos |
| 21 | `cleanup_after_merge` | 8538 | Clean up worktree after merge |
| 22 | `record_lifecycle_timing` | 8608 | Record PR lifecycle timing metrics |
| 23 | `cmd_pr_lifecycle` | 8664 | CLI: `pr-lifecycle` — full post-PR lifecycle |
| 24 | `extract_parent_id` | 9278 | Extract parent from subtask ID |
| 25 | `process_post_pr_lifecycle` | 9299 | Process post-PR lifecycle for all eligible |

**Depends on**: core, database, task, dispatch (for review-fix workers), lifecycle (cleanup)

### 8. Pulse Orchestration (pulse)

The central autonomous loop that drives all other domains.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `acquire_pulse_lock` | 481 | Acquire exclusive pulse lock |
| 2 | `release_pulse_lock` | 542 | Release pulse lock |
| 3 | `check_system_load` | 587 | Check CPU/memory/load pressure |
| 4 | `calculate_adaptive_concurrency` | 1037 | Dynamic worker count from load |
| 5 | `cmd_pulse` | 9390 | CLI: `pulse` — the main orchestration loop |
| 6 | `cmd_auto_pickup` | 13100 | CLI: `auto-pickup` — scan TODO.md for tasks |
| 7 | `cmd_cron` | 13356 | CLI: `cron` — manage cron scheduling |
| 8 | `cmd_watch` | 13473 | CLI: `watch` — fswatch TODO.md |

**Depends on**: ALL other domains. `cmd_pulse` calls 42 functions across every domain.

### 9. TODO Sync (todo-sync)

Synchronising task state with TODO.md and GitHub Issues.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `create_github_issue` | 10448 | Create GitHub issue for a task |
| 2 | `commit_and_push_todo` | 10535 | Commit and push TODO.md with retry |
| 3 | `verify_task_deliverables` | 10597 | Verify task has real deliverables |
| 4 | `update_todo_on_complete` | 11192 | Mark task done in TODO.md |
| 5 | `post_blocked_comment_to_github` | 11526 | Post blocked comment to GH issue |
| 6 | `update_todo_on_blocked` | 11603 | Update TODO.md for blocked/failed task |
| 7 | `cmd_update_todo` | 12710 | CLI: `update-todo` |
| 8 | `cmd_reconcile_todo` | 12764 | CLI: `reconcile-todo` — bulk fix stale entries |

**Depends on**: core, database, pr (for deliverable verification)

### 10. Verification (verify)

Post-merge verification via VERIFY.md queue.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `populate_verify_queue` | 10701 | Populate VERIFY.md after PR merge |
| 2 | `run_verify_checks` | 10852 | Run verification checks for a task |
| 3 | `mark_verify_entry` | 11011 | Mark verify entry passed/failed |
| 4 | `process_verify_queue` | 11037 | Process verification queue (t180.3) |
| 5 | `cmd_verify` | 11103 | CLI: `verify` |
| 6 | `commit_verify_changes` | 11164 | Commit and push VERIFY.md |
| 7 | `generate_verify_entry` | 11305 | Generate VERIFY.md entry for a task |
| 8 | `process_verify_queue` | 11440 | Process pending verifications (t180.4, shadows t180.3) |

**Note**: `process_verify_queue` is defined twice (lines 11037 and 11440). The second definition shadows the first at runtime. This is a bug — the t180.4 version at line 11440 is the active one.

**Depends on**: core, database, todo-sync (commit_and_push_todo), pr (parse_pr_url)

### 11. Recovery & Self-Healing (recovery)

Diagnostic subtask creation, self-healing for failed tasks.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `is_self_heal_eligible` | 12017 | Check if task qualifies for self-heal |
| 2 | `create_diagnostic_subtask` | 12066 | Create diagnostic subtask in DB |
| 3 | `attempt_self_heal` | 12166 | Attempt self-heal for failed task |
| 4 | `handle_diagnostic_completion` | 12202 | Re-queue parent after diagnostic completes |
| 5 | `cmd_self_heal` | 12248 | CLI: `self-heal` |

**Depends on**: core, database, task (cmd_reset)

### 12. Release & Retrospective (release)

Batch release triggering, retrospectives, session review.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `trigger_batch_release` | 2198 | Trigger release via version-manager.sh |
| 2 | `run_batch_retrospective` | 12306 | Run retrospective after batch completion |
| 3 | `run_session_review` | 12426 | Session review and distillation |
| 4 | `cmd_release` | 12520 | CLI: `release` |
| 5 | `cmd_retrospective` | 12640 | CLI: `retrospective` |

**Depends on**: core, database, task (check_batch_completion triggers release)

### 13. Memory & Patterns (memory)

Cross-session memory recall and pattern tracking.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `recall_task_memories` | 11788 | Recall relevant memories before dispatch |
| 2 | `store_failure_pattern` | 11838 | Store failure pattern after evaluation |
| 3 | `store_success_pattern` | 11926 | Store success pattern after completion |
| 4 | `cmd_recall` | 12670 | CLI: `recall` |

**Depends on**: core, database

### 14. Notifications (notify)

macOS notifications and inter-agent mail.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `send_task_notification` | 11672 | Send notification about state change |
| 2 | `notify_batch_progress` | 11751 | macOS notification for batch milestones |
| 3 | `cmd_notify` | 12858 | CLI: `notify` |

**Depends on**: core, database

### 15. Proof Log & Audit (audit)

Structured audit trail for task lifecycle.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `write_proof_log` | 269 | Write structured proof-log entry |
| 2 | `_proof_log_stage_duration` | 346 | Calculate stage duration |
| 3 | `cmd_proof_log` | 14052 | CLI: `proof-log` — query/export proof-logs |

**Depends on**: core, database

### 16. System Resources (system)

Memory monitoring, respawn management, system load.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `get_process_footprint_mb` | 721 | Get physical memory footprint |
| 2 | `check_supervisor_memory` | 802 | Check if supervisor should respawn |
| 3 | `log_respawn_event` | 869 | Log respawn to persistent history |
| 4 | `attempt_respawn_after_batch` | 898 | Check/trigger respawn after batch wave |
| 5 | `cmd_respawn_history` | 989 | CLI: `respawn-history` |
| 6 | `cmd_mem_check` | 5056 | CLI: `mem-check` |

**Depends on**: core, database

### 17. Dashboard (dashboard)

Terminal UI for monitoring.

| # | Function | Line | Description |
|---|----------|------|-------------|
| 1 | `cmd_dashboard` | 13531 | CLI: `dashboard` — live TUI |
| 2 | `_dashboard_cleanup` | 13562 | Cleanup on exit (nested) |
| 3 | `_fmt_elapsed` | 13582 | Format elapsed time (nested) |
| 4 | `_render_bar` | 13597 | Render progress bar (nested) |
| 5 | `_status_color` | 13617 | Status colour code (nested) |
| 6 | `_status_icon` | 13633 | Status icon (nested) |
| 7 | `_trunc` | 13659 | Truncate string (nested) |
| 8 | `_render_frame` | 13669 | Render one dashboard frame (nested) |

**Depends on**: core, database, system (check_system_load)

## Cross-Domain Dependency Matrix

Rows depend on columns. `X` = direct function calls exist between domains.

| Domain | core | database | task | claiming | dispatch | lifecycle | pr | pulse | todo-sync | verify | recovery | release | memory | notify | audit | system | dashboard |
|--------|------|----------|------|----------|----------|-----------|-----|-------|-----------|--------|----------|---------|--------|--------|-------|--------|-----------|
| **core** | - | | | | | | | | | | | | | | | | |
| **database** | X | - | | | | | | | | | | | | | | | |
| **task** | X | X | - | | | | | | | | | | | | | | |
| **claiming** | X | X | | - | | | | | X | | | | | | | | |
| **dispatch** | X | X | X | X | - | | | | | | | | X | | | | |
| **lifecycle** | X | X | | | X | - | | | | | | | | | | | |
| **pr** | X | X | X | | X | X | - | | X | | | | X | X | X | | |
| **pulse** | X | X | X | X | X | X | X | - | X | X | X | X | X | X | X | X | |
| **todo-sync** | X | X | | | | | X | | - | | | | | | X | | |
| **verify** | X | X | | | | | X | | X | - | | | | | X | | |
| **recovery** | X | X | X | | | | | | | | - | | | | | | |
| **release** | X | X | | | | | | | X | | | - | | X | | | |
| **memory** | X | X | | | | | | | | | | | - | | | | |
| **notify** | X | X | | | | | | | | | | | | - | | | |
| **audit** | X | X | | | | | | | | | | | | | - | | |
| **system** | X | X | | | | | | | | | | | | | | - | |
| **dashboard** | X | X | | | | | | | | | | | | | | X | - |

## Module Assignment Table

Proposed file names for modularisation. Each module is a sourceable shell library.

| Module File | Domain | Functions | Lines (est.) | CLI Commands |
|-------------|--------|-----------|-------------|--------------|
| `supervisor-core.sh` | core | 14 | ~250 | help |
| `supervisor-database.sh` | database | 10 | ~600 | init, backup, restore, db |
| `supervisor-task.sh` | task | 11 | ~900 | add, batch, transition, status, list, next, running-count, reset, cancel |
| `supervisor-claiming.sh` | claiming | 8 | ~500 | claim, unclaim |
| `supervisor-dispatch.sh` | dispatch | 15 | ~2,100 | dispatch |
| `supervisor-lifecycle.sh` | lifecycle | 14 | ~1,200 | evaluate, reprompt, worker-status, cleanup, kill-workers |
| `supervisor-pr.sh` | pr | 25 | ~2,800 | pr-lifecycle, pr-check, pr-merge, scan-orphaned-prs |
| `supervisor-pulse.sh` | pulse | 8 | ~1,500 | pulse, auto-pickup, cron, watch |
| `supervisor-todo-sync.sh` | todo-sync | 8 | ~700 | update-todo, reconcile-todo |
| `supervisor-verify.sh` | verify | 8 | ~600 | verify |
| `supervisor-recovery.sh` | recovery | 5 | ~300 | self-heal |
| `supervisor-release.sh` | release | 5 | ~500 | release, retrospective |
| `supervisor-memory.sh` | memory | 4 | ~250 | recall |
| `supervisor-notify.sh` | notify | 3 | ~200 | notify |
| `supervisor-audit.sh` | audit | 3 | ~250 | proof-log |
| `supervisor-system.sh` | system | 6 | ~400 | mem-check, respawn-history |
| `supervisor-dashboard.sh` | dashboard | 8 | ~550 | dashboard |
| **Total** | **17 modules** | **155** | **~13,600** | **42 commands** |

## Key Observations

1. **`cmd_pulse` is the god function** — 943 lines, calls 42 internal functions across all 17 domains. It is the primary candidate for decomposition into phase-based sub-functions.

2. **`cmd_pr_lifecycle` is the second-largest orchestrator** — 613 lines, 27 internal calls. Manages the complete PR lifecycle from status check through merge, deploy, and postflight.

3. **Duplicate function**: `process_verify_queue` is defined at both line 11037 (t180.3) and line 11440 (t180.4). The second shadows the first. Should be deduplicated.

4. **Recursive `main()` re-entry**: 11 functions call `main()` to re-invoke CLI commands. This pattern creates tight coupling — modularisation should replace these with direct function calls.

5. **Core utilities are called everywhere**: `db` (77 callers), `sql_escape` (67), `log_info` (64), `log_warn` (55), `ensure_db` (54), `log_error` (52). These must be in a shared core module sourced first.

6. **`cmd_transition` serves dual purpose**: Called from CLI and by 11 other functions. It is the state machine backbone — any module that changes task state depends on it.

7. **Nested functions**: `_meta_get` inside `evaluate_worker`, and 7 `_dashboard_*` functions inside `cmd_dashboard`. These stay with their parent modules.

8. **Source order matters**: Modules must be sourced in dependency order: core -> database -> task -> claiming -> dispatch -> lifecycle -> pr -> todo-sync -> verify -> recovery -> release -> memory -> notify -> audit -> system -> dashboard -> pulse (last, since it depends on everything).

## Modularisation Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| `main()` re-entry breaks when split | High | Replace `main transition` calls with direct `cmd_transition` calls |
| Source order dependencies | Medium | Document required source order; use `source_if_needed` guard |
| Duplicate `process_verify_queue` | Low | Deduplicate before splitting — keep t180.4 version |
| Global variables shared across modules | Medium | Audit globals; pass via function args or a shared config module |
| Testing regression | Medium | Run full pulse cycle test after each module extraction |
