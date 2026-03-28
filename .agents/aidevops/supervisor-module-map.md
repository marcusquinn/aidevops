# Supervisor Module Map

Audit of `supervisor-helper.sh` — 155 functions, 14,644 lines. Produced by t311.1 to guide modularisation (t311).

### 1. Core Infrastructure (core) — dependant: every domain
| Function | Line | Description |
|----------|------|-------------|
| `log_info` | 236 | Info-level logging |
| `log_success` | 237 | Success-level logging |
| `log_warn` | 238 | Warning-level logging |
| `log_error` | 239 | Error-level logging |
| `log_verbose` | 240 | Verbose debug logging |
| `log_cmd` | 448 | Log stderr from a command to supervisor log |
| `sql_escape` | 1134 | Escape single quotes for SQL |
| `db` | 1143 | SQLite wrapper with busy_timeout |
| `find_project_root` | 1097 | Find directory containing TODO.md |
| `detect_repo_slug` | 1116 | Detect GitHub owner/repo from git remote |
| `check_gh_auth` | 398 | Check GitHub CLI authentication |
| `get_cpu_cores` | 557 | Get CPU core count |
| `show_usage` | 14268 | Show CLI help text |
| `main` | 14593 | CLI dispatch entry point |
### 2. Database (database) — depends on: core
| Function | Line | Description |
|----------|------|-------------|
| `backup_db` | 1152 | Backup supervisor database |
| `safe_migrate` | 1190 | Schema migration with backup and rollback |
| `restore_db` | 1231 | Restore database from backup |
| `ensure_db` | 1280 | Ensure DB directory and file exist |
| `init_db` | 1653 | Initialize SQLite schema |
| `validate_transition` | 1770 | Validate state machine transitions |
| `cmd_init` | 1787 | CLI: `init` |
| `cmd_backup` | 1803 | CLI: `backup` |
| `cmd_restore` | 1811 | CLI: `restore` |
| `cmd_db` | 3361 | CLI: `db` (direct SQLite access) |
### 3. Task Management (task) — depends on: core, database
| Function | Line | Description |
|----------|------|-------------|
| `cmd_add` | 1819 | CLI: `add` — register a task |
| `cmd_batch` | 1938 | CLI: `batch` — create/manage batches |
| `cmd_transition` | 2037 | CLI: `transition` — state machine transitions |
| `check_batch_completion` | 2345 | Check if all tasks in a batch are done |
| `cmd_status` | 2417 | CLI: `status` — show task/batch status |
| `cmd_list` | 2624 | CLI: `list` — list tasks with filters |
| `cmd_reset` | 2710 | CLI: `reset` — reset task to queued |
| `cmd_cancel` | 2780 | CLI: `cancel` — cancel task or batch |
| `cmd_next` | 3408 | CLI: `next` — get next dispatchable tasks |
| `cmd_running_count` | 3377 | CLI: `running-count` — count active tasks |
| `check_task_already_done` | 3190 | Pre-dispatch: verify task not already complete |
### 4. Task Claiming (claiming) — depends on: core, database, todo-sync
| Function | Line | Description |
|----------|------|-------------|
| `get_aidevops_identity` | 2925 | Get identity string for claiming |
| `get_task_assignee` | 2957 | Read assignee: from TODO.md task line |
| `cmd_claim` | 2986 | CLI: `claim` — claim a task |
| `cmd_unclaim` | 3101 | CLI: `unclaim` — release a claimed task |
| `check_task_claimed` | 3272 | Check if task is claimed by another agent |
| `sync_claim_to_github` | 3319 | Sync claim to GitHub Issue assignee |
| `ensure_status_labels` | 2874 | Ensure GitHub status labels exist |
| `find_task_issue_number` | 2894 | Find GitHub issue # from TODO.md |
### 5. Dispatch (dispatch) — depends on: core, database, task, claiming
| Function | Line | Description |
|----------|------|-------------|
| `detect_dispatch_mode` | 3445 | Detect terminal environment |
| `resolve_ai_cli` | 3468 | Resolve AI CLI tool for dispatch |
| `resolve_model` | 3497 | Resolve best model for a tier |
| `resolve_model_from_frontmatter` | 3571 | Read model: from subagent YAML |
| `classify_task_complexity` | 3630 | Classify task for model routing |
| `resolve_task_model` | 3798 | Resolve model for a specific task |
| `get_next_tier` | 3905 | Get next higher model tier for escalation |
| `check_output_quality` | 3953 | Check worker output quality |
| `run_quality_gate` | 4058 | Quality gate with auto-escalation |
| `check_model_health` | 4154 | Pre-dispatch model health probe |
| `generate_worker_mcp_config` | 4354 | Generate worker MCP config |
| `build_dispatch_cmd` | 4404 | Build the full dispatch command |
| `create_task_worktree` | 4635 | Create git worktree for a task |
| `cmd_dispatch` | 5140 | CLI: `dispatch` — dispatch a single task |
| `dispatch_decomposition_worker` | 12903 | Dispatch a #plan decomposition worker |
### 6. Worker Lifecycle (lifecycle) — depends on: core, database, dispatch
| Function | Line | Description |
|----------|------|-------------|
| `cmd_worker_status` | 5538 | CLI: `worker-status` — check worker process |
| `extract_log_tail` | 5628 | Extract last N lines from worker log |
| `extract_log_metadata` | 5645 | Extract structured outcome from log |
| `evaluate_worker` | 6261 | Evaluate worker outcome from logs |
| `_meta_get` | 6356 | Helper: extract key=value from metadata (nested) |
| `evaluate_with_ai` | 6636 | AI-assisted evaluation of ambiguous outcomes |
| `cmd_reprompt` | 6726 | CLI: `reprompt` — re-prompt a worker |
| `cmd_evaluate` | 7024 | CLI: `evaluate` — manually evaluate a task |
| `cleanup_task_worktree` | 4830 | Clean up worktree for completed task |
| `cleanup_worker_processes` | 4885 | Kill worker process tree |
| `_kill_descendants` | 4924 | Recursively kill descendant processes |
| `_list_descendants` | 4943 | List all descendant PIDs |
| `cmd_kill_workers` | 4960 | CLI: `kill-workers` — emergency cleanup |
| `cmd_cleanup` | 10334 | CLI: `cleanup` — clean completed worktrees |
### 7. PR Management (pr) — depends on: core, database, task, dispatch, lifecycle
| Function | Line | Description |
|----------|------|-------------|
| `validate_pr_belongs_to_task` | 5790 | Validate PR title/branch matches task |
| `parse_pr_url` | 5860 | Parse PR URL into slug + number |
| `discover_pr_by_branch` | 5900 | Find PR via branch name lookup |
| `auto_create_pr_for_task` | 5963 | Auto-create PR for orphaned branch |
| `link_pr_to_task` | 6086 | Link PR to task (single source of truth) |
| `check_review_threads` | 7091 | Fetch unresolved review threads (GraphQL) |
| `triage_review_feedback` | 7179 | Triage review feedback by severity |
| `dispatch_review_fix_worker` | 7262 | Dispatch worker to fix review feedback |
| `dismiss_bot_reviews` | 7492 | Dismiss blocking bot reviews |
| `check_pr_status` | 7550 | Check PR CI and review status |
| `scan_orphaned_prs` | 7785 | Scan for PRs supervisor missed |
| `scan_orphaned_pr_for_task` | 7936 | Eager orphan PR scan for one task |
| `cmd_pr_check` | 8019 | CLI: `pr-check` |
| `get_sibling_tasks` | 8062 | Get sibling subtasks |
| `rebase_sibling_pr` | 8105 | Rebase a sibling PR onto main |
| `rebase_sibling_prs_after_merge` | 8198 | Rebase all sibling PRs after merge |
| `merge_task_pr` | 8252 | Squash-merge a task's PR |
| `cmd_pr_merge` | 8357 | CLI: `pr-merge` |
| `run_postflight_for_task` | 8395 | Run postflight checks after merge |
| `run_deploy_for_task` | 8424 | Run deploy for aidevops repos |
| `cleanup_after_merge` | 8538 | Clean up worktree after merge |
| `record_lifecycle_timing` | 8608 | Record PR lifecycle timing metrics |
| `cmd_pr_lifecycle` | 8664 | CLI: `pr-lifecycle` — full post-PR lifecycle |
| `extract_parent_id` | 9278 | Extract parent from subtask ID |
| `process_post_pr_lifecycle` | 9299 | Process post-PR lifecycle for all eligible |
### 8. Pulse Orchestration (pulse) — depends on: ALL domains
| Function | Line | Description |
|----------|------|-------------|
| `acquire_pulse_lock` | 481 | Acquire exclusive pulse lock |
| `release_pulse_lock` | 542 | Release pulse lock |
| `check_system_load` | 587 | Check CPU/memory/load pressure |
| `calculate_adaptive_concurrency` | 1037 | Dynamic worker count from load |
| `cmd_pulse` | 9390 | CLI: `pulse` — the main orchestration loop |
| `cmd_auto_pickup` | 13100 | CLI: `auto-pickup` — scan TODO.md for tasks |
| `cmd_cron` | 13356 | CLI: `cron` — manage cron scheduling |
| `cmd_watch` | 13473 | CLI: `watch` — fswatch TODO.md |

