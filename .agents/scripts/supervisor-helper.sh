#!/usr/bin/env bash
# supervisor-helper.sh - Autonomous supervisor for multi-task orchestration
#
# Manages long-running parallel objectives from dispatch through completion.
# Token-efficient: bash + SQLite only, AI invoked only for evaluation decisions.
#
# Usage:
#   supervisor-helper.sh init                          Initialize supervisor database
#   supervisor-helper.sh add <task_id> [--repo path] [--description "desc"] [--model model] [--max-retries N] [--with-issue]
#   supervisor-helper.sh batch <name> [--concurrency N] [--max-concurrency N] [--tasks "t001,t002,t003"]
#   supervisor-helper.sh claim <task_id>               Claim task via TODO.md assignee: (t165)
#   supervisor-helper.sh unclaim <task_id>             Release claimed task (t165)
#   supervisor-helper.sh dispatch <task_id> [--batch id] Dispatch a task (worktree + worker)
#   supervisor-helper.sh reprompt <task_id> [--prompt ""] Re-prompt a retrying task
#   supervisor-helper.sh evaluate <task_id> [--no-ai]  Evaluate a worker's outcome
#   supervisor-helper.sh pulse [--batch id]            Run supervisor pulse cycle
#   supervisor-helper.sh worker-status <task_id>       Check worker process status
#   supervisor-helper.sh cleanup [--dry-run]           Clean up completed worktrees + processes
#   supervisor-helper.sh kill-workers [--dry-run]      Kill orphaned worker processes (emergency)
#   supervisor-helper.sh mem-check                 Check supervisor session memory footprint
#   supervisor-helper.sh respawn-history [N]        Show last N respawn events (default: 20)
#   supervisor-helper.sh update-todo <task_id>         Update TODO.md for completed/blocked task
#   supervisor-helper.sh reconcile-todo [--batch id] [--dry-run]  Bulk-fix stale TODO.md entries
#   supervisor-helper.sh reconcile-db-todo [--batch id] [--dry-run]  Bidirectional DB<->TODO.md sync
#   supervisor-helper.sh reconcile-queue [--batch id] [--dry-run]  Sync DB queue with TODO.md dispatchability (t1180)
#   supervisor-helper.sh notify <task_id>              Send notification about task state
#   supervisor-helper.sh recall <task_id>              Recall memories relevant to a task
#   supervisor-helper.sh release [batch_id] [options]  Trigger or configure batch release (t128.10)
#   supervisor-helper.sh retrospective [batch_id]      Run batch retrospective and store insights
#   supervisor-helper.sh status [task_id|batch_id]     Show task/batch/overall status
#   supervisor-helper.sh transition <task_id> <new_state> [--error "reason"]
#   supervisor-helper.sh list [--state queued|running|...] [--batch name] [--format json]
#   supervisor-helper.sh reset <task_id>               Reset task to queued state
#   supervisor-helper.sh cancel <task_id|batch_id>     Cancel task or batch
#   supervisor-helper.sh auto-pickup [--repo path]      Scan TODO.md for #auto-dispatch tasks
#   supervisor-helper.sh batch-cleanup [scan|dispatch|status] [--repo path] [--dry-run]  Batch simple #chore tasks (t1146)
#   supervisor-helper.sh cron [install|uninstall|status] Manage cron-based pulse scheduling
#   supervisor-helper.sh watch [--repo path]            Watch TODO.md for changes (fswatch)
#   supervisor-helper.sh dashboard [--batch id] [--interval N] Live TUI dashboard (t068.8)
#   supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage] Handle post-PR lifecycle
#   supervisor-helper.sh pr-check <task_id>             Check PR CI/review status
#   supervisor-helper.sh scan-orphaned-prs [batch_id]   Scan for PRs workers created but supervisor missed (t210)
#   supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
#   supervisor-helper.sh verify <task_id>               Run post-merge verification checks (t180)
#   supervisor-helper.sh triage [--dry-run] [--auto-resolve]  Diagnose and resolve stuck tasks
#   supervisor-helper.sh self-heal <task_id>            Create diagnostic subtask for failed/blocked task
#   supervisor-helper.sh contest <subcommand> [args]    Model contest mode (t1011)
#   supervisor-helper.sh backup [reason]               Backup supervisor database (t162)
#   supervisor-helper.sh restore [backup_file]         Restore from backup (lists if no file) (t162)
#   supervisor-helper.sh db [sql]                      Direct SQLite access
#   supervisor-helper.sh help
#
# State machine:
#   queued -> dispatched -> running -> evaluating -> complete
#                                   -> retrying   -> reprompt -> dispatched (retry cycle)
#                                   -> blocked    (needs human input / max retries)
#                                   -> failed     (dispatch failure / unrecoverable)
#
# Self-healing (t150):
#   blocked/failed -> auto-create {task}-diag-N -> queued -> ... -> complete
#                     diagnostic completes -> re-queue original task
#
# Post-PR lifecycle (t128.8):
#   complete -> pr_review -> merging -> merged -> deploying -> deployed
#   Workers exit after PR creation. Supervisor handles remaining stages:
#   wait for CI, merge (squash), postflight, deploy, worktree cleanup.
#
# Post-merge verification (t180):
#   deployed -> verifying -> verified    (all checks pass)
#                         -> verify_failed (some checks fail)
#   Runs check: directives from todo/VERIFY.md (file-exists, shellcheck, rg, bash).
#
# Outcome evaluation (4-tier):
#   1. Deterministic: FULL_LOOP_COMPLETE/TASK_COMPLETE signals, EXIT codes
#   2. Heuristic: error pattern matching (rate limit, auth, conflict, OOM)
#   2.5. Git heuristic (t175): check commits on branch + uncommitted changes
#   3. AI eval: Sonnet dispatch (~30s) for ambiguous outcomes
#
# Task claiming (t165 - provider-agnostic):
#   Primary: TODO.md assignee: field (instant, offline, works with any git host)
#   Optional: GitHub Issue assignee sync (best-effort, requires gh CLI)
#   Identity: AIDEVOPS_IDENTITY env > GitHub username (cached) > user@hostname
#   Optimistic locking: claim = commit+push TODO.md; push failure = race lost
#   GH Issue creation: opt-in via --with-issue flag or SUPERVISOR_AUTO_ISSUE=true
#
# Model resolution (t132.5):
#   Priority: task explicit model > subagent frontmatter > fallback chain > static default
#   Tier names (haiku/sonnet/opus/flash/pro/grok) mapped to concrete provider/model strings
#   resolve_task_model() orchestrates: resolve_model_from_frontmatter() + resolve_model()
#   Integrates with: fallback-chain-helper.sh (t132.4), model-availability-helper.sh (t132.3)
#
# Quality gate with model escalation (t132.6):
#   Post-completion quality checks: log size, error patterns, file changes, syntax errors
#   Escalation chain: haiku -> sonnet -> opus, flash -> pro
#   Configurable: max_escalation per task (default 2), skip_quality_gate per batch
#   run_quality_gate() -> check_output_quality() -> get_next_tier() -> re-queue with higher model
#
# Database: ~/.aidevops/.agent-workspace/supervisor/supervisor.db
#
# Integration:
#   - Workers: opencode run in worktrees (via full-loop)
#   - Coordinator: coordinator-helper.sh (extends, doesn't replace)
#   - Mail: mail-helper.sh for escalation
#   - Memory: memory-helper.sh for cross-batch learning
#   - Git: wt/worktree-helper.sh for isolation
#
# IMPORTANT - Orchestration Requirements:
#   - CLI: opencode is the ONLY supported CLI for worker dispatch.
#     claude CLI fallback is DEPRECATED and will be removed.
#     Install: npm i -g opencode (https://opencode.ai/)
#   - Cron pulse: For autonomous operation, install the cron pulse:
#       supervisor-helper.sh cron install
#     This runs `pulse` every 2 minutes to check/dispatch/evaluate workers.
#     Without cron, the supervisor is passive and requires manual `pulse` calls.
#   - Batch lifecycle: add tasks -> create batch -> cron pulse handles the rest
#     The pulse cycle: check workers -> evaluate outcomes -> dispatch next -> cleanup