`cmd_pulse` calls 42 functions across all 17 domains.
### 9. TODO Sync (todo-sync) — depends on: core, database, pr
| Function | Line | Description |
|----------|------|-------------|
| `create_github_issue` | 10448 | Create GitHub issue for a task |
| `commit_and_push_todo` | 10535 | Commit and push TODO.md with retry |
| `verify_task_deliverables` | 10597 | Verify task has real deliverables |
| `update_todo_on_complete` | 11192 | Mark task done in TODO.md |
| `post_blocked_comment_to_github` | 11526 | Post blocked comment to GH issue |
| `update_todo_on_blocked` | 11603 | Update TODO.md for blocked/failed task |
| `cmd_update_todo` | 12710 | CLI: `update-todo` |
| `cmd_reconcile_todo` | 12764 | CLI: `reconcile-todo` — bulk fix stale entries |
### 10. Verification (verify) — depends on: core, database, todo-sync, pr
| Function | Line | Description |
|----------|------|-------------|
| `populate_verify_queue` | 10701 | Populate VERIFY.md after PR merge |
| `run_verify_checks` | 10852 | Run verification checks for a task |
| `mark_verify_entry` | 11011 | Mark verify entry passed/failed |
| `process_verify_queue` | 11037 | Process verification queue (t180.3) |
| `cmd_verify` | 11103 | CLI: `verify` |
| `commit_verify_changes` | 11164 | Commit and push VERIFY.md |
| `generate_verify_entry` | 11305 | Generate VERIFY.md entry for a task |
| `process_verify_queue` | 11440 | Process pending verifications (t180.4 — active, shadows t180.3) |

**Bug**: `process_verify_queue` defined twice (lines 11037 and 11440). Deduplicate before splitting — keep t180.4 version.
### 11. Recovery & Self-Healing (recovery) — depends on: core, database, task
| Function | Line | Description |
|----------|------|-------------|
| `is_self_heal_eligible` | 12017 | Check if task qualifies for self-heal |
| `create_diagnostic_subtask` | 12066 | Create diagnostic subtask in DB |
| `attempt_self_heal` | 12166 | Attempt self-heal for failed task |
| `handle_diagnostic_completion` | 12202 | Re-queue parent after diagnostic completes |
| `cmd_self_heal` | 12248 | CLI: `self-heal` |
### 12. Release & Retrospective (release) — depends on: core, database, task
| Function | Line | Description |
|----------|------|-------------|
| `trigger_batch_release` | 2198 | Trigger release via version-manager.sh |
| `run_batch_retrospective` | 12306 | Run retrospective after batch completion |
| `run_session_review` | 12426 | Session review and distillation |
| `cmd_release` | 12520 | CLI: `release` |
| `cmd_retrospective` | 12640 | CLI: `retrospective` |
### 13. Memory & Patterns (memory) — depends on: core, database
| Function | Line | Description |
|----------|------|-------------|
| `recall_task_memories` | 11788 | Recall relevant memories before dispatch |
| `store_failure_pattern` | 11838 | Store failure pattern after evaluation |
| `store_success_pattern` | 11926 | Store success pattern after completion |
| `cmd_recall` | 12670 | CLI: `recall` |
### 14. Notifications (notify) — depends on: core, database
| Function | Line | Description |
|----------|------|-------------|
| `send_task_notification` | 11672 | Send notification about state change |
| `notify_batch_progress` | 11751 | macOS notification for batch milestones |
| `cmd_notify` | 12858 | CLI: `notify` |
### 15. Proof Log & Audit (audit) — depends on: core, database
| Function | Line | Description |
|----------|------|-------------|
| `write_proof_log` | 269 | Write structured proof-log entry |
| `_proof_log_stage_duration` | 346 | Calculate stage duration |
| `cmd_proof_log` | 14052 | CLI: `proof-log` — query/export proof-logs |
### 16. System Resources (system) — depends on: core, database
| Function | Line | Description |
|----------|------|-------------|
| `get_process_footprint_mb` | 721 | Get physical memory footprint |
| `check_supervisor_memory` | 802 | Check if supervisor should respawn |
| `log_respawn_event` | 869 | Log respawn to persistent history |
| `attempt_respawn_after_batch` | 898 | Check/trigger respawn after batch wave |
| `cmd_respawn_history` | 989 | CLI: `respawn-history` |
| `cmd_mem_check` | 5056 | CLI: `mem-check` |
### 17. Dashboard (dashboard) — depends on: core, database, system
| Function | Line | Description |
|----------|------|-------------|
| `cmd_dashboard` | 13531 | CLI: `dashboard` — live TUI |
| `_dashboard_cleanup` | 13562 | Cleanup on exit (nested) |
| `_fmt_elapsed` | 13582 | Format elapsed time (nested) |
| `_render_bar` | 13597 | Render progress bar (nested) |
| `_status_color` | 13617 | Status colour code (nested) |
| `_status_icon` | 13633 | Status icon (nested) |
| `_trunc` | 13659 | Truncate string (nested) |
| `_render_frame` | 13669 | Render one dashboard frame (nested) |

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