set -euo pipefail

# Ensure common tool paths are available (cron has minimal PATH: /usr/bin:/bin)
# Without this, gh, opencode, node, etc. are unreachable from cron-triggered pulses
# No HOMEBREW_PREFIX guard: the idempotent ":$PATH:" check prevents duplicates,
# and cron may have HOMEBREW_PREFIX set without all tool paths present
for _p in /usr/sbin /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.cargo/bin"; do
	[[ -d "$_p" && ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
done
unset _p

# Resolve GH_TOKEN for cron environments where macOS keyring is inaccessible.
# Priority: existing GH_TOKEN env > `gh auth token` > cached token > gopass > credentials.sh
# When `gh auth token` succeeds (interactive), cache it for cron to use later.
_gh_token_cache="$HOME/.aidevops/.agent-workspace/supervisor/.gh-token-cache"
if [[ -z "${GH_TOKEN:-}" ]]; then
	# Try cached token FIRST (most reliable for cron — written by interactive sessions)
	if [[ -f "$_gh_token_cache" ]]; then
		GH_TOKEN=$(cat "$_gh_token_cache" 2>/dev/null || echo "")
	fi
	# If no cache, try gh auth token (works interactively, may fail in cron)
	if [[ -z "$GH_TOKEN" ]]; then
		GH_TOKEN=$(gh auth token 2>/dev/null || echo "")
	fi
	# Cache the token if we got one (for future cron runs)
	if [[ -n "$GH_TOKEN" ]]; then
		mkdir -p "$(dirname "$_gh_token_cache")"
		printf '%s' "$GH_TOKEN" >"$_gh_token_cache" 2>/dev/null || true
		chmod 600 "$_gh_token_cache" 2>/dev/null || true
	fi
	if [[ -z "$GH_TOKEN" ]]; then
		# Try gopass (encrypted secret store)
		GH_TOKEN=$(gopass show -o github/token 2>/dev/null || echo "")
	fi
	if [[ -z "$GH_TOKEN" ]]; then
		# Try credentials.sh (plaintext fallback)
		_local_creds="$HOME/.config/aidevops/credentials.sh"
		if [[ -f "$_local_creds" ]]; then
			# Source only GH_TOKEN/GITHUB_TOKEN, don't pollute env with everything
			GH_TOKEN=$(grep -E '^(export )?(GH_TOKEN|GITHUB_TOKEN)=' "$_local_creds" 2>/dev/null | head -1 | sed -E 's/^(export )?(GH_TOKEN|GITHUB_TOKEN)=//' | tr -d '"'"'" || echo "")
		fi
		unset _local_creds
	fi
	if [[ -n "$GH_TOKEN" ]]; then
		export GH_TOKEN
	fi
fi
unset _gh_token_cache

# Configuration - resolve relative to this script's real location (not symlink)
# When invoked via symlink (e.g. ~/.aidevops/bin/aidevops-supervisor-pulse),
# BASH_SOURCE[0] is the symlink path. We must resolve it to find sibling scripts.
_resolve_script_path() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir="$(cd "$(dirname "$src")" && pwd)" || return 1
		src="$(readlink "$src")"
		# Handle relative symlinks
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_path)" || exit
unset -f _resolve_script_path
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# Define all globals BEFORE sourcing modules — modules reference these in
# functions and traps. With set -u, any reference to an undefined variable
# is a fatal error. The t1031 modularisation moved functions into modules
# but left the globals defined after the source block, causing
# "PULSE_LOCK_DIR: unbound variable" errors in cron pulse (t1031 regression).
readonly SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
# shellcheck disable=SC2034 # Used by sourced supervisor/ modules
readonly SUPERVISOR_DB="$SUPERVISOR_DIR/supervisor.db"
readonly MAIL_HELPER="${SCRIPT_DIR}/mail-helper.sh"                             # Used by pulse command (t128.2)
readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"                         # Used by pulse command (t128.6)
readonly SESSION_REVIEW_HELPER="${SCRIPT_DIR}/session-review-helper.sh"         # Used by batch completion (t128.9)
readonly SESSION_DISTILL_HELPER="${SCRIPT_DIR}/session-distill-helper.sh"       # Used by batch completion (t128.9)
readonly MEMORY_AUDIT_HELPER="${SCRIPT_DIR}/memory-audit-pulse.sh"              # Used by pulse Phase 9 (t185)
readonly SESSION_CHECKPOINT_HELPER="${SCRIPT_DIR}/session-checkpoint-helper.sh" # Used by respawn (t264.1)
# shellcheck disable=SC2034 # Used by supervisor/utility.sh
readonly RESPAWN_LOG="${HOME}/.aidevops/logs/respawn-history.log" # Persistent respawn log (t264.1)
SUPERVISOR_LOG_DIR="${HOME}/.aidevops/logs"
mkdir -p "$SUPERVISOR_LOG_DIR" 2>/dev/null || true
SUPERVISOR_LOG="${SUPERVISOR_LOG_DIR}/supervisor.log"
readonly PULSE_LOCK_DIR="${SUPERVISOR_DIR}/pulse.lock"
readonly PULSE_LOCK_TIMEOUT="${SUPERVISOR_PULSE_LOCK_TIMEOUT:-600}"
export MAIL_HELPER MEMORY_HELPER SESSION_REVIEW_HELPER SESSION_DISTILL_HELPER MEMORY_AUDIT_HELPER SESSION_CHECKPOINT_HELPER
export SUPERVISOR_LOG SUPERVISOR_LOG_DIR PULSE_LOCK_DIR PULSE_LOCK_TIMEOUT

# Source all supervisor module files (globals must be defined above)
SUPERVISOR_MODULE_DIR="${SCRIPT_DIR}/supervisor"
source "${SUPERVISOR_MODULE_DIR}/_common.sh"
source "${SUPERVISOR_MODULE_DIR}/database.sh"
source "${SUPERVISOR_MODULE_DIR}/state.sh"
source "${SUPERVISOR_MODULE_DIR}/batch.sh"
source "${SUPERVISOR_MODULE_DIR}/dispatch.sh"
source "${SUPERVISOR_MODULE_DIR}/evaluate.sh"
source "${SUPERVISOR_MODULE_DIR}/pulse.sh"
source "${SUPERVISOR_MODULE_DIR}/cleanup.sh"
source "${SUPERVISOR_MODULE_DIR}/cron.sh"
source "${SUPERVISOR_MODULE_DIR}/lifecycle.sh"
source "${SUPERVISOR_MODULE_DIR}/deploy.sh"
source "${SUPERVISOR_MODULE_DIR}/self-heal.sh"
source "${SUPERVISOR_MODULE_DIR}/release.sh"
source "${SUPERVISOR_MODULE_DIR}/utility.sh"
source "${SUPERVISOR_MODULE_DIR}/git-ops.sh"
source "${SUPERVISOR_MODULE_DIR}/issue-sync.sh"
source "${SUPERVISOR_MODULE_DIR}/memory-integration.sh"
source "${SUPERVISOR_MODULE_DIR}/todo-sync.sh"
source "${SUPERVISOR_MODULE_DIR}/ai-context.sh"
source "${SUPERVISOR_MODULE_DIR}/ai-reason.sh"
source "${SUPERVISOR_MODULE_DIR}/ai-actions.sh"
source "${SUPERVISOR_MODULE_DIR}/issue-audit.sh"
source "${SUPERVISOR_MODULE_DIR}/routine-scheduler.sh"

# Valid states for the state machine
# shellcheck disable=SC2034 # Used by supervisor/state.sh
readonly VALID_STATES="queued dispatched running evaluating retrying complete pr_review review_triage merging merged deploying deployed verifying verified verify_failed blocked failed cancelled"

# Valid state transitions (from:to pairs)
# Format: "from_state:to_state" - checked by validate_transition()
# shellcheck disable=SC2034 # Used by supervisor/state.sh
readonly -a VALID_TRANSITIONS=(
	"queued:dispatched"
	"queued:cancelled"
	"dispatched:running"
	"dispatched:failed"
	"dispatched:cancelled"
	"running:evaluating"
	"running:failed"
	"running:cancelled"
	"evaluating:complete"
	"evaluating:pr_review"
	"evaluating:queued"
	"evaluating:retrying"
	"evaluating:blocked"
	"evaluating:failed"
	"retrying:dispatched"
	"retrying:failed"
	"retrying:cancelled"
	"blocked:queued"
	"blocked:pr_review"
	"blocked:cancelled"
	"failed:queued"
	# Post-PR lifecycle transitions (t128.8)
	"complete:pr_review"
	"complete:deployed"
	"pr_review:review_triage"
	"pr_review:merging"
	"pr_review:blocked"
	"pr_review:cancelled"
	# Review triage transitions (t148)
	"review_triage:merging"
	"review_triage:blocked"
	"review_triage:dispatched"
	"review_triage:cancelled"
	"merging:merged"
	"merging:blocked"
	"merging:failed"
	"merged:deploying"
	"merged:deployed"
	"deploying:deployed"
	"deploying:failed"
	# Post-merge verification transitions (t180)
	"deployed:verifying"
	"deployed:verified"
	"deployed:cancelled"
	"verifying:verified"
	"verifying:verify_failed"
	"verify_failed:verifying"
	"verify_failed:cancelled"
	"verified:cancelled"
)

# shellcheck disable=SC2034 # Used by sourced supervisor/ modules
readonly BOLD='\033[1m'
# shellcheck disable=SC2034 # Used by supervisor/utility.sh
readonly DIM='\033[2m'

# log_info, log_success, log_warn, log_error, log_verbose, sql_escape, db, log_cmd
# are defined in supervisor/_common.sh (sourced above)

# ============================================================
# Functions below are kept in the monolith as glue/router/UI.
# All domain functions have been moved to supervisor/ modules.
# ============================================================

#######################################
# Show usage
#######################################
show_usage() {
	cat <<'EOF'
supervisor-helper.sh - Autonomous supervisor for multi-task orchestration

Usage:
  supervisor-helper.sh init                          Initialize supervisor database
  supervisor-helper.sh add <task_id> [options]       Add a task
  supervisor-helper.sh batch <name> [options]        Create a batch of tasks
  supervisor-helper.sh dispatch <task_id> [options]  Dispatch a task (worktree + worker)
  supervisor-helper.sh reprompt <task_id> [options]  Re-prompt a retrying task
  supervisor-helper.sh evaluate <task_id> [--no-ai]  Evaluate a worker's outcome
  supervisor-helper.sh pulse [--batch id]            Run supervisor pulse cycle
  supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage] Handle post-PR lifecycle
  supervisor-helper.sh pr-check <task_id>             Check PR CI/review status
  supervisor-helper.sh scan-orphaned-prs [batch_id]   Scan for PRs workers created but supervisor missed (t210)
  supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
  supervisor-helper.sh verify <task_id>               Run post-merge verification checks (t180)
  supervisor-helper.sh proof-log <task_id> [options]  Query structured proof-logs (t218)
  supervisor-helper.sh triage [--dry-run] [--auto-resolve]  Diagnose and resolve stuck tasks
  supervisor-helper.sh self-heal <task_id>            Create diagnostic subtask for failed/blocked task
  supervisor-helper.sh worker-status <task_id>       Check worker process status
  supervisor-helper.sh cleanup [--dry-run]           Clean up completed worktrees
  supervisor-helper.sh mem-check                    Check supervisor session memory (t264)
  supervisor-helper.sh respawn-history [N]          Show last N respawn events (t264.1)
  supervisor-helper.sh update-todo <task_id>         Update TODO.md for completed/blocked task
  supervisor-helper.sh reconcile-todo [--batch id] [--dry-run]  Bulk-fix stale TODO.md entries
  supervisor-helper.sh reconcile-db-todo [--batch id] [--dry-run]  Bidirectional DB<->TODO.md sync (t1001)
  supervisor-helper.sh reconcile-queue [--batch id] [--dry-run]  Sync DB queue with TODO.md dispatchability (t1180)
  supervisor-helper.sh notify <task_id>              Send notification about task state
  supervisor-helper.sh recall <task_id>              Recall memories relevant to a task
  supervisor-helper.sh release [batch_id] [options]  Trigger or configure batch release
  supervisor-helper.sh retrospective [batch_id]      Run batch retrospective and store insights
  supervisor-helper.sh transition <id> <state>       Transition task state
  supervisor-helper.sh status [task_id|batch_id]     Show status
  supervisor-helper.sh list [--state X] [--batch Y]  List tasks
  supervisor-helper.sh next [batch_id] [limit]       Get next dispatchable tasks
  supervisor-helper.sh running-count [batch_id]      Count active tasks
  supervisor-helper.sh reset <task_id>               Reset task to queued
  supervisor-helper.sh cancel <task_id|batch_id>     Cancel task or batch
  supervisor-helper.sh backup [reason]               Backup supervisor database
  supervisor-helper.sh restore [backup_file]         Restore from backup (lists if no file)
  supervisor-helper.sh auto-pickup [--repo path]      Scan TODO.md for auto-dispatch tasks
  supervisor-helper.sh batch-cleanup [scan|dispatch|status] [--repo path] [--dry-run]  Batch simple #chore tasks (t1146)
  supervisor-helper.sh cron [install|uninstall|status] Manage cron-based pulse scheduling
  supervisor-helper.sh watch [--repo path]            Watch TODO.md for changes (fswatch)
  supervisor-helper.sh dashboard [--batch id] [--interval N] Live TUI dashboard
  supervisor-helper.sh queue-health [--batch id]     Update pinned queue health issue (t1013)
  supervisor-helper.sh stale-gc-report [--days N] [--json]  Stale state GC metrics report (t1202)
  supervisor-helper.sh labels [--action X] [--model Y] [--json]  Query model usage labels (t1010)
  supervisor-helper.sh ai-pipeline [full|dry-run]    Run AI reasoning + action pipeline manually
  supervisor-helper.sh ai-status                     Show AI supervisor status and next-run countdown
  supervisor-helper.sh db [sql]                      Direct SQLite access
  supervisor-helper.sh help                          Show this help

State Machine (worker lifecycle):
  queued -> dispatched -> running -> evaluating -> complete
                                  -> retrying   -> reprompt -> dispatched -> running (retry cycle)
                                  -> blocked    (needs human input / max retries exceeded)
                                  -> failed     (dispatch failure / unrecoverable)

Post-PR Lifecycle (t128.8 - supervisor handles directly, no worker needed):
  complete -> pr_review -> review_triage -> merging -> merged -> deploying -> deployed
  Workers exit after PR creation. Supervisor detects complete tasks with PR URLs
  and handles: CI wait, review triage (t148), merge (squash), postflight, deploy,
  worktree cleanup. Review triage checks unresolved review threads from bot
  reviewers before merge. Use --skip-review-triage or SUPERVISOR_SKIP_REVIEW_TRIAGE=true
  to bypass.

Outcome Evaluation (4-tier):
  1. Deterministic: FULL_LOOP_COMPLETE/TASK_COMPLETE signals, EXIT codes
  2. Heuristic: error pattern matching (rate limit, auth, conflict, OOM, timeout)
  2.5. Git heuristic (t175): check commits on branch + uncommitted changes in worktree
  3. AI eval: Sonnet dispatch (~30s) for remaining ambiguous outcomes

Self-Healing (t150):
  On failure/block, the supervisor auto-creates a diagnostic subtask
  ({task_id}-diag-N) that analyzes the failure log and attempts a fix.
  When the diagnostic completes, the original task is re-queued.
  Guards: max 1 diagnostic per task, skips auth/OOM/conflict (human-only),
  skips recursive diagnostics. Disable: SUPERVISOR_SELF_HEAL=false

Re-prompt Cycle:
  On retry, the supervisor re-prompts the worker in its existing worktree
  with context about the previous failure. After max_retries, the task is
  marked blocked (not failed) so a human can investigate and reset.

Worker Dispatch:
  For each task: creates a worktree (wt switch -c feature/tXXX), then
  dispatches opencode run --format json "/full-loop tXXX" in the worktree.
  Concurrency semaphore limits parallel workers (default 4, set via
  SUPERVISOR_MAX_CONCURRENCY or batch --concurrency).

  Dispatch modes (auto-detected):
    headless  - Background process (default)
    tabby     - Tabby terminal tab (when TERM_PROGRAM=Tabby)
  Override: SUPERVISOR_DISPATCH_MODE=headless|tabby

Task Claiming (t165 - provider-agnostic, TODO.md primary):
  claim <task_id>        Claim a task (adds assignee: to TODO.md, optional GH sync)
  unclaim <task_id>      Release a claimed task (removes assignee: from TODO.md)
  Claiming is automatic during dispatch. TODO.md assignee: field is the
  authoritative source. GitHub Issue sync is optional (best-effort).
  Identity: AIDEVOPS_IDENTITY env > GitHub username > user@hostname

Options for 'add':
  --repo <path>          Repository path (default: current directory)
  --description "desc"   Task description (auto-detected from TODO.md)
  --model <model>        AI model (default: anthropic/claude-opus-4-6)
  --max-retries <N>      Max retry attempts (default: 3)
  --with-issue           Create a GitHub issue for this task (opt-in)
  --no-issue             Alias for default (no GitHub issue creation)

Options for 'batch':
  --concurrency <N>      Base parallel workers (default: 4, scales up/down with load)
  --max-concurrency <N>  Hard upper limit (default: 0 = auto, capped at cpu_cores)
  --tasks "t001,t002"    Comma-separated task IDs to add
  --max-load <N>         Max load factor before throttling (default: 2)
  --release-on-complete  Trigger a release when all tasks complete (t128.10)
  --release-type <type>  Release type: major|minor|patch (default: patch)

Options for 'dispatch':
  --batch <batch_id>     Dispatch within batch concurrency limits

Options for 'reprompt':
  --prompt "text"        Custom re-prompt message (default: auto-generated with failure context)

Options for 'evaluate':
  --no-ai                Skip AI evaluation tier (deterministic + heuristic only)

Options for 'pr-lifecycle':
  --dry-run              Show what would happen without doing it
  --skip-review-triage   Skip review thread triage before merge (t148)

Options for 'pulse':
  --batch <batch_id>     Only pulse tasks in this batch
  --no-self-heal         Disable automatic diagnostic subtask creation

Options for 'self-heal':
  (no options)           Creates diagnostic subtask for a blocked/failed task

Options for 'cleanup':
  --dry-run              Show what would be cleaned without doing it

Options for 'transition':
  --error "reason"       Error message / block reason
  --session <id>         Worker session ID
  --worktree <path>      Worktree path
  --branch <name>        Git branch name
  --log-file <path>      Worker log file path
  --pr-url <url>         Pull request URL

Options for 'list':
  --state <state>        Filter by state
  --batch <batch_id>     Filter by batch
  --format json          Output as JSON

Environment:
  SUPERVISOR_MAX_CONCURRENCY  Global concurrency limit (default: 4)
  SUPERVISOR_DISPATCH_MODE    Force dispatch mode: headless|tabby
  SUPERVISOR_SELF_HEAL        Enable/disable self-healing (default: true)
  SUPERVISOR_AUTO_ISSUE       Enable/disable GitHub issue creation (default: false)
  SUPERVISOR_SKIP_REVIEW_TRIAGE Skip review triage before merge (default: false)
  SUPERVISOR_SKIP_STALENESS    Skip pre-dispatch staleness check (default: false)
  SUPERVISOR_WORKER_TIMEOUT   Seconds before a hung worker is killed (default: 3600, fallback for unclassified tasks)
  SUPERVISOR_WORKER_MAX_RUNTIME Absolute max runtime before kill regardless of output (default: 14400)
  SUPERVISOR_TIMEOUT_TESTING  Hang timeout for #test tasks (default: 7200 — 2h)
  SUPERVISOR_TIMEOUT_REFACTOR Hang timeout for #refactor tasks (default: 7200 — 2h)
  SUPERVISOR_TIMEOUT_ARCHITECTURE Hang timeout for #architecture tasks (default: 7200 — 2h)
  SUPERVISOR_TIMEOUT_FEATURE  Hang timeout for #feature/#enhancement tasks (default: 5400 — 90m)
  SUPERVISOR_TIMEOUT_SECURITY Hang timeout for #security tasks (default: 5400 — 90m)
  SUPERVISOR_TIMEOUT_BUGFIX   Hang timeout for #bugfix/#fix tasks (default: 3600 — 1h)
  SUPERVISOR_TIMEOUT_DOCS     Hang timeout for #docs tasks (default: 1800 — 30m)
  SUPERVISOR_HEARTBEAT_INTERVAL Seconds between worker heartbeat writes to log (default: 300 — 5m)
  SUPERVISOR_HANG_GRACEFUL    Enable two-phase hang detection: SIGTERM at 50% timeout, SIGKILL at 100% (default: true, t1222)
  SUPERVISOR_SELF_MEM_LIMIT   MB before supervisor respawns after batch (default: 8192)
  SUPERVISOR_SKILL_UPDATE_PR  Enable skill update PR pipeline in pulse (default: false)
  SUPERVISOR_SKILL_UPDATE_INTERVAL Seconds between skill update PR runs (default: 86400)
  SUPERVISOR_AI_ENABLED       Enable AI supervisor reasoning in pulse (default: true)
  SUPERVISOR_AI_INTERVAL      Pulses between AI reasoning runs (default: 15, ~30min)
  AI_MAX_ACTIONS_PER_CYCLE    Max actions per AI reasoning cycle (default: 10)
  AIDEVOPS_SUPERVISOR_DIR     Override supervisor data directory

Database: ~/.aidevops/.agent-workspace/supervisor/supervisor.db

Integration:
  - Workers: opencode run in worktrees (via full-loop)
  - Coordinator: coordinator-helper.sh (extends, doesn't replace)
  - Mail: mail-helper.sh for escalation
  - Memory: memory-helper.sh for cross-batch learning
  - Git: wt/worktree-helper.sh for isolation
  - TODO: auto-updates TODO.md on task completion/failure
   - GitHub: creates issues on task add when --with-issue or SUPERVISOR_AUTO_ISSUE=true (t149)
  - Proof-logs: structured audit trail for task completion trust (t218)

TODO.md Auto-Update (t128.4):
  On task completion: marks [ ] -> [x], adds completed:YYYY-MM-DD, commits+pushes
  On task blocked/failed: adds Notes line with reason, commits+pushes
  Notifications sent via mail-helper.sh and Matrix (if configured)
  Triggered automatically during pulse cycle, or manually via update-todo command

GitHub Issue Auto-Creation (t149):
  On task add: creates a GitHub issue with t{NNN}: prefix title, adds ref:GH#N
  to TODO.md, stores issue_url in supervisor DB. Skips if issue already exists
  (dedup by title search). Requires: gh CLI authenticated.
   Enable: --with-issue flag on add, or SUPERVISOR_AUTO_ISSUE=true globally.

Cron Integration & Auto-Pickup (t128.5, t296, t1085.4):
  Auto-pickup scans TODO.md for tasks to automatically queue:
    1. Tasks tagged with #auto-dispatch anywhere in the line
    2. Tasks listed under a "## Dispatch Queue" section header
    3. Tasks tagged with #plan that have PLANS.md references (decomposition)
    4. Subtasks (tXXX.N) of #auto-dispatch parents — inherits dispatch eligibility
       and propagates parent model tier when subtask has no explicit model: field
    5. Batch-cleanup: #chore tasks with ~<=15m estimates grouped into a single
       dispatch (t1146). Reduces N*(worktree+PR+CI+merge) to 1 for simple cleanups.
       Triggers when >=2 eligible tasks found. See batch-cleanup-helper.sh.
  All strategies skip tasks already tracked by the supervisor.
  All strategies respect blocked-by: dependencies — tasks with unresolved
  blockers are skipped until their dependencies are completed ([x] in TODO.md
  or terminal state in supervisor DB).

  Auto-batching (t296, t321): When new tasks are picked up, they are automatically
  assigned to a batch. If an active batch exists, tasks are added to it.
  Otherwise, a new batch named 'auto-YYYYMMDD-HHMMSS' is created with
  base concurrency derived from CPU cores (cores / 2, min 2). A 10-core
  machine gets base 5, a 32-core server gets 16, etc. The adaptive scaling
  then adjusts up/down from this base depending on actual CPU load.
  This ensures all auto-dispatched tasks get batch-level
  concurrency control, completion tracking, and lifecycle management.

  Cron scheduling runs pulse (which includes auto-pickup) every N minutes:
    supervisor-helper.sh cron install              # Every 5 minutes (default)
    supervisor-helper.sh cron install --interval 2 # Every 2 minutes
    supervisor-helper.sh cron uninstall            # Remove cron entry
    supervisor-helper.sh cron status               # Show cron status + log tail

  fswatch alternative for real-time TODO.md monitoring:
    supervisor-helper.sh watch                     # Watch current dir
    supervisor-helper.sh watch --repo ~/Git/myapp  # Watch specific repo
    Requires: brew install fswatch

Memory & Self-Assessment (t128.6):
  Before dispatch: recalls relevant memories and injects into worker prompt
  After evaluation: stores failure/success patterns via memory-helper.sh --auto
  On batch completion: runs retrospective, stores insights and recurring errors
  Manual commands: recall <task_id>, retrospective [batch_id]
  Tags: supervisor,<task_id>,<outcome_type> for targeted recall

Post-PR Lifecycle (t128.8, t148):
  Workers exit after PR creation (context limit). The supervisor detects
  tasks in 'complete' state with PR URLs and handles remaining stages:
    1. pr_review: Wait for CI checks to pass and reviews to approve
    2. review_triage: Check unresolved review threads from bot reviewers (t148)
       - 0 threads: proceed to merge
       - Low/dismiss only: proceed to merge
       - High/medium threads: dispatch fix worker
       - Critical threads: block for human review
    3. merging: Squash merge the PR via gh pr merge --squash
    4. merged: Pull main, run postflight verification
    5. deploying: Run setup.sh (aidevops repos only)
    6. deployed: Clean up worktree and branch, update TODO.md
    7. verifying: Run check: directives from VERIFY.md (t180)
    8. verified: All checks pass — task fully confirmed

  Automatic: pulse cycle Phase 3 processes all eligible tasks each run
  Automatic: pulse cycle Phase 3b runs verification for deployed tasks (t180)
  Manual commands:
    supervisor-helper.sh pr-check <task_id>              # Check CI/review status
    supervisor-helper.sh pr-merge <task_id> [--dry-run]  # Merge PR
    supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage] # Full lifecycle
    supervisor-helper.sh verify <task_id>                # Run verification checks

  CI pending tasks are retried on the next pulse (no state change).
  CI failures and review rejections transition to 'blocked' for human action.

Options for 'scan-orphaned-prs':
  [batch_id]             Optional batch ID to scope the scan (default: all tasks)
  Scans GitHub for PRs that reference task IDs in title or branch name but
  are not linked in the supervisor DB. Links found PRs and transitions
  failed/blocked/retrying tasks to complete. Throttled to every 10 minutes.

Options for 'pr-lifecycle':
  --dry-run              Show what would happen without executing

Options for 'pr-check':
  (no options)           Shows PR CI and review status

Options for 'pr-merge':
  --dry-run              Show what would happen without executing

Options for 'verify':
  (no options)           Runs check: directives from VERIFY.md for the task

Options for 'proof-log' (t218):
  <task_id>              Show proof-log entries for a specific task
  <task_id> --json       Export task proof-log as JSON
  <task_id> --timeline   Show stage timing timeline with durations
  --recent [N]           Show N most recent entries across all tasks (default 20)
  --stats                Show aggregate statistics (event counts, avg durations)

Options for 'auto-pickup':
  --repo <path>          Repository with TODO.md (default: current directory)

Options for 'batch-cleanup' (t1146):
  scan                   Find and list eligible tasks without dispatching
  dispatch               Scan and dispatch a single worker for all eligible tasks
  status                 Show current batch-cleanup worker status
  --repo <path>          Repository with TODO.md (default: current directory)
  --dry-run              Show what would happen without executing
  --force                Dispatch even if fewer than minimum tasks (2) found

  Eligibility: #chore tag + ~<=15m estimate + unclaimed + unblocked
  Savings: N*(worktree+PR+CI+merge) → 1*(worktree+PR+CI+merge) (~80% reduction)

Options for 'cron':
  install                Install cron entry for periodic pulse
  uninstall              Remove cron entry
  status                 Show cron status and recent log
  --interval <N>         Minutes between pulses (default: 5)
  --batch <batch_id>     Only pulse tasks in this batch

Options for 'watch':
  --repo <path>          Repository with TODO.md (default: current directory)

Automatic Release on Batch Completion (t128.10):
  When a batch is created with --release-on-complete, the supervisor
  automatically triggers version-manager.sh release when all tasks in the
  batch reach terminal states (complete, deployed, merged, failed, cancelled).

  The release runs from the batch's repo on the main branch with
  --skip-preflight (batch tasks already passed CI individually).

  Create a batch with auto-release:
    supervisor-helper.sh batch "my-batch" --tasks "t001,t002" --release-on-complete
    supervisor-helper.sh batch "my-batch" --tasks "t001,t002" --release-on-complete --release-type minor

  Enable/disable auto-release on an existing batch:
    supervisor-helper.sh release <batch_id> --enable
    supervisor-helper.sh release <batch_id> --enable --type minor
    supervisor-helper.sh release <batch_id> --disable

  Manually trigger a release for a batch:
    supervisor-helper.sh release <batch_id>                    # Uses batch's configured type
    supervisor-helper.sh release <batch_id> --type minor       # Override type
    supervisor-helper.sh release <batch_id> --dry-run          # Preview only

Options for 'release':
  --type <type>          Release type: major|minor|patch (default: batch config or patch)
  --enable               Enable release_on_complete for the batch
  --disable              Disable release_on_complete for the batch
  --dry-run              Show what would happen without executing

TUI Dashboard (t068.8):
  Live-updating terminal dashboard for monitoring supervisor tasks.
  Shows task states, batch progress, system resources, and active workers.
  Zero dependencies beyond bash + sqlite3 + tput.

  Keyboard controls:
    q     Quit dashboard
    p     Pause/resume auto-refresh
    r     Force refresh now
    j/k   Scroll task list down/up
    ?     Show help overlay

Options for 'dashboard':
  --batch <batch_id>     Filter to a specific batch
  --interval <N>         Refresh interval in seconds (default: 2)
EOF
}