## Module Assignment

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

1. **`cmd_pulse` is the god function** — 943 lines, calls 42 functions across all 17 domains. Primary candidate for decomposition into phase-based sub-functions.
2. **`cmd_pr_lifecycle` is the second-largest orchestrator** — 613 lines, 27 internal calls.
3. **Duplicate `process_verify_queue`** — defined at lines 11037 (t180.3) and 11440 (t180.4). Second shadows first. Deduplicate before splitting.
4. **Recursive `main()` re-entry** — 11 functions call `main()` to re-invoke CLI commands. Replace with direct function calls during modularisation.
5. **Core utilities called everywhere** — `db` (77 callers), `sql_escape` (67), `log_info` (64), `log_warn` (55), `ensure_db` (54), `log_error` (52). Must be sourced first.
6. **`cmd_transition` serves dual purpose** — called from CLI and by 11 other functions; the state machine backbone.
7. **Nested functions** — `_meta_get` inside `evaluate_worker`; 7 `_dashboard_*` inside `cmd_dashboard`. Stay with parent modules.
8. **Source order** — core → database → task → claiming → dispatch → lifecycle → pr → todo-sync → verify → recovery → release → memory → notify → audit → system → dashboard → pulse (last).


## Modularisation Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| `main()` re-entry breaks when split | High | Replace `main transition` calls with direct `cmd_transition` calls |
| Source order dependencies | Medium | Document required source order; use `source_if_needed` guard |
| Duplicate `process_verify_queue` | Low | Deduplicate before splitting — keep t180.4 version |
| Global variables shared across modules | Medium | Audit globals; pass via function args or a shared config module |
| Testing regression | Medium | Run full pulse cycle test after each module extraction |