#######################################
# Contest mode — delegate to contest-helper.sh (t1011)
# Usage: supervisor-helper.sh contest <subcommand> [args...]
# Subcommands: create, dispatch, status, evaluate, apply, list, should-contest, pulse-check
#######################################
cmd_contest() {
	local contest_helper="${SCRIPT_DIR}/contest-helper.sh"
	if [[ ! -x "$contest_helper" ]]; then
		log_error "contest-helper.sh not found at $contest_helper"
		return 1
	fi
	"$contest_helper" "$@"
	return $?
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	init) cmd_init "$@" ;;
	add) cmd_add "$@" ;;
	batch) cmd_batch "$@" ;;
	dispatch) cmd_dispatch "$@" ;;
	reprompt) cmd_reprompt "$@" ;;
	evaluate) cmd_evaluate "$@" ;;
	pulse) cmd_pulse "$@" ;;
	pr-lifecycle) cmd_pr_lifecycle "$@" ;;
	pr-check) cmd_pr_check "$@" ;;
	scan-orphaned-prs) scan_orphaned_prs "$@" ;;
	pr-merge) cmd_pr_merge "$@" ;;
	verify) cmd_verify "$@" ;;
	proof-log) cmd_proof_log "$@" ;;
	triage) cmd_triage "$@" ;;
	self-heal) cmd_self_heal "$@" ;;
	worker-status) cmd_worker_status "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	kill-workers) cmd_kill_workers "$@" ;;
	mem-check) cmd_mem_check "$@" ;;
	respawn-history) cmd_respawn_history "$@" ;;
	update-todo) cmd_update_todo "$@" ;;
	reconcile-todo) cmd_reconcile_todo "$@" ;;
	reconcile-db-todo) cmd_reconcile_db_todo "$@" ;;
	reconcile-queue) cmd_reconcile_queue_dispatchability "$@" ;;
	notify) cmd_notify "$@" ;;
	auto-pickup) cmd_auto_pickup "$@" ;;
	auto-unblock)
		# t1247: Manually trigger auto-unblock for a repo
		# Usage: supervisor-helper.sh auto-unblock [--repo <path>]
		local _au_repo="${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--repo)
				_au_repo="$2"
				shift 2
				;;
			*) shift ;;
			esac
		done
		ensure_db
		auto_unblock_resolved_tasks "$_au_repo"
		;;
	batch-cleanup)
		local _bc_helper="${SCRIPT_DIR}/batch-cleanup-helper.sh"
		if [[ ! -x "$_bc_helper" ]]; then
			log_error "batch-cleanup-helper.sh not found or not executable at $_bc_helper"
			return 1
		fi
		"$_bc_helper" "$@"
		return $?
		;;
	cron) cmd_cron "$@" ;;
	watch) cmd_watch "$@" ;;
	dashboard) cmd_dashboard "$@" ;;
	queue-health) cmd_queue_health "$@" ;;
	stale-gc-report) cmd_stale_gc_report "$@" ;;
	recall) cmd_recall "$@" ;;
	release) cmd_release "$@" ;;
	retrospective) cmd_retrospective "$@" ;;
	transition) cmd_transition "$@" ;;
	status) cmd_status "$@" ;;
	list) cmd_list "$@" ;;
	next) cmd_next "$@" ;;
	running-count) cmd_running_count "$@" ;;
	reset) cmd_reset "$@" ;;
	cancel) cmd_cancel "$@" ;;
	claim) cmd_claim "$@" ;;
	unclaim) cmd_unclaim "$@" ;;
	backup) cmd_backup "$@" ;;
	restore) cmd_restore "$@" ;;
	db) cmd_db "$@" ;;
	labels) cmd_labels "$@" ;;
	contest) cmd_contest "$@" ;;
	ai-context) build_ai_context "${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" "${1:-full}" ;;
	ai-reason) run_ai_reasoning "${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" "${1:-full}" ;;
	ai-actions)
		# Execute an action plan: supervisor-helper.sh ai-actions [--mode execute|dry-run|validate-only] --plan '<json>'
		local _aa_mode="execute" _aa_plan="" _aa_repo=""
		_aa_repo="${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--mode)
				_aa_mode="$2"
				shift 2
				;;
			--plan)
				_aa_plan="$2"
				shift 2
				;;
			--dry-run)
				_aa_mode="dry-run"
				shift
				;;
			--repo)
				_aa_repo="$2"
				shift 2
				;;
			*) shift ;;
			esac
		done
		if [[ -z "$_aa_plan" ]]; then
			log_error "ai-actions requires --plan '<json>'"
			return 1
		fi
		execute_action_plan "$_aa_plan" "$_aa_repo" "$_aa_mode"
		;;
	ai-pipeline)
		# Run full reasoning + action execution: supervisor-helper.sh ai-pipeline [full|dry-run]
		run_ai_actions_pipeline "${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" "${1:-full}"
		;;
	ai-status)
		local last_run_ts
		last_run_ts=$(db "$SUPERVISOR_DB" "SELECT MAX(timestamp) FROM state_log WHERE task_id = 'ai-supervisor' AND to_state = 'complete';" 2>/dev/null || echo "")
		local run_count
		run_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM state_log WHERE task_id = 'ai-supervisor' AND to_state = 'complete';" 2>/dev/null || echo 0)
		local action_count
		action_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM state_log WHERE task_id = 'ai-supervisor' AND from_state = 'actions';" 2>/dev/null || echo 0)

		# Read pulse counter and last-run timestamp from files
		local ai_pulse_count_file="${SUPERVISOR_DIR}/ai-pulse-count"
		local ai_last_run_file="${SUPERVISOR_DIR}/ai-supervisor-last-run"
		local ai_log_file="${SUPERVISOR_DIR}/logs/ai-supervisor.log"
		local ai_interval="${SUPERVISOR_AI_INTERVAL:-15}"

		local ai_pulse_count=0
		if [[ -f "$ai_pulse_count_file" ]]; then
			ai_pulse_count=$(cat "$ai_pulse_count_file" 2>/dev/null || echo 0)
		fi

		local ai_last_run="never"
		if [[ -f "$ai_last_run_file" ]]; then
			ai_last_run=$(cat "$ai_last_run_file" 2>/dev/null || echo "never")
		elif [[ -n "$last_run_ts" ]]; then
			ai_last_run="$last_run_ts"
		fi

		local ai_pulses_remaining=$((ai_interval - ai_pulse_count))
		local ai_minutes_remaining=$((ai_pulses_remaining * 2))

		echo "AI Supervisor Status"
		echo "  Enabled:          ${SUPERVISOR_AI_ENABLED:-true}"
		echo "  Interval:         ${ai_interval} pulses (~$((ai_interval * 2))min)"
		echo "  Pulse counter:    ${ai_pulse_count}/${ai_interval} (${ai_pulses_remaining} pulses / ~${ai_minutes_remaining}min until next run)"
		echo "  Last run:         ${ai_last_run}"
		echo "  Total runs:       $run_count"
		echo "  Total actions:    $action_count"
		echo "  Max actions/cycle: ${AI_MAX_ACTIONS_PER_CYCLE:-10}"
		echo "  Log file:         ${ai_log_file}"
		echo "  Reason log dir:   ${AI_REASON_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"
		;;
	routine-status)
		# Show Phase 14 intelligent routine scheduling state
		routine_scheduler_status
		;;
	help | --help | -h) show_usage ;;
	*)
		log_error "Unknown command: $command"
		show_usage
		return 1
		;;
	esac
}

main "$@"
