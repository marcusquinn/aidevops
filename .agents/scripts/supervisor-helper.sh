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
#   supervisor-helper.sh update-todo <task_id>         Update TODO.md for completed/blocked task
#   supervisor-helper.sh reconcile-todo [--batch id] [--dry-run]  Bulk-fix stale TODO.md entries
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
#   supervisor-helper.sh cron [install|uninstall|status] Manage cron-based pulse scheduling
#   supervisor-helper.sh watch [--repo path]            Watch TODO.md for changes (fswatch)
#   supervisor-helper.sh dashboard [--batch id] [--interval N] Live TUI dashboard (t068.8)
#   supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage] Handle post-PR lifecycle
#   supervisor-helper.sh pr-check <task_id>             Check PR CI/review status
#   supervisor-helper.sh scan-orphaned-prs [batch_id]   Scan for PRs workers created but supervisor missed (t210)
#   supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
#   supervisor-helper.sh verify <task_id>               Run post-merge verification checks (t180)
#   supervisor-helper.sh self-heal <task_id>            Create diagnostic subtask for failed/blocked task
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
        printf '%s' "$GH_TOKEN" > "$_gh_token_cache" 2>/dev/null || true
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

# Configuration - resolve relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
readonly SUPERVISOR_DB="$SUPERVISOR_DIR/supervisor.db"
readonly MAIL_HELPER="${SCRIPT_DIR}/mail-helper.sh"       # Used by pulse command (t128.2)
readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"   # Used by pulse command (t128.6)
readonly SESSION_REVIEW_HELPER="${SCRIPT_DIR}/session-review-helper.sh"   # Used by batch completion (t128.9)
readonly SESSION_DISTILL_HELPER="${SCRIPT_DIR}/session-distill-helper.sh" # Used by batch completion (t128.9)
readonly MEMORY_AUDIT_HELPER="${SCRIPT_DIR}/memory-audit-pulse.sh"       # Used by pulse Phase 9 (t185)
export MAIL_HELPER MEMORY_HELPER SESSION_REVIEW_HELPER SESSION_DISTILL_HELPER MEMORY_AUDIT_HELPER

# Valid states for the state machine
readonly VALID_STATES="queued dispatched running evaluating retrying complete pr_review review_triage merging merged deploying deployed verifying verified verify_failed blocked failed cancelled"

# Valid state transitions (from:to pairs)
# Format: "from_state:to_state" - checked by validate_transition()
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
    "evaluating:queued"
    "evaluating:retrying"
    "evaluating:blocked"
    "evaluating:failed"
    "retrying:dispatched"
    "retrying:failed"
    "retrying:cancelled"
    "blocked:queued"
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

readonly BOLD='\033[1m'

log_info() { echo -e "${BLUE}[SUPERVISOR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUPERVISOR]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[SUPERVISOR]${NC} $*" >&2; }
log_error() { echo -e "${RED}[SUPERVISOR]${NC} $*" >&2; }
log_verbose() { [[ "${SUPERVISOR_VERBOSE:-}" == "true" ]] && echo -e "${BLUE}[SUPERVISOR]${NC} $*" >&2 || true; }

#######################################
# Write a structured proof-log entry (t218)
#
# Records an immutable evidence record for task completion trust.
# Each entry captures: what happened, what evidence was used, and
# who/what made the decision. Used for audit trails, pipeline
# latency analysis (t219), and trust verification.
#
# Arguments (all via flags for clarity):
#   --task <id>           Task ID (required)
#   --event <type>        Event type (required): evaluate, complete, retry,
#                         blocked, failed, verify_pass, verify_fail,
#                         pr_review, merge, deploy, quality_gate,
#                         dispatch, escalate, self_heal
#   --stage <name>        Pipeline stage: evaluate, pr_review, review_triage,
#                         merging, deploying, verifying, etc.
#   --decision <text>     Decision made (e.g., "complete:PR_URL", "retry:rate_limited")
#   --evidence <text>     Evidence used (e.g., "exit_code=0, signal=FULL_LOOP_COMPLETE")
#   --maker <text>        Decision maker (e.g., "heuristic:tier1", "ai_eval:sonnet",
#                         "quality_gate", "human")
#   --pr-url <url>        PR URL if relevant
#   --duration <secs>     Duration of this stage in seconds
#   --metadata <json>     Additional JSON metadata
#
# Returns 0 on success, 1 on missing required args, silently succeeds
# if DB is unavailable (proof-logs are best-effort, never block pipeline).
#######################################
write_proof_log() {
    local task_id="" event="" stage="" decision="" evidence=""
    local maker="" pr_url="" duration="" metadata=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) task_id="${2:-}"; shift 2 ;;
            --event) event="${2:-}"; shift 2 ;;
            --stage) stage="${2:-}"; shift 2 ;;
            --decision) decision="${2:-}"; shift 2 ;;
            --evidence) evidence="${2:-}"; shift 2 ;;
            --maker) maker="${2:-}"; shift 2 ;;
            --pr-url) pr_url="${2:-}"; shift 2 ;;
            --duration) duration="${2:-}"; shift 2 ;;
            --metadata) metadata="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Required fields
    if [[ -z "$task_id" || -z "$event" ]]; then
        return 1
    fi

    # Best-effort: don't block pipeline if DB is unavailable
    if [[ ! -f "${SUPERVISOR_DB:-}" ]]; then
        return 0
    fi

    # Escape all text fields for SQL safety
    local e_task e_event e_stage e_decision e_evidence e_maker e_pr e_meta
    e_task=$(sql_escape "$task_id")
    e_event=$(sql_escape "$event")
    e_stage=$(sql_escape "${stage:-}")
    e_decision=$(sql_escape "${decision:-}")
    e_evidence=$(sql_escape "${evidence:-}")
    e_maker=$(sql_escape "${maker:-}")
    e_pr=$(sql_escape "${pr_url:-}")
    e_meta=$(sql_escape "${metadata:-}")

    # Build INSERT with only non-empty optional fields
    local cols="task_id, event"
    local vals="'$e_task', '$e_event'"

    if [[ -n "$stage" ]]; then
        cols="$cols, stage"; vals="$vals, '$e_stage'"
    fi
    if [[ -n "$decision" ]]; then
        cols="$cols, decision"; vals="$vals, '$e_decision'"
    fi
    if [[ -n "$evidence" ]]; then
        cols="$cols, evidence"; vals="$vals, '$e_evidence'"
    fi
    if [[ -n "$maker" ]]; then
        cols="$cols, decision_maker"; vals="$vals, '$e_maker'"
    fi
    if [[ -n "$pr_url" ]]; then
        cols="$cols, pr_url"; vals="$vals, '$e_pr'"
    fi
    if [[ -n "$duration" ]]; then
        cols="$cols, duration_secs"; vals="$vals, $duration"
    fi
    if [[ -n "$metadata" ]]; then
        cols="$cols, metadata"; vals="$vals, '$e_meta'"
    fi

    db "$SUPERVISOR_DB" "INSERT INTO proof_logs ($cols) VALUES ($vals);" 2>/dev/null || true

    log_verbose "proof-log: $task_id $event ${stage:+stage=$stage }${decision:+decision=$decision}"
    return 0
}

#######################################
# Calculate stage duration from the last proof-log entry for a task (t218)
# Returns duration in seconds between the last logged event and now.
# Used to measure pipeline stage latency for t219 analysis.
#######################################
_proof_log_stage_duration() {
    local task_id="$1"
    local stage="${2:-}"

    if [[ ! -f "${SUPERVISOR_DB:-}" ]]; then
        echo ""
        return 0
    fi

    local e_task
    e_task=$(sql_escape "$task_id")

    local last_ts=""
    if [[ -n "$stage" ]]; then
        local e_stage
        e_stage=$(sql_escape "$stage")
        last_ts=$(db "$SUPERVISOR_DB" "
            SELECT timestamp FROM proof_logs
            WHERE task_id = '$e_task' AND stage = '$e_stage'
            ORDER BY id DESC LIMIT 1;
        " 2>/dev/null || echo "")
    fi

    # Fallback: last event for this task regardless of stage
    if [[ -z "$last_ts" ]]; then
        last_ts=$(db "$SUPERVISOR_DB" "
            SELECT timestamp FROM proof_logs
            WHERE task_id = '$e_task'
            ORDER BY id DESC LIMIT 1;
        " 2>/dev/null || echo "")
    fi

    if [[ -z "$last_ts" ]]; then
        echo ""
        return 0
    fi

    local last_epoch now_epoch
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null || date -d "$last_ts" "+%s" 2>/dev/null || echo "")
    now_epoch=$(date +%s)

    if [[ -n "$last_epoch" && -n "$now_epoch" ]]; then
        echo $((now_epoch - last_epoch))
    else
        echo ""
    fi
    return 0
}

# Check GitHub authentication in a way that works with GH_TOKEN env var.
# gh auth status may fail in cron even when GH_TOKEN is valid (keyring issues).
# This function checks GH_TOKEN first, then falls back to gh auth status.
check_gh_auth() {
    # Cache auth check result for 5 minutes to avoid repeated API calls.
    # Each pulse calls this 1-5 times; cron runs every 2-5 minutes.
    # Caching saves ~288 API calls/day at 2-min pulse intervals.
    local cache_file="${SUPERVISOR_DIR:-.}/.gh-auth-cache"
    local cache_ttl=300  # 5 minutes

    if [[ -f "$cache_file" ]]; then
        local cache_age
        local cache_mtime
        cache_mtime=$(stat -f '%m' "$cache_file" 2>/dev/null || stat -c '%Y' "$cache_file" 2>/dev/null || echo "0")
        cache_age=$(( $(date +%s) - cache_mtime ))
        if [[ "$cache_age" -lt "$cache_ttl" ]]; then
            local cached_result
            cached_result=$(cat "$cache_file" 2>/dev/null || echo "")
            if [[ "$cached_result" == "ok" ]]; then
                return 0
            fi
            # Cached failure — still retry in case token was refreshed
        fi
    fi

    # If GH_TOKEN is set, verify it works with a lightweight API call
    if [[ -n "${GH_TOKEN:-}" ]]; then
        if gh api user --jq '.login' >/dev/null 2>&1; then
            mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
            echo "ok" > "$cache_file" 2>/dev/null || true
            return 0
        fi
    fi
    # Fall back to gh auth status (works interactively with keyring)
    if gh auth status >/dev/null 2>&1; then
        mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
        echo "ok" > "$cache_file" 2>/dev/null || true
        return 0
    fi
    echo "fail" > "$cache_file" 2>/dev/null || true
    return 1
}

# Supervisor stderr log file - captures stderr from commands that previously
# used 2>/dev/null, making errors debuggable without cluttering terminal output.
# See GH#441 (t144) for rationale.
SUPERVISOR_LOG_DIR="${HOME}/.aidevops/logs"
mkdir -p "$SUPERVISOR_LOG_DIR" 2>/dev/null || true
SUPERVISOR_LOG="${SUPERVISOR_LOG_DIR}/supervisor.log"

# Log stderr from a command to the supervisor log file instead of /dev/null.
# Usage: log_cmd "context" command args...
# Preserves exit code. Use for DB writes, API calls, state transitions.
log_cmd() {
    local context="$1"
    shift
    local ts
    ts="$(date '+%H:%M:%S' 2>/dev/null || echo "?")"
    echo "[$ts] [$context] $*" >> "$SUPERVISOR_LOG" 2>/dev/null || true
    "$@" 2>> "$SUPERVISOR_LOG"
    local rc=$?
    [[ $rc -ne 0 ]] && echo "[$ts] [$context] exit=$rc" >> "$SUPERVISOR_LOG" 2>/dev/null || true
    return $rc
}

#######################################
# Pulse dispatch lock (t159)
#
# Prevents concurrent pulse invocations from independently dispatching
# workers, which can exceed the batch concurrency limit. When both cron
# pulse and manual pulse (or overlapping cron pulses) run simultaneously,
# each checks the running count, sees available slots, and dispatches —
# resulting in 2x the intended concurrency.
#
# Uses mkdir-based locking (atomic on all POSIX filesystems, no external
# dependencies needed on macOS where flock is not built-in).
#
# Stale lock detection: if the lock directory is older than
# SUPERVISOR_PULSE_LOCK_TIMEOUT seconds (default: 600 = 10 minutes),
# it is considered stale and forcibly removed. This prevents permanent
# deadlock if a pulse process crashes without releasing the lock.
#######################################
readonly PULSE_LOCK_DIR="${SUPERVISOR_DIR}/pulse.lock"
readonly PULSE_LOCK_TIMEOUT="${SUPERVISOR_PULSE_LOCK_TIMEOUT:-600}"

# Acquire the pulse lock. Returns 0 on success, 1 if another pulse is running.
acquire_pulse_lock() {
    # Attempt 1: try atomic mkdir directly (fast path, no races)
    if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$PULSE_LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    # Lock exists — check if it's stale (age > timeout) or held by a dead process.
    # To avoid TOCTOU races where two processes both detect a dead/stale holder,
    # both rm the lock, and both re-acquire: use atomic rename (mv) to claim the
    # stale lock exclusively, then clean up and retry mkdir.
    local should_break=false
    local break_reason=""

    # Check stale lock (age exceeds timeout)
    local lock_age=0
    local lock_mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        lock_mtime=$(stat -f %m "$PULSE_LOCK_DIR" 2>/dev/null || echo "0")
    else
        lock_mtime=$(stat -c %Y "$PULSE_LOCK_DIR" 2>/dev/null || echo "0")
    fi
    local now_epoch
    now_epoch=$(date +%s)
    lock_age=$(( now_epoch - lock_mtime ))

    if [[ "$lock_age" -gt "$PULSE_LOCK_TIMEOUT" ]]; then
        should_break=true
        break_reason="stale (age: ${lock_age}s > timeout: ${PULSE_LOCK_TIMEOUT}s)"
    fi

    # Check dead holder process
    if [[ "$should_break" == "false" ]]; then
        local holder_pid
        holder_pid=$(cat "$PULSE_LOCK_DIR/pid" 2>/dev/null || echo "")
        if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
            should_break=true
            break_reason="dead holder (PID $holder_pid)"
        fi
    fi

    if [[ "$should_break" == "true" ]]; then
        # Atomically rename the stale lock to a unique temp name.
        # mv on the same filesystem is atomic — only one process wins.
        local stale_dir="${PULSE_LOCK_DIR}.stale.$$"
        if mv "$PULSE_LOCK_DIR" "$stale_dir" 2>/dev/null; then
            # We won the rename race — clean up and retry
            log_warn "Breaking pulse lock ($break_reason)"
            rm -rf "$stale_dir"
            if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
                echo $$ > "$PULSE_LOCK_DIR/pid" 2>/dev/null || true
                return 0
            fi
        fi
        # Another process won the rename race or re-acquired first — fall through
    fi

    return 1
}

# Release the pulse lock. Safe to call multiple times.
release_pulse_lock() {
    # Only release if we own the lock (PID matches)
    local holder_pid
    holder_pid=$(cat "$PULSE_LOCK_DIR/pid" 2>/dev/null || echo "")
    if [[ "$holder_pid" == "$$" ]]; then
        rm -rf "$PULSE_LOCK_DIR"
    fi
    return 0
}


#######################################
# Get the number of CPU cores on this system
# Returns integer count on stdout
#######################################
get_cpu_cores() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sysctl -n hw.logicalcpu 2>/dev/null || echo 4
    elif [[ -f /proc/cpuinfo ]]; then
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4
    else
        nproc 2>/dev/null || echo 4
    fi
    return 0
}

#######################################
# Check system load and resource pressure (t135.15)
#
# Outputs key=value pairs:
#   load_1m, load_5m, load_15m  - Load averages
#   cpu_cores                    - Logical CPU count
#   load_ratio                   - Actual CPU usage percentage (0-100)
#                                  On macOS: from `top` (100 - idle%), accurate
#                                  On Linux: from /proc/stat or load average fallback
#                                  NOTE: Previously used load_avg/cores which is
#                                  misleading on macOS — load average includes I/O
#                                  wait and uninterruptible sleep, not just CPU.
#   process_count                - Total system processes
#   supervisor_process_count     - Processes spawned by supervisor workers
#   memory_pressure              - low|medium|high (macOS) or free MB (Linux)
#   overloaded                   - true|false (cpu_usage > threshold)
#
# $1 (optional): max load factor (default: 2, used for Linux fallback only)
#######################################
check_system_load() {
    local max_load_factor="${1:-2}"

    local cpu_cores
    cpu_cores=$(get_cpu_cores)
    echo "cpu_cores=$cpu_cores"

    # Load averages (cross-platform, kept for logging/display)
    local load_1m="0" load_5m="0" load_15m="0"
    if [[ "$(uname)" == "Darwin" ]]; then
        local load_str
        load_str=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0.00 0.00 0.00 }")
        load_1m=$(echo "$load_str" | awk '{print $2}')
        load_5m=$(echo "$load_str" | awk '{print $3}')
        load_15m=$(echo "$load_str" | awk '{print $4}')
    elif [[ -f /proc/loadavg ]]; then
        read -r load_1m load_5m load_15m _ < /proc/loadavg
    else
        local uptime_str
        uptime_str=$(uptime 2>/dev/null || echo "")
        if [[ -n "$uptime_str" ]]; then
            load_1m=$(echo "$uptime_str" | grep -oE 'load average[s]?: [0-9.]+' | grep -oE '[0-9.]+$' || echo "0")
            load_5m=$(echo "$uptime_str" | awk -F'[, ]+' '{print $(NF-1)}' || echo "0")
            load_15m=$(echo "$uptime_str" | awk -F'[, ]+' '{print $NF}' || echo "0")
        fi
    fi
    echo "load_1m=$load_1m"
    echo "load_5m=$load_5m"
    echo "load_15m=$load_15m"

    # Actual CPU usage (the PRIMARY metric for throttling decisions)
    # On macOS, load average is misleading — it includes processes in
    # uninterruptible sleep (I/O wait, Backblaze, Spotlight, etc.),
    # so load avg of 150 on 10 cores can coexist with 35% idle CPU.
    # Use `top -l 1` to get real CPU idle percentage instead.
    local load_ratio=0
    if [[ "$(uname)" == "Darwin" ]]; then
        local cpu_idle_pct
        # Use -l 2 and take the LAST sample: top's first sample is cumulative
        # since boot, the second is the actual current interval delta.
        cpu_idle_pct=$(top -l 2 -n 0 -s 1 2>/dev/null | awk '/CPU usage/ {gsub(/%/,""); for(i=1;i<=NF;i++) if($(i+1)=="idle") idle=int($i)} END {print idle}')
        if [[ -n "$cpu_idle_pct" && "$cpu_idle_pct" -ge 0 ]]; then
            load_ratio=$((100 - cpu_idle_pct))
        else
            # Fallback to load average if top fails
            if [[ "$cpu_cores" -gt 0 ]]; then
                load_ratio=$(awk "BEGIN {printf \"%d\", ($load_1m / $cpu_cores) * 100}")
            fi
        fi
    elif [[ "$cpu_cores" -gt 0 ]]; then
        # Linux: use load average ratio (load avg includes only runnable processes)
        load_ratio=$(awk "BEGIN {printf \"%d\", ($load_1m / $cpu_cores) * 100}")
    fi
    echo "load_ratio=$load_ratio"

    # Total process count
    local process_count=0
    process_count=$(ps aux 2>/dev/null | wc -l | tr -d ' ')
    echo "process_count=$process_count"

    # Supervisor worker process count (opencode workers spawned by supervisor)
    local supervisor_process_count=0
    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local wpid
            wpid=$(cat "$pid_file")
            if kill -0 "$wpid" 2>/dev/null; then
                # Count this worker + all its descendants
                local desc_count
                desc_count=$(_list_descendants "$wpid" 2>/dev/null | wc -l | tr -d ' ')
                supervisor_process_count=$((supervisor_process_count + 1 + desc_count))
            fi
        done
    fi
    echo "supervisor_process_count=$supervisor_process_count"

    # Memory pressure
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use memory_pressure command for system-wide free percentage
        # vm_stat "Pages free" is misleading — macOS keeps it near zero by design,
        # using inactive/purgeable/compressed pages as available memory instead.
        local pressure="low"
        local free_pct=100
        local mp_output
        mp_output=$(memory_pressure 2>/dev/null || echo "")
        if [[ -n "$mp_output" ]]; then
            free_pct=$(echo "$mp_output" | grep -oE 'free percentage: [0-9]+' | grep -oE '[0-9]+' || echo "100")
        fi
        if [[ "$free_pct" -lt 10 ]]; then
            pressure="high"
        elif [[ "$free_pct" -lt 25 ]]; then
            pressure="medium"
        fi
        echo "memory_pressure=$pressure"
    else
        # Linux: parse /proc/meminfo
        local mem_available_kb=0
        if [[ -f /proc/meminfo ]]; then
            mem_available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
        fi
        local mem_available_mb=$((mem_available_kb / 1024))
        echo "memory_pressure=${mem_available_mb}MB"
    fi

    # Overloaded check: CPU usage > 85% (real saturation)
    # On macOS load_ratio is now actual CPU% (0-100), not load_avg/cores*100
    # On Linux load_ratio is still load_avg/cores*100 (threshold adjusted)
    if [[ "$(uname)" == "Darwin" ]]; then
        if [[ "$load_ratio" -gt 85 ]]; then
            echo "overloaded=true"
        else
            echo "overloaded=false"
        fi
    else
        local threshold=$((cpu_cores * max_load_factor * 100))
        if [[ "$load_ratio" -gt "$threshold" ]]; then
            echo "overloaded=true"
        else
            echo "overloaded=false"
        fi
    fi

    return 0
}

#######################################
# Calculate adaptive concurrency based on system load (t135.15.2)
# Returns the recommended concurrency limit on stdout
#
# Strategy (bidirectional scaling, using actual CPU usage):
#   On macOS, load_ratio = actual CPU usage % (0-100) from `top`.
#   On Linux, load_ratio = load_avg / cores * 100 (traditional).
#
#   - CPU < 40%:  scale UP (base * 2, capped at max_concurrency)
#   - CPU 40-70%: use base concurrency (no change)
#   - CPU 70-85%: reduce by 50%
#   - CPU > 85%:  reduce to minimum floor
#   - Memory pressure high: reduce to minimum floor
#   - Minimum floor is 1 (allows at least 1 worker always)
#   - Maximum cap defaults to cpu_cores (prevents runaway scaling)
#
# $1: base concurrency (from batch or global default)
# $2: max load factor (default: 2, Linux fallback only)
# $3: max concurrency cap (default: cpu_cores, hard upper limit)
#######################################
calculate_adaptive_concurrency() {
    local base_concurrency="${1:-4}"
    local max_load_factor="${2:-2}"
    local max_concurrency_cap="${3:-0}"
    local min_concurrency=1

    local load_output
    load_output=$(check_system_load "$max_load_factor")

    local cpu_cores load_ratio memory_pressure overloaded
    cpu_cores=$(echo "$load_output" | grep '^cpu_cores=' | cut -d= -f2)
    load_ratio=$(echo "$load_output" | grep '^load_ratio=' | cut -d= -f2)
    memory_pressure=$(echo "$load_output" | grep '^memory_pressure=' | cut -d= -f2)
    overloaded=$(echo "$load_output" | grep '^overloaded=' | cut -d= -f2)

    # Default max cap to cpu_cores if not specified
    if [[ "$max_concurrency_cap" -le 0 ]]; then
        max_concurrency_cap="$cpu_cores"
    fi

    local effective_concurrency="$base_concurrency"

    # High memory pressure: drop to minimum floor
    if [[ "$memory_pressure" == "high" ]]; then
        effective_concurrency="$min_concurrency"
        echo "$effective_concurrency"
        return 0
    fi

    if [[ "$overloaded" == "true" ]]; then
        # Severely overloaded (CPU > 85%): minimum floor
        effective_concurrency="$min_concurrency"
    elif [[ "$load_ratio" -gt 70 ]]; then
        # Heavy load (CPU 70-85%): halve concurrency
        effective_concurrency=$(( (base_concurrency + 1) / 2 ))
    elif [[ "$load_ratio" -lt 40 ]]; then
        # Light load (CPU < 40%): scale up to double base
        effective_concurrency=$((base_concurrency * 2))
    fi
    # else: CPU 40-70% — use base_concurrency as-is

    # Enforce minimum floor
    if [[ "$effective_concurrency" -lt "$min_concurrency" ]]; then
        effective_concurrency="$min_concurrency"
    fi

    # Enforce maximum cap
    if [[ "$effective_concurrency" -gt "$max_concurrency_cap" ]]; then
        effective_concurrency="$max_concurrency_cap"
    fi

    echo "$effective_concurrency"
    return 0
}

#######################################
# Find the project root (directory containing TODO.md) (t165)
# Walks up from $PWD until it finds TODO.md or hits /.
# Outputs the path on stdout, returns 1 if not found.
#######################################
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/TODO.md" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    log_error "No TODO.md found in directory tree"
    return 1
}

#######################################
# Detect GitHub repo slug from git remote (t165)
# Handles both HTTPS and SSH remote URLs.
# $1: project_root (directory with .git)
# Outputs "owner/repo" on stdout, returns 1 if not detected.
#######################################
detect_repo_slug() {
    local project_root="${1:-.}"
    local remote_url
    remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
    remote_url="${remote_url%.git}"
    local slug
    slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
    if [[ -z "$slug" ]]; then
        log_error "Could not detect GitHub repo slug from git remote"
        return 1
    fi
    echo "$slug"
    return 0
}

#######################################
# Escape single quotes for SQL
#######################################
sql_escape() {
    local input="$1"
    echo "${input//\'/\'\'}"
}

#######################################
# SQLite wrapper: sets busy_timeout on every connection (t135.3)
# busy_timeout is per-connection and must be set each time
#######################################
db() {
    sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Backup supervisor database before destructive operations (t162, t188)
# Delegates to shared backup_sqlite_db() from shared-constants.sh.
# Usage: backup_db [reason]
#######################################
backup_db() {
    local reason="${1:-manual}"
    local backup_file

    backup_file=$(backup_sqlite_db "$SUPERVISOR_DB" "$reason")
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "Failed to backup database"
        return 1
    fi

    log_success "Database backed up: $backup_file"

    # Prune old backups: keep last 5
    cleanup_sqlite_backups "$SUPERVISOR_DB" 5

    echo "$backup_file"
    return 0
}

#######################################
# Run a schema migration with backup, verification, and rollback (t188)
# Wraps the backup-migrate-verify pattern to prevent silent data loss.
# Reads migration SQL from stdin to avoid quoting issues with heredocs.
#
# Usage:
#   safe_migrate "t180" "tasks" <<'SQL'
#   ALTER TABLE tasks ADD COLUMN new_col TEXT;
#   SQL
#
# Arguments:
#   $1 - migration label (e.g., "t180", "t128.8")
#   $2 - space-separated list of tables to verify row counts for
#   stdin - migration SQL
#
# Returns: 0 on success, 1 on failure (with automatic rollback)
#######################################
safe_migrate() {
    local label="$1"
    local verify_tables="$2"
    local migration_sql
    migration_sql=$(cat)

    log_info "Migrating database schema ($label)..."

    # Step 1: Backup before migration
    local backup_file
    backup_file=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-${label}")
    if [[ $? -ne 0 || -z "$backup_file" ]]; then
        log_error "Backup failed for migration $label — aborting migration"
        return 1
    fi
    log_info "Pre-migration backup: $backup_file"

    # Step 2: Run the migration
    if ! db "$SUPERVISOR_DB" "$migration_sql"; then
        log_error "Migration $label FAILED — rolling back from backup"
        rollback_sqlite_db "$SUPERVISOR_DB" "$backup_file"
        return 1
    fi

    # Step 3: Verify row counts didn't decrease
    if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$backup_file" "$verify_tables"; then
        log_error "Migration $label VERIFICATION FAILED — row counts decreased, rolling back"
        rollback_sqlite_db "$SUPERVISOR_DB" "$backup_file"
        return 1
    fi

    log_success "Database schema migrated ($label) — row counts verified"
    cleanup_sqlite_backups "$SUPERVISOR_DB" 5
    return 0
}

#######################################
# Restore supervisor database from backup (t162)
# Usage: restore_db [backup_file]
# If no file specified, lists available backups
#######################################
restore_db() {
    local backup_file="${1:-}"

    if [[ -z "$backup_file" ]]; then
        log_info "Available backups:"
        # shellcheck disable=SC2012
        ls -1t "$SUPERVISOR_DIR"/supervisor-backup-*.db 2>/dev/null | while IFS= read -r f; do
            local size
            size=$(du -h "$f" 2>/dev/null | cut -f1)
            local task_count
            task_count=$(sqlite3 "$f" "SELECT count(*) FROM tasks;" 2>/dev/null || echo "?")
            echo "  $f ($size, $task_count tasks)"
        done
        return 0
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    # Verify backup is valid SQLite
    if ! sqlite3 "$backup_file" "SELECT count(*) FROM tasks;" >/dev/null 2>&1; then
        log_error "Backup file is not a valid supervisor database: $backup_file"
        return 1
    fi

    # Backup current DB before overwriting
    if [[ -f "$SUPERVISOR_DB" ]]; then
        backup_db "pre-restore" >/dev/null 2>&1 || true
    fi

    cp "$backup_file" "$SUPERVISOR_DB"
    [[ -f "${backup_file}-wal" ]] && cp "${backup_file}-wal" "${SUPERVISOR_DB}-wal" 2>/dev/null || true
    [[ -f "${backup_file}-shm" ]] && cp "${backup_file}-shm" "${SUPERVISOR_DB}-shm" 2>/dev/null || true

    local task_count
    task_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
    local batch_count
    batch_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM batches;")

    log_success "Database restored from: $backup_file"
    log_info "Tasks: $task_count | Batches: $batch_count"
    return 0
}

#######################################
# Ensure supervisor directory and DB exist
#######################################
ensure_db() {
    if [[ ! -d "$SUPERVISOR_DIR" ]]; then
        mkdir -p "$SUPERVISOR_DIR"
    fi

    if [[ ! -f "$SUPERVISOR_DB" ]]; then
        init_db
        return 0
    fi

    # Check if schema needs upgrade
    local has_tasks
    has_tasks=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='tasks';")
    if [[ "$has_tasks" -eq 0 ]]; then
        init_db
    fi

    # Migrate: add post-PR lifecycle states if CHECK constraint is outdated (t128.8)
    # SQLite doesn't support ALTER CHECK, so we recreate the constraint via a temp table
    # Note: uses dynamic column lists so cannot use safe_migrate() directly (t188)
    local check_sql
    check_sql=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
    if [[ -n "$check_sql" ]] && ! echo "$check_sql" | grep -q 'pr_review'; then
        log_info "Migrating database schema for post-PR lifecycle states (t128.8)..."

        # Backup before migration (t188: fail-safe — abort if backup fails)
        local t128_backup
        t128_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-t128.8")
        if [[ $? -ne 0 || -z "$t128_backup" ]]; then
            log_error "Backup failed for t128.8 migration — aborting"
            return 1
        fi

        # Detect which optional columns exist in the old table to preserve data (t162)
        local has_issue_url_col has_diagnostic_of_col has_triage_result_col
        has_issue_url_col=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='issue_url';" 2>/dev/null || echo "0")
        has_diagnostic_of_col=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='diagnostic_of';" 2>/dev/null || echo "0")
        has_triage_result_col=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='triage_result';" 2>/dev/null || echo "0")

        # Build column lists dynamically based on what exists
        local insert_cols="id, repo, description, status, session_id, worktree, branch, log_file, retries, max_retries, model, error, pr_url, created_at, started_at, completed_at, updated_at"
        local select_cols="$insert_cols"
        [[ "$has_issue_url_col" -gt 0 ]] && { insert_cols="$insert_cols, issue_url"; select_cols="$select_cols, issue_url"; }
        [[ "$has_diagnostic_of_col" -gt 0 ]] && { insert_cols="$insert_cols, diagnostic_of"; select_cols="$select_cols, diagnostic_of"; }
        [[ "$has_triage_result_col" -gt 0 ]] && { insert_cols="$insert_cols, triage_result"; select_cols="$select_cols, triage_result"; }

        db "$SUPERVISOR_DB" << MIGRATE
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks ($insert_cols)
SELECT $select_cols
FROM tasks_old;
DROP TABLE tasks_old;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE

        # Verify row counts after migration (t188)
        if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$t128_backup" "tasks"; then
            log_error "t128.8 migration VERIFICATION FAILED — rolling back"
            rollback_sqlite_db "$SUPERVISOR_DB" "$t128_backup"
            return 1
        fi
        log_success "Database schema migrated for post-PR lifecycle states (verified)"
    fi

    # Backup before ALTER TABLE migrations if any are needed (t162, t188)
    local needs_alter_migration=false
    local has_max_load has_release_on_complete has_diagnostic_of has_issue_url has_max_concurrency
    has_max_load=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='max_load_factor';" 2>/dev/null || echo "0")
    has_release_on_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='release_on_complete';" 2>/dev/null || echo "0")
    has_diagnostic_of=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='diagnostic_of';" 2>/dev/null || echo "0")
    has_issue_url=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='issue_url';" 2>/dev/null || echo "0")
    has_max_concurrency=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='max_concurrency';" 2>/dev/null || echo "0")
    if [[ "$has_max_load" -eq 0 || "$has_release_on_complete" -eq 0 || "$has_diagnostic_of" -eq 0 || "$has_issue_url" -eq 0 || "$has_max_concurrency" -eq 0 ]]; then
        needs_alter_migration=true
    fi
    if [[ "$needs_alter_migration" == "true" ]]; then
        local alter_backup
        alter_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-alter-columns")
        if [[ $? -ne 0 || -z "$alter_backup" ]]; then
            log_warn "Backup failed for ALTER TABLE migrations, proceeding cautiously"
        fi
    fi

    # Migrate: add max_load_factor column to batches if missing (t135.15.4)
    if [[ "$has_max_load" -eq 0 ]]; then
        log_info "Migrating batches table: adding max_load_factor column (t135.15.4)..."
        if ! log_cmd "db-migrate" db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN max_load_factor INTEGER NOT NULL DEFAULT 2;"; then
            log_warn "Failed to add max_load_factor column (may already exist)"
        else
            log_success "Added max_load_factor column to batches"
        fi
    fi

    # Migrate: add max_concurrency column to batches if missing (adaptive scaling cap)
    if [[ "$has_max_concurrency" -eq 0 ]]; then
        log_info "Migrating batches table: adding max_concurrency column..."
        db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN max_concurrency INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
        log_success "Added max_concurrency column to batches (0 = auto-detect from cpu_cores)"
    fi

    # Migrate: add release_on_complete and release_type columns to batches if missing (t128.10)
    if [[ "$has_release_on_complete" -eq 0 ]]; then
        log_info "Migrating batches table: adding release columns (t128.10)..."
        db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN release_on_complete INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
        db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN release_type TEXT NOT NULL DEFAULT 'patch';" 2>/dev/null || true
        log_success "Added release_on_complete and release_type columns to batches"
    fi

    # Migrate: add diagnostic_of column to tasks if missing (t150)
    if [[ "$has_diagnostic_of" -eq 0 ]]; then
        log_info "Migrating tasks table: adding diagnostic_of column (t150)..."
        db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN diagnostic_of TEXT;" 2>/dev/null || true
        db "$SUPERVISOR_DB" "CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);" 2>/dev/null || true
        log_success "Added diagnostic_of column to tasks"
    fi

    # Migrate: add issue_url column (t149)
    if [[ "$has_issue_url" -eq 0 ]]; then
        log_info "Migrating tasks table: adding issue_url column (t149)..."
        db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN issue_url TEXT;" 2>/dev/null || true
        log_success "Added issue_url column to tasks"
    fi

    # Migrate: add triage_result column to tasks if missing (t148)
    local has_triage_result
    has_triage_result=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='triage_result';" 2>/dev/null || echo "0")
    if [[ "$has_triage_result" -eq 0 ]]; then
        log_info "Migrating tasks table: adding triage_result column (t148)..."
        db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN triage_result TEXT;" 2>/dev/null || true
        log_success "Added triage_result column to tasks"
    fi

    # Migrate: add review_triage to CHECK constraint if missing (t148)
    local check_sql_t148
    check_sql_t148=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
    if [[ -n "$check_sql_t148" ]] && ! echo "$check_sql_t148" | grep -q 'review_triage'; then
        log_info "Migrating database schema for review_triage state (t148)..."

        # Backup before migration (t188: fail-safe — abort if backup fails)
        local t148_backup
        t148_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-t148")
        if [[ $? -ne 0 || -z "$t148_backup" ]]; then
            log_error "Backup failed for t148 migration — aborting"
            return 1
        fi

        db "$SUPERVISOR_DB" << 'MIGRATE_T148'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old_t148;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks (id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    created_at, started_at, completed_at, updated_at)
SELECT id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    created_at, started_at, completed_at, updated_at
FROM tasks_old_t148;
DROP TABLE tasks_old_t148;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE_T148

        # Verify row counts after migration (t188)
        if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$t148_backup" "tasks"; then
            log_error "t148 migration VERIFICATION FAILED — rolling back"
            rollback_sqlite_db "$SUPERVISOR_DB" "$t148_backup"
            return 1
        fi
        log_success "Database schema migrated for review_triage state (verified)"
    fi

    # Migration: add verifying/verified/verify_failed states to CHECK constraint (t180)
    # Check if the current schema already supports verify states
    # NOTE: This migration originally used "INSERT INTO tasks SELECT * FROM tasks_old_t180"
    # which silently fails if column counts don't match. Fixed in t188 to use explicit
    # column lists and row-count verification with automatic rollback.
    local has_verify_states
    has_verify_states=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
    if [[ -n "$has_verify_states" ]] && ! echo "$has_verify_states" | grep -q "verifying"; then
        log_info "Migrating database schema for post-merge verification states (t180)..."

        # Backup before migration (t188: fail-safe — abort if backup fails)
        local t180_backup
        t180_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-t180")
        if [[ $? -ne 0 || -z "$t180_backup" ]]; then
            log_error "Backup failed for t180 migration — aborting"
            return 1
        fi

        db "$SUPERVISOR_DB" << 'MIGRATE_T180'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old_t180;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks (id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    triage_result, created_at, started_at, completed_at, updated_at)
SELECT id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    triage_result, created_at, started_at, completed_at, updated_at
FROM tasks_old_t180;
DROP TABLE tasks_old_t180;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE_T180

        # Verify row counts after migration (t188)
        if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$t180_backup" "tasks"; then
            log_error "t180 migration VERIFICATION FAILED — rolling back"
            rollback_sqlite_db "$SUPERVISOR_DB" "$t180_backup"
            return 1
        fi
        log_success "Database schema migrated for post-merge verification states"
    fi

    # Migrate: add escalation_depth and max_escalation columns to tasks (t132.6)
    local has_escalation_depth
    has_escalation_depth=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='escalation_depth';" 2>/dev/null || echo "0")
    if [[ "$has_escalation_depth" -eq 0 ]]; then
        log_info "Migrating tasks table: adding escalation columns (t132.6)..."
        db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN escalation_depth INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
        db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN max_escalation INTEGER NOT NULL DEFAULT 2;" 2>/dev/null || true
        log_success "Added escalation_depth and max_escalation columns to tasks"
    fi

    # Migrate: add skip_quality_gate column to batches (t132.6)
    local has_skip_quality_gate
    has_skip_quality_gate=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='skip_quality_gate';" 2>/dev/null || echo "0")
    if [[ "$has_skip_quality_gate" -eq 0 ]]; then
        log_info "Migrating batches table: adding skip_quality_gate column (t132.6)..."
        db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN skip_quality_gate INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
        log_success "Added skip_quality_gate column to batches"
    fi

    # Migrate: add proof_logs table if missing (t218)
    local has_proof_logs
    has_proof_logs=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='proof_logs';" 2>/dev/null || echo "0")
    if [[ "$has_proof_logs" -eq 0 ]]; then
        log_info "Migrating database: adding proof_logs table (t218)..."
        db "$SUPERVISOR_DB" << 'MIGRATE_T218'
CREATE TABLE IF NOT EXISTS proof_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    event           TEXT NOT NULL,
    stage           TEXT,
    decision        TEXT,
    evidence        TEXT,
    decision_maker  TEXT,
    pr_url          TEXT,
    duration_secs   INTEGER,
    metadata        TEXT,
    timestamp       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_proof_logs_task ON proof_logs(task_id);
CREATE INDEX IF NOT EXISTS idx_proof_logs_event ON proof_logs(event);
CREATE INDEX IF NOT EXISTS idx_proof_logs_timestamp ON proof_logs(timestamp);
MIGRATE_T218
        log_success "Added proof_logs table (t218)"
    fi

    # Ensure WAL mode for existing databases created before t135.3
    local current_mode
    current_mode=$(db "$SUPERVISOR_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
    if [[ "$current_mode" != "wal" ]]; then
        log_cmd "db-wal" db "$SUPERVISOR_DB" "PRAGMA journal_mode=WAL;" || log_warn "Failed to enable WAL mode"
    fi

    return 0
}

#######################################
# Initialize SQLite database with schema
#######################################
init_db() {
    mkdir -p "$SUPERVISOR_DIR"

    db "$SUPERVISOR_DB" << 'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    escalation_depth INTEGER NOT NULL DEFAULT 0,
    max_escalation  INTEGER NOT NULL DEFAULT 2,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);

CREATE TABLE IF NOT EXISTS batches (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    concurrency     INTEGER NOT NULL DEFAULT 4,
    max_concurrency INTEGER NOT NULL DEFAULT 0,
    max_load_factor INTEGER NOT NULL DEFAULT 2,
    release_on_complete INTEGER NOT NULL DEFAULT 0,
    release_type    TEXT NOT NULL DEFAULT 'patch'
                    CHECK(release_type IN ('major','minor','patch')),
    skip_quality_gate INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active','paused','complete','cancelled')),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_batches_status ON batches(status);

CREATE TABLE IF NOT EXISTS batch_tasks (
    batch_id        TEXT NOT NULL,
    task_id         TEXT NOT NULL,
    position        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (batch_id, task_id),
    FOREIGN KEY (batch_id) REFERENCES batches(id) ON DELETE CASCADE,
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_batch_tasks_batch ON batch_tasks(batch_id);
CREATE INDEX IF NOT EXISTS idx_batch_tasks_task ON batch_tasks(task_id);

CREATE TABLE IF NOT EXISTS state_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    from_state      TEXT NOT NULL,
    to_state        TEXT NOT NULL,
    reason          TEXT,
    timestamp       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_state_log_task ON state_log(task_id);
CREATE INDEX IF NOT EXISTS idx_state_log_timestamp ON state_log(timestamp);

-- Proof-logs: structured audit trail for task completion trust (t218)
-- Each row is an immutable evidence record capturing what happened, what
-- evidence was used, and who/what made the decision. Enables:
--   - Trust verification: "why was this task marked complete?"
--   - Pipeline latency analysis: stage-level timing (t219 prep)
--   - Audit export: JSON/CSV for compliance or retrospective
CREATE TABLE IF NOT EXISTS proof_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    event           TEXT NOT NULL,
    stage           TEXT,
    decision        TEXT,
    evidence        TEXT,
    decision_maker  TEXT,
    pr_url          TEXT,
    duration_secs   INTEGER,
    metadata        TEXT,
    timestamp       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_proof_logs_task ON proof_logs(task_id);
CREATE INDEX IF NOT EXISTS idx_proof_logs_event ON proof_logs(event);
CREATE INDEX IF NOT EXISTS idx_proof_logs_timestamp ON proof_logs(timestamp);
SQL

    log_success "Initialized supervisor database: $SUPERVISOR_DB"
    return 0
}

#######################################
# Validate a state transition
# Returns 0 if valid, 1 if invalid
#######################################
validate_transition() {
    local from_state="$1"
    local to_state="$2"
    local transition="${from_state}:${to_state}"

    for valid in "${VALID_TRANSITIONS[@]}"; do
        if [[ "$valid" == "$transition" ]]; then
            return 0
        fi
    done

    return 1
}

#######################################
# Initialize database (explicit command)
#######################################
cmd_init() {
    ensure_db
    log_success "Supervisor database ready at: $SUPERVISOR_DB"

    local task_count
    task_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
    local batch_count
    batch_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM batches;")

    log_info "Tasks: $task_count | Batches: $batch_count"
    return 0
}

#######################################
# Backup supervisor database (t162)
#######################################
cmd_backup() {
    local reason="${1:-manual}"
    backup_db "$reason"
}

#######################################
# Restore supervisor database from backup (t162)
#######################################
cmd_restore() {
    local backup_file="${1:-}"
    restore_db "$backup_file"
}

#######################################
# Add a task to the supervisor
#######################################
cmd_add() {
    local task_id="" repo="" description="" model="anthropic/claude-opus-4-6" max_retries=3
    # t165: GH Issue creation is now opt-in (--with-issue), not opt-out.
    # TODO.md is the primary task registry; GH Issues are an optional sync layer.
    # SUPERVISOR_AUTO_ISSUE=true restores the old default for backward compat.
    local create_issue=false

    # First positional arg is task_id
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) [[ $# -lt 2 ]] && { log_error "--repo requires a value"; return 1; }; repo="$2"; shift 2 ;;
            --description) [[ $# -lt 2 ]] && { log_error "--description requires a value"; return 1; }; description="$2"; shift 2 ;;
            --model) [[ $# -lt 2 ]] && { log_error "--model requires a value"; return 1; }; model="$2"; shift 2 ;;
            --max-retries) [[ $# -lt 2 ]] && { log_error "--max-retries requires a value"; return 1; }; max_retries="$2"; shift 2 ;;
            --with-issue) create_issue=true; shift ;;
            --no-issue) create_issue=false; shift ;;  # Kept for backward compat (now the default)
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Backward compat: SUPERVISOR_AUTO_ISSUE=true restores old default
    if [[ "${SUPERVISOR_AUTO_ISSUE:-false}" == "true" && "$create_issue" == "false" ]]; then
        create_issue=true
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh add <task_id> [--repo path] [--description \"desc\"]"
        return 1
    fi

    # Default repo to current directory
    if [[ -z "$repo" ]]; then
        repo="$(pwd)"
    fi

    # Try to look up description from TODO.md if not provided
    if [[ -z "$description" ]]; then
        local todo_file="$repo/TODO.md"
        if [[ -f "$todo_file" ]]; then
            description=$(grep -E "^[[:space:]]*- \[( |x|-)\] $task_id " "$todo_file" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*- \[( |x|-)\] [^ ]* //' || true)
        fi
    fi

    ensure_db

    # Check if task already exists
    local existing
    existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';")
    if [[ -n "$existing" ]]; then
        log_warn "Task $task_id already exists (status: $existing)"
        return 1
    fi

    # Pre-add check: prevent re-queuing tasks that already have a merged PR (t224).
    # This catches tasks completed outside the supervisor (fresh DB, DB reset, etc.)
    # that would otherwise be re-added and re-dispatched, wasting compute.
    if check_task_already_done "$task_id" "$repo"; then
        log_warn "Task $task_id already completed (merged PR or [x] in TODO.md) — skipping add"
        return 1
    fi

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local escaped_repo
    escaped_repo=$(sql_escape "$repo")
    local escaped_desc
    escaped_desc=$(sql_escape "$description")
    local escaped_model
    escaped_model=$(sql_escape "$model")

    db "$SUPERVISOR_DB" "
        INSERT INTO tasks (id, repo, description, model, max_retries)
        VALUES ('$escaped_id', '$escaped_repo', '$escaped_desc', '$escaped_model', $max_retries);
    "

    # Log the initial state
    db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_id', '', 'queued', 'Task added to supervisor');
    "

    log_success "Added task: $task_id (repo: $repo)"
    if [[ -n "$description" ]]; then
        log_info "Description: $(echo "$description" | head -c 80)"
    fi

    # Create GitHub issue only if explicitly requested (t165: opt-in, not default)
    # Use --with-issue flag or SUPERVISOR_AUTO_ISSUE=true env var
    # t020.6: create_github_issue delegates to issue-sync-helper.sh which also
    # adds ref:GH#N to TODO.md and commits/pushes — no separate step needed.
    if [[ "$create_issue" == "true" ]]; then
        create_github_issue "$task_id" "$description" "$repo"
    fi

    return 0
}

#######################################
# Create or manage a batch
#######################################
cmd_batch() {
    local name="" concurrency=4 max_concurrency=0 tasks="" max_load_factor=2
    local release_on_complete=0 release_type="patch" skip_quality_gate=0

    # First positional arg is batch name
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        name="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --concurrency) [[ $# -lt 2 ]] && { log_error "--concurrency requires a value"; return 1; }; concurrency="$2"; shift 2 ;;
            --max-concurrency) [[ $# -lt 2 ]] && { log_error "--max-concurrency requires a value"; return 1; }; max_concurrency="$2"; shift 2 ;;
            --tasks) [[ $# -lt 2 ]] && { log_error "--tasks requires a value"; return 1; }; tasks="$2"; shift 2 ;;
            --max-load) [[ $# -lt 2 ]] && { log_error "--max-load requires a value"; return 1; }; max_load_factor="$2"; shift 2 ;;
            --release-on-complete) release_on_complete=1; shift ;;
            --release-type) [[ $# -lt 2 ]] && { log_error "--release-type requires a value"; return 1; }; release_type="$2"; shift 2 ;;
            --skip-quality-gate) skip_quality_gate=1; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$name" ]]; then
        log_error "Usage: supervisor-helper.sh batch <name> [--concurrency N] [--max-concurrency N] [--tasks \"t001,t002\"] [--release-on-complete] [--release-type patch|minor|major] [--skip-quality-gate]"
        return 1
    fi

    # Validate release_type
    case "$release_type" in
        major|minor|patch) ;;
        *) log_error "Invalid release type: $release_type (must be major, minor, or patch)"; return 1 ;;
    esac

    ensure_db

    local batch_id
    batch_id="batch-$(date +%Y%m%d%H%M%S)-$$"
    local escaped_id
    escaped_id=$(sql_escape "$batch_id")
    local escaped_name
    escaped_name=$(sql_escape "$name")
    local escaped_release_type
    escaped_release_type=$(sql_escape "$release_type")

    db "$SUPERVISOR_DB" "
        INSERT INTO batches (id, name, concurrency, max_concurrency, max_load_factor, release_on_complete, release_type, skip_quality_gate)
        VALUES ('$escaped_id', '$escaped_name', $concurrency, $max_concurrency, $max_load_factor, $release_on_complete, '$escaped_release_type', $skip_quality_gate);
    "

    local release_info=""
    if [[ "$release_on_complete" -eq 1 ]]; then
        release_info=", release: $release_type on complete"
    fi
    local max_conc_info=""
    if [[ "$max_concurrency" -gt 0 ]]; then
        max_conc_info=", max: $max_concurrency"
    else
        max_conc_info=", max: auto"
    fi
    local quality_gate_info=""
    if [[ "$skip_quality_gate" -eq 1 ]]; then
        quality_gate_info=", quality-gate: skipped"
    fi
    log_success "Created batch: $name (id: $batch_id, concurrency: $concurrency${max_conc_info}, max-load: $max_load_factor${release_info}${quality_gate_info})"

    # Add tasks to batch if provided
    if [[ -n "$tasks" ]]; then
        local position=0
        local -a task_array
        IFS=',' read -ra task_array <<< "$tasks"
        for task_id in "${task_array[@]}"; do
            task_id=$(echo "$task_id" | tr -d ' ')

            # Ensure task exists in tasks table (auto-add if not)
            local task_exists
            task_exists=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE id = '$(sql_escape "$task_id")';")
            if [[ "$task_exists" -eq 0 ]]; then
                cmd_add "$task_id"
            fi

            local escaped_task
            escaped_task=$(sql_escape "$task_id")
            db "$SUPERVISOR_DB" "
                INSERT OR IGNORE INTO batch_tasks (batch_id, task_id, position)
                VALUES ('$escaped_id', '$escaped_task', $position);
            "
            position=$((position + 1))
        done
        log_info "Added ${#task_array[@]} tasks to batch"
    fi

    echo "$batch_id"
    return 0
}

#######################################
# Transition a task to a new state
#######################################
cmd_transition() {
    local task_id="" new_state="" error_msg=""
    local session_id="" worktree="" branch="" log_file="" pr_url=""

    # Positional args
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        new_state="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --error) [[ $# -lt 2 ]] && { log_error "--error requires a value"; return 1; }; error_msg="$2"; shift 2 ;;
            --session) [[ $# -lt 2 ]] && { log_error "--session requires a value"; return 1; }; session_id="$2"; shift 2 ;;
            --worktree) [[ $# -lt 2 ]] && { log_error "--worktree requires a value"; return 1; }; worktree="$2"; shift 2 ;;
            --branch) [[ $# -lt 2 ]] && { log_error "--branch requires a value"; return 1; }; branch="$2"; shift 2 ;;
            --log-file) [[ $# -lt 2 ]] && { log_error "--log-file requires a value"; return 1; }; log_file="$2"; shift 2 ;;
            --pr-url) [[ $# -lt 2 ]] && { log_error "--pr-url requires a value"; return 1; }; pr_url="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task_id" || -z "$new_state" ]]; then
        log_error "Usage: supervisor-helper.sh transition <task_id> <new_state> [--error \"reason\"]"
        return 1
    fi

    # Validate new_state is a known state
    if [[ ! " $VALID_STATES " =~ [[:space:]]${new_state}[[:space:]] ]]; then
        log_error "Invalid state: $new_state"
        log_error "Valid states: $VALID_STATES"
        return 1
    fi

    ensure_db

    # Get current state
    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local current_state
    current_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

    if [[ -z "$current_state" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    # Validate transition
    if ! validate_transition "$current_state" "$new_state"; then
        log_error "Invalid transition: $current_state -> $new_state for task $task_id"
        log_error "Valid transitions from '$current_state':"
        for valid in "${VALID_TRANSITIONS[@]}"; do
            if [[ "$valid" == "${current_state}:"* ]]; then
                echo "  -> ${valid#*:}"
            fi
        done
        return 1
    fi

    # Build UPDATE query with optional fields
    local -a update_parts=("status = '$new_state'")
    update_parts+=("updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')")

    if [[ -n "$error_msg" ]]; then
        update_parts+=("error = '$(sql_escape "$error_msg")'")
    fi

    # Set started_at on first dispatch
    if [[ "$new_state" == "dispatched" && "$current_state" == "queued" ]]; then
        update_parts+=("started_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')")
    fi

    # Set completed_at on terminal states
    if [[ "$new_state" == "complete" || "$new_state" == "deployed" || "$new_state" == "verified" || "$new_state" == "failed" || "$new_state" == "cancelled" ]]; then
        update_parts+=("completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')")
    fi

    # Increment retries on retry
    if [[ "$new_state" == "retrying" ]]; then
        update_parts+=("retries = retries + 1")
    fi

    # Set optional metadata fields
    if [[ -n "${session_id:-}" ]]; then
        update_parts+=("session_id = '$(sql_escape "$session_id")'")
    fi
    if [[ -n "${worktree:-}" ]]; then
        update_parts+=("worktree = '$(sql_escape "$worktree")'")
    fi
    if [[ -n "${branch:-}" ]]; then
        update_parts+=("branch = '$(sql_escape "$branch")'")
    fi
    if [[ -n "${log_file:-}" ]]; then
        update_parts+=("log_file = '$(sql_escape "$log_file")'")
    fi
    if [[ -n "${pr_url:-}" ]]; then
        update_parts+=("pr_url = '$(sql_escape "$pr_url")'")
    fi

    local update_sql
    update_sql=$(IFS=','; echo "${update_parts[*]}")

    db "$SUPERVISOR_DB" "
        UPDATE tasks SET $update_sql WHERE id = '$escaped_id';
    "

    # Log the transition
    local escaped_reason
    escaped_reason=$(sql_escape "${error_msg:-State transition}")
    db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_id', '$current_state', '$new_state', '$escaped_reason');
    "

    log_success "Task $task_id: $current_state -> $new_state"
    if [[ -n "$error_msg" ]]; then
        log_info "Reason: $error_msg"
    fi

    # Proof-log: record lifecycle stage transitions (t218)
    # Only log transitions that represent significant pipeline stages
    # (not every micro-transition, to keep proof-logs focused)
    case "$new_state" in
        dispatched|pr_review|review_triage|merging|merged|deploying|deployed|verifying|verified|verify_failed)
            local _stage_duration
            _stage_duration=$(_proof_log_stage_duration "$task_id" "$current_state")
            write_proof_log --task "$task_id" --event "transition" --stage "$new_state" \
                --decision "$current_state->$new_state" \
                --evidence "${error_msg:+error=$error_msg}" \
                --maker "cmd_transition" \
                ${pr_url:+--pr-url "$pr_url"} \
                ${_stage_duration:+--duration "$_stage_duration"} 2>/dev/null || true
            ;;
    esac

    # Auto-generate VERIFY.md entry when task reaches deployed (t180.4)
    if [[ "$new_state" == "deployed" ]]; then
        generate_verify_entry "$task_id" 2>>"$SUPERVISOR_LOG" || true
    fi

    # Check if batch is complete after task completion
    check_batch_completion "$task_id"

    return 0
}

#######################################
# Trigger a release via version-manager.sh when a batch completes (t128.10)
#
# Called from check_batch_completion() when a batch with release_on_complete=1
# reaches completion. Runs version-manager.sh release from the batch's repo
# on the main branch.
#
# $1: batch_id
# $2: release_type (major|minor|patch)
# $3: repo path (from first task in batch)
#######################################
trigger_batch_release() {
    local batch_id="$1"
    local release_type="$2"
    local repo="$3"

    local version_manager="${SCRIPT_DIR}/version-manager.sh"
    if [[ ! -x "$version_manager" ]]; then
        log_error "version-manager.sh not found or not executable: $version_manager"
        return 1
    fi

    if [[ -z "$repo" || ! -d "$repo" ]]; then
        log_error "Invalid repo path for batch release: $repo"
        return 1
    fi

    # Validate release_type
    case "$release_type" in
        major|minor|patch) ;;
        *)
            log_error "Invalid release type for batch $batch_id: $release_type"
            return 1
            ;;
    esac

    local escaped_batch
    escaped_batch=$(sql_escape "$batch_id")
    local batch_name
    batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")

    # Gather batch stats for the release log
    local total_tasks complete_count failed_count
    total_tasks=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks WHERE batch_id = '$escaped_batch';
    ")
    complete_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status IN ('complete', 'deployed', 'merged');
    ")
    failed_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status IN ('failed', 'blocked');
    ")

    log_info "Triggering $release_type release for batch $batch_name ($complete_count/$total_tasks tasks complete, $failed_count failed)"

    # Release must run from the main repo on the main branch
    # version-manager.sh handles: bump, update files, changelog, tag, push, GitHub release
    local release_log
    release_log="$SUPERVISOR_DIR/logs/release-${batch_id}-$(date +%Y%m%d%H%M%S).log"
    mkdir -p "$SUPERVISOR_DIR/logs"

    # Ensure we're on main and in sync before releasing
    local current_branch
    current_branch=$(git -C "$repo" branch --show-current 2>/dev/null || echo "")
    if [[ "$current_branch" != "main" ]]; then
        log_warn "Repo not on main branch (on: $current_branch), switching..."
        git -C "$repo" checkout main 2>/dev/null || {
            log_error "Failed to switch to main branch for release"
            return 1
        }
    fi

    # Pull latest (all batch PRs should be merged by now)
    git -C "$repo" pull --ff-only origin main 2>/dev/null || {
        log_warn "Fast-forward pull failed, trying rebase..."
        git -C "$repo" pull --rebase origin main 2>/dev/null || {
            log_error "Failed to pull latest main for release"
            return 1
        }
    }

    # Run the release (--skip-preflight: batch tasks already passed CI individually)
    local release_output=""
    local release_exit=0
    release_output=$(cd "$repo" && bash "$version_manager" release "$release_type" --skip-preflight 2>&1) || release_exit=$?

    echo "$release_output" > "$release_log" 2>/dev/null || true

    if [[ "$release_exit" -ne 0 ]]; then
        log_error "Release failed for batch $batch_name (exit: $release_exit)"
        log_error "See log: $release_log"
        # Store failure in memory for future reference
        if [[ -x "$MEMORY_HELPER" ]]; then
            "$MEMORY_HELPER" store \
                --auto \
                --type "FAILED_APPROACH" \
                --content "Batch release failed: $batch_name ($release_type). Exit: $release_exit. Check $release_log" \
                --tags "supervisor,release,batch,$batch_name,failed" \
                2>/dev/null || true
        fi
        # Send notification about release failure
        send_task_notification "batch-$batch_id" "failed" "Batch release ($release_type) failed for $batch_name" 2>/dev/null || true
        return 1
    fi

    # Extract the new version from the release output
    local new_version
    new_version=$(echo "$release_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || echo "unknown")

    log_success "Release $new_version created for batch $batch_name ($release_type)"

    # Store success in memory
    if [[ -x "$MEMORY_HELPER" ]]; then
        "$MEMORY_HELPER" store \
            --auto \
            --type "WORKING_SOLUTION" \
            --content "Batch release succeeded: $batch_name -> v$new_version ($release_type). $complete_count/$total_tasks tasks, $failed_count failed." \
            --tags "supervisor,release,batch,$batch_name,success,v$new_version" \
            2>/dev/null || true
    fi

    # Send notification about successful release
    send_task_notification "batch-$batch_id" "deployed" "Released v$new_version ($release_type) for batch $batch_name" 2>/dev/null || true

    # macOS celebration notification
    if [[ "$(uname)" == "Darwin" ]]; then
        nohup afplay /System/Library/Sounds/Hero.aiff &>/dev/null &
    fi

    return 0
}

#######################################
# Check if a batch is complete after task state change
#######################################
check_batch_completion() {
    local task_id="$1"
    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Find batches containing this task
    local batch_ids
    batch_ids=$(db "$SUPERVISOR_DB" "
        SELECT batch_id FROM batch_tasks WHERE task_id = '$escaped_id';
    ")

    if [[ -z "$batch_ids" ]]; then
        return 0
    fi

    while IFS= read -r batch_id; do
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")

        # Count incomplete tasks in this batch
        local incomplete
        incomplete=$(db "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status NOT IN ('complete', 'deployed', 'verified', 'merged', 'failed', 'cancelled');
        ")

        if [[ "$incomplete" -eq 0 ]]; then
            db "$SUPERVISOR_DB" "
                UPDATE batches SET status = 'complete', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch' AND status = 'active';
            "
            log_success "Batch $batch_id is now complete"
            # Run batch retrospective and store insights (t128.6)
            run_batch_retrospective "$batch_id" 2>>"$SUPERVISOR_LOG" || true

            # Run session review and distillation (t128.9)
            run_session_review "$batch_id" 2>>"$SUPERVISOR_LOG" || true

            # Trigger automatic release if configured (t128.10)
            local batch_release_flag
            batch_release_flag=$(db "$SUPERVISOR_DB" "SELECT release_on_complete FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "0")
            if [[ "$batch_release_flag" -eq 1 ]]; then
                local batch_release_type
                batch_release_type=$(db "$SUPERVISOR_DB" "SELECT release_type FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "patch")
                # Get repo from the first task in the batch
                local batch_repo
                batch_repo=$(db "$SUPERVISOR_DB" "
                    SELECT t.repo FROM batch_tasks bt
                    JOIN tasks t ON bt.task_id = t.id
                    WHERE bt.batch_id = '$escaped_batch'
                    ORDER BY bt.position LIMIT 1;
                " 2>/dev/null || echo "")
                if [[ -n "$batch_repo" ]]; then
                    log_info "Batch $batch_id has release_on_complete enabled ($batch_release_type)"
                    trigger_batch_release "$batch_id" "$batch_release_type" "$batch_repo" 2>>"$SUPERVISOR_LOG" || {
                        log_error "Automatic release failed for batch $batch_id (non-blocking)"
                    }
                else
                    log_warn "Cannot trigger release for batch $batch_id: no repo found"
                fi
            fi
        fi
    done <<< "$batch_ids"

    return 0
}

#######################################
# Show status of a task, batch, or overall
#######################################
cmd_status() {
    local target="${1:-}"

    ensure_db

    if [[ -z "$target" ]]; then
        # Overall status
        echo -e "${BOLD}=== Supervisor Status ===${NC}"
        echo ""

        # Task counts by state
        echo "Tasks:"
        db -separator ': ' "$SUPERVISOR_DB" "
            SELECT status, count(*) FROM tasks GROUP BY status ORDER BY
            CASE status
                WHEN 'running' THEN 1
                WHEN 'dispatched' THEN 2
                WHEN 'evaluating' THEN 3
                WHEN 'retrying' THEN 4
                WHEN 'queued' THEN 5
                WHEN 'pr_review' THEN 6
                WHEN 'review_triage' THEN 7
                WHEN 'merging' THEN 8
                WHEN 'deploying' THEN 9
                WHEN 'blocked' THEN 10
                WHEN 'failed' THEN 11
                WHEN 'complete' THEN 12
                WHEN 'merged' THEN 13
                WHEN 'deployed' THEN 14
                WHEN 'cancelled' THEN 15
            END;
        " 2>/dev/null | while IFS=': ' read -r state count; do
            local color="$NC"
            case "$state" in
                running|dispatched) color="$GREEN" ;;
                evaluating|retrying|pr_review|review_triage|merging|deploying|verifying) color="$YELLOW" ;;
                blocked|failed|verify_failed) color="$RED" ;;
                complete|merged) color="$CYAN" ;;
                deployed|verified) color="$GREEN" ;;
            esac
            echo -e "  ${color}${state}${NC}: $count"
        done

        local total
        total=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
        echo "  total: $total"
        echo ""

        # Active batches
        echo "Batches:"
        local batches
        batches=$(db -separator '|' "$SUPERVISOR_DB" "
            SELECT b.id, b.name, b.concurrency, b.status,
                   (SELECT count(*) FROM batch_tasks bt WHERE bt.batch_id = b.id) as task_count,
                   (SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
                    WHERE bt.batch_id = b.id AND t.status = 'complete') as done_count,
                   b.release_on_complete, b.release_type
            FROM batches b ORDER BY b.created_at DESC LIMIT 10;
        ")

        if [[ -n "$batches" ]]; then
            while IFS='|' read -r bid bname bconc bstatus btotal bdone brelease_flag brelease_type; do
                local release_label=""
                if [[ "${brelease_flag:-0}" -eq 1 ]]; then
                    release_label=", release:${brelease_type:-patch}"
                fi
                echo -e "  ${CYAN}$bname${NC} ($bid) [$bstatus] $bdone/$btotal tasks, concurrency:$bconc${release_label}"
            done <<< "$batches"
        else
            echo "  No batches"
        fi

        echo ""

        # DB file size
        if [[ -f "$SUPERVISOR_DB" ]]; then
            local db_size
            db_size=$(du -h "$SUPERVISOR_DB" | cut -f1)
            echo "Database: $SUPERVISOR_DB ($db_size)"
        fi

        return 0
    fi

    # Check if target is a task or batch
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, session_id, worktree, branch,
               log_file, retries, max_retries, model, error, pr_url,
               created_at, started_at, completed_at
        FROM tasks WHERE id = '$(sql_escape "$target")';
    ")

    if [[ -n "$task_row" ]]; then
        echo -e "${BOLD}=== Task: $target ===${NC}"
        IFS='|' read -r tid trepo tdesc tstatus tsession tworktree tbranch \
            tlog tretries tmax_retries tmodel terror tpr tcreated tstarted tcompleted <<< "$task_row"

        echo -e "  Status:      ${BOLD}$tstatus${NC}"
        echo "  Repo:        $trepo"
        [[ -n "$tdesc" ]] && echo "  Description: $(echo "$tdesc" | head -c 100)"
        echo "  Model:       $tmodel"
        echo "  Retries:     $tretries / $tmax_retries"
        [[ -n "$tsession" ]] && echo "  Session:     $tsession"
        [[ -n "$tworktree" ]] && echo "  Worktree:    $tworktree"
        [[ -n "$tbranch" ]] && echo "  Branch:      $tbranch"
        [[ -n "$tlog" ]] && echo "  Log:         $tlog"
        [[ -n "$terror" ]] && echo -e "  Error:       ${RED}$terror${NC}"
        [[ -n "$tpr" ]] && echo "  PR:          $tpr"
        echo "  Created:     $tcreated"
        [[ -n "$tstarted" ]] && echo "  Started:     $tstarted"
        [[ -n "$tcompleted" ]] && echo "  Completed:   $tcompleted"

        # Show state history
        echo ""
        echo "  State History:"
        db -separator '|' "$SUPERVISOR_DB" "
            SELECT from_state, to_state, reason, timestamp
            FROM state_log WHERE task_id = '$(sql_escape "$target")'
            ORDER BY timestamp ASC;
        " | while IFS='|' read -r from to reason ts; do
            if [[ -z "$from" ]]; then
                echo "    $ts: -> $to ($reason)"
            else
                echo "    $ts: $from -> $to ($reason)"
            fi
        done

        # Show batch membership
        local batch_membership
        batch_membership=$(db -separator '|' "$SUPERVISOR_DB" "
            SELECT b.name, b.id FROM batch_tasks bt
            JOIN batches b ON bt.batch_id = b.id
            WHERE bt.task_id = '$(sql_escape "$target")';
        ")
        if [[ -n "$batch_membership" ]]; then
            echo ""
            echo "  Batches:"
            while IFS='|' read -r bname bid; do
                echo "    $bname ($bid)"
            done <<< "$batch_membership"
        fi

        return 0
    fi

    # Check if target is a batch
    local batch_row
    batch_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, name, concurrency, status, created_at, release_on_complete, release_type
        FROM batches WHERE id = '$(sql_escape "$target")' OR name = '$(sql_escape "$target")';
    ")

    if [[ -n "$batch_row" ]]; then
        local bid bname bconc bstatus bcreated brelease_flag brelease_type
        IFS='|' read -r bid bname bconc bstatus bcreated brelease_flag brelease_type <<< "$batch_row"
        local bmax_conc
        bmax_conc=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$(sql_escape "$bid")';" 2>/dev/null || echo "0")
        local bmax_load
        bmax_load=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_load_factor, 2) FROM batches WHERE id = '$(sql_escape "$bid")';" 2>/dev/null || echo "2")
        local badaptive
        badaptive=$(calculate_adaptive_concurrency "${bconc:-4}" "${bmax_load:-2}" "${bmax_conc:-0}")
        local cap_display="auto"
        [[ "${bmax_conc:-0}" -gt 0 ]] && cap_display="$bmax_conc"
        echo -e "${BOLD}=== Batch: $bname ===${NC}"
        echo "  ID:          $bid"
        echo "  Status:      $bstatus"
        echo "  Concurrency: $bconc (adaptive: $badaptive, cap: $cap_display)"
        if [[ "${brelease_flag:-0}" -eq 1 ]]; then
            echo -e "  Release:     ${GREEN}enabled${NC} (${brelease_type:-patch} on complete)"
        else
            echo "  Release:     disabled"
        fi
        echo "  Created:     $bcreated"
        echo ""
        echo "  Tasks:"

        db -separator '|' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries
            FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$(sql_escape "$bid")'
            ORDER BY bt.position;
        " | while IFS='|' read -r tid tstatus tdesc tretries tmax; do
            local color="$NC"
            case "$tstatus" in
                running|dispatched) color="$GREEN" ;;
                evaluating|retrying|pr_review|review_triage|merging|deploying|verifying) color="$YELLOW" ;;
                blocked|failed|verify_failed) color="$RED" ;;
                complete|merged) color="$CYAN" ;;
                deployed|verified) color="$GREEN" ;;
            esac
            local desc_short
            desc_short=$(echo "$tdesc" | head -c 60)
            echo -e "    ${color}[$tstatus]${NC} $tid: $desc_short (retries: $tretries/$tmax)"
        done

        return 0
    fi

    log_error "Not found: $target (not a task ID or batch ID/name)"
    return 1
}

#######################################
# List tasks with optional filters
#######################################
cmd_list() {
    local state="" batch="" format="text"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state) [[ $# -lt 2 ]] && { log_error "--state requires a value"; return 1; }; state="$2"; shift 2 ;;
            --batch) [[ $# -lt 2 ]] && { log_error "--batch requires a value"; return 1; }; batch="$2"; shift 2 ;;
            --format) [[ $# -lt 2 ]] && { log_error "--format requires a value"; return 1; }; format="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_db

    local where_clauses=()
    if [[ -n "$state" ]]; then
        where_clauses+=("t.status = '$(sql_escape "$state")'")
    fi
    if [[ -n "$batch" ]]; then
        where_clauses+=("EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch")')")
    fi

    local where_sql=""
    if [[ ${#where_clauses[@]} -gt 0 ]]; then
        where_sql="WHERE $(IFS=' AND '; echo "${where_clauses[*]}")"
    fi

    if [[ "$format" == "json" ]]; then
        db -json "$SUPERVISOR_DB" "
            SELECT t.id, t.repo, t.description, t.status, t.retries, t.max_retries,
                   t.model, t.error, t.pr_url, t.session_id, t.worktree, t.branch,
                   t.created_at, t.started_at, t.completed_at
            FROM tasks t $where_sql
            ORDER BY t.created_at DESC;
        "
    else
        local results
        results=$(db -separator '|' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries, t.repo
            FROM tasks t $where_sql
            ORDER BY
                CASE t.status
                    WHEN 'running' THEN 1
                    WHEN 'dispatched' THEN 2
                    WHEN 'evaluating' THEN 3
                    WHEN 'retrying' THEN 4
                    WHEN 'queued' THEN 5
                    WHEN 'pr_review' THEN 6
                    WHEN 'review_triage' THEN 7
                    WHEN 'merging' THEN 8
                    WHEN 'deploying' THEN 9
                    WHEN 'blocked' THEN 10
                    WHEN 'failed' THEN 11
                    WHEN 'complete' THEN 12
                    WHEN 'merged' THEN 13
                    WHEN 'deployed' THEN 14
                    WHEN 'cancelled' THEN 15
                END, t.created_at DESC;
        ")

        if [[ -z "$results" ]]; then
            log_info "No tasks found"
            return 0
        fi

        while IFS='|' read -r tid tstatus tdesc tretries tmax trepo; do
            local color="$NC"
            case "$tstatus" in
                running|dispatched) color="$GREEN" ;;
                evaluating|retrying|pr_review|review_triage|merging|deploying|verifying) color="$YELLOW" ;;
                blocked|failed|verify_failed) color="$RED" ;;
                complete|merged) color="$CYAN" ;;
                deployed|verified) color="$GREEN" ;;
            esac
            local desc_short
            desc_short=$(echo "$tdesc" | head -c 60)
            echo -e "${color}[$tstatus]${NC} $tid: $desc_short (retries: $tretries/$tmax)"
        done <<< "$results"
    fi

    return 0
}

#######################################
# Reset a task back to queued state
#######################################
cmd_reset() {
    local task_id="${1:-}"

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh reset <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local current_state
    current_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

    if [[ -z "$current_state" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    if [[ "$current_state" == "queued" ]]; then
        log_info "Task $task_id is already queued"
        return 0
    fi

    # Only allow reset from terminal or blocked states
    if [[ "$current_state" != "blocked" && "$current_state" != "failed" && "$current_state" != "cancelled" && "$current_state" != "complete" ]]; then
        log_error "Cannot reset task in '$current_state' state. Only blocked/failed/cancelled/complete tasks can be reset."
        return 1
    fi

    # Pre-reset check: prevent re-queuing tasks that already have a merged PR (t224).
    # Without this, a completed task can be reset -> queued -> dispatched, wasting
    # an entire AI session on work that's already done and merged.
    local task_repo
    task_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';")
    if check_task_already_done "$task_id" "${task_repo:-.}"; then
        log_warn "Task $task_id has a merged PR or is marked [x] in TODO.md — refusing reset"
        log_warn "Use 'cancel' instead, or remove the merged PR reference to force reset"
        return 1
    fi

    db "$SUPERVISOR_DB" "
        UPDATE tasks SET
            status = 'queued',
            retries = 0,
            error = NULL,
            session_id = NULL,
            worktree = NULL,
            branch = NULL,
            log_file = NULL,
            pr_url = NULL,
            started_at = NULL,
            completed_at = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$escaped_id';
    "

    db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_id', '$current_state', 'queued', 'Manual reset');
    "

    log_success "Task $task_id reset: $current_state -> queued"
    return 0
}

#######################################
# Cancel a task or batch
#######################################
cmd_cancel() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        log_error "Usage: supervisor-helper.sh cancel <task_id|batch_id>"
        return 1
    fi

    ensure_db

    local escaped_target
    escaped_target=$(sql_escape "$target")

    # Try as task first
    local task_status
    task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_target';")

    if [[ -n "$task_status" ]]; then
        if [[ "$task_status" == "deployed" || "$task_status" == "cancelled" || "$task_status" == "failed" ]]; then
            log_warn "Task $target is already in terminal state: $task_status"
            return 0
        fi

        # Check if transition is valid
        if ! validate_transition "$task_status" "cancelled"; then
            log_error "Cannot cancel task in '$task_status' state"
            return 1
        fi

        db "$SUPERVISOR_DB" "
            UPDATE tasks SET
                status = 'cancelled',
                completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = '$escaped_target';
        "

        db "$SUPERVISOR_DB" "
            INSERT INTO state_log (task_id, from_state, to_state, reason)
            VALUES ('$escaped_target', '$task_status', 'cancelled', 'Manual cancellation');
        "

        log_success "Cancelled task: $target"
        return 0
    fi

    # Try as batch
    local batch_status
    batch_status=$(db "$SUPERVISOR_DB" "SELECT status FROM batches WHERE id = '$escaped_target' OR name = '$escaped_target';")

    if [[ -n "$batch_status" ]]; then
        local batch_id
        batch_id=$(db "$SUPERVISOR_DB" "SELECT id FROM batches WHERE id = '$escaped_target' OR name = '$escaped_target';")
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")

        db "$SUPERVISOR_DB" "
            UPDATE batches SET status = 'cancelled', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = '$escaped_batch';
        "

        # Cancel all non-terminal tasks in the batch
        local cancelled_count
        cancelled_count=$(db "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status NOT IN ('deployed', 'merged', 'failed', 'cancelled');
        ")

        db "$SUPERVISOR_DB" "
            UPDATE tasks SET
                status = 'cancelled',
                completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id IN (
                SELECT task_id FROM batch_tasks WHERE batch_id = '$escaped_batch'
            ) AND status NOT IN ('deployed', 'merged', 'failed', 'cancelled');
        "

        log_success "Cancelled batch: $target ($cancelled_count tasks cancelled)"
        return 0
    fi

    log_error "Not found: $target"
    return 1
}

#######################################
# Ensure status labels exist in the repo (t164)
# Creates status:available, status:claimed, status:in-review, status:done
# if they don't already exist. Idempotent — safe to call repeatedly.
# $1: repo_slug (e.g. "owner/repo")
#######################################
ensure_status_labels() {
    local repo_slug="${1:-}"
    if [[ -z "$repo_slug" ]]; then
        return 0
    fi

    # --force updates existing labels without error, creates if missing
    gh label create "status:available" --repo "$repo_slug" --color "0E8A16" --description "Task is available for claiming" --force 2>/dev/null || true
    gh label create "status:claimed" --repo "$repo_slug" --color "D93F0B" --description "Task is claimed by a worker" --force 2>/dev/null || true
    gh label create "status:in-review" --repo "$repo_slug" --color "FBCA04" --description "Task PR is in review" --force 2>/dev/null || true
    gh label create "status:done" --repo "$repo_slug" --color "6F42C1" --description "Task is complete" --force 2>/dev/null || true
    return 0
}

#######################################
# Find GitHub issue number for a task from TODO.md (t164)
# Outputs the issue number on stdout, empty if not found.
# $1: task_id
# $2: project_root (optional, default: find_project_root)
#######################################
find_task_issue_number() {
    local task_id="${1:-}"
    local project_root="${2:-}"

    if [[ -z "$task_id" ]]; then
        return 0
    fi

    # Escape dots in task_id for regex (e.g. t128.10 -> t128\.10)
    local task_id_escaped
    task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')

    if [[ -z "$project_root" ]]; then
        project_root=$(find_project_root 2>/dev/null || echo ".")
    fi

    local todo_file="$project_root/TODO.md"
    if [[ -f "$todo_file" ]]; then
        local task_line
        task_line=$(grep -E "^[[:space:]]*- \[.\] ${task_id_escaped} " "$todo_file" | head -1 || echo "")
        echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo ""
    fi
    return 0
}

#######################################
# Get the identity string for task claiming (t165)
# Priority: AIDEVOPS_IDENTITY env > GitHub username (cached) > user@hostname
# The GitHub username is preferred because TODO.md assignees typically use
# GitHub usernames (e.g., assignee:marcusquinn), not user@host format.
#######################################
get_aidevops_identity() {
    if [[ -n "${AIDEVOPS_IDENTITY:-}" ]]; then
        echo "$AIDEVOPS_IDENTITY"
        return 0
    fi

    # Try GitHub username (cached for the session to avoid repeated API calls)
    # Validate: must be a simple alphanumeric string (not JSON error like {"message":"..."})
    if [[ -z "${_CACHED_GH_USERNAME:-}" ]]; then
        local gh_user=""
        gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
        if [[ -n "$gh_user" && "$gh_user" =~ ^[A-Za-z0-9._-]+$ ]]; then
            _CACHED_GH_USERNAME="$gh_user"
        fi
    fi
    if [[ -n "${_CACHED_GH_USERNAME:-}" ]]; then
        echo "$_CACHED_GH_USERNAME"
        return 0
    fi

    local user host
    user=$(whoami 2>/dev/null || echo "unknown")
    host=$(hostname -s 2>/dev/null || echo "local")
    echo "${user}@${host}"
    return 0
}

#######################################
# Get the assignee: value from a task line in TODO.md (t165)
# Outputs the assignee identity string, empty if unassigned.
# $1: task_id  $2: todo_file path
#######################################
get_task_assignee() {
    local task_id="$1"
    local todo_file="$2"

    if [[ ! -f "$todo_file" ]]; then
        return 0
    fi

    local task_id_escaped
    task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')

    local task_line
    task_line=$(grep -E "^[[:space:]]*- \[.\] ${task_id_escaped} " "$todo_file" | head -1 || echo "")
    if [[ -z "$task_line" ]]; then
        return 0
    fi

    # Extract assignee:value — unambiguous key:value field
    local assignee
    assignee=$(echo "$task_line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo "")
    echo "$assignee"
    return 0
}

#######################################
# Claim a task (t165)
# Primary: TODO.md assignee: field (provider-agnostic, offline-capable)
# Optional: sync to GitHub Issue assignee if ref:GH# exists and gh is available
#######################################
cmd_claim() {
    local task_id="${1:-}"
    local explicit_root="${2:-}"

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh claim <task_id> [project_root]"
        return 1
    fi

    local project_root
    if [[ -n "$explicit_root" && -f "$explicit_root/TODO.md" ]]; then
        project_root="$explicit_root"
    else
        project_root=$(find_project_root 2>/dev/null || echo "")
        # Fallback: look up repo from task DB record (needed for cron/non-interactive)
        if [[ -z "$project_root" || ! -f "$project_root/TODO.md" ]]; then
            local db_repo=""
            db_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
            if [[ -n "$db_repo" && -f "$db_repo/TODO.md" ]]; then
                project_root="$db_repo"
            fi
        fi
    fi
    local todo_file="$project_root/TODO.md"

    if [[ ! -f "$todo_file" ]]; then
        log_error "TODO.md not found at $todo_file"
        return 1
    fi

    local identity
    identity=$(get_aidevops_identity)

    # Validate identity is safe for sed interpolation (no newlines, pipes, or JSON)
    if [[ -z "$identity" || "$identity" == *$'\n'* || "$identity" == *"{"* ]]; then
        log_error "Invalid identity for claim: '${identity:0:40}...' — check gh auth or set AIDEVOPS_IDENTITY"
        return 1
    fi

    # Check current assignee in TODO.md
    local current_assignee
    current_assignee=$(get_task_assignee "$task_id" "$todo_file")

    if [[ -n "$current_assignee" ]]; then
        # Use check_task_claimed for consistent fuzzy matching (handles
        # username vs user@host mismatches)
        local claimed_other=""
        claimed_other=$(check_task_claimed "$task_id" "$project_root" 2>/dev/null) || true
        if [[ -z "$claimed_other" ]]; then
            log_info "$task_id already claimed by you (assignee:$current_assignee)"
            return 0
        fi
        log_error "$task_id is claimed by assignee:$current_assignee"
        return 1
    fi

    # Verify task exists and is open (supports both top-level and indented subtasks)
    local task_id_escaped
    task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')
    local task_line
    task_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id_escaped} " "$todo_file" | head -1 || echo "")
    if [[ -z "$task_line" ]]; then
        log_error "Task $task_id not found as open in $todo_file"
        return 1
    fi

    # Add assignee:identity and started:ISO to the task line
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local line_num
    line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id_escaped} " "$todo_file" | head -1 | cut -d: -f1)
    if [[ -z "$line_num" ]]; then
        log_error "Could not find line number for $task_id"
        return 1
    fi

    # Escape identity for safe sed interpolation (handles . / & \ in user@host)
    local identity_esc
    identity_esc=$(printf '%s' "$identity" | sed -e 's/[\/&.\\]/\\&/g')

    # Insert assignee: and started: before logged: or at end of metadata
    local new_line
    if echo "$task_line" | grep -qE 'logged:'; then
        new_line=$(echo "$task_line" | sed -E "s/( logged:)/ assignee:${identity_esc} started:${now}\1/")
    else
        new_line="${task_line} assignee:${identity} started:${now}"
    fi
    sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"

    # Commit and push (optimistic lock — push failure = someone else claimed first)
    if commit_and_push_todo "$project_root" "chore: claim $task_id by assignee:$identity"; then
        log_success "Claimed $task_id (assignee:$identity, started:$now)"
    else
        # Push failed — check if someone else claimed
        git -C "$project_root" checkout -- TODO.md 2>/dev/null || true
        git -C "$project_root" pull --rebase 2>/dev/null || true
        local new_assignee
        new_assignee=$(get_task_assignee "$task_id" "$todo_file")
        if [[ -n "$new_assignee" && "$new_assignee" != "$identity" ]]; then
            log_error "$task_id was claimed by assignee:$new_assignee (race condition)"
            return 1
        fi
        log_warn "Claimed locally but push failed — will retry on next pulse"
    fi

    # Optional: sync to GitHub Issue assignee (bi-directional sync layer)
    sync_claim_to_github "$task_id" "$project_root" "claim"
    return 0
}

#######################################
# Release a claimed task (t165)
# Primary: TODO.md remove assignee:
# Optional: sync to GitHub Issue
#######################################
cmd_unclaim() {
    local task_id="${1:-}"
    local explicit_root="${2:-}"

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh unclaim <task_id> [project_root]"
        return 1
    fi

    local project_root
    if [[ -n "$explicit_root" && -f "$explicit_root/TODO.md" ]]; then
        project_root="$explicit_root"
    else
        project_root=$(find_project_root 2>/dev/null || echo "")
        # Fallback: look up repo from task DB record (needed for cron/non-interactive)
        if [[ -z "$project_root" || ! -f "$project_root/TODO.md" ]]; then
            local db_repo=""
            db_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
            if [[ -n "$db_repo" && -f "$db_repo/TODO.md" ]]; then
                project_root="$db_repo"
            fi
        fi
    fi
    local todo_file="$project_root/TODO.md"

    if [[ ! -f "$todo_file" ]]; then
        log_error "TODO.md not found at $todo_file"
        return 1
    fi

    local identity
    identity=$(get_aidevops_identity)

    local current_assignee
    current_assignee=$(get_task_assignee "$task_id" "$todo_file")

    if [[ -z "$current_assignee" ]]; then
        log_info "$task_id is not claimed"
        return 0
    fi

    # Use check_task_claimed for consistent fuzzy matching
    local claimed_other=""
    claimed_other=$(check_task_claimed "$task_id" "$project_root" 2>/dev/null) || true
    if [[ -n "$claimed_other" ]]; then
        log_error "$task_id is claimed by assignee:$current_assignee, not by you (assignee:$identity)"
        return 1
    fi

    # Remove assignee:identity and started:... from the task line
    local task_id_escaped
    task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')
    local line_num
    line_num=$(grep -nE "^[[:space:]]*- \[.\] ${task_id_escaped} " "$todo_file" | head -1 | cut -d: -f1)
    if [[ -z "$line_num" ]]; then
        log_error "Could not find line number for $task_id"
        return 1
    fi

    local task_line
    task_line=$(sed -n "${line_num}p" "$todo_file")
    local new_line
    # Remove assignee:value and started:value
    # Use character class pattern (no identity interpolation needed — matches any assignee)
    new_line=$(echo "$task_line" | sed -E "s/ ?assignee:[A-Za-z0-9._@-]+//; s/ ?started:[0-9T:Z-]+//")
    sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"

    if commit_and_push_todo "$project_root" "chore: unclaim $task_id (released by assignee:$identity)"; then
        log_success "Released $task_id (unclaimed by assignee:$identity)"
    else
        log_warn "Unclaimed locally but push failed — will retry on next pulse"
    fi

    # Optional: sync to GitHub Issue
    sync_claim_to_github "$task_id" "$project_root" "unclaim"
    return 0
}

#######################################
# Check if a task is claimed by someone else (t165)
# Primary: TODO.md assignee: field (instant, offline)
# Returns 0 if free or claimed by self, 1 if claimed by another.
# Outputs the assignee on stdout if claimed by another.
#######################################
# check_task_already_done() — pre-dispatch verification
# Checks git history for evidence that a task was already completed.
# Returns 0 (true) if task appears done, 1 (false) if not.
# Searches for: (1) commits with task ID in message, (2) TODO.md [x] marker,
# (3) merged PR references. Fast path: git log grep is O(log n) on packed refs.
check_task_already_done() {
    local task_id="${1:-}"
    local project_root="${2:-.}"

    if [[ -z "$task_id" ]]; then
        return 1
    fi

    # Check 1: Is the task already marked [x] in TODO.md?
    # IMPORTANT: TODO.md may contain the same task ID in multiple sections:
    # - Active task list (authoritative — near the top)
    # - Completed plan archive (historical — further down, from earlier iterations)
    # We must check the FIRST occurrence only. If the first match is [x], it's done.
    # If the first match is [ ] or [-], it's NOT done (even if a later [x] exists).
    local todo_file="$project_root/TODO.md"
    if [[ -f "$todo_file" ]]; then
        local first_match=""
        first_match=$(grep -E "^\s*- \[(x| |-)\] ${task_id}[[:space:]]" "$todo_file" 2>/dev/null | head -1) || true
        if [[ -n "$first_match" ]]; then
            if [[ "$first_match" =~ \[x\] ]]; then
                log_info "Pre-dispatch check: $task_id is marked [x] in TODO.md (first occurrence)" >&2
                return 0
            else
                # First occurrence is [ ] or [-] — task is NOT done, skip further checks
                log_info "Pre-dispatch check: $task_id is [ ] in TODO.md (first occurrence — ignoring any later [x] entries)" >&2
                return 1
            fi
        fi
    fi

    # Check 2: Are there merged commits referencing this task ID?
    # IMPORTANT: Use word-boundary matching to prevent t020 matching t020.6.
    # Escaped task_id for regex: dots become literal dots.
    local escaped_task_regex
    escaped_task_regex=$(printf '%s' "$task_id" | sed 's/\./\\./g')
    # grep -w uses word boundaries but dots aren't word chars, so for subtask IDs
    # like t020.1 we need a custom boundary: task_id followed by non-digit or EOL.
    # This prevents t020 from matching t020.1, t020.2, etc.
    local boundary_pattern="${task_id}([^.0-9]|$)"

    local commit_count=0
    commit_count=$(git -C "$project_root" log --oneline -500 --all --grep="$task_id" 2>/dev/null \
        | grep -cE "$boundary_pattern" 2>/dev/null) || true
    if [[ "$commit_count" -gt 0 ]]; then
        # Verify at least one commit looks like a REAL completion:
        # Must have a PR merge reference "(#NNN)" AND the exact task ID.
        # Exclude: "add tNNN", "claim tNNN", "mark tNNN blocked", "queue tNNN"
        local completion_evidence=""
        completion_evidence=$(git -C "$project_root" log --oneline -500 --all --grep="$task_id" 2>/dev/null \
            | grep -E "$boundary_pattern" \
            | grep -iE "\(#[0-9]+\)|PR #[0-9]+ merged" \
            | grep -ivE "add ${task_id}|claim ${task_id}|mark ${task_id}|queue ${task_id}|blocked" \
            | head -1) || true
        if [[ -n "$completion_evidence" ]]; then
            log_info "Pre-dispatch check: $task_id has completion evidence: $completion_evidence" >&2
            return 0
        fi
    fi

    # Check 3: Does a merged PR exist for this task?
    # Only check if gh CLI is available and authenticated (cached check).
    # Use exact task ID in title search to prevent substring matches.
    # IMPORTANT: gh pr list --repo requires OWNER/REPO slug, not a local path (t224).
    if command -v gh &>/dev/null && check_gh_auth 2>/dev/null; then
        local repo_slug=""
        repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null) || true
        if [[ -n "$repo_slug" ]]; then
            local pr_count=0
            pr_count=$(gh pr list --repo "$repo_slug" --state merged --search "\"$task_id\" in:title" --limit 1 --json number --jq 'length' 2>/dev/null) || true
            if [[ "$pr_count" -gt 0 ]]; then
                log_info "Pre-dispatch check: $task_id has a merged PR on GitHub" >&2
                return 0
            fi
        fi
    fi

    return 1
}

check_task_claimed() {
    local task_id="${1:-}"
    local project_root="${2:-.}"
    local todo_file="$project_root/TODO.md"

    local current_assignee
    current_assignee=$(get_task_assignee "$task_id" "$todo_file")

    # No assignee = free
    if [[ -z "$current_assignee" ]]; then
        return 0
    fi

    local identity
    identity=$(get_aidevops_identity)

    # Exact match = claimed by self
    if [[ "$current_assignee" == "$identity" ]]; then
        return 0
    fi

    # Fuzzy match: assignee might be just a username while identity is user@host,
    # or vice versa. Also check the local username (whoami) and GitHub username.
    local local_user
    local_user=$(whoami 2>/dev/null || echo "")
    local gh_user="${_CACHED_GH_USERNAME:-}"
    local identity_user="${identity%%@*}"  # Strip @host portion

    if [[ "$current_assignee" == "$local_user" ]] ||
       [[ "$current_assignee" == "$gh_user" ]] ||
       [[ "$current_assignee" == "$identity_user" ]] ||
       [[ "${current_assignee%%@*}" == "$identity_user" ]]; then
        return 0
    fi

    # Claimed by someone else
    echo "$current_assignee"
    return 1
}

#######################################
# Sync claim/unclaim to GitHub Issue assignee (t165)
# Optional bi-directional sync layer — fails silently if gh unavailable
# or if the task has no ref:GH# in TODO.md. This is a best-effort
# convenience; TODO.md assignee: is the authoritative claim source.
# $1: task_id  $2: project_root  $3: action (claim|unclaim)
#######################################
sync_claim_to_github() {
    local task_id="$1"
    local project_root="$2"
    local action="$3"

    # Skip if gh CLI not available or not authenticated
    command -v gh &>/dev/null || return 0
    check_gh_auth || return 0

    local issue_number
    issue_number=$(find_task_issue_number "$task_id" "$project_root")
    if [[ -z "$issue_number" ]]; then
        return 0
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")
    if [[ -z "$repo_slug" ]]; then
        return 0
    fi

    ensure_status_labels "$repo_slug"

    if [[ "$action" == "claim" ]]; then
        gh issue edit "$issue_number" --repo "$repo_slug" \
            --add-assignee "@me" \
            --add-label "status:claimed" --remove-label "status:available" 2>/dev/null || true
    elif [[ "$action" == "unclaim" ]]; then
        local my_login
        my_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
        if [[ -n "$my_login" ]]; then
            gh issue edit "$issue_number" --repo "$repo_slug" \
                --remove-assignee "$my_login" \
                --add-label "status:available" --remove-label "status:claimed" 2>/dev/null || true
        fi
    fi
    return 0
}

#######################################
# Direct SQLite access for debugging
#######################################
cmd_db() {
    ensure_db

    if [[ $# -eq 0 ]]; then
        log_info "Opening interactive SQLite shell: $SUPERVISOR_DB"
        db -column -header "$SUPERVISOR_DB"
    else
        db -column -header "$SUPERVISOR_DB" "$*"
    fi

    return 0
}

#######################################
# Get count of running tasks (for concurrency checks)
#######################################
cmd_running_count() {
    ensure_db

    local batch_id="${1:-}"

    if [[ -n "$batch_id" ]]; then
        db "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$(sql_escape "$batch_id")'
            AND t.status IN ('dispatched', 'running', 'evaluating');
        "
    else
        db "$SUPERVISOR_DB" "
            SELECT count(*) FROM tasks
            WHERE status IN ('dispatched', 'running', 'evaluating');
        "
    fi

    return 0
}

#######################################
# Get next queued tasks eligible for dispatch
#
# Returns queued tasks up to $limit. Does NOT check concurrency here —
# cmd_dispatch() performs the authoritative concurrency check with a fresh
# running count at dispatch time. This avoids a TOCTOU race where cmd_next()
# computes available slots based on a stale count, then cmd_dispatch() sees
# a different count after prior dispatches in the same pulse loop (t172).
#######################################
cmd_next() {
    local batch_id="${1:-}" limit="${2:-1}"

    ensure_db

    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")

        db -separator $'\t' "$SUPERVISOR_DB" "
            SELECT t.id, t.repo, t.description, t.model
            FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status = 'queued'
            AND t.retries < t.max_retries
            ORDER BY bt.position
            LIMIT $limit;
        "
    else
        db -separator $'\t' "$SUPERVISOR_DB" "
            SELECT id, repo, description, model
            FROM tasks
            WHERE status = 'queued'
            AND retries < max_retries
            ORDER BY created_at ASC
            LIMIT $limit;
        "
    fi

    return 0
}

#######################################
# Detect terminal environment for dispatch mode
# Returns: "tabby", "headless", or "interactive"
#######################################
detect_dispatch_mode() {
    if [[ "${SUPERVISOR_DISPATCH_MODE:-}" == "headless" ]]; then
        echo "headless"
        return 0
    fi
    if [[ "${SUPERVISOR_DISPATCH_MODE:-}" == "tabby" ]]; then
        echo "tabby"
        return 0
    fi
    if [[ "${TERM_PROGRAM:-}" == "Tabby" ]]; then
        echo "tabby"
        return 0
    fi
    echo "headless"
    return 0
}

#######################################
# Resolve the AI CLI tool to use for dispatch
# Resolve AI CLI for worker dispatch
# opencode is the ONLY supported CLI for aidevops supervisor workers.
# claude CLI fallback is DEPRECATED and will be removed in a future release.
#######################################
resolve_ai_cli() {
    # opencode is the primary and only supported CLI
    if command -v opencode &>/dev/null; then
        echo "opencode"
        return 0
    fi
    # DEPRECATED: claude CLI fallback - will be removed
    if command -v claude &>/dev/null; then
        log_warning "Using deprecated claude CLI fallback. Install opencode: npm i -g opencode"
        echo "claude"
        return 0
    fi
    log_error "opencode CLI not found. Install it: npm i -g opencode"
    log_error "See: https://opencode.ai/docs/installation/"
    return 1
}

#######################################
# Resolve the best available model for a given task tier
# Uses fallback-chain-helper.sh (t132.4) for configurable multi-provider
# fallback chains with gateway support, falling back to
# model-availability-helper.sh (t132.3) for simple primary/fallback,
# then static defaults.
#
# Tiers:
#   coding  - Best SOTA model for code tasks (default)
#   eval    - Cheap/fast model for evaluation calls
#   health  - Cheapest model for health probes
#######################################
resolve_model() {
    local tier="${1:-coding}"
    local ai_cli="${2:-opencode}"

    # Allow env var override for all tiers
    if [[ -n "${SUPERVISOR_MODEL:-}" ]]; then
        echo "$SUPERVISOR_MODEL"
        return 0
    fi

    # If tier is already a full provider/model string (contains /), return as-is
    if [[ "$tier" == *"/"* ]]; then
        echo "$tier"
        return 0
    fi

    # Try fallback-chain-helper.sh for full chain resolution (t132.4)
    # This walks the configured chain including gateway providers
    local chain_helper="${SCRIPT_DIR}/fallback-chain-helper.sh"
    if [[ -x "$chain_helper" ]]; then
        local resolved
        resolved=$("$chain_helper" resolve "$tier" --quiet 2>/dev/null) || true
        if [[ -n "$resolved" ]]; then
            echo "$resolved"
            return 0
        fi
        log_verbose "fallback-chain-helper.sh could not resolve tier '$tier', trying availability helper"
    fi

    # Try model-availability-helper.sh for availability-aware resolution (t132.3)
    # IMPORTANT: When using OpenCode CLI with Anthropic OAuth, the availability
    # helper sees anthropic as "no-key" (no standalone ANTHROPIC_API_KEY) and
    # resolves to opencode/* models that route through OpenCode's Zen proxy.
    # Only accept anthropic/* results to enforce Anthropic-only routing.
    local availability_helper="${SCRIPT_DIR}/model-availability-helper.sh"
    if [[ -x "$availability_helper" ]]; then
        local resolved
        resolved=$("$availability_helper" resolve "$tier" --quiet 2>/dev/null) || true
        if [[ -n "$resolved" && "$resolved" == anthropic/* ]]; then
            echo "$resolved"
            return 0
        fi
        # Fallback: availability helper returned non-anthropic or empty, use static defaults
        log_verbose "model-availability-helper.sh resolved '$resolved' (non-anthropic or empty), using static default"
    fi

    # Static fallback: map tier names to concrete models (t132.5)
    case "$tier" in
        opus|coding)
            echo "anthropic/claude-opus-4-6"
            ;;
        sonnet|eval|health)
            echo "anthropic/claude-sonnet-4-5"
            ;;
        haiku|flash)
            echo "anthropic/claude-haiku-4-5"
            ;;
        pro)
            echo "anthropic/claude-sonnet-4-5"
            ;;
        *)
            # Unknown tier — treat as coding tier default
            echo "anthropic/claude-opus-4-6"
            ;;
    esac

    return 0
}

#######################################
# Read model: field from subagent YAML frontmatter (t132.5)
# Searches deployed agents dir and repo .agents/ dir
# Returns the model value or empty string if not found
#######################################
resolve_model_from_frontmatter() {
    local subagent_name="$1"
    local repo="${2:-.}"

    # Search paths for subagent files
    local -a search_paths=(
        "${HOME}/.aidevops/agents"
        "${repo}/.agents"
    )

    local agents_dir subagent_file model_value
    for agents_dir in "${search_paths[@]}"; do
        [[ -d "$agents_dir" ]] || continue

        # Try exact path first (e.g., "tools/ai-assistants/models/opus.md")
        subagent_file="${agents_dir}/${subagent_name}"
        [[ -f "$subagent_file" ]] || subagent_file="${agents_dir}/${subagent_name}.md"

        if [[ -f "$subagent_file" ]]; then
            # Extract model: from YAML frontmatter (between --- delimiters)
            model_value=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//; p; q; } }' "$subagent_file" 2>/dev/null) || true
            if [[ -n "$model_value" ]]; then
                echo "$model_value"
                return 0
            fi
        fi

        # Try finding by name in subdirectories
        # shellcheck disable=SC2044
        local found_file
        found_file=$(find "$agents_dir" -name "${subagent_name}.md" -type f 2>/dev/null | head -1) || true
        if [[ -n "$found_file" && -f "$found_file" ]]; then
            model_value=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//; p; q; } }' "$found_file" 2>/dev/null) || true
            if [[ -n "$model_value" ]]; then
                echo "$model_value"
                return 0
            fi
        fi
    done

    return 1
}

#######################################
# Classify task complexity from description to suggest model tier.
# Returns: "sonnet" for simple tasks, "opus" for complex ones.
# Simple tasks: docs updates, config changes, renaming, formatting,
#   adding comments, updating references, simple script additions.
# Complex tasks: architecture, novel features, multi-file refactors,
#   security, anything requiring deep reasoning.
#######################################
classify_task_complexity() {
    local description="$1"
    local desc_lower
    desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

    # Patterns that indicate simple/docs/config tasks → sonnet
    local simple_patterns=(
        "update.*readme"
        "update.*docs"
        "update.*documentation"
        "add.*comment"
        "add.*reference"
        "update.*reference"
        "rename"
        "fix.*typo"
        "update.*version"
        "bump.*version"
        "update.*changelog"
        "add.*to.*index"
        "update.*index"
        "wire.*up.*command"
        "add.*slash.*command"
        "update.*agents\.md"
        "progressive.*disclosure"
        "cross-reference"
    )

    for pattern in "${simple_patterns[@]}"; do
        if [[ "$desc_lower" =~ $pattern ]]; then
            echo "sonnet"
            return 0
        fi
    done

    # Patterns that indicate complex tasks → opus
    local complex_patterns=(
        "architect"
        "design.*system"
        "security.*audit"
        "refactor.*major"
        "migration"
        "novel"
        "from.*scratch"
        "implement.*new.*system"
        "multi.*provider"
        "cross.*model"
        "quality.*gate"
        "fallback.*chain"
    )

    for pattern in "${complex_patterns[@]}"; do
        if [[ "$desc_lower" =~ $pattern ]]; then
            echo "opus"
            return 0
        fi
    done

    # Default: opus for safety (complex tasks fail on weaker models)
    echo "opus"
    return 0
}

#######################################
# Resolve the model for a task (t132.5)
# Priority: 1) Task's explicit model (if not default)
#           2) Subagent frontmatter model:
#           3) Task complexity classification (auto-route simple tasks to sonnet)
#           4) resolve_model() with tier/fallback chain
# Returns the resolved provider/model string
#######################################
resolve_task_model() {
    local task_id="$1"
    local task_model="${2:-}"
    local task_repo="${3:-.}"
    local ai_cli="${4:-opencode}"

    local default_model="anthropic/claude-opus-4-6"

    # 1) If task has an explicit non-default model, use it
    if [[ -n "$task_model" && "$task_model" != "$default_model" ]]; then
        # Could be a tier name or full model string — resolve_model handles both
        local resolved
        resolved=$(resolve_model "$task_model" "$ai_cli")
        if [[ -n "$resolved" ]]; then
            log_info "Model for $task_id: $resolved (from task config)"
            echo "$resolved"
            return 0
        fi
    fi

    # 2) Try to find a model-specific subagent definition matching the task
    #    Look for tools/ai-assistants/models/*.md files that match the task's
    #    model tier or the task description keywords
    local model_agents_dir="${HOME}/.aidevops/agents/tools/ai-assistants/models"
    if [[ -d "$model_agents_dir" ]]; then
        # If task_model is a tier name, check for a matching model agent
        if [[ -n "$task_model" && ! "$task_model" == *"/"* ]]; then
            local tier_agent="${model_agents_dir}/${task_model}.md"
            if [[ -f "$tier_agent" ]]; then
                local frontmatter_model
                frontmatter_model=$(resolve_model_from_frontmatter "tools/ai-assistants/models/${task_model}" "$task_repo") || true
                if [[ -n "$frontmatter_model" ]]; then
                    local resolved
                    resolved=$(resolve_model "$frontmatter_model" "$ai_cli")
                    log_info "Model for $task_id: $resolved (from subagent frontmatter: ${task_model}.md)"
                    echo "$resolved"
                    return 0
                fi
            fi
        fi
    fi

    # 3) Auto-classify task complexity from description
    #    Route simple tasks (docs, config, renaming) to sonnet (~5x cheaper)
    #    Keep complex tasks (architecture, novel features) on opus
    local task_desc
    task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
    if [[ -n "$task_desc" ]]; then
        local suggested_tier
        suggested_tier=$(classify_task_complexity "$task_desc")
        if [[ "$suggested_tier" != "opus" ]]; then
            local resolved
            resolved=$(resolve_model "$suggested_tier" "$ai_cli")
            log_info "Model for $task_id: $resolved (auto-classified as $suggested_tier)"
            echo "$resolved"
            return 0
        fi
    fi

    # 4) Fall back to resolve_model with default tier
    local resolved
    resolved=$(resolve_model "coding" "$ai_cli")
    log_info "Model for $task_id: $resolved (default coding tier)"
    echo "$resolved"
    return 0
}

#######################################
# Get the next higher-tier model for escalation (t132.6)
# Maps current model to the next tier in the escalation chain:
#   haiku -> sonnet -> opus (Anthropic)
#   flash -> pro (Google)
# Returns the next tier name, or empty string if already at max tier.
#######################################
get_next_tier() {
    local current_model="$1"

    # Normalize: extract the tier from a full model string
    local tier=""
    case "$current_model" in
        *haiku*) tier="haiku" ;;
        *sonnet*) tier="sonnet" ;;
        *opus*) tier="opus" ;;
        *flash*) tier="flash" ;;
        *pro*) tier="pro" ;;
        *grok*) tier="grok" ;;
        *) tier="" ;;
    esac

    # Escalation chains
    case "$tier" in
        haiku) echo "sonnet" ;;
        sonnet) echo "opus" ;;
        opus) echo "" ;;  # Already at max Anthropic tier
        flash) echo "pro" ;;
        pro) echo "" ;;    # Already at max Google tier
        grok) echo "" ;;   # No escalation path for Grok
        *)
            # Unknown model — try escalating to opus as a safe default
            if [[ "$current_model" != *"opus"* ]]; then
                echo "opus"
            else
                echo ""
            fi
            ;;
    esac

    return 0
}

#######################################
# Check output quality of a completed worker (t132.6)
# Heuristic quality checks on worker output to decide if escalation is needed.
# Returns: "pass" if quality is acceptable, "fail:<reason>" if not.
#
# Checks performed:
#   1. Empty/trivial output (log too small)
#   2. Error patterns in log (panics, crashes, unhandled exceptions)
#   3. No substantive file changes (git diff empty)
#   4. ShellCheck violations for .sh files (if applicable)
#   5. Very low token-to-substance ratio
#######################################
check_output_quality() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT log_file, worktree, branch, repo, pr_url
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        echo "pass"  # Can't check, assume OK
        return 0
    fi

    local tlog tworktree tbranch trepo tpr_url
    IFS='|' read -r tlog tworktree tbranch trepo tpr_url <<< "$task_row"

    # Check 1: Log file size — very small logs suggest trivial/empty output
    if [[ -n "$tlog" && -f "$tlog" ]]; then
        local log_size
        log_size=$(wc -c < "$tlog" 2>/dev/null | tr -d ' ')
        # Less than 2KB of log output is suspicious for a coding task
        if [[ "$log_size" -lt 2048 ]]; then
            # But check if it's a legitimate small task (e.g., docs-only)
            local has_pr_signal
            has_pr_signal=$(grep -c 'WORKER_PR_CREATED\|WORKER_COMPLETE\|PR_URL' "$tlog" 2>/dev/null || echo "0")
            if [[ "$has_pr_signal" -eq 0 ]]; then
                echo "fail:trivial_output_${log_size}b"
                return 0
            fi
        fi

        # Check 2: Error patterns in log
        local error_count
        error_count=$(grep -ciE 'panic|fatal|unhandled.*exception|segfault|SIGKILL|out of memory|OOM' "$tlog" 2>/dev/null || echo "0")
        if [[ "$error_count" -gt 2 ]]; then
            echo "fail:error_patterns_${error_count}"
            return 0
        fi

        # Check 3: Token-to-substance ratio
        # If the log is very large (>500KB) but has no PR or meaningful output markers,
        # the worker may have been spinning without producing results
        if [[ "$log_size" -gt 512000 ]]; then
            local substance_markers
            substance_markers=$(grep -ciE 'WORKER_COMPLETE|WORKER_PR_CREATED|PR_URL|commit|merged|created file|wrote file' "$tlog" 2>/dev/null || echo "0")
            if [[ "$substance_markers" -lt 3 ]]; then
                echo "fail:low_substance_ratio_${log_size}b_${substance_markers}markers"
                return 0
            fi
        fi
    fi

    # Check 4: If we have a worktree/branch, check for substantive changes
    if [[ -n "$tworktree" && -d "$tworktree" ]]; then
        local diff_stat
        diff_stat=$(git -C "$tworktree" diff --stat "main..HEAD" 2>/dev/null || echo "")
        if [[ -z "$diff_stat" ]]; then
            # No changes at all on the branch
            echo "fail:no_file_changes"
            return 0
        fi

        # Check 5: ShellCheck for .sh files (quick heuristic)
        local changed_sh_files
        changed_sh_files=$(git -C "$tworktree" diff --name-only "main..HEAD" 2>/dev/null | grep '\.sh$' || true)
        if [[ -n "$changed_sh_files" ]]; then
            local shellcheck_errors=0
            while IFS= read -r sh_file; do
                [[ -z "$sh_file" ]] && continue
                local full_path="${tworktree}/${sh_file}"
                [[ -f "$full_path" ]] || continue
                local sc_count
                sc_count=$(bash -n "$full_path" 2>&1 | wc -l | tr -d ' ')
                shellcheck_errors=$((shellcheck_errors + sc_count))
            done <<< "$changed_sh_files"
            if [[ "$shellcheck_errors" -gt 5 ]]; then
                echo "fail:syntax_errors_${shellcheck_errors}"
                return 0
            fi
        fi
    fi

    # Check 6: If PR was created, verify it has substantive content
    if [[ -n "$tpr_url" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" ]]; then
        # PR exists — that's a strong positive signal
        echo "pass"
        return 0
    fi

    # All checks passed
    echo "pass"
    return 0
}

#######################################
# Run quality gate and escalate if needed (t132.6)
# Called after evaluate_worker() returns "complete".
# Returns: "pass" if quality OK or escalation not possible,
#          "escalate:<new_model>" if re-dispatch needed.
#######################################
run_quality_gate() {
    local task_id="$1"
    local batch_id="${2:-}"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Check if quality gate is skipped for this batch
    if [[ -n "$batch_id" ]]; then
        local skip_gate
        skip_gate=$(db "$SUPERVISOR_DB" "SELECT skip_quality_gate FROM batches WHERE id = '$(sql_escape "$batch_id")';" 2>/dev/null || echo "0")
        if [[ "$skip_gate" -eq 1 ]]; then
            log_info "Quality gate skipped for batch $batch_id"
            echo "pass"
            return 0
        fi
    fi

    # Check escalation depth
    local task_escalation
    task_escalation=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT escalation_depth, max_escalation, model
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_escalation" ]]; then
        echo "pass"
        return 0
    fi

    local current_depth max_depth current_model
    IFS='|' read -r current_depth max_depth current_model <<< "$task_escalation"

    # Already at max escalation depth
    if [[ "$current_depth" -ge "$max_depth" ]]; then
        log_info "Quality gate: $task_id at max escalation depth ($current_depth/$max_depth), accepting result"
        echo "pass"
        return 0
    fi

    # Run quality checks
    local quality_result
    quality_result=$(check_output_quality "$task_id")

    if [[ "$quality_result" == "pass" ]]; then
        log_info "Quality gate: $task_id passed quality checks"
        echo "pass"
        return 0
    fi

    # Quality failed — try to escalate
    local fail_reason="${quality_result#fail:}"
    local next_tier
    next_tier=$(get_next_tier "$current_model")

    if [[ -z "$next_tier" ]]; then
        log_warn "Quality gate: $task_id failed ($fail_reason) but no higher tier available from $current_model"
        echo "pass"
        return 0
    fi

    # Resolve the next tier to a full model string
    local ai_cli
    ai_cli=$(resolve_ai_cli 2>/dev/null || echo "opencode")
    local next_model
    next_model=$(resolve_model "$next_tier" "$ai_cli")

    log_warn "Quality gate: $task_id failed ($fail_reason), escalating from $current_model to $next_model (depth $((current_depth + 1))/$max_depth)"

    # Update escalation depth and model, then transition to queued via state machine
    db "$SUPERVISOR_DB" "
        UPDATE tasks SET
            escalation_depth = $((current_depth + 1)),
            model = '$(sql_escape "$next_model")'
        WHERE id = '$escaped_id';
    "
    cmd_transition "$task_id" "queued" --error "Quality gate escalation: $fail_reason" 2>/dev/null || true

    echo "escalate:${next_model}"
    return 0
}

#######################################
# Pre-dispatch model health check (t132.3, t233)
# Two-tier probe strategy:
#   1. Fast path: model-availability-helper.sh (direct HTTP, ~1-2s, cached)
#   2. Slow path: Full AI CLI probe (spawns session, ~8-15s)
# Exit codes (t233 — propagated from model-availability-helper.sh):
#   0 = healthy
#   1 = unavailable (provider down, generic error)
#   2 = rate limited (defer dispatch, retry soon)
#   3 = API key invalid/missing (block, don't retry)
# Result is cached for 5 minutes to avoid repeated probes.
#######################################
check_model_health() {
    local ai_cli="$1"
    local model="${2:-}"
    _save_cleanup_scope; trap '_run_cleanups' RETURN

    # Pulse-level fast path: if health was already verified in this pulse
    # invocation, skip the probe entirely (avoids 8s per task)
    if [[ -n "${_PULSE_HEALTH_VERIFIED:-}" ]]; then
        log_info "Model health: pulse-verified OK (skipping probe)"
        return 0
    fi

    # Fast path: use model-availability-helper.sh for lightweight HTTP probe (t132.3)
    # This checks the provider's /models endpoint (~1-2s) instead of spawning
    # a full AI CLI session (~8-15s). Falls through to slow path on failure.
    local availability_helper="${SCRIPT_DIR}/model-availability-helper.sh"
    if [[ -x "$availability_helper" ]]; then
        local provider_name=""
        if [[ -n "$model" && "$model" == *"/"* ]]; then
            provider_name="${model%%/*}"
        else
            provider_name="anthropic"  # Default provider
        fi

        local avail_exit=0
        "$availability_helper" check "$provider_name" --quiet 2>/dev/null || avail_exit=$?

        case "$avail_exit" in
            0)
                _PULSE_HEALTH_VERIFIED="true"
                log_info "Model health: OK via availability helper (fast path)"
                return 0
                ;;
            2)
                # t233: propagate rate-limit exit code so callers can defer dispatch
                # without burning retries (previously collapsed to exit 1)
                log_warn "Model health check: rate limited (via availability helper) — deferring dispatch"
                return 2
                ;;
            3)
                # t233: propagate invalid-key exit code so callers can block dispatch
                # (previously collapsed to exit 1)
                log_warn "Model health check: API key invalid/missing (via availability helper) — blocking dispatch"
                return 3
                ;;
            *)
                # When using OpenCode, the availability helper may fail because OpenCode
                # manages API keys internally (no standalone ANTHROPIC_API_KEY env var).
                # In this case, skip the slow CLI probe entirely and trust OpenCode.
                # If the model is truly unavailable, dispatch will fail and retry handles it.
                if [[ "$ai_cli" == "opencode" ]]; then
                    log_info "Model health: skipping probe for OpenCode-managed provider (no direct API key)"
                    _PULSE_HEALTH_VERIFIED="true"
                    return 0
                fi
                log_verbose "Availability helper returned $avail_exit, falling through to CLI probe"
                ;;
        esac
    fi

    # Slow path: file-based cache check (legacy, kept for environments without the helper)
    local cache_dir="$SUPERVISOR_DIR/health"
    mkdir -p "$cache_dir"
    local cache_key="${ai_cli}-${model//\//_}"
    local cache_file="$cache_dir/${cache_key}"

    if [[ -f "$cache_file" ]]; then
        local cached_at
        cached_at=$(cat "$cache_file")
        local now
        now=$(date +%s)
        local age=$(( now - cached_at ))
        if [[ "$age" -lt 300 ]]; then
            log_info "Model health: cached OK ($age seconds ago)"
            _PULSE_HEALTH_VERIFIED="true"
            return 0
        fi
    fi

    # Slow path: spawn AI CLI for a trivial prompt
    local timeout_cmd=""
    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout"
    fi

    local probe_result=""
    local probe_exit=1

    if [[ "$ai_cli" == "opencode" ]]; then
        local -a probe_cmd=(opencode run --format json)
        if [[ -n "$model" ]]; then
            probe_cmd+=(-m "$model")
        fi
        probe_cmd+=(--title "health-check" "Reply with exactly: OK")
        if [[ -n "$timeout_cmd" ]]; then
            probe_result=$("$timeout_cmd" 15 "${probe_cmd[@]}" 2>&1)
            probe_exit=$?
        else
            local probe_pid probe_tmpfile
            probe_tmpfile=$(mktemp)
            push_cleanup "rm -f '${probe_tmpfile}'"
            ("${probe_cmd[@]}" > "$probe_tmpfile" 2>&1) &
            probe_pid=$!
            local waited=0
            while kill -0 "$probe_pid" 2>/dev/null && [[ "$waited" -lt 15 ]]; do
                sleep 1
                waited=$((waited + 1))
            done
            if kill -0 "$probe_pid" 2>/dev/null; then
                kill "$probe_pid" 2>/dev/null || true
                wait "$probe_pid" 2>/dev/null || true
                probe_exit=124
            else
                wait "$probe_pid" 2>/dev/null || true
                probe_exit=$?
            fi
            probe_result=$(cat "$probe_tmpfile" 2>/dev/null || true)
            rm -f "$probe_tmpfile"
        fi
    else
        local -a probe_cmd=(claude -p "Reply with exactly: OK" --output-format text)
        if [[ -n "$model" ]]; then
            probe_cmd+=(--model "$model")
        fi
        if [[ -n "$timeout_cmd" ]]; then
            probe_result=$("$timeout_cmd" 15 "${probe_cmd[@]}" 2>&1)
            probe_exit=$?
        else
            local probe_pid probe_tmpfile
            probe_tmpfile=$(mktemp)
            push_cleanup "rm -f '${probe_tmpfile}'"
            ("${probe_cmd[@]}" > "$probe_tmpfile" 2>&1) &
            probe_pid=$!
            local waited=0
            while kill -0 "$probe_pid" 2>/dev/null && [[ "$waited" -lt 15 ]]; do
                sleep 1
                waited=$((waited + 1))
            done
            if kill -0 "$probe_pid" 2>/dev/null; then
                kill "$probe_pid" 2>/dev/null || true
                wait "$probe_pid" 2>/dev/null || true
                probe_exit=124
            else
                wait "$probe_pid" 2>/dev/null || true
                probe_exit=$?
            fi
            probe_result=$(cat "$probe_tmpfile" 2>/dev/null || true)
            rm -f "$probe_tmpfile"
        fi
    fi

    # Check for known failure patterns (t233: distinguish quota/rate-limit from generic failures)
    if echo "$probe_result" | grep -qiE 'CreditsError|Insufficient balance'; then
        log_warn "Model health check FAILED: billing/credits exhausted (slow path)"
        return 3  # t233: credits = invalid key equivalent (won't resolve without human action)
    fi
    if echo "$probe_result" | grep -qiE 'Quota protection|over[_ -]?usage|quota reset|429|too many requests|rate.limit'; then
        log_warn "Model health check FAILED: quota/rate limited (slow path)"
        return 2  # t233: rate-limited = defer dispatch, retry soon
    fi
    if echo "$probe_result" | grep -qiE 'endpoints failed|"status":[[:space:]]*503|HTTP 503|503 Service|service unavailable'; then
        log_warn "Model health check FAILED: provider error detected (slow path)"
        return 1
    fi

    if [[ "$probe_exit" -eq 124 ]]; then
        log_warn "Model health check FAILED: timeout (15s)"
        return 1
    fi

    if [[ -z "$probe_result" && "$probe_exit" -ne 0 ]]; then
        log_warn "Model health check FAILED: empty response (exit $probe_exit)"
        return 1
    fi

    # Healthy - cache the result
    date +%s > "$cache_file"
    _PULSE_HEALTH_VERIFIED="true"
    log_info "Model health: OK (cached for 5m)"
    return 0
}

#######################################
# Generate a worker-specific MCP config with heavy indexers disabled (t221)
#
# Workers inherit the global ~/.config/opencode/opencode.json which may have
# osgrep enabled. osgrep indexes the entire codebase on startup, consuming
# ~4 CPU cores per worker. With 3-4 concurrent workers, that's 12-16 cores
# wasted on indexing that workers don't need (they have rg/grep/read tools).
#
# This function copies the user's config to a per-worker temp directory and
# disables osgrep (and augment-context-engine, another heavy indexer).
# The caller sets XDG_CONFIG_HOME to redirect OpenCode to this config.
#
# Args: $1 = task_id (used for directory naming)
# Outputs: XDG_CONFIG_HOME path on stdout
# Returns: 0 on success, 1 on failure (caller should proceed without override)
#######################################
generate_worker_mcp_config() {
    local task_id="$1"

    local user_config="$HOME/.config/opencode/opencode.json"
    if [[ ! -f "$user_config" ]]; then
        log_warn "No opencode.json found at $user_config — skipping worker MCP override"
        return 1
    fi

    # Create per-worker config directory under supervisor's pids dir
    local worker_config_dir="${SUPERVISOR_DIR}/pids/${task_id}-config/opencode"
    mkdir -p "$worker_config_dir"

    # Copy and modify: disable heavy indexing MCPs
    # osgrep: local semantic search, spawns indexer (~4 CPU cores)
    # augment-context-engine: another semantic indexer
    if command -v jq &>/dev/null; then
        jq '
            # Disable heavy indexing MCP servers for workers
            .mcp["osgrep"].enabled = false |
            .mcp["augment-context-engine"].enabled = false |
            # Also disable their tools to avoid tool-not-found errors
            .tools["osgrep_*"] = false |
            .tools["augment-context-engine_*"] = false
        ' "$user_config" > "$worker_config_dir/opencode.json" 2>/dev/null
    else
        # Fallback: copy as-is if jq unavailable (workers still get osgrep but
        # this is a best-effort optimisation, not a hard requirement)
        log_warn "jq not available — cannot generate worker MCP config"
        return 1
    fi

    # Validate the generated config is valid JSON
    if ! jq empty "$worker_config_dir/opencode.json" 2>/dev/null; then
        log_warn "Generated worker config is invalid JSON — removing"
        rm -f "$worker_config_dir/opencode.json"
        return 1
    fi

    # Return the parent of the opencode/ dir (XDG_CONFIG_HOME points to the
    # directory that *contains* the opencode/ subdirectory)
    echo "${SUPERVISOR_DIR}/pids/${task_id}-config"
    return 0
}

#######################################
# Build the dispatch command for a task
# Outputs the command array elements, one per line
# $5 (optional): memory context to inject into the prompt
#######################################
build_dispatch_cmd() {
    local task_id="$1"
    local worktree_path="$2"
    local log_file="$3"
    local ai_cli="$4"
    local memory_context="${5:-}"
    local model="${6:-}"
    local description="${7:-}"

    # Include task description in the prompt so the worker knows what to do
    # even if TODO.md doesn't have an entry for this task (t158)
    # Always pass --headless for supervisor-dispatched workers (t174)
    # Inject explicit TODO.md restriction into worker prompt (t173)
    local prompt="/full-loop $task_id --headless"
    if [[ -n "$description" ]]; then
        prompt="/full-loop $task_id --headless -- $description"
    fi

    # t173: Explicit worker restriction — prevents TODO.md race condition
    # t176: Uncertainty decision framework for headless workers
    prompt="$prompt

## MANDATORY Worker Restrictions (t173)
- Do NOT edit, commit, or push TODO.md — the supervisor owns all TODO.md updates.
- Do NOT edit todo/PLANS.md or todo/tasks/* — these are supervisor-managed.
- Report status via exit code, log output, and PR creation only.
- Put task notes in commit messages or PR body, never in TODO.md.

## Uncertainty Decision Framework (t176)
You are a headless worker with no human at the terminal. Use this framework when uncertain:

**PROCEED autonomously when:**
- Multiple valid approaches exist but all achieve the goal (pick the simplest)
- Style/naming choices are ambiguous (follow existing conventions in the codebase)
- Task description is slightly vague but intent is clear from context
- You need to choose between equivalent libraries/patterns (match project precedent)
- Minor scope questions (e.g., should I also fix this adjacent issue?) — stay focused on the assigned task

**FLAG uncertainty and exit cleanly when:**
- The task description contradicts what you find in the codebase
- Completing the task would require breaking changes to public APIs or shared interfaces
- You discover the task is already done or obsolete
- Required dependencies, credentials, or services are missing and cannot be inferred
- The task requires decisions that would significantly affect architecture or other tasks
- You are unsure whether a file should be created vs modified, and getting it wrong would cause data loss

**When you proceed autonomously**, document your decision in the commit message:
\`feat: add retry logic (chose exponential backoff over linear — matches existing patterns in src/utils/retry.ts)\`

**When you exit due to uncertainty**, include a clear explanation in your final output:
\`BLOCKED: Task says 'update the auth endpoint' but there are 3 auth endpoints (JWT, OAuth, API key). Need clarification on which one.\`

## Worker Efficiency Protocol

Maximise your output per token. Follow these practices to avoid wasted work:

**1. Decompose with TodoWrite (MANDATORY)**
At the START of your session, use the TodoWrite tool to break your task into 3-7 subtasks.
Your LAST subtask must ALWAYS be: 'Push branch and create PR via gh pr create'.
Example for 'add retry logic to API client':
- Research: read existing API client code and error handling patterns
- Implement: add retry with exponential backoff to the HTTP client
- Test: write unit tests for retry behaviour (success, max retries, backoff timing)
- Integrate: update callers if the API surface changed
- Verify: run linters, shellcheck, and existing tests
- Deliver: push branch and create PR via gh pr create

Mark each subtask in_progress when you start it and completed when done.
Only have ONE subtask in_progress at a time.

**2. Commit early, commit often (CRITICAL — prevents lost work)**
After EACH implementation subtask, immediately:
\`\`\`bash
git add -A && git commit -m 'feat: <what you just did> (<task-id>)'
\`\`\`
Do NOT wait until all subtasks are done. If your session ends unexpectedly (context
exhaustion, crash, timeout), uncommitted work is LOST. Committed work survives.

After your FIRST commit, push and create a draft PR immediately:
\`\`\`bash
git push -u origin HEAD
gh pr create --draft --title '<task-id>: <description>' --body 'WIP - incremental commits'
\`\`\`
Subsequent commits just need \`git push\`. The PR already exists.
This ensures the supervisor can detect your PR even if you run out of context.

When ALL implementation is done, mark the PR as ready for review:
\`\`\`bash
gh pr ready
\`\`\`
If you run out of context before this step, the supervisor will auto-promote
your draft PR after detecting your session has ended.

**3. ShellCheck gate before push (MANDATORY for .sh files — t234)**
Before EVERY \`git push\`, check if your commits include \`.sh\` files:
\`\`\`bash
sh_files=\$(git diff --name-only origin/HEAD..HEAD 2>/dev/null | grep '\\.sh\$' || true)
if [[ -n \"\$sh_files\" ]]; then
  echo \"Running ShellCheck on modified .sh files...\"
  sc_failed=0
  while IFS= read -r f; do
    [[ -f \"\$f\" ]] || continue
    if ! shellcheck -x -S warning \"\$f\"; then
      sc_failed=1
    fi
  done <<< \"\$sh_files\"
  if [[ \"\$sc_failed\" -eq 1 ]]; then
    echo \"ShellCheck violations found — fix before pushing.\"
    # Fix the violations, then git add -A && git commit --amend --no-edit
  fi
fi
\`\`\`
This catches CI failures 5-10 min earlier. Do NOT push .sh files with ShellCheck violations.
If \`shellcheck\` is not installed, skip this gate and note it in the PR body.

**4. Offload research to Task sub-agents (saves context for implementation)**
Reading large files (500+ lines) consumes your context budget fast. Instead of reading
entire files yourself, spawn a Task sub-agent with a focused question:
\`\`\`
Task(description='Find dispatch points', prompt='In .agents/scripts/supervisor-helper.sh,
find all functions that dispatch workers. Return: function name, line number, and the
key variables/patterns used. Do NOT return full code — just the summary.')
\`\`\`
The sub-agent gets its own fresh context window. You get a concise answer that costs
~100 tokens instead of ~5000 tokens from reading the file directly.

**When to offload**: Any time you would read >200 lines of a file you don't plan to edit,
or when you need to understand a codebase pattern across multiple files.

**When NOT to offload**: When you need to edit the file (you must read it yourself for
the Edit tool to work), or when the answer is a simple grep/rg query.

**5. Parallel sub-work with Task tool (MANDATORY when applicable)**
After creating your TodoWrite subtasks, check: do any two subtasks modify DIFFERENT files?
If yes, you MUST spawn the independent subtask via the Task tool — do NOT execute sequentially.

**Decision heuristic**: If your TodoWrite has 3+ subtasks and any two don't modify the same
files, spawn the independent one via Task tool. Common parallelisable pairs:
- Writing tests (test files) while implementing the feature (source files)
- Updating docs/subagent-index while writing the main script
- Creating a new helper script while updating an existing one that won't import it yet

**Worked example** — task: 'add retry logic to API client + tests + docs':
\`\`\`
# TodoWrite subtasks:
# 1. Implement retry logic in src/client.ts        (modifies: src/client.ts)
# 2. Write unit tests in tests/client.test.ts      (modifies: tests/client.test.ts)
# 3. Update API docs in docs/client.md             (modifies: docs/client.md)
# 4. Push and create PR

# Subtask 1 modifies different files from subtasks 2 and 3.
# After completing subtask 1, git add && git commit immediately.
# Then spawn TWO Task tool calls simultaneously:
#   Task(description='Write retry tests', prompt='Write unit tests for retry logic in tests/client.test.ts...')
#   Task(description='Update API docs', prompt='Update docs/client.md to document retry behaviour...')
# Wait for both to complete, commit their work, then push + create PR.
\`\`\`

**Do NOT parallelise when**: subtasks modify the same file, or subtask B depends on
subtask A's output (e.g., B imports a function A creates). When in doubt, run sequentially.

**6. Fail fast, not late**
Before writing any code, verify your assumptions:
- Read the files you plan to modify (stale assumptions waste entire sessions)
- Check that dependencies/imports you plan to use actually exist in the project
- If the task seems already done, EXIT immediately with explanation — don't redo work

**7. Minimise token waste**
- Don't read entire large files — use line ranges from search results
- Don't output verbose explanations in commit messages — be concise
- Don't retry failed approaches more than once — exit with BLOCKED instead"

    if [[ -n "$memory_context" ]]; then
        prompt="$prompt

$memory_context"
    fi

    # Use NUL-delimited output so multi-line prompts stay as single arguments
    if [[ "$ai_cli" == "opencode" ]]; then
        printf '%s\0' "opencode"
        printf '%s\0' "run"
        printf '%s\0' "--format"
        printf '%s\0' "json"
        if [[ -n "$model" ]]; then
            printf '%s\0' "-m"
            printf '%s\0' "$model"
        fi
        printf '%s\0' "--title"
        printf '%s\0' "$task_id"
        printf '%s\0' "$prompt"
    else
        # claude CLI
        printf '%s\0' "claude"
        printf '%s\0' "-p"
        printf '%s\0' "$prompt"
        if [[ -n "$model" ]]; then
            printf '%s\0' "--model"
            printf '%s\0' "$model"
        fi
        printf '%s\0' "--output-format"
        printf '%s\0' "json"
    fi

    return 0
}

#######################################
# Create a worktree for a task
# Returns the worktree path on stdout
#######################################
create_task_worktree() {
    local task_id="$1"
    local repo="$2"
    local force_fresh="${3:-false}"

    local branch_name="feature/${task_id}"
    # Derive worktree path: ~/Git/repo-name.feature-tXXX (matches wt convention)
    local repo_basename
    repo_basename=$(basename "$repo")
    local repo_parent
    repo_parent=$(dirname "$repo")
    local worktree_path="${repo_parent}/${repo_basename}.feature-${task_id}"

    # Detect and clean stale branches/worktrees before creating new ones.
    # A branch is "stale" if it exists but is not ahead of main (no unique
    # commits), or if force_fresh is requested (retry with clean slate).
    local needs_cleanup=false

    if [[ "$force_fresh" == "true" ]]; then
        # (t229) Check for open PRs — reuse the branch to preserve review context
        # instead of deleting and recreating (reduces PR churn)
        local open_pr_url
        open_pr_url=$(gh pr list --head "$branch_name" --state open --json url --jq '.[0].url' 2>/dev/null || echo "")
        if [[ -n "$open_pr_url" && "$open_pr_url" != "null" ]]; then
            # Validate PR belongs to this task (t223)
            local repo_slug_ff
            repo_slug_ff=$(detect_repo_slug "$repo" 2>/dev/null || echo "")
            local validated_ff=""
            if [[ -n "$repo_slug_ff" ]]; then
                validated_ff=$(validate_pr_belongs_to_task "$task_id" "$repo_slug_ff" "$open_pr_url") || validated_ff=""
            fi
            if [[ -n "$validated_ff" ]]; then
                # (t229) Reuse existing branch+PR: reset worktree to main content
                # but keep the branch so the open PR and its review context survive.
                log_info "Force-fresh with existing PR — resetting branch to main (preserving PR: $open_pr_url)" >&2
                if [[ -d "$worktree_path" ]]; then
                    # Reset worktree contents to match main (fresh code, same branch)
                    if git -C "$worktree_path" fetch origin main &>/dev/null && \
                       git -C "$worktree_path" reset --hard origin/main &>/dev/null; then
                        # Force-push the reset so remote branch matches local.
                        # This lets the worker's normal `git push` work without --force.
                        # --force-with-lease is safer than --force (rejects if someone else pushed).
                        git -C "$worktree_path" push --force-with-lease origin "$branch_name" &>/dev/null || \
                            log_warn "Force-push after reset failed — worker may need --force on first push" >&2
                        log_info "Worktree $worktree_path reset to origin/main on branch $branch_name" >&2
                        echo "$worktree_path"
                        return 0
                    else
                        log_warn "Failed to reset worktree to main — falling back to recreate" >&2
                    fi
                else
                    # No worktree but branch+PR exist — create worktree on existing branch
                    # First fetch to ensure we have the remote branch
                    git -C "$repo" fetch origin "$branch_name" &>/dev/null || true
                    if git -C "$repo" worktree add "$worktree_path" "$branch_name" >&2 2>&1; then
                        # Reset to main for fresh code
                        if git -C "$worktree_path" fetch origin main &>/dev/null && \
                           git -C "$worktree_path" reset --hard origin/main &>/dev/null; then
                            # Force-push the reset so remote branch matches local
                            git -C "$worktree_path" push --force-with-lease origin "$branch_name" &>/dev/null || \
                                log_warn "Force-push after reset failed — worker may need --force on first push" >&2
                            register_worktree "$worktree_path" "$branch_name" --task "$task_id"
                            log_info "Created worktree on existing branch $branch_name, reset to origin/main" >&2
                            echo "$worktree_path"
                            return 0
                        else
                            log_warn "Failed to reset new worktree to main — falling back to recreate" >&2
                            git -C "$repo" worktree remove "$worktree_path" --force &>/dev/null || true
                        fi
                    else
                        log_warn "Failed to create worktree on existing branch — falling back to recreate" >&2
                    fi
                fi
                # If we get here, the reuse attempt failed — fall through to full cleanup
                log_warn "Branch reuse failed for $task_id — falling back to delete+recreate" >&2
            else
                log_warn "Force-fresh: open PR on $branch_name does not reference $task_id — skipping PR reuse to prevent cross-contamination" >&2
            fi
        fi
        needs_cleanup=true
        log_info "Force-fresh requested for $task_id — cleaning stale worktree/branch" >&2
    elif [[ -d "$worktree_path" ]]; then
        # Worktree exists — check if the branch has unmerged work worth keeping
        local ahead_count
        ahead_count=$(git -C "$worktree_path" rev-list --count "main..HEAD" 2>/dev/null || echo "0")
        if [[ "$ahead_count" -eq 0 ]]; then
            # Before deleting, check if branch has an open PR with unmerged work
            local open_pr_count
            open_pr_count=$(gh pr list --head "$branch_name" --state open --json number --jq 'length' 2>/dev/null || echo "0")
            if [[ "$open_pr_count" -gt 0 ]]; then
                log_warn "Branch $branch_name has 0 commits ahead but has an open PR — keeping" >&2
                echo "$worktree_path"
                return 0
            fi
            needs_cleanup=true
            log_info "Stale worktree for $task_id (0 commits ahead of main, no open PR) — recreating" >&2
        else
            # Has commits — check if branch has diverged badly from main
            # (more than 50 files changed = likely rebased from old main)
            local diff_files
            diff_files=$(git -C "$worktree_path" diff --name-only "main..HEAD" 2>/dev/null | wc -l || echo "0")
            diff_files=$(echo "$diff_files" | tr -d ' ')
            if [[ "$diff_files" -gt 50 ]]; then
                needs_cleanup=true
                log_warn "Stale worktree for $task_id ($diff_files files diverged from main) — recreating" >&2
            else
                log_info "Worktree already exists with $ahead_count commit(s): $worktree_path" >&2
                echo "$worktree_path"
                return 0
            fi
        fi
    elif git -C "$repo" rev-parse --verify "$branch_name" &>/dev/null; then
        # No worktree but branch exists — check if it's stale
        local ahead_count
        ahead_count=$(git -C "$repo" rev-list --count "main..$branch_name" 2>/dev/null || echo "0")
        if [[ "$ahead_count" -eq 0 ]]; then
            # Before deleting, check if branch has an open PR with unmerged work
            local open_pr_count
            open_pr_count=$(gh pr list --head "$branch_name" --state open --json number --jq 'length' 2>/dev/null || echo "0")
            if [[ "$open_pr_count" -gt 0 ]]; then
                log_warn "Branch $branch_name has 0 commits ahead but has an open PR — skipping cleanup" >&2
            else
                needs_cleanup=true
                log_info "Stale branch $branch_name (0 commits ahead of main, no open PR) — deleting" >&2
            fi
        else
            local diff_files
            diff_files=$(git -C "$repo" diff --name-only "main..$branch_name" 2>/dev/null | wc -l || echo "0")
            diff_files=$(echo "$diff_files" | tr -d ' ')
            if [[ "$diff_files" -gt 50 ]]; then
                needs_cleanup=true
                log_warn "Stale branch $branch_name ($diff_files files diverged from main) — deleting" >&2
            fi
        fi
    fi

    if [[ "$needs_cleanup" == "true" ]]; then
        # Ownership check (t189): refuse to clean worktrees owned by other sessions
        if [[ -d "$worktree_path" ]] && is_worktree_owned_by_others "$worktree_path"; then
            local stale_owner_info
            stale_owner_info=$(check_worktree_owner "$worktree_path" || echo "unknown")
            log_warn "Cannot clean stale worktree $worktree_path — owned by another active session (owner: $stale_owner_info)" >&2
            # Return existing path — let the caller decide
            echo "$worktree_path"
            return 0
        fi
        # Remove worktree if it exists
        if [[ -d "$worktree_path" ]]; then
            git -C "$repo" worktree remove "$worktree_path" --force &>/dev/null || rm -rf "$worktree_path"
            git -C "$repo" worktree prune &>/dev/null || true
            # Unregister ownership (t189)
            unregister_worktree "$worktree_path"
        fi
        # Delete local branch — MUST suppress stdout (outputs "Deleted branch ...")
        # which would pollute the function's return value captured by $()
        git -C "$repo" branch -D "$branch_name" &>/dev/null || true
        # Delete remote branch (best-effort, don't fail if remote is gone)
        git -C "$repo" push origin --delete "$branch_name" &>/dev/null || true
    fi

    # Try wt first (redirect its verbose output to stderr)
    if command -v wt &>/dev/null; then
        if wt switch -c "$branch_name" -C "$repo" >&2 2>&1; then
            # Register ownership (t189)
            register_worktree "$worktree_path" "$branch_name" --task "$task_id"
            echo "$worktree_path"
            return 0
        fi
    fi

    # Fallback: raw git worktree add (quiet, reliable)
    if git -C "$repo" worktree add "$worktree_path" -b "$branch_name" >&2 2>&1; then
        # Register ownership (t189)
        register_worktree "$worktree_path" "$branch_name" --task "$task_id"
        echo "$worktree_path"
        return 0
    fi

    # Branch may already exist without worktree (e.g. remote-only)
    if git -C "$repo" worktree add "$worktree_path" "$branch_name" >&2 2>&1; then
        # Register ownership (t189)
        register_worktree "$worktree_path" "$branch_name" --task "$task_id"
        echo "$worktree_path"
        return 0
    fi

    log_error "Failed to create worktree for $task_id at $worktree_path"
    return 1
}

#######################################
# Clean up a worktree for a completed/failed task
# Checks ownership registry (t189) before removal
#######################################
cleanup_task_worktree() {
    local worktree_path="$1"
    local repo="$2"

    if [[ ! -d "$worktree_path" ]]; then
        # Directory gone — clean up registry entry if any
        unregister_worktree "$worktree_path"
        return 0
    fi

    # Ownership check (t189): refuse to remove worktrees owned by other sessions
    if is_worktree_owned_by_others "$worktree_path"; then
        local owner_info
        owner_info=$(check_worktree_owner "$worktree_path" || echo "unknown")
        log_warn "Skipping cleanup of $worktree_path — owned by another active session (owner: $owner_info)"
        return 0
    fi

    # Try wt prune first
    if command -v wt &>/dev/null; then
        if wt remove -C "$repo" "$worktree_path" 2>>"$SUPERVISOR_LOG"; then
            unregister_worktree "$worktree_path"
            return 0
        fi
    fi

    # Fallback: git worktree remove
    git -C "$repo" worktree remove "$worktree_path" --force 2>>"$SUPERVISOR_LOG" || true
    # Unregister regardless of removal success (directory may be partially cleaned)
    unregister_worktree "$worktree_path"
    return 0
}

#######################################
# Kill a worker's process tree (PID + all descendants)
# Called when a worker finishes to prevent orphaned processes
#######################################
cleanup_worker_processes() {
    local task_id="$1"

    local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi

    local pid
    pid=$(cat "$pid_file")

    # Kill the entire process group if possible
    # First kill descendants (children, grandchildren), then the worker itself
    local killed=0
    if kill -0 "$pid" 2>/dev/null; then
        # Recursively kill all descendants
        _kill_descendants "$pid"
        # Kill the worker process itself
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
        # Wait briefly for cleanup
        sleep 1
        # Force kill if still alive
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$pid_file"

    if [[ "$killed" -gt 0 ]]; then
        log_info "Cleaned up worker process for $task_id (PID: $pid)"
    fi

    return 0
}

#######################################
# Recursively kill all descendant processes of a PID
#######################################
_kill_descendants() {
    local parent_pid="$1"
    local children
    children=$(pgrep -P "$parent_pid" 2>/dev/null) || true

    if [[ -n "$children" ]]; then
        for child in $children; do
            _kill_descendants "$child"
            kill "$child" 2>/dev/null || true
        done
    fi

    return 0
}

#######################################
# List all descendant PIDs of a process (stdout, space-separated)
# Used to build protection lists without killing anything
#######################################
_list_descendants() {
    local parent_pid="$1"
    local children
    children=$(pgrep -P "$parent_pid" 2>/dev/null) || true

    for child in $children; do
        echo "$child"
        _list_descendants "$child"
    done

    return 0
}

#######################################
# Kill all orphaned worker processes (emergency cleanup)
# Finds opencode worker processes with PPID=1 that match supervisor patterns
#######################################
cmd_kill_workers() {
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_db

    # Collect PIDs to protect: active workers still in running/dispatched state
    local protected_pattern=""
    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            pid=$(cat "$pid_file")
            local task_id
            task_id=$(basename "$pid_file" .pid)

            # Check if task is still active
            local task_status
            task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")

            if [[ "$task_status" == "running" || "$task_status" == "dispatched" ]] && kill -0 "$pid" 2>/dev/null; then
                protected_pattern="${protected_pattern}|${pid}"
                # Also protect all descendants (children, grandchildren, MCP servers)
                local descendants
                descendants=$(_list_descendants "$pid")
                for desc in $descendants; do
                    protected_pattern="${protected_pattern}|${desc}"
                done
            fi
        done
    fi

    # Also protect the calling process chain (this terminal session)
    local self_pid=$$
    while [[ "$self_pid" -gt 1 ]] 2>/dev/null; do
        protected_pattern="${protected_pattern}|${self_pid}"
        self_pid=$(ps -o ppid= -p "$self_pid" 2>/dev/null | tr -d ' ')
        [[ -z "$self_pid" ]] && break
    done
    protected_pattern="${protected_pattern#|}"

    log_info "Protected PIDs (active workers + self): $(echo "$protected_pattern" | tr '|' ' ' | wc -w | tr -d ' ') processes"

    # Find orphaned opencode worker processes (PPID=1, not in any terminal session)
    local orphan_count=0
    local killed_count=0

    while read -r pid; do
        local ppid
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ "$ppid" != "1" ]] && continue

        # Check not in protected list
        if [[ -n "$protected_pattern" ]] && echo "|${protected_pattern}|" | grep -q "|${pid}|"; then
            continue
        fi

        orphan_count=$((orphan_count + 1))

        if [[ "$dry_run" == "true" ]]; then
            local cmd_info
            cmd_info=$(ps -o args= -p "$pid" 2>/dev/null | head -c 80)
            log_info "  [dry-run] Would kill PID $pid: $cmd_info"
        else
            _kill_descendants "$pid"
            kill "$pid" 2>/dev/null && killed_count=$((killed_count + 1))
        fi
    done < <(pgrep -f 'opencode|claude' 2>/dev/null || true)

    if [[ "$dry_run" == "true" ]]; then
        log_info "Found $orphan_count orphaned worker processes (dry-run, none killed)"
    else
        if [[ "$killed_count" -gt 0 ]]; then
            log_success "Killed $killed_count orphaned worker processes"
        else
            log_info "No orphaned worker processes found"
        fi
    fi

    return 0
}

#######################################
# Dispatch a single task
# Creates worktree, starts worker, updates DB
#######################################
cmd_dispatch() {
    local task_id="" batch_id=""

    # First positional arg is task_id
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --batch) [[ $# -lt 2 ]] && { log_error "--batch requires a value"; return 1; }; batch_id="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh dispatch <task_id>"
        return 1
    fi

    ensure_db

    # Get task details
    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, model, retries, max_retries
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tid trepo tdesc tstatus tmodel tretries tmax_retries
    IFS=$'\t' read -r tid trepo tdesc tstatus tmodel tretries tmax_retries <<< "$task_row"

    # Validate task is in dispatchable state
    if [[ "$tstatus" != "queued" ]]; then
        log_error "Task $task_id is in '$tstatus' state, must be 'queued' to dispatch"
        return 1
    fi

    # Pre-dispatch verification: check if task was already completed in a prior batch.
    # Searches git history for commits referencing this task ID. If a merged PR commit
    # exists, the task is already done — cancel it instead of wasting an Opus session.
    # This prevents the exact bug from backlog-10 where 6 t135 subtasks were dispatched
    # despite being completed months earlier.
    if check_task_already_done "$task_id" "${trepo:-.}"; then
        log_warn "Task $task_id appears already completed in git history — cancelling"
        db "$SUPERVISOR_DB" "UPDATE tasks SET status='cancelled', error='Pre-dispatch: already completed in git history' WHERE id='$(sql_escape "$task_id")';"
        return 0
    fi

    # Check if task is claimed by someone else via TODO.md assignee: field (t165)
    local claimed_by=""
    claimed_by=$(check_task_claimed "$task_id" "${trepo:-.}" 2>/dev/null) || true
    if [[ -n "$claimed_by" ]]; then
        log_warn "Task $task_id is claimed by assignee:$claimed_by — skipping dispatch"
        return 0
    fi

    # Claim the task before dispatching (t165 — TODO.md primary, GH Issue sync optional)
    # CRITICAL: abort dispatch if claim fails (race condition = another worker claimed first)
    # Pass trepo so claim works from cron (where $PWD != repo dir)
    if ! cmd_claim "$task_id" "${trepo:-.}"; then
        log_error "Failed to claim $task_id — aborting dispatch"
        return 1
    fi

    # Authoritative concurrency check with adaptive load awareness (t151, t172)
    # This is the single source of truth for concurrency enforcement.
    # cmd_next() intentionally does NOT check concurrency to avoid a TOCTOU race
    # where the count becomes stale between cmd_next() and cmd_dispatch() calls
    # within the same pulse loop.
    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")
        local base_concurrency max_load_factor batch_max_concurrency
        base_concurrency=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
        max_load_factor=$(db "$SUPERVISOR_DB" "SELECT max_load_factor FROM batches WHERE id = '$escaped_batch';")
        batch_max_concurrency=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "0")
        local concurrency
        concurrency=$(calculate_adaptive_concurrency "${base_concurrency:-4}" "${max_load_factor:-2}" "${batch_max_concurrency:-0}")
        local active_count
        active_count=$(cmd_running_count "$batch_id")

        if [[ "$active_count" -ge "$concurrency" ]]; then
            log_warn "Concurrency limit reached ($active_count/$concurrency, base:$base_concurrency, adaptive) for batch $batch_id"
            return 2
        fi
    else
        # Global concurrency check with adaptive load awareness (t151)
        local base_global_concurrency="${SUPERVISOR_MAX_CONCURRENCY:-4}"
        local global_concurrency
        global_concurrency=$(calculate_adaptive_concurrency "$base_global_concurrency")
        local global_active
        global_active=$(cmd_running_count)
        if [[ "$global_active" -ge "$global_concurrency" ]]; then
            log_warn "Global concurrency limit reached ($global_active/$global_concurrency, base:$base_global_concurrency)"
            return 2
        fi
    fi

    # Check max retries
    if [[ "$tretries" -ge "$tmax_retries" ]]; then
        log_error "Task $task_id has exceeded max retries ($tretries/$tmax_retries)"
        cmd_transition "$task_id" "failed" --error "Max retries exceeded"
        return 1
    fi

    # Resolve AI CLI
    local ai_cli
    ai_cli=$(resolve_ai_cli) || return 1

    # Pre-dispatch model availability check (t233 — replaces simple health check)
    # Calls model-availability-helper.sh check before spawning workers.
    # Distinct exit codes prevent wasted dispatch attempts:
    #   exit 0 = healthy, proceed
    #   exit 1 = provider unavailable, defer dispatch
    #   exit 2 = rate limited, defer dispatch (retry next pulse)
    #   exit 3 = API key invalid/credits exhausted, block dispatch
    # Previously: 9 wasted failures from ambiguous_ai_unavailable + backend_quota_error
    # because the health check collapsed all failures to a single exit code.
    local health_model health_exit=0
    health_model=$(resolve_model "health" "$ai_cli")
    check_model_health "$ai_cli" "$health_model" || health_exit=$?
    if [[ "$health_exit" -ne 0 ]]; then
        case "$health_exit" in
            2)
                log_warn "Provider rate-limited for $task_id ($health_model via $ai_cli) — deferring dispatch to next pulse"
                return 3  # Return 3 = provider unavailable (distinct from concurrency limit 2)
                ;;
            3)
                log_error "API key invalid/credits exhausted for $task_id ($health_model via $ai_cli) — blocking dispatch"
                log_error "Human action required: check API key or billing. Task will not auto-retry."
                return 3
                ;;
            *)
                log_error "Provider unavailable for $task_id ($health_model via $ai_cli) — deferring dispatch"
                return 3
                ;;
        esac
    fi

    # Pre-dispatch GitHub auth check — verify the worker can push before
    # creating worktrees and burning compute. Workers spawned via nohup/cron
    # may lack SSH keys; gh auth git-credential only works with HTTPS remotes.
    if ! check_gh_auth; then
        log_error "GitHub auth unavailable for $task_id — check_gh_auth failed"
        log_error "Workers need 'gh auth login' or GH_TOKEN set. Skipping dispatch."
        return 3
    fi

    # Verify repo remote uses HTTPS (not SSH) — workers in cron can't use SSH keys
    local remote_url
    remote_url=$(git -C "${trepo:-.}" remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" == git@* || "$remote_url" == ssh://* ]]; then
        log_warn "Remote URL is SSH ($remote_url) — switching to HTTPS for worker compatibility"
        local https_url
        https_url=$(echo "$remote_url" | sed -E 's|^git@github\.com:|https://github.com/|; s|^ssh://git@github\.com/|https://github.com/|; s|\.git$||').git
        git -C "${trepo:-.}" remote set-url origin "$https_url" 2>/dev/null || true
        log_info "Remote URL updated to $https_url"
    fi

    # Create worktree
    log_info "Creating worktree for $task_id..."
    local worktree_path
    worktree_path=$(create_task_worktree "$task_id" "$trepo") || {
        log_error "Failed to create worktree for $task_id"
        cmd_transition "$task_id" "failed" --error "Worktree creation failed"
        return 1
    }

    # Validate worktree path is an actual directory (guards against stdout
    # pollution from git commands inside create_task_worktree)
    if [[ ! -d "$worktree_path" ]]; then
        log_error "Worktree path is not a directory: '$worktree_path'"
        log_error "This usually means a git command leaked stdout into the path variable"
        cmd_transition "$task_id" "failed" --error "Worktree path invalid: $worktree_path"
        return 1
    fi

    local branch_name="feature/${task_id}"

    # Set up log file
    local log_dir="$SUPERVISOR_DIR/logs"
    mkdir -p "$log_dir"
    local log_file
    log_file="$log_dir/${task_id}-$(date +%Y%m%d%H%M%S).log"

    # Pre-create log file with dispatch metadata (t183)
    # If the worker fails to start (opencode not found, permission error, etc.),
    # the log file still exists with context for diagnosis instead of no_log_file.
    {
        echo "=== DISPATCH METADATA (t183) ==="
        echo "task_id=$task_id"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "worktree=$worktree_path"
        echo "branch=$branch_name"
        echo "model=${resolved_model:-${tmodel:-default}}"
        echo "ai_cli=$(resolve_ai_cli 2>/dev/null || echo unknown)"
        echo "dispatch_mode=$(detect_dispatch_mode 2>/dev/null || echo unknown)"
        echo "=== END DISPATCH METADATA ==="
        echo ""
    } > "$log_file" 2>/dev/null || true

    # Transition to dispatched
    cmd_transition "$task_id" "dispatched" \
        --worktree "$worktree_path" \
        --branch "$branch_name" \
        --log-file "$log_file"

    # Detect dispatch mode
    local dispatch_mode
    dispatch_mode=$(detect_dispatch_mode)

    # Recall relevant memories before dispatch (t128.6)
    local memory_context=""
    memory_context=$(recall_task_memories "$task_id" "$tdesc" 2>/dev/null || echo "")
    if [[ -n "$memory_context" ]]; then
        log_info "Injecting ${#memory_context} bytes of memory context for $task_id"
    fi

    # Resolve model via frontmatter + fallback chain (t132.5)
    local resolved_model
    resolved_model=$(resolve_task_model "$task_id" "$tmodel" "${trepo:-.}" "$ai_cli")

    # Secondary availability check: verify the resolved model's provider (t233)
    # The initial health check uses the "health" tier (typically anthropic).
    # If the resolved model uses a different provider (e.g., google/gemini for pro tier),
    # we need to verify that provider too. Skip if same provider or if using OpenCode
    # (which manages routing internally).
    if [[ "$ai_cli" != "opencode" && -n "$resolved_model" && "$resolved_model" == *"/"* ]]; then
        local resolved_provider="${resolved_model%%/*}"
        local health_provider="${health_model%%/*}"
        if [[ "$resolved_provider" != "$health_provider" ]]; then
            local availability_helper="${SCRIPT_DIR}/model-availability-helper.sh"
            if [[ -x "$availability_helper" ]]; then
                local resolved_avail_exit=0
                "$availability_helper" check "$resolved_provider" --quiet || resolved_avail_exit=$?
                if [[ "$resolved_avail_exit" -ne 0 ]]; then
                    case "$resolved_avail_exit" in
                        2)
                            log_warn "Resolved model provider '$resolved_provider' is rate-limited (exit $resolved_avail_exit) for $task_id — deferring dispatch"
                            ;;
                        3)
                            log_error "Resolved model provider '$resolved_provider' has invalid key/credits (exit $resolved_avail_exit) for $task_id — blocking dispatch"
                            ;;
                        *)
                            log_warn "Resolved model provider '$resolved_provider' unavailable (exit $resolved_avail_exit) for $task_id — deferring dispatch"
                            ;;
                    esac
                    return 3
                fi
            fi
        fi
    fi

    log_info "Dispatching $task_id via $ai_cli ($dispatch_mode mode)"
    log_info "Worktree: $worktree_path"
    log_info "Model: $resolved_model"
    log_info "Log: $log_file"

    # Build and execute dispatch command
    # Use NUL-delimited read to preserve multi-line prompts as single arguments
    local -a cmd_parts=()
    while IFS= read -r -d '' part; do
        cmd_parts+=("$part")
    done < <(build_dispatch_cmd "$task_id" "$worktree_path" "$log_file" "$ai_cli" "$memory_context" "$resolved_model" "$tdesc")

    # Ensure PID directory exists before dispatch
    mkdir -p "$SUPERVISOR_DIR/pids"

    # Set FULL_LOOP_HEADLESS for all supervisor-dispatched workers (t174)
    # This ensures headless mode even if the AI doesn't parse --headless from the prompt
    local headless_env="FULL_LOOP_HEADLESS=true"

    # Generate worker-specific MCP config with heavy indexers disabled (t221)
    # Saves ~4 CPU cores per worker by preventing osgrep from indexing
    local worker_xdg_config=""
    worker_xdg_config=$(generate_worker_mcp_config "$task_id" 2>/dev/null) || true

    # Write dispatch script to a temp file to avoid bash -c quoting issues
    # with multi-line prompts (newlines in printf '%q' break bash -c strings)
    local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-dispatch.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "# Startup sentinel (t183): if this line appears in the log, the script started"
        echo "echo 'WORKER_STARTED task_id=${task_id} pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "cd '${worktree_path}' || { echo 'WORKER_FAILED: cd to worktree failed: ${worktree_path}'; exit 1; }"
        echo "export ${headless_env}"
        # Redirect worker to use MCP config with heavy indexers disabled (t221)
        if [[ -n "$worker_xdg_config" ]]; then
            echo "export XDG_CONFIG_HOME='${worker_xdg_config}'"
        fi
        # Write each cmd_part as a properly quoted array element
        printf 'exec '
        printf '%q ' "${cmd_parts[@]}"
        printf '\n'
    } > "$dispatch_script"
    chmod +x "$dispatch_script"

    # Wrapper script (t183): captures errors from the dispatch script itself.
    # Previous approach used nohup bash -c with &>/dev/null which swallowed
    # errors when the dispatch script failed to start (e.g., opencode not found).
    # Now errors are appended to the log file for diagnosis.
    local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-wrapper.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "'${dispatch_script}' >> '${log_file}' 2>&1"
        echo "rc=\$?"
        echo "echo \"EXIT:\${rc}\" >> '${log_file}'"
        echo "if [ \$rc -ne 0 ]; then"
        echo "  echo \"WORKER_DISPATCH_ERROR: dispatch script exited with code \${rc}\" >> '${log_file}'"
        echo "fi"
    } > "$wrapper_script"
    chmod +x "$wrapper_script"

    if [[ "$dispatch_mode" == "tabby" ]]; then
        # Tabby: attempt to open in a new tab via OSC 1337 escape sequence
        log_info "Opening Tabby tab for $task_id..."
        printf '\e]1337;NewTab=%s\a' "'${wrapper_script}'" 2>/dev/null || true
        # Also start background process as fallback (Tabby may not support OSC 1337)
        # Use nohup + disown to survive parent (cron) exit
        nohup bash "${wrapper_script}" &>/dev/null &
    else
        # Headless: background process
        # Use nohup + disown to survive parent (cron) exit — without this,
        # workers die after ~2 minutes when the cron pulse script exits
        nohup bash "${wrapper_script}" &>/dev/null &
    fi

    local worker_pid=$!
    disown "$worker_pid" 2>/dev/null || true

    # Store PID for monitoring
    echo "$worker_pid" > "$SUPERVISOR_DIR/pids/${task_id}.pid"

    # Transition to running
    cmd_transition "$task_id" "running" --session "pid:$worker_pid"

    log_success "Dispatched $task_id (PID: $worker_pid)"
    echo "$worker_pid"
    return 0
}

#######################################
# Check the status of a running worker
# Reads log file and PID to determine state
#######################################
cmd_worker_status() {
    local task_id="${1:-}"

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh worker-status <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, session_id, log_file, worktree
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tstatus tsession tlog tworktree
    IFS='|' read -r tstatus tsession tlog tworktree <<< "$task_row"

    echo -e "${BOLD}Worker: $task_id${NC}"
    echo "  DB Status:  $tstatus"
    echo "  Session:    ${tsession:-none}"
    echo "  Log:        ${tlog:-none}"
    echo "  Worktree:   ${tworktree:-none}"

    # Check PID if running
    if [[ "$tstatus" == "running" || "$tstatus" == "dispatched" ]]; then
        local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                echo -e "  Process:    ${GREEN}alive${NC} (PID: $pid)"
            else
                echo -e "  Process:    ${RED}dead${NC} (PID: $pid was)"
            fi
        else
            echo "  Process:    unknown (no PID file)"
        fi
    fi

    # Check log file for completion signals
    if [[ -n "$tlog" && -f "$tlog" ]]; then
        local log_size
        log_size=$(wc -c < "$tlog" | tr -d ' ')
        echo "  Log size:   ${log_size} bytes"

        # Check for completion signals
        if grep -q 'FULL_LOOP_COMPLETE' "$tlog" 2>/dev/null; then
            echo -e "  Signal:     ${GREEN}FULL_LOOP_COMPLETE${NC}"
        elif grep -q 'TASK_COMPLETE' "$tlog" 2>/dev/null; then
            echo -e "  Signal:     ${YELLOW}TASK_COMPLETE${NC}"
        fi

        # Show PR URL from DB (t151: don't grep log - picks up wrong URLs)
        local pr_url
        pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || true)
        if [[ -n "$pr_url" && "$pr_url" != "no_pr" && "$pr_url" != "task_only" ]]; then
            echo "  PR:         $pr_url"
        fi

        # Check for EXIT code
        local exit_line
        exit_line=$(grep '^EXIT:' "$tlog" 2>/dev/null | tail -1 || true)
        if [[ -n "$exit_line" ]]; then
            echo "  Exit:       ${exit_line#EXIT:}"
        fi

        # Show last 3 lines of log
        echo ""
        echo "  Last output:"
        tail -3 "$tlog" 2>/dev/null | while IFS= read -r line; do
            echo "    $line"
        done
    fi

    return 0
}

#######################################
# Extract the last N lines from a log file (for AI eval context)
# Avoids sending entire multi-MB logs to the evaluator
#######################################
extract_log_tail() {
    local log_file="$1"
    local lines="${2:-200}"

    if [[ ! -f "$log_file" ]]; then
        echo "(no log file)"
        return 0
    fi

    tail -n "$lines" "$log_file" 2>/dev/null || echo "(failed to read log)"
    return 0
}

#######################################
# Extract structured outcome data from a log file
# Outputs key=value pairs for: pr_url, exit_code, signals, errors
#######################################
extract_log_metadata() {
    local log_file="$1"

    if [[ ! -f "$log_file" ]]; then
        echo "log_exists=false"
        return 0
    fi

    echo "log_exists=true"
    echo "log_bytes=$(wc -c < "$log_file" | tr -d ' ')"
    echo "log_lines=$(wc -l < "$log_file" | tr -d ' ')"

    # Content lines: exclude REPROMPT METADATA header (t198). Retry logs include
    # an 8-line metadata block that inflates log_lines, causing the backend error
    # threshold (< 10 lines) to miss short error-only logs. content_lines counts
    # only the actual worker output.
    local content_lines
    content_lines=$(grep -cv '^=== \(REPROMPT METADATA\|END REPROMPT METADATA\)\|^task_id=\|^timestamp=\|^retry=\|^work_dir=\|^previous_error=\|^fresh_worktree=' "$log_file" 2>/dev/null || echo 0)
    echo "content_lines=$content_lines"

    # Worker startup sentinel (t183)
    if grep -q 'WORKER_STARTED' "$log_file" 2>/dev/null; then
        echo "worker_started=true"
    else
        echo "worker_started=false"
    fi

    # Dispatch error sentinel (t183)
    if grep -q 'WORKER_DISPATCH_ERROR\|WORKER_FAILED' "$log_file" 2>/dev/null; then
        local dispatch_error
        dispatch_error=$(grep -o 'WORKER_DISPATCH_ERROR:.*\|WORKER_FAILED:.*' "$log_file" 2>/dev/null | head -1 | head -c 200 || echo "")
        echo "dispatch_error=${dispatch_error:-unknown}"
    else
        echo "dispatch_error="
    fi

    # Completion signals
    if grep -q 'FULL_LOOP_COMPLETE' "$log_file" 2>/dev/null; then
        echo "signal=FULL_LOOP_COMPLETE"
    elif grep -q 'TASK_COMPLETE' "$log_file" 2>/dev/null; then
        echo "signal=TASK_COMPLETE"
    else
        echo "signal=none"
    fi

    # PR URL extraction (t192): Extract from the worker's FINAL text output only.
    # Full-log grep is unsafe (t151) — memory recalls, TODO reads, and git log
    # embed PR URLs from other tasks. But the last "type":"text" JSON entry is
    # the worker's own summary and is authoritative. This eliminates the race
    # condition where gh pr list --head (in evaluate_worker) misses a just-created
    # PR, causing false clean_exit_no_signal retries.
    # Fallback: gh pr list --head in evaluate_worker() remains as a safety net.
    local final_pr_url=""
    local last_text_line
    last_text_line=$(grep '"type":"text"' "$log_file" 2>/dev/null | tail -1 || true)
    if [[ -n "$last_text_line" ]]; then
        final_pr_url=$(echo "$last_text_line" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -1 || true)
    fi
    echo "pr_url=${final_pr_url}"

    # Task obsolete detection (t198): workers that determine a task is already
    # done or obsolete exit cleanly with no signal and no PR. Without this,
    # the supervisor retries them as clean_exit_no_signal, wasting retries.
    # Only check the final text entry (authoritative, same as PR URL extraction).
    local task_obsolete="false"
    if [[ -n "$last_text_line" ]]; then
        if echo "$last_text_line" | grep -qiE 'already done|already complete[d]?|task.*(obsolete|no longer needed)|no (changes|PR) needed|nothing to (change|fix|do)|no work (needed|required|to do)'; then
            task_obsolete="true"
        fi
    fi
    echo "task_obsolete=$task_obsolete"

    # Task tool parallelism tracking (t217): detect whether the worker used the
    # Task tool (mcp_task) to spawn sub-agents for parallel work. This is a
    # heuristic quality signal — workers that parallelise independent subtasks
    # are more efficient. Logged for pattern tracking and supervisor dashboards.
    local task_tool_count=0
    task_tool_count=$(grep -c 'mcp_task\|"tool_name":"task"\|"name":"task"' "$log_file" 2>/dev/null || echo 0)
    echo "task_tool_count=$task_tool_count"

    # Exit code
    local exit_line
    exit_line=$(grep '^EXIT:' "$log_file" 2>/dev/null | tail -1 || true)
    echo "exit_code=${exit_line#EXIT:}"

    # Error patterns - search only the LAST 20 lines to avoid false positives
    # from generated content. Worker logs (opencode JSON) embed tool outputs
    # that may discuss auth, errors, conflicts as documentation content.
    # Only the final lines contain actual execution status/errors.
    local log_tail_file
    log_tail_file=$(mktemp)
    _save_cleanup_scope; trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${log_tail_file}'"
    tail -20 "$log_file" > "$log_tail_file" 2>/dev/null || true

    local rate_limit_count=0 auth_error_count=0 conflict_count=0 timeout_count=0 oom_count=0
    rate_limit_count=$(grep -ci 'rate.limit\|429\|too many requests' "$log_tail_file" 2>/dev/null || echo 0)
    auth_error_count=$(grep -ci 'permission denied\|unauthorized\|403\|401' "$log_tail_file" 2>/dev/null || echo 0)
    conflict_count=$(grep -ci 'merge conflict\|CONFLICT\|conflict marker' "$log_tail_file" 2>/dev/null || echo 0)
    timeout_count=$(grep -ci 'timeout\|timed out\|ETIMEDOUT' "$log_tail_file" 2>/dev/null || echo 0)
    oom_count=$(grep -ci 'out of memory\|OOM\|heap.*exceeded\|ENOMEM' "$log_tail_file" 2>/dev/null || echo 0)

    # Backend infrastructure errors - search tail only (same as other heuristics).
    # Full-log search caused false positives: worker logs embed tool output that
    # discusses errors, APIs, status codes as documentation content.
    # Anchored patterns prevent substring matches (e.g., 503 in timestamps).
    local backend_error_count=0
    backend_error_count=$(grep -ci 'endpoints failed\|gateway[[:space:]].*error\|service unavailable\|HTTP 503\|503 Service\|"status":[[:space:]]*503\|Quota protection\|over[_ -]\{0,1\}usage\|quota reset\|CreditsError\|Insufficient balance\|statusCode.*401' "$log_tail_file" 2>/dev/null || echo 0)

    rm -f "$log_tail_file"

    echo "rate_limit_count=$rate_limit_count"
    echo "auth_error_count=$auth_error_count"
    echo "conflict_count=$conflict_count"
    echo "timeout_count=$timeout_count"
    echo "oom_count=$oom_count"
    echo "backend_error_count=$backend_error_count"

    # JSON parse errors (opencode --format json output)
    if grep -q '"error"' "$log_file" 2>/dev/null; then
        local json_error
        json_error=$(grep -o '"error"[[:space:]]*:[[:space:]]*"[^"]*"' "$log_file" 2>/dev/null | tail -1 || true)
        echo "json_error=${json_error:-}"
    fi

    return 0
}

#######################################
# Validate that a PR belongs to a task by checking title/branch for task ID (t195)
#
# Prevents false attribution: a PR found via branch lookup must contain the
# task ID in its title or head branch name. Without this, stale branches or
# reused branch names could cause the supervisor to attribute an unrelated PR
# to a task, triggering false completion cascades (TODO.md [x] → GH issue close).
#
# $1: task_id (e.g., "t195")
# $2: repo_slug (e.g., "owner/repo")
# $3: pr_url (the candidate PR URL to validate)
#
# Returns 0 if PR belongs to task, 1 if not
# Outputs validated PR URL to stdout on success (empty on failure)
#######################################
validate_pr_belongs_to_task() {
    local task_id="$1"
    local repo_slug="$2"
    local pr_url="$3"

    if [[ -z "$pr_url" || -z "$task_id" || -z "$repo_slug" ]]; then
        return 1
    fi

    # Extract PR number from URL
    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
    if [[ -z "$pr_number" ]]; then
        return 1
    fi

    # Fetch PR title and head branch with retry + exponential backoff (t211).
    # GitHub API can fail transiently (rate limits, network blips, 502s).
    # 3 attempts: immediate, then 2s, then 4s delay.
    local pr_info="" attempt max_attempts=3 backoff=2
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
            --json title,headRefName 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")
        if [[ -n "$pr_info" ]]; then
            break
        fi
        if (( attempt < max_attempts )); then
            log_warn "validate_pr_belongs_to_task: attempt $attempt/$max_attempts failed for PR #$pr_number — retrying in ${backoff}s"
            sleep "$backoff"
            backoff=$(( backoff * 2 ))
        fi
    done

    if [[ -z "$pr_info" ]]; then
        log_warn "validate_pr_belongs_to_task: cannot fetch PR #$pr_number for $task_id after $max_attempts attempts"
        return 1
    fi

    local pr_title pr_branch
    pr_title=$(echo "$pr_info" | jq -r '.title // ""' 2>/dev/null || echo "")
    pr_branch=$(echo "$pr_info" | jq -r '.headRefName // ""' 2>/dev/null || echo "")

    # Check if task ID appears in title or branch (case-insensitive).
    # Uses word boundary \b so "t195" matches "feature/t195", "(t195)",
    # "t195-fix-auth" but NOT "t1950" or "t1195".
    if echo "$pr_title" | grep -qi "\b${task_id}\b" 2>/dev/null; then
        echo "$pr_url"
        return 0
    fi

    if echo "$pr_branch" | grep -qi "\b${task_id}\b" 2>/dev/null; then
        echo "$pr_url"
        return 0
    fi

    log_warn "validate_pr_belongs_to_task: PR #$pr_number does not reference $task_id (title='$pr_title', branch='$pr_branch')"
    return 1
}

#######################################
# Parse a GitHub PR URL into repo_slug and pr_number (t232)
#
# Single source of truth for PR URL parsing. Replaces scattered
# grep -oE '[0-9]+$' and grep -oE 'github\.com/...' patterns.
#
# $1: pr_url (e.g., "https://github.com/owner/repo/pull/123")
#
# Outputs: "repo_slug|pr_number" on stdout (e.g., "owner/repo|123")
# Returns 0 on success, 1 if URL cannot be parsed
#######################################
parse_pr_url() {
    local pr_url="$1"

    if [[ -z "$pr_url" ]]; then
        return 1
    fi

    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
    if [[ -z "$pr_number" ]]; then
        return 1
    fi

    local repo_slug
    repo_slug=$(echo "$pr_url" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||' || echo "")
    if [[ -z "$repo_slug" ]]; then
        return 1
    fi

    echo "${repo_slug}|${pr_number}"
    return 0
}

#######################################
# Discover a PR for a task via GitHub branch-name lookup (t232)
#
# Single source of truth for branch-based PR discovery. Tries:
#   1. The task's actual branch from the DB (worktree branch name)
#   2. Convention: feature/${task_id}
#
# All candidates are validated via validate_pr_belongs_to_task() before
# being returned. This prevents cross-contamination (t195, t223).
#
# $1: task_id (e.g., "t195")
# $2: repo_slug (e.g., "owner/repo")
# $3: task_branch (optional — the DB branch column; empty to skip)
#
# Outputs: validated PR URL on stdout (empty if none found)
# Returns 0 on success (URL found), 1 if no PR found
#######################################
discover_pr_by_branch() {
    local task_id="$1"
    local repo_slug="$2"
    local task_branch="${3:-}"

    if [[ -z "$task_id" || -z "$repo_slug" ]]; then
        return 1
    fi

    local candidate_pr_url=""

    # Try DB branch first (actual worktree branch name)
    if [[ -n "$task_branch" ]]; then
        candidate_pr_url=$(gh pr list --repo "$repo_slug" --head "$task_branch" --json url --jq '.[0].url' 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")
    fi

    # Fallback to convention: feature/${task_id}
    if [[ -z "$candidate_pr_url" ]]; then
        candidate_pr_url=$(gh pr list --repo "$repo_slug" --head "feature/${task_id}" --json url --jq '.[0].url' 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")
    fi

    if [[ -z "$candidate_pr_url" ]]; then
        return 1
    fi

    # Validate candidate PR contains task ID in title or branch (t195)
    local validated_url
    validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$candidate_pr_url") || validated_url=""

    if [[ -n "$validated_url" ]]; then
        echo "$validated_url"
        return 0
    fi

    log_warn "discover_pr_by_branch: candidate PR for $task_id failed task ID validation — ignoring"
    return 1
}

#######################################
# Link a PR to a task — single source of truth (t232)
#
# Centralizes the full discover-validate-persist pipeline for PR-to-task
# linking. Replaces scattered inline patterns across evaluate_worker(),
# check_pr_status(), scan_orphaned_prs(), scan_orphaned_pr_for_task(),
# and cmd_pr_lifecycle().
#
# Modes:
#   1. With --url: validate and persist a known PR URL
#   2. Without --url: discover PR via branch lookup, validate, persist
#
# Options:
#   --url <pr_url>     Candidate PR URL to validate and link
#   --transition       Also transition the task to complete (for orphan scans)
#   --notify           Send task notification after linking
#   --caller <name>    Caller name for log messages (default: "link_pr_to_task")
#
# $1: task_id
#
# Outputs: validated PR URL on stdout (empty if none found/linked)
# Returns 0 if PR was linked, 1 if no PR found/validated
#######################################
link_pr_to_task() {
    local task_id=""
    local candidate_url=""
    local do_transition="false"
    local do_notify="false"
    local caller="link_pr_to_task"

    # Parse arguments
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url) [[ $# -lt 2 ]] && { log_error "--url requires a value"; return 1; }; candidate_url="$2"; shift 2 ;;
            --transition) do_transition="true"; shift ;;
            --notify) do_notify="true"; shift ;;
            --caller) [[ $# -lt 2 ]] && { log_error "--caller requires a value"; return 1; }; caller="$2"; shift 2 ;;
            *) log_error "link_pr_to_task: unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        log_error "link_pr_to_task: task_id required"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Fetch task details from DB
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, branch, pr_url FROM tasks
        WHERE id = '$escaped_id';
    " 2>/dev/null || echo "")

    if [[ -z "$task_row" ]]; then
        log_error "$caller: task not found: $task_id"
        return 1
    fi

    local tstatus trepo tbranch tpr_url
    IFS='|' read -r tstatus trepo tbranch tpr_url <<< "$task_row"

    # If a candidate URL was provided, validate and persist it
    if [[ -n "$candidate_url" ]]; then
        # Resolve repo slug for validation
        local repo_slug=""
        if [[ -n "$trepo" ]]; then
            repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
        fi

        if [[ -z "$repo_slug" ]]; then
            log_warn "$caller: cannot validate PR URL for $task_id (repo slug detection failed) — clearing to prevent cross-contamination"
            return 1
        fi

        local validated_url
        validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$candidate_url") || validated_url=""

        if [[ -z "$validated_url" ]]; then
            log_warn "$caller: PR URL for $task_id failed task ID validation — not linking"
            return 1
        fi

        # Persist to DB
        db "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$validated_url")' WHERE id = '$escaped_id';" 2>/dev/null || {
            log_warn "$caller: failed to persist PR URL for $task_id"
            return 1
        }

        # Transition if requested (for orphan scan use cases)
        if [[ "$do_transition" == "true" ]]; then
            case "$tstatus" in
                failed|blocked|retrying)
                    log_info "  $caller: PR found for $task_id ($tstatus -> complete): $validated_url"
                    cmd_transition "$task_id" "complete" --pr-url "$validated_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
                    update_todo_on_complete "$task_id" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
                    ;;
                complete)
                    log_info "  $caller: linked PR to completed task $task_id: $validated_url"
                    ;;
                *)
                    log_info "  $caller: linked PR to $task_id ($tstatus): $validated_url"
                    ;;
            esac
        fi

        # Notify if requested
        if [[ "$do_notify" == "true" ]]; then
            send_task_notification "$task_id" "complete" "pr_linked:$validated_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
            local tid_desc
            tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
            store_success_pattern "$task_id" "pr_linked_${caller}" "$tid_desc" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
        fi

        echo "$validated_url"
        return 0
    fi

    # No candidate URL — discover via branch lookup
    # Skip if PR already linked
    if [[ -n "$tpr_url" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" && "$tpr_url" != "task_obsolete" && "$tpr_url" != "" ]]; then
        echo "$tpr_url"
        return 0
    fi

    # Need a repo to discover
    if [[ -z "$trepo" ]]; then
        return 1
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
    if [[ -z "$repo_slug" ]]; then
        return 1
    fi

    # Discover via branch lookup
    local discovered_url
    discovered_url=$(discover_pr_by_branch "$task_id" "$repo_slug" "$tbranch") || discovered_url=""

    if [[ -z "$discovered_url" ]]; then
        return 1
    fi

    # Persist to DB
    db "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$discovered_url")' WHERE id = '$escaped_id';" 2>/dev/null || {
        log_warn "$caller: failed to persist discovered PR URL for $task_id"
        return 1
    }

    # Transition if requested
    if [[ "$do_transition" == "true" ]]; then
        case "$tstatus" in
            failed|blocked|retrying)
                log_info "  $caller: discovered PR for $task_id ($tstatus -> complete): $discovered_url"
                cmd_transition "$task_id" "complete" --pr-url "$discovered_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
                update_todo_on_complete "$task_id" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
                ;;
            complete)
                log_info "  $caller: linked discovered PR to completed task $task_id: $discovered_url"
                ;;
            *)
                log_info "  $caller: linked discovered PR to $task_id ($tstatus): $discovered_url"
                ;;
        esac
    fi

    # Notify if requested
    if [[ "$do_notify" == "true" ]]; then
        send_task_notification "$task_id" "complete" "pr_discovered:$discovered_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
        local tid_desc
        tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
        store_success_pattern "$task_id" "pr_discovered_${caller}" "$tid_desc" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
    fi

    echo "$discovered_url"
    return 0
}

#######################################
# Evaluate a completed worker's outcome using log analysis
# Returns: complete:<detail>, retry:<reason>, blocked:<reason>, failed:<reason>
#
# Four-tier evaluation:
#   1. Deterministic: check for known signals and error patterns
#   2. Heuristic: analyze exit codes and error counts
#   2.5. Git heuristic (t175): check commits on branch + uncommitted changes
#   3. AI eval: dispatch cheap Sonnet call for ambiguous outcomes
#######################################
evaluate_worker() {
    local task_id="$1"
    local skip_ai_eval="${2:-false}"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, log_file, retries, max_retries, session_id, pr_url
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tstatus tlog tretries tmax_retries tsession tpr_url
    IFS='|' read -r tstatus tlog tretries tmax_retries tsession tpr_url <<< "$task_row"

    # Enhanced no_log_file diagnostics (t183)
    # Instead of a bare "failed:no_log_file", gather context about why the log
    # is missing so the supervisor can make better retry/block decisions and
    # self-healing diagnostics have actionable information.
    if [[ -z "$tlog" ]]; then
        # No log path in DB at all — dispatch likely failed before setting log_file
        local diag_detail="no_log_path_in_db"
        local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
        if [[ -f "$pid_file" ]]; then
            local stale_pid
            stale_pid=$(cat "$pid_file" 2>/dev/null || echo "")
            if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
                diag_detail="no_log_path_in_db:worker_pid_${stale_pid}_dead"
            elif [[ -n "$stale_pid" ]]; then
                diag_detail="no_log_path_in_db:worker_pid_${stale_pid}_alive"
            fi
        fi
        echo "failed:${diag_detail}"
        return 0
    fi

    if [[ ! -f "$tlog" ]]; then
        # Log path set in DB but file doesn't exist — worker wrapper never ran
        local diag_detail="log_file_missing"
        local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-dispatch.sh"
        local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-wrapper.sh"
        if [[ ! -f "$dispatch_script" && ! -f "$wrapper_script" ]]; then
            diag_detail="log_file_missing:no_dispatch_scripts"
        elif [[ -f "$dispatch_script" && ! -x "$dispatch_script" ]]; then
            diag_detail="log_file_missing:dispatch_script_not_executable"
        fi
        local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
        if [[ -f "$pid_file" ]]; then
            local stale_pid
            stale_pid=$(cat "$pid_file" 2>/dev/null || echo "")
            if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
                diag_detail="${diag_detail}:worker_pid_${stale_pid}_dead"
            fi
        else
            diag_detail="${diag_detail}:no_pid_file"
        fi
        echo "failed:${diag_detail}"
        return 0
    fi

    # Log file exists but may be empty or contain only metadata header (t183)
    local log_size
    log_size=$(wc -c < "$tlog" 2>/dev/null | tr -d ' ')
    if [[ "$log_size" -eq 0 ]]; then
        echo "failed:log_file_empty"
        return 0
    fi

    # Check if worker never started (only dispatch metadata, no WORKER_STARTED sentinel)
    if [[ "$log_size" -lt 500 ]] && ! grep -q 'WORKER_STARTED' "$tlog" 2>/dev/null; then
        # Log has metadata but worker never started — extract any error from log
        local startup_error=""
        startup_error=$(grep -i 'WORKER_FAILED\|WORKER_DISPATCH_ERROR\|command not found\|No such file\|Permission denied' "$tlog" 2>/dev/null | head -1 | head -c 200 || echo "")
        if [[ -n "$startup_error" ]]; then
            echo "failed:worker_never_started:$(echo "$startup_error" | tr ' ' '_' | tr -cd '[:alnum:]_:-')"
        else
            echo "failed:worker_never_started:no_sentinel"
        fi
        return 0
    fi

    # --- Tier 1: Deterministic signal detection ---

    # Parse structured metadata from log (bash 3.2 compatible - no associative arrays)
    local meta_output
    meta_output=$(extract_log_metadata "$tlog")

    # Helper: extract a value from key=value metadata output
    _meta_get() {
        local key="$1" default="${2:-}"
        local val
        val=$(echo "$meta_output" | grep "^${key}=" | head -1 | cut -d= -f2-)
        echo "${val:-$default}"
    }

    local meta_signal meta_pr_url meta_exit_code
    meta_signal=$(_meta_get "signal" "none")
    meta_pr_url=$(_meta_get "pr_url" "")
    meta_exit_code=$(_meta_get "exit_code" "")

    # Seed PR URL from DB (t171): check_pr_status() or a previous pulse may have
    # already found and persisted the PR URL. Use it before expensive gh API calls.
    if [[ -z "$meta_pr_url" && -n "${tpr_url:-}" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" ]]; then
        meta_pr_url="$tpr_url"
    fi

    # Resolve repo slug early — needed for PR validation (t195) and fallback detection
    local task_repo task_branch repo_slug_detect
    task_repo=$(sqlite3 "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    task_branch=$(sqlite3 "$SUPERVISOR_DB" "SELECT branch FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    repo_slug_detect=""
    if [[ -n "$task_repo" ]]; then
        repo_slug_detect=$(detect_repo_slug "$task_repo" 2>/dev/null || echo "")
    fi

    # Validate PR URL belongs to this task (t195, t223): a previous pulse
    # may have stored a PR URL that doesn't actually reference this task ID
    # (e.g., branch reuse, stale data, or log containing another task's PR URL).
    # Validate before using for attribution. If repo slug detection failed,
    # clear the PR URL entirely — unvalidated URLs cause cross-contamination
    # where the wrong PR gets linked to the wrong task (t223).
    if [[ -n "$meta_pr_url" ]]; then
        if [[ -n "$repo_slug_detect" ]]; then
            local validated_url
            validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug_detect" "$meta_pr_url") || validated_url=""
            if [[ -z "$validated_url" ]]; then
                log_warn "evaluate_worker: PR URL for $task_id failed task ID validation — clearing"
                meta_pr_url=""
            fi
        else
            log_warn "evaluate_worker: cannot validate PR URL for $task_id (repo slug detection failed) — clearing to prevent cross-contamination"
            meta_pr_url=""
        fi
    fi

    # Fallback PR URL detection via centralized discover_pr_by_branch() (t232, t161, t195)
    if [[ -z "$meta_pr_url" && -n "$repo_slug_detect" ]]; then
        meta_pr_url=$(discover_pr_by_branch "$task_id" "$repo_slug_detect" "$task_branch") || meta_pr_url=""
    fi

    local meta_rate_limit_count meta_auth_error_count meta_conflict_count
    local meta_timeout_count meta_oom_count meta_backend_error_count
    meta_rate_limit_count=$(_meta_get "rate_limit_count" "0")
    meta_auth_error_count=$(_meta_get "auth_error_count" "0")
    meta_conflict_count=$(_meta_get "conflict_count" "0")
    meta_timeout_count=$(_meta_get "timeout_count" "0")
    meta_oom_count=$(_meta_get "oom_count" "0")
    meta_backend_error_count=$(_meta_get "backend_error_count" "0")

    # FULL_LOOP_COMPLETE = definitive success
    if [[ "$meta_signal" == "FULL_LOOP_COMPLETE" ]]; then
        echo "complete:${meta_pr_url:-no_pr}"
        return 0
    fi

    # TASK_COMPLETE with clean exit = partial success (PR phase may have failed)
    # If a PR URL is available (from DB or gh fallback), include it.
    if [[ "$meta_signal" == "TASK_COMPLETE" && "$meta_exit_code" == "0" ]]; then
        echo "complete:${meta_pr_url:-task_only}"
        return 0
    fi

    # PR URL with clean exit = task completed (PR was created successfully)
    # This takes priority over heuristic error patterns because log content
    # may discuss auth/errors as part of the task itself (e.g., creating an
    # API integration subagent that documents authentication flows)
    if [[ -n "$meta_pr_url" && "$meta_exit_code" == "0" ]]; then
        echo "complete:${meta_pr_url}"
        return 0
    fi

    # Backend infrastructure error with EXIT:0 (t095-diag-1): CLI wrappers like
    # OpenCode exit 0 even when the backend rejects the request (quota exceeded,
    # backend down). A short log with backend errors means the worker never
    # started - this is NOT content discussion, it's a real failure.
    # Must be checked BEFORE clean_exit_no_signal to avoid wasting retries.
    # (t198): Use content_lines instead of log_lines to exclude REPROMPT METADATA
    # headers that inflate the line count in retry logs (8-line header caused
    # 12-line logs to miss the < 10 threshold).
    if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
        local meta_content_lines
        meta_content_lines=$(_meta_get "content_lines" "0")
        # Billing/credits errors: block immediately, retrying won't help.
        # OpenCode Zen proxy returns CreditsError when credits exhausted;
        # this is a billing issue, not a transient backend error.
        if [[ "$meta_backend_error_count" -gt 0 && "$meta_content_lines" -lt 10 ]]; then
            if grep -qi 'CreditsError\|Insufficient balance' "$log_file" 2>/dev/null; then
                echo "blocked:billing_credits_exhausted"
                return 0
            fi
            echo "retry:backend_quota_error"
            return 0
        fi
    fi

    # Task obsolete detection (t198): workers that determine a task is already
    # done or obsolete exit cleanly with EXIT:0, no signal, and no PR. Without
    # this check, the supervisor retries them as clean_exit_no_signal, wasting
    # retry attempts on work that will never produce a PR.
    # Uses the final "type":"text" entry (authoritative) to detect explicit
    # "already done" / "no changes needed" language from the worker.
    if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
        local meta_task_obsolete
        meta_task_obsolete=$(_meta_get "task_obsolete" "false")
        if [[ "$meta_task_obsolete" == "true" ]]; then
            echo "complete:task_obsolete"
            return 0
        fi
    fi

    # Clean exit with no completion signal and no PR (checked DB + gh API above)
    # = likely incomplete. The agent finished cleanly but didn't emit a signal
    # and no PR was found. Retry (agent may have run out of context or hit a
    # soft limit). If a PR exists, it was caught at line ~3179 via DB seed (t171)
    # or gh fallback (t161).
    if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
        echo "retry:clean_exit_no_signal"
        return 0
    fi

    # --- Tier 2: Heuristic error pattern matching ---
    # ONLY applied when exit code is non-zero or missing.
    # When exit=0, the agent finished cleanly - any "error" strings in the log
    # are content (e.g., subagents documenting auth flows), not real failures.

    if [[ "$meta_exit_code" != "0" ]]; then
        # Backend infrastructure error (quota, API gateway) = transient retry
        # Only checked on non-zero exit: a clean exit with backend error strings in
        # the log is content discussion, not a real infrastructure failure.
        if [[ "$meta_backend_error_count" -gt 0 ]]; then
            echo "retry:backend_infrastructure_error"
            return 0
        fi

        # Auth errors are always blocking (human must fix credentials)
        if [[ "$meta_auth_error_count" -gt 0 ]]; then
            echo "blocked:auth_error"
            return 0
        fi

        # Merge conflicts require human resolution
        if [[ "$meta_conflict_count" -gt 0 ]]; then
            echo "blocked:merge_conflict"
            return 0
        fi

        # OOM is infrastructure - blocking
        if [[ "$meta_oom_count" -gt 0 ]]; then
            echo "blocked:out_of_memory"
            return 0
        fi

        # Rate limiting is transient - retry with backoff
        if [[ "$meta_rate_limit_count" -gt 0 ]]; then
            echo "retry:rate_limited"
            return 0
        fi

        # Timeout is transient - retry
        if [[ "$meta_timeout_count" -gt 0 ]]; then
            echo "retry:timeout"
            return 0
        fi
    fi

    # Non-zero exit with known code
    if [[ -n "$meta_exit_code" && "$meta_exit_code" != "0" ]]; then
        # Exit code 130 = SIGINT (Ctrl+C), 137 = SIGKILL, 143 = SIGTERM
        case "$meta_exit_code" in
            130) echo "retry:interrupted_sigint"; return 0 ;;
            137) echo "retry:killed_sigkill"; return 0 ;;
            143) echo "retry:terminated_sigterm"; return 0 ;;
        esac
    fi

    # Check if retries exhausted before attempting AI eval
    if [[ "$tretries" -ge "$tmax_retries" ]]; then
        echo "failed:max_retries"
        return 0
    fi

    # --- Tier 2.5: Git heuristic signals (t175) ---
    # Before expensive AI eval, check for concrete evidence of work in the
    # task's worktree/branch. This resolves most ambiguous outcomes cheaply
    # and prevents false retries when the worker completed but didn't emit
    # a signal (e.g., context exhaustion after creating a PR).

    # Reuse task_repo/task_branch from PR detection above; fetch worktree
    local task_worktree
    task_worktree=$(db "$SUPERVISOR_DB" "SELECT worktree FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

    if [[ -n "$task_repo" && -d "$task_repo" ]]; then
        # Use worktree path if available, otherwise fall back to repo
        local git_dir="${task_worktree:-$task_repo}"
        if [[ ! -d "$git_dir" ]]; then
            git_dir="$task_repo"
        fi

        # Check for commits on branch ahead of main/master
        local branch_commits=0
        if [[ -n "$task_branch" ]]; then
            local base_branch
            base_branch=$(git -C "$git_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
            branch_commits=$(git -C "$git_dir" rev-list --count "${base_branch}..${task_branch}" 2>/dev/null || echo 0)
        fi

        # Check for uncommitted changes in worktree
        local uncommitted_changes=0
        if [[ -n "$task_worktree" && -d "$task_worktree" ]]; then
            uncommitted_changes=$(git -C "$task_worktree" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        fi

        # Decision matrix:
        # - Commits + PR URL → complete (worker finished, signal was lost)
        # - Commits + no PR  → complete:task_only (PR creation may have failed)
        # - No commits + uncommitted changes → retry:work_in_progress
        # - No commits + no changes → genuine ambiguity (fall through to AI/retry)

        if [[ "$branch_commits" -gt 0 ]]; then
            if [[ -n "$meta_pr_url" ]]; then
                echo "complete:${meta_pr_url}"
            else
                echo "complete:task_only"
            fi
            return 0
        fi

        if [[ "$uncommitted_changes" -gt 0 ]]; then
            echo "retry:work_in_progress"
            return 0
        fi
    fi

    # --- Tier 3: AI evaluation for ambiguous outcomes ---

    if [[ "$skip_ai_eval" == "true" ]]; then
        echo "retry:ambiguous_skipped_ai"
        return 0
    fi

    local ai_verdict
    ai_verdict=$(evaluate_with_ai "$task_id" "$tlog" 2>/dev/null || echo "")

    if [[ -n "$ai_verdict" ]]; then
        echo "$ai_verdict"
        return 0
    fi

    # AI eval failed or unavailable - default to retry
    echo "retry:ambiguous_ai_unavailable"
    return 0
}

#######################################
# Dispatch a cheap AI call to evaluate ambiguous worker outcomes
# Uses Sonnet for speed (~30s) and cost efficiency
# Returns: complete:<detail>, retry:<reason>, blocked:<reason>
#######################################
evaluate_with_ai() {
    local task_id="$1"
    local log_file="$2"

    local ai_cli
    ai_cli=$(resolve_ai_cli 2>/dev/null) || return 1

    # Extract last 200 lines of log for context (avoid sending huge logs)
    local log_tail
    log_tail=$(extract_log_tail "$log_file" 200)

    # Get task description for context
    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_desc
    task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

    local eval_prompt
    eval_prompt="You are evaluating the outcome of an automated task worker. Respond with EXACTLY one line in the format: VERDICT:<type>:<detail>

Types:
- complete:<what_succeeded> (task finished successfully)
- retry:<reason> (transient failure, worth retrying)
- blocked:<reason> (needs human intervention)

Task: $task_id
Description: ${task_desc:-unknown}

Last 200 lines of worker log:
---
$log_tail
---

Analyze the log and determine the outcome. Look for:
1. Did the task complete its objective? (code changes, PR created, tests passing)
2. Is there a transient error that a retry would fix? (network, rate limit, timeout)
3. Is there a permanent blocker? (auth, permissions, merge conflict, missing dependency)

Respond with ONLY the verdict line, nothing else."

    local ai_result=""
    local eval_timeout=60
    local eval_model
    eval_model=$(resolve_model "eval" "$ai_cli")

    if [[ "$ai_cli" == "opencode" ]]; then
        ai_result=$(timeout "$eval_timeout" opencode run \
            -m "$eval_model" \
            --format text \
            --title "eval-${task_id}" \
            "$eval_prompt" 2>/dev/null || echo "")
    else
        # Strip provider prefix for claude CLI (expects bare model name)
        local claude_model="${eval_model#*/}"
        ai_result=$(timeout "$eval_timeout" claude \
            -p "$eval_prompt" \
            --model "$claude_model" \
            --output-format text 2>/dev/null || echo "")
    fi

    # Parse the VERDICT line from AI response
    local verdict_line
    verdict_line=$(echo "$ai_result" | grep -o 'VERDICT:[a-z]*:[a-z_]*' | head -1 || true)

    if [[ -n "$verdict_line" ]]; then
        # Strip VERDICT: prefix and return
        local verdict="${verdict_line#VERDICT:}"
        log_info "AI eval for $task_id: $verdict"

        # Store AI evaluation in state log for audit trail
        db "$SUPERVISOR_DB" "
            INSERT INTO state_log (task_id, from_state, to_state, reason)
            VALUES ('$(sql_escape "$task_id")', 'evaluating', 'evaluating',
                    'AI eval verdict: $verdict');
        " 2>/dev/null || true

        echo "$verdict"
        return 0
    fi

    # AI didn't return a parseable verdict
    log_warn "AI eval for $task_id returned unparseable result"
    return 1
}

#######################################
# Re-prompt a worker session to continue/retry
# Uses opencode run -c (continue last session) or -s <id> (specific session)
# Returns 0 on successful dispatch, 1 on failure
#######################################
cmd_reprompt() {
    local task_id=""
    local prompt_override=""

    # First positional arg is task_id
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt) [[ $# -lt 2 ]] && { log_error "--prompt requires a value"; return 1; }; prompt_override="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh reprompt <task_id> [--prompt \"custom prompt\"]"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, session_id, worktree, log_file, retries, max_retries, error
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tid trepo tdesc tstatus tsession tworktree tlog tretries tmax_retries terror
    IFS='|' read -r tid trepo tdesc tstatus tsession tworktree tlog tretries tmax_retries terror <<< "$task_row"

    # Validate state - must be in retrying state
    if [[ "$tstatus" != "retrying" ]]; then
        log_error "Task $task_id is in '$tstatus' state, must be 'retrying' to re-prompt"
        return 1
    fi

    # Check max retries
    if [[ "$tretries" -ge "$tmax_retries" ]]; then
        log_error "Task $task_id has exceeded max retries ($tretries/$tmax_retries)"
        cmd_transition "$task_id" "failed" --error "Max retries exceeded during re-prompt"
        return 1
    fi

    local ai_cli
    ai_cli=$(resolve_ai_cli) || return 1

    # Pre-reprompt availability check (t233 — distinct exit codes from check_model_health)
    # Avoids wasting retry attempts on dead/rate-limited backends.
    # (t153-pre-diag-1: retries 1+2 failed instantly with backend endpoint errors)
    local health_model health_exit=0
    health_model=$(resolve_model "health" "$ai_cli")
    check_model_health "$ai_cli" "$health_model" || health_exit=$?
    if [[ "$health_exit" -ne 0 ]]; then
        case "$health_exit" in
            2)
                log_warn "Provider rate-limited for $task_id re-prompt ($health_model via $ai_cli) — deferring to next pulse"
                ;;
            3)
                log_error "API key invalid/credits exhausted for $task_id re-prompt ($health_model via $ai_cli)"
                ;;
            *)
                log_error "Provider unavailable for $task_id re-prompt ($health_model via $ai_cli) — deferring retry"
                ;;
        esac
        # Task is already in 'retrying' state with counter incremented.
        # Do NOT transition again (would double-increment). Return 75 (EX_TEMPFAIL)
        # so the pulse cycle can distinguish transient backend failures from real
        # reprompt failures and leave the task in retrying state for the next pulse.
        return 75
    fi

    # Set up log file for this retry attempt
    local log_dir="$SUPERVISOR_DIR/logs"
    mkdir -p "$log_dir"
    local new_log_file
    new_log_file="$log_dir/${task_id}-retry${tretries}-$(date +%Y%m%d%H%M%S).log"

    # Clean-slate retry: if the previous error suggests the worktree is stale
    # or the worker exited without producing a PR, recreate from fresh main.
    # (t178: moved before prompt construction so $needs_fresh_worktree is set
    # when the prompt message references it)
    local needs_fresh_worktree=false
    case "${terror:-}" in
        *clean_exit_no_signal*|*stale*|*diverged*|*worktree*) needs_fresh_worktree=true ;;
    esac

    if [[ "$needs_fresh_worktree" == "true" && -n "$tworktree" ]]; then
        log_info "Clean-slate retry for $task_id — recreating worktree from main"
        local new_worktree
        new_worktree=$(create_task_worktree "$task_id" "$trepo" "true") || {
            log_error "Failed to recreate worktree for $task_id"
            cmd_transition "$task_id" "failed" --error "Clean-slate worktree recreation failed"
            return 1
        }
        tworktree="$new_worktree"
        # Update worktree path in DB
        db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = '$(sql_escape "$tworktree")'
            WHERE id = '$(sql_escape "$task_id")';
        " 2>/dev/null || true
    fi

    # (t178) Worktree missing but not a clean-slate case — recreate it.
    # The worktree directory may have been removed between retries (manual
    # cleanup, disk cleanup, wt prune, etc.). Without this, the worker
    # falls back to the main repo which is wrong.
    if [[ -n "$tworktree" && ! -d "$tworktree" && "$needs_fresh_worktree" != "true" ]]; then
        log_warn "Worktree missing for $task_id ($tworktree) — recreating"
        local new_worktree
        new_worktree=$(create_task_worktree "$task_id" "$trepo") || {
            log_error "Failed to recreate missing worktree for $task_id"
            cmd_transition "$task_id" "failed" --error "Missing worktree recreation failed"
            return 1
        }
        tworktree="$new_worktree"
        db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = '$(sql_escape "$tworktree")'
            WHERE id = '$(sql_escape "$task_id")';
        " 2>/dev/null || true
        needs_fresh_worktree=true
    fi

    # Determine working directory
    local work_dir="$trepo"
    if [[ -n "$tworktree" && -d "$tworktree" ]]; then
        work_dir="$tworktree"
    fi

    # Build re-prompt message with context about the failure
    local reprompt_msg
    if [[ -n "$prompt_override" ]]; then
        reprompt_msg="$prompt_override"
    elif [[ "$needs_fresh_worktree" == "true" ]]; then
        # (t229) Check if there's an existing PR on this branch — tell the worker to reuse it
        local existing_pr_url=""
        existing_pr_url=$(gh pr list --head "feature/${task_id}" --state open --json url --jq '.[0].url' 2>/dev/null || echo "")
        local pr_reuse_note=""
        if [[ -n "$existing_pr_url" && "$existing_pr_url" != "null" ]]; then
            pr_reuse_note="
IMPORTANT: An existing PR is open on this branch: $existing_pr_url
Push your commits to this branch and the PR will update automatically. Do NOT create a new PR — use the existing one. When done, run: gh pr ready"
        fi
        reprompt_msg="/full-loop $task_id -- ${tdesc:-$task_id}

NOTE: This is a clean-slate retry. The branch has been reset to main. Start fresh — do not look for previous work on this branch.${pr_reuse_note}"
    else
        reprompt_msg="The previous attempt for task $task_id encountered an issue: ${terror:-unknown error}.

Please continue the /full-loop for $task_id. Pick up where the previous attempt left off.
If the task was partially completed, verify what's done and continue from there.
If it failed entirely, start fresh with /full-loop $task_id.

Task description: ${tdesc:-$task_id}"
    fi

    # Pre-create log file with reprompt metadata (t183)
    {
        echo "=== REPROMPT METADATA (t183) ==="
        echo "task_id=$task_id"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "retry=$tretries/$tmax_retries"
        echo "work_dir=$work_dir"
        echo "previous_error=${terror:-none}"
        echo "fresh_worktree=$needs_fresh_worktree"
        echo "=== END REPROMPT METADATA ==="
        echo ""
    } > "$new_log_file" 2>/dev/null || true

    # Transition to dispatched
    cmd_transition "$task_id" "dispatched" --log-file "$new_log_file"

    log_info "Re-prompting $task_id (retry $tretries/$tmax_retries)"
    log_info "Working dir: $work_dir"
    log_info "Log: $new_log_file"

    # Dispatch the re-prompt
    local -a cmd_parts=()
    if [[ "$ai_cli" == "opencode" ]]; then
        cmd_parts=(opencode run --format json --title "${task_id}-retry${tretries}" "$reprompt_msg")
    else
        cmd_parts=(claude -p "$reprompt_msg" --output-format json)
    fi

    # Ensure PID directory exists
    mkdir -p "$SUPERVISOR_DIR/pids"

    # Generate worker-specific MCP config with heavy indexers disabled (t221)
    local worker_xdg_config=""
    worker_xdg_config=$(generate_worker_mcp_config "$task_id" 2>/dev/null) || true

    # Write dispatch script with startup sentinel (t183)
    local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-reprompt.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "echo 'WORKER_STARTED task_id=${task_id} retry=${tretries} pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "cd '${work_dir}' || { echo 'WORKER_FAILED: cd to work_dir failed: ${work_dir}'; exit 1; }"
        # Redirect worker to use MCP config with heavy indexers disabled (t221)
        if [[ -n "$worker_xdg_config" ]]; then
            echo "export XDG_CONFIG_HOME='${worker_xdg_config}'"
        fi
        printf 'exec '
        printf '%q ' "${cmd_parts[@]}"
        printf '\n'
    } > "$dispatch_script"
    chmod +x "$dispatch_script"

    # Wrapper script (t183): captures dispatch errors in log file
    local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-reprompt-wrapper.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "'${dispatch_script}' >> '${new_log_file}' 2>&1"
        echo "rc=\$?"
        echo "echo \"EXIT:\${rc}\" >> '${new_log_file}'"
        echo "if [ \$rc -ne 0 ]; then"
        echo "  echo \"WORKER_DISPATCH_ERROR: reprompt script exited with code \${rc}\" >> '${new_log_file}'"
        echo "fi"
    } > "$wrapper_script"
    chmod +x "$wrapper_script"

    # Use nohup + disown to survive parent (cron) exit
    nohup bash "${wrapper_script}" &>/dev/null &
    local worker_pid=$!
    disown "$worker_pid" 2>/dev/null || true

    echo "$worker_pid" > "$SUPERVISOR_DIR/pids/${task_id}.pid"

    # Transition to running
    cmd_transition "$task_id" "running" --session "pid:$worker_pid"

    log_success "Re-prompted $task_id (PID: $worker_pid, retry $tretries/$tmax_retries)"
    echo "$worker_pid"
    return 0
}

#######################################
# Manually evaluate a task's worker outcome
# Useful for debugging or forcing evaluation of a stuck task
#######################################
cmd_evaluate() {
    local task_id="" skip_ai="false"

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-ai) skip_ai=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh evaluate <task_id> [--no-ai]"
        return 1
    fi

    ensure_db

    # Show metadata first
    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local tlog
    tlog=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';")

    if [[ -n "$tlog" && -f "$tlog" ]]; then
        echo -e "${BOLD}=== Log Metadata: $task_id ===${NC}"
        extract_log_metadata "$tlog"
        echo ""
    fi

    # Run evaluation
    echo -e "${BOLD}=== Evaluation Result ===${NC}"
    local outcome
    outcome=$(evaluate_worker "$task_id" "$skip_ai")
    local outcome_type="${outcome%%:*}"
    local outcome_detail="${outcome#*:}"

    local color="$NC"
    case "$outcome_type" in
        complete) color="$GREEN" ;;
        retry) color="$YELLOW" ;;
        blocked) color="$RED" ;;
        failed) color="$RED" ;;
    esac

    echo -e "Verdict: ${color}${outcome_type}${NC}: $outcome_detail"
    return 0
}

#######################################
# Fetch unresolved review threads for a PR via GitHub GraphQL API (t148.1)
#
# Bot reviews post as COMMENTED (not CHANGES_REQUESTED), so reviewDecision
# stays NONE even when there are actionable review threads. This function
# checks unresolved threads directly.
#
# $1: repo_slug (owner/repo)
# $2: pr_number
#
# Outputs JSON array of unresolved threads to stdout:
#   [{"id":"...", "path":"file.sh", "line":42, "body":"...", "author":"gemini-code-assist", "isBot":true, "createdAt":"..."}]
# Returns 0 on success, 1 on failure
#######################################
check_review_threads() {
    local repo_slug="$1"
    local pr_number="$2"

    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not found, cannot check review threads"
        echo "[]"
        return 1
    fi

    local owner repo
    owner="${repo_slug%%/*}"
    repo="${repo_slug##*/}"

    # GraphQL query to fetch all review threads with resolution status
    local graphql_query
    graphql_query='query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 1) {
            nodes {
              body
              author {
                login
              }
              createdAt
            }
          }
        }
      }
    }
  }
}'

    local result
    result=$(gh api graphql -f query="$graphql_query" \
        -F owner="$owner" -F repo="$repo" -F pr="$pr_number" \
        2>>"$SUPERVISOR_LOG" || echo "")

    if [[ -z "$result" ]]; then
        log_warn "GraphQL query failed for $repo_slug#$pr_number"
        echo "[]"
        return 1
    fi

    # Extract unresolved, non-outdated threads and format as JSON array
    local threads
    threads=$(echo "$result" | jq -r '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved == false and .isOutdated == false)
         | {
             id: .id,
             path: .path,
             line: .line,
             body: (.comments.nodes[0].body // ""),
             author: (.comments.nodes[0].author.login // "unknown"),
             isBot: ((.comments.nodes[0].author.login // "") | test("bot$|\\[bot\\]$|gemini|coderabbit|copilot|codacy|sonar"; "i")),
             createdAt: (.comments.nodes[0].createdAt // "")
           }
        ]' 2>/dev/null || echo "[]")

    echo "$threads"
    return 0
}

#######################################
# Triage review feedback by severity (t148.2)
#
# Classifies each unresolved review thread into severity levels:
#   critical - Security vulnerabilities, data loss, crashes
#   high     - Bugs, logic errors, missing error handling
#   medium   - Code quality, performance, maintainability
#   low      - Style, naming, documentation, nits
#   dismiss  - False positives, already addressed, bot noise
#
# $1: JSON array of threads (from check_review_threads)
#
# Outputs JSON with classified threads and summary:
#   {"threads":[...with severity field...], "summary":{"critical":0,"high":1,...}, "action":"fix|merge|block"}
# Returns 0 on success
#######################################
triage_review_feedback() {
    local threads_json="$1"

    local thread_count
    thread_count=$(echo "$threads_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$thread_count" -eq 0 ]]; then
        echo '{"threads":[],"summary":{"critical":0,"high":0,"medium":0,"low":0,"dismiss":0},"action":"merge"}'
        return 0
    fi

    # Classify each thread using keyword heuristics
    # This avoids an AI call for most cases; AI eval is reserved for ambiguous threads
    local classified
    classified=$(echo "$threads_json" | jq '
        [.[] | . + {
            severity: (
                if (.body | test("security|vulnerab|injection|XSS|CSRF|auth bypass|privilege escalat|CVE|RCE|SSRF|secret|credential|password.*leak"; "i"))
                then "critical"
                elif (.body | test("bug|crash|data loss|race condition|deadlock|null pointer|undefined|NaN|infinite loop|memory leak|use.after.free|buffer overflow|missing error|unhandled|uncaught|panic|fatal"; "i"))
                then "high"
                elif (.body | test("performance|complexity|O\\(n|inefficient|redundant|duplicate|unused|dead code|refactor|simplif|error handling|validation|sanitiz|timeout|retry|fallback|edge case"; "i"))
                then "medium"
                elif (.body | test("nit|style|naming|typo|comment|documentation|whitespace|formatting|indentation|spelling|grammar|convention|prefer|consider|suggest|minor|optional|cosmetic"; "i"))
                then "low"
                elif (.isBot == true and (.body | test("looks good|no issues|approved|LGTM"; "i")))
                then "dismiss"
                else "medium"
                end
            )
        }]
    ' 2>/dev/null || echo "[]")

    # Count by severity
    local critical high medium low dismiss
    critical=$(echo "$classified" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
    high=$(echo "$classified" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
    medium=$(echo "$classified" | jq '[.[] | select(.severity == "medium")] | length' 2>/dev/null || echo "0")
    low=$(echo "$classified" | jq '[.[] | select(.severity == "low")] | length' 2>/dev/null || echo "0")
    dismiss=$(echo "$classified" | jq '[.[] | select(.severity == "dismiss")] | length' 2>/dev/null || echo "0")

    # Determine action based on severity distribution
    local action="merge"
    if [[ "$critical" -gt 0 ]]; then
        action="block"
    elif [[ "$high" -gt 0 ]]; then
        action="fix"
    elif [[ "$medium" -gt 2 ]]; then
        action="fix"
    fi
    # low-only or dismiss-only threads: safe to merge

    # Build result JSON
    local result
    result=$(jq -n \
        --argjson threads "$classified" \
        --argjson critical "$critical" \
        --argjson high "$high" \
        --argjson medium "$medium" \
        --argjson low "$low" \
        --argjson dismiss "$dismiss" \
        --arg action "$action" \
        '{
            threads: $threads,
            summary: {critical: $critical, high: $high, medium: $medium, low: $low, dismiss: $dismiss},
            action: $action
        }' 2>/dev/null || echo '{"threads":[],"summary":{},"action":"merge"}')

    echo "$result"
    return 0
}

#######################################
# Dispatch a worker to fix review feedback for a task (t148.5)
#
# Creates a re-prompt in the task's existing worktree with context about
# the review threads that need fixing. The worker applies fixes and
# pushes to the existing PR branch.
#
# $1: task_id
# $2: triage_result JSON (from triage_review_feedback)
# Returns 0 on success, 1 on failure
#######################################
dispatch_review_fix_worker() {
    local task_id="$1"
    local triage_json="$2"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, worktree, branch, pr_url, model
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local trepo tworktree tbranch tpr tmodel
    IFS='|' read -r trepo tworktree tbranch tpr tmodel <<< "$task_row"

    # Extract actionable threads (high + medium, skip low/dismiss)
    local fix_threads
    fix_threads=$(echo "$triage_json" | jq '[.threads[] | select(.severity == "critical" or .severity == "high" or .severity == "medium")]' 2>/dev/null || echo "[]")

    local fix_count
    fix_count=$(echo "$fix_threads" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$fix_count" -eq 0 ]]; then
        log_info "No actionable review threads to fix for $task_id"
        return 0
    fi

    # Build a concise fix prompt with thread details
    local thread_details
    thread_details=$(echo "$fix_threads" | jq -r '.[] | "- [\(.severity)] \(.path):\(.line // "?"): \(.body | split("\n")[0] | .[0:200])"' 2>/dev/null || echo "")

    local fix_prompt="Review feedback needs fixing for $task_id (PR: ${tpr:-unknown}).

$fix_count review thread(s) require attention:

$thread_details

Instructions:
1. Read each file mentioned and understand the review feedback
2. Apply fixes for critical and high severity issues (these are real bugs/security issues)
3. Apply fixes for medium severity issues where the feedback is valid
4. Dismiss low/nit feedback with a brief reply explaining why (if not already addressed)
5. After fixing, commit with message: fix: address review feedback for $task_id
6. Push to the existing branch ($tbranch) - do NOT create a new PR
7. Reply to resolved review threads on the PR with a brief note about the fix"

    # Determine working directory
    local work_dir="$trepo"
    if [[ -n "$tworktree" && -d "$tworktree" ]]; then
        work_dir="$tworktree"
    else
        # Worktree may have been cleaned up; recreate it
        local new_worktree
        new_worktree=$(create_task_worktree "$task_id" "$trepo" 2>/dev/null) || {
            log_error "Failed to create worktree for review fix: $task_id"
            return 1
        }
        work_dir="$new_worktree"
        # Update DB with new worktree path
        db "$SUPERVISOR_DB" "UPDATE tasks SET worktree = '$(sql_escape "$new_worktree")' WHERE id = '$escaped_id';"
    fi

    local ai_cli
    ai_cli=$(resolve_ai_cli) || return 1

    # Pre-dispatch availability check for review-fix workers (t233)
    # Previously missing — review-fix workers were spawned without any health check,
    # wasting compute when the provider was down or rate-limited.
    local health_model health_exit=0
    health_model=$(resolve_model "health" "$ai_cli")
    check_model_health "$ai_cli" "$health_model" || health_exit=$?
    if [[ "$health_exit" -ne 0 ]]; then
        case "$health_exit" in
            2)
                log_warn "Provider rate-limited for $task_id review-fix — deferring to next pulse"
                ;;
            3)
                log_error "API key invalid/credits exhausted for $task_id review-fix"
                ;;
            *)
                log_error "Provider unavailable for $task_id review-fix — deferring"
                ;;
        esac
        return 1
    fi

    # Set up log file
    local log_dir="$SUPERVISOR_DIR/logs"
    mkdir -p "$log_dir"
    local log_file
    log_file="$log_dir/${task_id}-review-fix-$(date +%Y%m%d%H%M%S).log"

    # Pre-create log file with review-fix metadata (t183)
    {
        echo "=== REVIEW-FIX METADATA (t183) ==="
        echo "task_id=$task_id"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "work_dir=$work_dir"
        echo "fix_threads=$fix_count"
        echo "=== END REVIEW-FIX METADATA ==="
        echo ""
    } > "$log_file" 2>/dev/null || true

    # Transition to dispatched for the fix cycle
    cmd_transition "$task_id" "dispatched" --log-file "$log_file" 2>>"$SUPERVISOR_LOG" || true

    log_info "Dispatching review fix worker for $task_id ($fix_count threads)"
    log_info "Working dir: $work_dir"

    # Build and execute dispatch command
    local -a cmd_parts=()
    if [[ "$ai_cli" == "opencode" ]]; then
        cmd_parts=(opencode run --format json)
        if [[ -n "$tmodel" ]]; then
            cmd_parts+=(-m "$tmodel")
        fi
        cmd_parts+=(--title "${task_id}-review-fix" "$fix_prompt")
    else
        cmd_parts=(claude -p "$fix_prompt" --output-format json)
    fi

    mkdir -p "$SUPERVISOR_DIR/pids"

    # Generate worker-specific MCP config with heavy indexers disabled (t221)
    local worker_xdg_config=""
    worker_xdg_config=$(generate_worker_mcp_config "$task_id" 2>/dev/null) || true

    # Write dispatch script with startup sentinel (t183)
    local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-review-fix.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "echo 'WORKER_STARTED task_id=${task_id} type=review-fix pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "cd '${work_dir}' || { echo 'WORKER_FAILED: cd to work_dir failed: ${work_dir}'; exit 1; }"
        # Redirect worker to use MCP config with heavy indexers disabled (t221)
        if [[ -n "$worker_xdg_config" ]]; then
            echo "export XDG_CONFIG_HOME='${worker_xdg_config}'"
        fi
        printf 'exec '
        printf '%q ' "${cmd_parts[@]}"
        printf '\n'
    } > "$dispatch_script"
    chmod +x "$dispatch_script"

    # Wrapper script (t183): captures dispatch errors in log file
    local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-review-fix-wrapper.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "'${dispatch_script}' >> '${log_file}' 2>&1"
        echo "rc=\$?"
        echo "echo \"EXIT:\${rc}\" >> '${log_file}'"
        echo "if [ \$rc -ne 0 ]; then"
        echo "  echo \"WORKER_DISPATCH_ERROR: review-fix script exited with code \${rc}\" >> '${log_file}'"
        echo "fi"
    } > "$wrapper_script"
    chmod +x "$wrapper_script"

    nohup bash "${wrapper_script}" &>/dev/null &
    local worker_pid=$!
    disown "$worker_pid" 2>/dev/null || true

    echo "$worker_pid" > "$SUPERVISOR_DIR/pids/${task_id}.pid"

    cmd_transition "$task_id" "running" --session "pid:$worker_pid" 2>>"$SUPERVISOR_LOG" || true

    log_success "Dispatched review fix worker for $task_id (PID: $worker_pid, $fix_count threads)"
    return 0
}

#######################################
# Dismiss bot reviews that are blocking PR merge (t226)
# Only dismisses reviews from known bot accounts (coderabbitai, gemini-code-assist)
# Returns: 0 if any reviews dismissed, 1 if none found or error
#######################################
dismiss_bot_reviews() {
    local pr_number="$1"
    local repo_slug="$2"
    
    if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
        log_warn "dismiss_bot_reviews: missing pr_number or repo_slug"
        return 1
    fi
    
    # Get all reviews for the PR
    local reviews_json
    reviews_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" 2>>"$SUPERVISOR_LOG" || echo "[]")
    
    if [[ -z "$reviews_json" || "$reviews_json" == "[]" ]]; then
        log_debug "dismiss_bot_reviews: no reviews found for PR #${pr_number}"
        return 1
    fi
    
    # Find bot reviews with CHANGES_REQUESTED state
    local bot_reviews
    bot_reviews=$(echo "$reviews_json" | jq -r '.[] | select(.state == "CHANGES_REQUESTED" and (.user.login == "coderabbitai" or .user.login == "gemini-code-assist[bot]")) | .id' 2>/dev/null || echo "")
    
    if [[ -z "$bot_reviews" ]]; then
        log_debug "dismiss_bot_reviews: no blocking bot reviews found for PR #${pr_number}"
        return 1
    fi
    
    local dismissed_count=0
    while IFS= read -r review_id; do
        if [[ -n "$review_id" ]]; then
            log_info "Dismissing bot review #${review_id} on PR #${pr_number}"
            if gh api -X PUT "repos/${repo_slug}/pulls/${pr_number}/reviews/${review_id}/dismissals" \
                -f message="Auto-dismissed: bot review does not block autonomous pipeline" \
                -f event="DISMISS" 2>>"$SUPERVISOR_LOG"; then
                ((dismissed_count++))
                log_success "Dismissed bot review #${review_id}"
            else
                log_warn "Failed to dismiss bot review #${review_id}"
            fi
        fi
    done <<< "$bot_reviews"
    
    if [[ "$dismissed_count" -gt 0 ]]; then
        log_success "Dismissed ${dismissed_count} bot review(s) on PR #${pr_number}"
        return 0
    fi
    
    return 1
}

#######################################
# Check PR CI and review status for a task
# Returns: ready_to_merge, unstable_sonarcloud, ci_pending, ci_failed, changes_requested, draft, no_pr
# t227: unstable_sonarcloud = SonarCloud GH Action passed but external quality gate failed
# t226: auto-dismiss bot reviews that block merge
#######################################
check_pr_status() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local pr_url
    pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';")

    # If no PR URL stored, discover via centralized link_pr_to_task() (t232)
    if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
        pr_url=$(link_pr_to_task "$task_id" --caller "check_pr_status") || pr_url=""
        if [[ -z "$pr_url" ]]; then
            echo "no_pr"
            return 0
        fi
    fi

    # Extract owner/repo and PR number from URL (t232)
    local parsed_pr pr_number repo_slug
    parsed_pr=$(parse_pr_url "$pr_url") || parsed_pr=""
    if [[ -z "$parsed_pr" ]]; then
        echo "no_pr"
        return 0
    fi
    repo_slug="${parsed_pr%%|*}"
    pr_number="${parsed_pr##*|}"

    if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
        echo "no_pr"
        return 0
    fi

    # Check PR state
    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json state,isDraft,reviewDecision,statusCheckRollup 2>>"$SUPERVISOR_LOG" || echo "")

    if [[ -z "$pr_json" ]]; then
        echo "no_pr"
        return 0
    fi

    local pr_state
    pr_state=$(echo "$pr_json" | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

    # Already merged
    if [[ "$pr_state" == "MERGED" ]]; then
        echo "already_merged"
        return 0
    fi

    # Closed without merge
    if [[ "$pr_state" == "CLOSED" ]]; then
        echo "closed"
        return 0
    fi

    # Draft PR
    local is_draft
    is_draft=$(echo "$pr_json" | jq -r '.isDraft // false' 2>/dev/null || echo "false")
    if [[ "$is_draft" == "true" ]]; then
        echo "draft"
        return 0
    fi

    # Check CI status
    local ci_status="pass"
    local check_rollup
    check_rollup=$(echo "$pr_json" | jq -r '.statusCheckRollup // []' 2>/dev/null || echo "[]")

    if [[ "$check_rollup" != "[]" && "$check_rollup" != "null" ]]; then
        local has_failure
        has_failure=$(echo "$check_rollup" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length' 2>/dev/null || echo "0")
        local has_pending
        has_pending=$(echo "$check_rollup" | jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length' 2>/dev/null || echo "0")

        if [[ "$has_failure" -gt 0 ]]; then
            # t227: Check for SonarCloud pattern: GH Action passes but external quality gate fails
            # This is UNSTABLE but safe to merge with --admin flag
            local sonar_action_pass
            sonar_action_pass=$(echo "$check_rollup" | jq '[.[] | select(.name == "SonarCloud Analysis" and .conclusion == "SUCCESS")] | length' 2>/dev/null || echo "0")
            local sonar_gate_fail
            sonar_gate_fail=$(echo "$check_rollup" | jq '[.[] | select(.name == "SonarCloud Code Analysis" and .conclusion == "FAILURE")] | length' 2>/dev/null || echo "0")
            
            if [[ "$sonar_action_pass" -gt 0 && "$sonar_gate_fail" -gt 0 ]]; then
                # Only the external SonarCloud quality gate failed, GH Action passed
                # Check if there are any OTHER failures besides SonarCloud Code Analysis
                local other_failures
                other_failures=$(echo "$check_rollup" | jq '[.[] | select((.conclusion == "FAILURE" or .conclusion == "ERROR") and .name != "SonarCloud Code Analysis")] | length' 2>/dev/null || echo "0")
                
                if [[ "$other_failures" -eq 0 ]]; then
                    # Only SonarCloud external gate failed, everything else passed
                    ci_status="unstable_sonarcloud"
                else
                    # Other checks also failed
                    ci_status="failed"
                fi
            else
                ci_status="failed"
            fi
        elif [[ "$has_pending" -gt 0 ]]; then
            ci_status="pending"
        fi
    fi

    if [[ "$ci_status" == "failed" ]]; then
        echo "ci_failed"
        return 0
    fi
    
    if [[ "$ci_status" == "unstable_sonarcloud" ]]; then
        echo "unstable_sonarcloud"
        return 0
    fi

    if [[ "$ci_status" == "pending" ]]; then
        echo "ci_pending"
        return 0
    fi

    # Check review status
    local review_decision
    review_decision=$(echo "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")

    if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
        # t226: Try to auto-dismiss bot reviews before declaring changes_requested
        log_info "PR #${pr_number} has CHANGES_REQUESTED — checking for bot reviews to dismiss"
        if dismiss_bot_reviews "$pr_number" "$repo_slug"; then
            # Re-fetch PR status after dismissal
            log_info "Re-checking PR #${pr_number} status after dismissing bot reviews"
            pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json state,isDraft,reviewDecision,statusCheckRollup 2>>"$SUPERVISOR_LOG" || echo "")
            review_decision=$(echo "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")
            
            # If still CHANGES_REQUESTED after dismissal, there are human reviews blocking
            if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
                log_warn "PR #${pr_number} still has CHANGES_REQUESTED after dismissing bot reviews (human reviews present)"
                echo "changes_requested"
                return 0
            else
                log_success "PR #${pr_number} unblocked after dismissing bot reviews"
                # Fall through to ready_to_merge check
            fi
        else
            # No bot reviews to dismiss, must be human reviews
            log_info "PR #${pr_number} has CHANGES_REQUESTED from human reviewers (not auto-dismissing)"
            echo "changes_requested"
            return 0
        fi
    fi

    # CI passed, no blocking reviews
    echo "ready_to_merge"
    return 0
}

#######################################
# Scan for orphaned PRs — PRs that workers created but the supervisor
# missed during evaluation (t210, t216).
#
# Scenarios this catches:
#   - Worker created PR but exited without FULL_LOOP_COMPLETE signal
#   - Worker used a non-standard branch name not in the DB branch column
#   - evaluate_worker() fallback PR detection failed (API timeout, etc.)
#   - Task stuck in failed/blocked/retrying with a valid PR on GitHub
#   - Tasks evaluated by Phase 4b DB orphan detection (no eager scan)
#
# Strategy:
#   1. Find tasks in non-terminal states that have no PR URL (or no_pr/task_only)
#   2. For each unique repo, do a single bulk gh pr list call
#   3. Match PRs to tasks by task ID in title or branch name
#   4. Link matched PRs and transition tasks to complete
#
# Throttled: runs at most every 10 minutes (uses timestamp file).
# Called from cmd_pulse() Phase 6 as a broad sweep.
# Note: Phase 1 now runs scan_orphaned_pr_for_task() eagerly after
# each worker evaluation (t216), so this broad sweep is a safety net.
#######################################
scan_orphaned_prs() {
    local batch_id="${1:-}"

    ensure_db

    # Throttle: run at most every 10 minutes to avoid excessive GH API calls
    local scan_interval=600  # seconds (10 min)
    local scan_stamp="$SUPERVISOR_DIR/orphan-pr-scan-last-run"
    local now_epoch
    now_epoch=$(date +%s)
    local last_run=0
    if [[ -f "$scan_stamp" ]]; then
        last_run=$(cat "$scan_stamp" 2>/dev/null || echo 0)
    fi
    local elapsed=$((now_epoch - last_run))
    if [[ "$elapsed" -lt "$scan_interval" ]]; then
        local remaining=$((scan_interval - elapsed))
        log_verbose "  Phase 6: Orphaned PR scan skipped (${remaining}s until next run)"
        return 0
    fi

    # Find tasks that might have orphaned PRs:
    # - Status indicates work was done but no PR linked
    # - pr_url is NULL, empty, 'no_pr', 'task_only', or 'task_obsolete'
    local where_clause="status IN ('failed', 'blocked', 'retrying', 'complete', 'running', 'evaluating')
        AND (pr_url IS NULL OR pr_url = '' OR pr_url = 'no_pr' OR pr_url = 'task_only' OR pr_url = 'task_obsolete')"
    if [[ -n "$batch_id" ]]; then
        where_clause="$where_clause AND id IN (SELECT task_id FROM batch_tasks WHERE batch_id = '$(sql_escape "$batch_id")')"
    fi

    local candidate_tasks
    candidate_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, branch FROM tasks
        WHERE $where_clause
        ORDER BY updated_at DESC;
    " 2>/dev/null || echo "")

    if [[ -z "$candidate_tasks" ]]; then
        echo "$now_epoch" > "$scan_stamp"
        log_verbose "  Phase 6: Orphaned PR scan — no candidate tasks"
        return 0
    fi

    # Group tasks by repo to minimise API calls (one gh pr list per repo)
    local linked_count=0
    local scanned_repos=0

    # Collect unique repos from candidate tasks
    local unique_repos=""
    while IFS='|' read -r tid trepo tbranch; do
        [[ -n "$trepo" ]] || continue
        # Deduplicate repos (bash 3.2 compatible — no associative arrays)
        case "|${unique_repos}|" in
            *"|${trepo}|"*) ;;  # already seen
            *) unique_repos="${unique_repos:+${unique_repos}|}${trepo}" ;;
        esac
    done <<< "$candidate_tasks"

    # For each unique repo, fetch open PRs and match against task IDs
    while IFS='|' read -r repo_path; do
        [[ -n "$repo_path" && -d "$repo_path" ]] || continue

        local repo_slug
        repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
        if [[ -z "$repo_slug" ]]; then
            log_verbose "  Phase 6: Cannot determine repo slug for $repo_path — skipping"
            continue
        fi

        # Fetch all open PRs for this repo in a single API call
        # Include title, headRefName, and url for matching
        local pr_list
        pr_list=$(gh pr list --repo "$repo_slug" --state open --limit 100 \
            --json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

        if [[ -z "$pr_list" || "$pr_list" == "[]" ]]; then
            scanned_repos=$((scanned_repos + 1))
            continue
        fi

        # Also check recently merged PRs (last 7 days) — workers may have
        # created PRs that were auto-merged or manually merged
        local merged_pr_list
        merged_pr_list=$(gh pr list --repo "$repo_slug" --state merged --limit 50 \
            --json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

        # Combine open and merged PR lists
        local all_prs
        if [[ -n "$merged_pr_list" && "$merged_pr_list" != "[]" ]]; then
            # Merge the two JSON arrays
            all_prs=$(echo "$pr_list" "$merged_pr_list" | jq -s 'add' 2>/dev/null || echo "$pr_list")
        else
            all_prs="$pr_list"
        fi

        # For each candidate task in this repo, check if any PR matches
        while IFS='|' read -r tid trepo tbranch; do
            [[ -n "$tid" && "$trepo" == "$repo_path" ]] || continue

            # Check if any PR references this task ID in title or branch
            # Uses jq to filter — word boundary matching via regex
            local matched_pr_url
            matched_pr_url=$(echo "$all_prs" | jq -r --arg tid "$tid" '
                .[] | select(
                    (.title | test("\\b" + $tid + "\\b"; "i")) or
                    (.headRefName | test("\\b" + $tid + "\\b"; "i"))
                ) | .url
            ' 2>/dev/null | head -1 || echo "")

            if [[ -n "$matched_pr_url" ]]; then
                # Validate, persist, and transition via centralized link_pr_to_task() (t232)
                if link_pr_to_task "$tid" --url "$matched_pr_url" --transition --notify \
                    --caller "scan_orphaned_prs" 2>>"${SUPERVISOR_LOG:-/dev/null}"; then
                    linked_count=$((linked_count + 1))
                fi
            fi
        done <<< "$candidate_tasks"

        scanned_repos=$((scanned_repos + 1))
    done <<< "$(echo "$unique_repos" | tr '|' '\n')"

    # Update throttle timestamp
    echo "$now_epoch" > "$scan_stamp"

    if [[ "$linked_count" -gt 0 ]]; then
        log_success "  Phase 6: Orphaned PR scan — linked $linked_count PRs across $scanned_repos repos"
    else
        log_verbose "  Phase 6: Orphaned PR scan — no orphaned PRs found ($scanned_repos repos scanned)"
    fi

    return 0
}

#######################################
# Eager orphaned PR scan for a single task (t216).
#
# Called immediately after worker evaluation when the outcome is
# retry/failed/blocked and no PR was linked. Unlike scan_orphaned_prs()
# which is a throttled batch sweep (Phase 6), this does a targeted
# single-task lookup — one repo, one API call — with no throttle.
#
# This catches the common case where a worker created a PR but exited
# without the FULL_LOOP_COMPLETE signal, and evaluate_worker()'s
# fallback PR detection missed it (API timeout, non-standard branch, etc.).
#
# $1: task_id
#
# Returns 0 on success. Sets pr_url in DB and transitions task to
# complete if a matching PR is found.
#######################################
scan_orphaned_pr_for_task() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Get task details
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, branch, pr_url FROM tasks
        WHERE id = '$escaped_id';
    " 2>/dev/null || echo "")

    if [[ -z "$task_row" ]]; then
        return 0
    fi

    local tstatus trepo tbranch tpr_url
    IFS='|' read -r tstatus trepo tbranch tpr_url <<< "$task_row"

    # Skip if PR already linked (not orphaned)
    if [[ -n "$tpr_url" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" && "$tpr_url" != "task_obsolete" && "$tpr_url" != "" ]]; then
        return 0
    fi

    # Need a repo to scan
    if [[ -z "$trepo" || ! -d "$trepo" ]]; then
        return 0
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
    if [[ -z "$repo_slug" ]]; then
        return 0
    fi

    # Fetch open PRs for this repo (single API call)
    local pr_list
    pr_list=$(gh pr list --repo "$repo_slug" --state open --limit 100 \
        --json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

    # Also check recently merged PRs
    local merged_pr_list
    merged_pr_list=$(gh pr list --repo "$repo_slug" --state merged --limit 50 \
        --json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

    # Combine open and merged PR lists
    local all_prs
    if [[ -n "$merged_pr_list" && "$merged_pr_list" != "[]" && -n "$pr_list" && "$pr_list" != "[]" ]]; then
        all_prs=$(echo "$pr_list" "$merged_pr_list" | jq -s 'add' 2>/dev/null || echo "$pr_list")
    elif [[ -n "$pr_list" && "$pr_list" != "[]" ]]; then
        all_prs="$pr_list"
    elif [[ -n "$merged_pr_list" && "$merged_pr_list" != "[]" ]]; then
        all_prs="$merged_pr_list"
    else
        return 0
    fi

    # Match PRs to this task by task ID in title or branch name
    local matched_pr_url
    matched_pr_url=$(echo "$all_prs" | jq -r --arg tid "$task_id" '
        .[] | select(
            (.title | test("\\b" + $tid + "\\b"; "i")) or
            (.headRefName | test("\\b" + $tid + "\\b"; "i"))
        ) | .url
    ' 2>/dev/null | head -1 || echo "")

    if [[ -z "$matched_pr_url" ]]; then
        return 0
    fi

    # Validate, persist, and optionally transition via centralized link_pr_to_task() (t232)
    link_pr_to_task "$task_id" --url "$matched_pr_url" --transition --notify \
        --caller "scan_orphaned_pr_for_task" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true

    return 0
}

#######################################
# Command: pr-check - check PR CI/review status for a task
#######################################
cmd_pr_check() {
    local task_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh pr-check <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local pr_url
    pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';")

    echo -e "${BOLD}=== PR Check: $task_id ===${NC}"
    echo "  PR URL: ${pr_url:-none}"

    local status
    status=$(check_pr_status "$task_id")
    local color="$NC"
    case "$status" in
        ready_to_merge) color="$GREEN" ;;
        ci_pending|draft) color="$YELLOW" ;;
        ci_failed|changes_requested|closed) color="$RED" ;;
        already_merged) color="$CYAN" ;;
    esac
    echo -e "  Status: ${color}${status}${NC}"

    return 0
}

#######################################
# Get sibling subtasks for a given task (t225)
# Siblings share the same parent ID (e.g., t215.1, t215.2, t215.3 are siblings)
# Returns pipe-separated rows: id|status|pr_url|branch|worktree|repo
# Args: task_id [exclude_self]
#######################################
get_sibling_tasks() {
    local task_id="$1"
    local exclude_self="${2:-true}"

    # Extract parent ID: t215.3 -> t215, t100.1.2 -> t100.1
    local parent_id=""
    if [[ "$task_id" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+$ ]]; then
        parent_id="${BASH_REMATCH[1]}"
    else
        # Not a subtask (no dot notation) — no siblings
        return 0
    fi

    ensure_db

    local escaped_parent
    escaped_parent=$(sql_escape "$parent_id")

    # Find all tasks whose ID starts with parent_id followed by a dot and a number
    # e.g., parent t215 matches t215.1, t215.2, etc. but not t2150 or t215abc
    local where_clause="t.id LIKE '${escaped_parent}.%' AND t.id GLOB '${escaped_parent}.[0-9]*'"
    if [[ "$exclude_self" == "true" ]]; then
        local escaped_id
        escaped_id=$(sql_escape "$task_id")
        where_clause="$where_clause AND t.id != '$escaped_id'"
    fi

    db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.status, t.pr_url, t.branch, t.worktree, t.repo
        FROM tasks t
        WHERE $where_clause
        ORDER BY t.id ASC;
    "
    return 0
}

#######################################
# Rebase a single PR branch onto updated main (t225)
# Used after merging a sibling's PR to prevent cascading conflicts.
# Operates on the worktree if available, otherwise uses the main repo.
# Args: task_id
# Returns: 0 on success, 1 on rebase failure, 2 on force-push failure
#######################################
rebase_sibling_pr() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT branch, worktree, repo, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_warn "rebase_sibling_pr: task $task_id not found in DB"
        return 1
    fi

    local tbranch tworktree trepo tpr
    IFS='|' read -r tbranch tworktree trepo tpr <<< "$task_row"

    if [[ -z "$tbranch" ]]; then
        log_warn "rebase_sibling_pr: no branch recorded for $task_id"
        return 1
    fi

    if [[ -z "$trepo" || ! -d "$trepo/.git" ]]; then
        log_warn "rebase_sibling_pr: repo not found for $task_id ($trepo)"
        return 1
    fi

    # Determine the git directory to operate in
    local git_dir="$trepo"
    local use_worktree=false
    if [[ -n "$tworktree" && -d "$tworktree" ]]; then
        git_dir="$tworktree"
        use_worktree=true
    fi

    log_info "rebase_sibling_pr: rebasing $task_id ($tbranch) onto main..."

    # Fetch latest main
    if ! git -C "$trepo" fetch origin main 2>>"$SUPERVISOR_LOG"; then
        log_warn "rebase_sibling_pr: failed to fetch origin main for $task_id"
        return 1
    fi

    if [[ "$use_worktree" == "true" ]]; then
        # Worktree is already on the branch — rebase in place
        if ! git -C "$git_dir" rebase origin/main 2>>"$SUPERVISOR_LOG"; then
            log_warn "rebase_sibling_pr: rebase conflict for $task_id — aborting"
            git -C "$git_dir" rebase --abort 2>>"$SUPERVISOR_LOG" || true
            return 1
        fi
    else
        # No worktree — checkout branch in main repo temporarily
        # This is less ideal but handles edge cases where worktree was cleaned up
        local current_branch
        current_branch=$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

        if ! git -C "$git_dir" checkout "$tbranch" 2>>"$SUPERVISOR_LOG"; then
            log_warn "rebase_sibling_pr: cannot checkout $tbranch for $task_id"
            return 1
        fi

        if ! git -C "$git_dir" rebase origin/main 2>>"$SUPERVISOR_LOG"; then
            log_warn "rebase_sibling_pr: rebase conflict for $task_id — aborting"
            git -C "$git_dir" rebase --abort 2>>"$SUPERVISOR_LOG" || true
            # Return to original branch
            git -C "$git_dir" checkout "${current_branch:-main}" 2>>"$SUPERVISOR_LOG" || true
            return 1
        fi

        # Return to original branch
        git -C "$git_dir" checkout "${current_branch:-main}" 2>>"$SUPERVISOR_LOG" || true
    fi

    # Force-push the rebased branch (required after rebase)
    if ! git -C "$git_dir" push --force-with-lease origin "$tbranch" 2>>"$SUPERVISOR_LOG"; then
        log_warn "rebase_sibling_pr: force-push failed for $task_id ($tbranch)"
        return 2
    fi

    log_success "rebase_sibling_pr: $task_id ($tbranch) rebased onto main and pushed"
    return 0
}

#######################################
# Rebase all sibling PRs after a merge (t225)
# Called after a subtask's PR is merged to prevent cascading conflicts
# in remaining sibling subtasks.
# Args: merged_task_id
# Returns: 0 (best-effort — individual failures are logged but don't block)
#######################################
rebase_sibling_prs_after_merge() {
    local merged_task_id="$1"

    local siblings
    siblings=$(get_sibling_tasks "$merged_task_id" "true")

    if [[ -z "$siblings" ]]; then
        return 0
    fi

    local rebase_count=0
    local fail_count=0
    local skip_count=0

    while IFS='|' read -r sid sstatus spr sbranch sworktree srepo; do
        # Only rebase siblings that have open PRs and are in states where
        # their branch is still active (not yet merged/deployed/cancelled)
        case "$sstatus" in
            complete|pr_review|review_triage|merging|running|evaluating|retrying|queued|dispatched)
                # These states have active branches that need rebasing
                ;;
            *)
                # merged, deployed, verified, blocked, failed, cancelled — skip
                log_verbose "  rebase_siblings: skipping $sid (status: $sstatus)"
                skip_count=$((skip_count + 1))
                continue
                ;;
        esac

        if [[ -z "$sbranch" ]]; then
            log_verbose "  rebase_siblings: skipping $sid (no branch)"
            skip_count=$((skip_count + 1))
            continue
        fi

        if rebase_sibling_pr "$sid"; then
            rebase_count=$((rebase_count + 1))
        else
            fail_count=$((fail_count + 1))
            log_warn "  rebase_siblings: failed to rebase $sid (non-blocking)"
        fi
    done <<< "$siblings"

    if [[ "$rebase_count" -gt 0 || "$fail_count" -gt 0 ]]; then
        log_info "rebase_siblings after $merged_task_id: rebased=$rebase_count failed=$fail_count skipped=$skip_count"
    fi

    return 0
}

#######################################
# Merge a PR for a task (squash merge)
# Returns 0 on success, 1 on failure
#######################################
merge_task_pr() {
    local task_id="$1"
    local dry_run="${2:-false}"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT pr_url, worktree, repo, branch FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tpr tworktree trepo tbranch
    IFS='|' read -r tpr tworktree trepo tbranch <<< "$task_row"

    if [[ -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ]]; then
        log_error "No PR URL for task $task_id"
        return 1
    fi

    # t232: Use centralized parse_pr_url() for URL parsing
    local parsed_merge pr_number repo_slug
    parsed_merge=$(parse_pr_url "$tpr") || parsed_merge=""
    if [[ -z "$parsed_merge" ]]; then
        log_error "Cannot parse PR URL: $tpr"
        return 1
    fi
    repo_slug="${parsed_merge%%|*}"
    pr_number="${parsed_merge##*|}"

    # Defense-in-depth: validate PR belongs to this task before merging (t223).
    # Prevents merging the wrong PR if cross-contamination occurred upstream.
    local merge_validated_url
    merge_validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$tpr") || merge_validated_url=""
    if [[ -z "$merge_validated_url" ]]; then
        log_error "merge_task_pr: PR #$pr_number does not reference $task_id — refusing to merge (cross-contamination guard)"
        return 1
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] Would merge PR #$pr_number in $repo_slug (squash)"
        return 0
    fi

    # t227: Check if this PR needs --admin flag due to SonarCloud external gate failure
    local use_admin_flag="false"
    local triage_result
    triage_result=$(db "$SUPERVISOR_DB" "SELECT triage_result FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    if [[ -n "$triage_result" && "$triage_result" != "null" ]]; then
        local sonarcloud_unstable
        sonarcloud_unstable=$(echo "$triage_result" | jq -r '.sonarcloud_unstable // false' 2>/dev/null || echo "false")
        if [[ "$sonarcloud_unstable" == "true" ]]; then
            use_admin_flag="true"
            log_info "SonarCloud external gate failed but GH Action passed - using --admin to bypass"
        fi
    fi
    
    # Also check current PR status for unstable_sonarcloud
    if [[ "$use_admin_flag" == "false" ]]; then
        local current_pr_status
        current_pr_status=$(check_pr_status "$task_id")
        if [[ "$current_pr_status" == "unstable_sonarcloud" ]]; then
            use_admin_flag="true"
            log_info "SonarCloud external gate failed but GH Action passed - using --admin to bypass"
        fi
    fi

    log_info "Merging PR #$pr_number in $repo_slug (squash)..."

    # Record pre-merge commit for targeted deploy (t213)
    local pre_merge_commit=""
    if [[ -n "$trepo" && -d "$trepo/.git" ]]; then
        pre_merge_commit=$(git -C "$trepo" rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "$pre_merge_commit" ]]; then
            db "$SUPERVISOR_DB" "UPDATE tasks SET error = json_set(COALESCE(error, '{}'), '$.pre_merge_commit', '$pre_merge_commit') WHERE id = '$escaped_id';" 2>/dev/null || true
        fi
    fi

    # Squash merge without --delete-branch (worktree handles branch cleanup)
    # t227: Add --admin flag if SonarCloud external gate failed
    local merge_output
    local merge_cmd="gh pr merge \"$pr_number\" --repo \"$repo_slug\" --squash"
    if [[ "$use_admin_flag" == "true" ]]; then
        merge_cmd="$merge_cmd --admin"
    fi
    
    if ! merge_output=$(eval "$merge_cmd" 2>&1); then
        log_error "Failed to merge PR #$pr_number. Output from gh:"
        log_error "$merge_output"
        return 1
    fi
    log_success "PR #$pr_number merged successfully"
    return 0
}

#######################################
# Command: pr-merge - merge a task's PR
#######################################
cmd_pr_merge() {
    local task_id="" dry_run="false"

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh pr-merge <task_id> [--dry-run]"
        return 1
    fi

    # Check PR is ready
    local pr_status
    pr_status=$(check_pr_status "$task_id")

    if [[ "$pr_status" != "ready_to_merge" ]]; then
        log_error "PR for $task_id is not ready to merge (status: $pr_status)"
        return 1
    fi

    merge_task_pr "$task_id" "$dry_run"
    return $?
}

#######################################
# Run postflight checks after merge
# Lightweight: just verifies the merge landed on main
#######################################
run_postflight_for_task() {
    local task_id="$1"
    local repo="$2"

    log_info "Running postflight for $task_id..."

    # Pull latest main to verify merge landed
    if ! git -C "$repo" pull origin main --ff-only 2>>"$SUPERVISOR_LOG"; then
        git -C "$repo" pull origin main 2>>"$SUPERVISOR_LOG" || true
    fi

    # Verify the branch was merged (PR should show as merged)
    local pr_status
    pr_status=$(check_pr_status "$task_id")
    if [[ "$pr_status" == "already_merged" ]]; then
        log_success "Postflight: PR confirmed merged for $task_id"
        return 0
    fi

    log_warn "Postflight: PR status is '$pr_status' for $task_id (expected already_merged)"
    return 1
}

#######################################
# Run deploy for a task (aidevops repos only)
# Uses targeted deploy-agents-on-merge.sh when available (t213),
# falls back to full setup.sh --non-interactive
#######################################
run_deploy_for_task() {
    local task_id="$1"
    local repo="$2"

    # Check if this is an aidevops repo
    local is_aidevops=false
    if [[ "$repo" == *"/aidevops"* ]]; then
        is_aidevops=true
    elif [[ -f "$repo/.aidevops-repo" ]]; then
        is_aidevops=true
    elif [[ -f "$repo/setup.sh" ]] && grep -q "aidevops" "$repo/setup.sh" 2>/dev/null; then
        is_aidevops=true
    fi

    if [[ "$is_aidevops" == "false" ]]; then
        log_info "Not an aidevops repo, skipping deploy for $task_id"
        return 0
    fi

    local deploy_log
    deploy_log="$SUPERVISOR_DIR/logs/${task_id}-deploy-$(date +%Y%m%d%H%M%S).log"
    mkdir -p "$SUPERVISOR_DIR/logs"

    # Try targeted deploy first (faster: only syncs changed agent files)
    local deploy_script="$repo/.agents/scripts/deploy-agents-on-merge.sh"
    if [[ -x "$deploy_script" ]]; then
        # Detect what changed in the merged PR to choose deploy strategy
        local pre_merge_commit=""
        local escaped_id
        escaped_id=$(sql_escape "$task_id")
        pre_merge_commit=$(db "$SUPERVISOR_DB" "
            SELECT json_extract(error, '$.pre_merge_commit')
            FROM tasks WHERE id = '$escaped_id';
        " 2>/dev/null || echo "")

        local deploy_args=("--repo" "$repo" "--quiet")
        if [[ -n "$pre_merge_commit" && "$pre_merge_commit" != "null" ]]; then
            deploy_args+=("--diff" "$pre_merge_commit")
            log_info "Targeted deploy for $task_id (diff since $pre_merge_commit)..."
        else
            log_info "Targeted deploy for $task_id (version-based detection)..."
        fi

        local deploy_output
        if deploy_output=$("$deploy_script" "${deploy_args[@]}" 2>&1); then
            log_success "Targeted deploy complete for $task_id"
            echo "$deploy_output" > "$deploy_log" 2>/dev/null || true
            return 0
        fi

        local deploy_exit=$?
        if [[ "$deploy_exit" -eq 2 ]]; then
            # Exit 2 = nothing to deploy (no changes detected)
            log_info "No agent changes to deploy for $task_id"
            return 0
        fi

        log_warn "Targeted deploy failed for $task_id (exit $deploy_exit), falling back to setup.sh"
        echo "$deploy_output" > "$deploy_log" 2>/dev/null || true
    fi

    # Fallback: full setup.sh --non-interactive
    if [[ ! -x "$repo/setup.sh" ]]; then
        log_warn "setup.sh not found or not executable in $repo"
        return 0
    fi

    log_info "Running setup.sh for $task_id (timeout: 300s)..."

    # Portable timeout: prefer timeout/gtimeout, fall back to background+kill
    local timeout_cmd=""
    if command -v timeout &>/dev/null; then
        timeout_cmd="timeout 300"
    elif command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout 300"
    fi

    local deploy_output
    if [[ -n "$timeout_cmd" ]]; then
        if ! deploy_output=$(cd "$repo" && AIDEVOPS_NON_INTERACTIVE=true $timeout_cmd ./setup.sh --non-interactive 2>&1); then
            log_warn "Deploy (setup.sh) returned non-zero for $task_id (see $deploy_log)"
            echo "$deploy_output" > "$deploy_log" 2>/dev/null || true
            return 1
        fi
    else
        # Fallback: background process with manual timeout
        (cd "$repo" && AIDEVOPS_NON_INTERACTIVE=true ./setup.sh --non-interactive > "$deploy_log" 2>&1) &
        local deploy_pid=$!
        local waited=0
        while kill -0 "$deploy_pid" 2>/dev/null && [[ "$waited" -lt 300 ]]; do
            sleep 5
            waited=$((waited + 5))
        done
        if kill -0 "$deploy_pid" 2>/dev/null; then
            kill "$deploy_pid" 2>/dev/null || true
            log_warn "Deploy (setup.sh) timed out after 300s for $task_id (see $deploy_log)"
            return 1
        fi
        if ! wait "$deploy_pid"; then
            deploy_output=$(cat "$deploy_log" 2>/dev/null || echo "")
            log_warn "Deploy (setup.sh) returned non-zero for $task_id (see $deploy_log)"
            return 1
        fi
        deploy_output=$(cat "$deploy_log" 2>/dev/null || echo "")
    fi
    log_success "Deploy complete for $task_id"
    return 0
}

#######################################
# Clean up worktree after successful merge
# Returns to main repo, pulls, removes worktree
#######################################
cleanup_after_merge() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT worktree, repo, branch FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        return 0
    fi

    local tworktree trepo tbranch
    IFS='|' read -r tworktree trepo tbranch <<< "$task_row"

    # Clean up worktree
    if [[ -n "$tworktree" && -d "$tworktree" ]]; then
        log_info "Cleaning up worktree for $task_id: $tworktree"
        cleanup_task_worktree "$tworktree" "$trepo"

        # Clear worktree field in DB
        db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = NULL WHERE id = '$escaped_id';
        "
    fi

    # Delete the remote branch (already merged)
    if [[ -n "$tbranch" ]]; then
        git -C "$trepo" push origin --delete "$tbranch" 2>>"$SUPERVISOR_LOG" || true
        git -C "$trepo" branch -d "$tbranch" 2>>"$SUPERVISOR_LOG" || true
        log_info "Cleaned up branch: $tbranch"
    fi

    # Prune worktrees
    if command -v wt &>/dev/null; then
        wt prune -C "$trepo" 2>>"$SUPERVISOR_LOG" || true
    else
        git -C "$trepo" worktree prune 2>>"$SUPERVISOR_LOG" || true
    fi

    return 0
}

#######################################
# Record PR lifecycle timing metrics to proof-log for pipeline latency analysis (t219)
# Args: task_id, stage_timings (e.g., "pr_review:5s,merging:3s,deploying:12s,total:20s")
#######################################
record_lifecycle_timing() {
    local task_id="$1"
    local stage_timings="$2"
    
    if [[ -z "$task_id" || -z "$stage_timings" ]]; then
        return 0
    fi
    
    # Write to proof-log if it exists
    local proof_log="${SUPERVISOR_DIR}/proof-log.jsonl"
    if [[ ! -f "$proof_log" ]]; then
        return 0
    fi
    
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Parse stage timings into JSON object
    local stages_json="{"
    local first=true
    IFS=',' read -ra STAGES <<< "$stage_timings"
    for stage in "${STAGES[@]}"; do
        if [[ "$stage" =~ ^([^:]+):(.+)$ ]]; then
            local stage_name="${BASH_REMATCH[1]}"
            local stage_time="${BASH_REMATCH[2]}"
            if [[ "$first" == "true" ]]; then
                first=false
            else
                stages_json="${stages_json},"
            fi
            stages_json="${stages_json}\"${stage_name}\":\"${stage_time}\""
        fi
    done
    stages_json="${stages_json}}"
    
    # Append to proof-log
    local log_entry
    log_entry=$(jq -n \
        --arg ts "$timestamp" \
        --arg tid "$task_id" \
        --arg event "pr_lifecycle_timing" \
        --argjson stages "$stages_json" \
        '{timestamp: $ts, task_id: $tid, event: $event, stages: $stages}' 2>/dev/null || echo "")
    
    if [[ -n "$log_entry" ]]; then
        echo "$log_entry" >> "$proof_log"
    fi
    
    return 0
}

#######################################
# Command: pr-lifecycle - handle full post-PR lifecycle for a task
# Checks CI, triages review threads, merges, runs postflight, deploys, cleans up worktree
# t219: Multi-stage transitions within single pulse for faster merge pipeline
#######################################
cmd_pr_lifecycle() {
    local task_id="" dry_run="false" skip_review_triage="false"

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --skip-review-triage) skip_review_triage=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Also check env var for global bypass (t148.6)
    if [[ "${SUPERVISOR_SKIP_REVIEW_TRIAGE:-false}" == "true" ]]; then
        skip_review_triage=true
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage]"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, pr_url, repo, worktree FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tstatus tpr trepo tworktree
    IFS='|' read -r tstatus tpr trepo tworktree <<< "$task_row"

    # t219: Track timing metrics for pipeline latency analysis
    local lifecycle_start_time
    lifecycle_start_time=$(date +%s)
    local stage_timings=""

    echo -e "${BOLD}=== Post-PR Lifecycle: $task_id ===${NC}"
    echo "  Status:   $tstatus"
    echo "  PR:       ${tpr:-none}"
    echo "  Repo:     $trepo"
    echo "  Worktree: ${tworktree:-none}"

    # Step 1: Transition to pr_review if still in complete
    if [[ "$tstatus" == "complete" ]]; then
        if [[ -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ]]; then
            # Discover PR via centralized link_pr_to_task() (t232, t223)
            local found_pr=""
            if [[ "$dry_run" == "false" ]]; then
                found_pr=$(link_pr_to_task "$task_id" --caller "cmd_pr_lifecycle") || found_pr=""
            fi
            if [[ -n "$found_pr" ]]; then
                log_info "Found PR for $task_id via branch lookup (validated): $found_pr"
                tpr="$found_pr"
            else
                log_warn "No PR for $task_id - skipping post-PR lifecycle"
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
                fi
                return 0
            fi
        fi
        if [[ "$dry_run" == "false" ]]; then
            cmd_transition "$task_id" "pr_review" 2>>"$SUPERVISOR_LOG" || true
        fi
        tstatus="pr_review"
    fi

    # Step 2: Check PR status
    if [[ "$tstatus" == "pr_review" ]]; then
        local stage_start
        stage_start=$(date +%s)
        
        local pr_status
        pr_status=$(check_pr_status "$task_id")
        log_info "PR status: $pr_status"

        case "$pr_status" in
            ready_to_merge|unstable_sonarcloud)
                # t227: unstable_sonarcloud = GH Action passed but external quality gate failed
                # This is safe to merge with --admin flag
                local merge_note=""
                if [[ "$pr_status" == "unstable_sonarcloud" ]]; then
                    merge_note=" (SonarCloud external gate failed but GH Action passed - using --admin)"
                    log_info "SonarCloud pattern detected: GH Action passed, external quality gate failed - will merge with --admin"
                fi
                
                # CI passed and no CHANGES_REQUESTED - but bot reviews post as
                # COMMENTED, so we need to check unresolved threads directly (t148)
                # t219: Fast-path optimization - check for zero review threads immediately
                # If CI is green and no threads exist, skip review_triage state entirely
                if [[ "$skip_review_triage" == "true" ]]; then
                    log_info "Review triage skipped (--skip-review-triage) for $task_id${merge_note}"
                    if [[ "$dry_run" == "false" ]]; then
                        cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
                    fi
                    tstatus="merging"
                else
                    # t219: Fast-path check - if zero review threads, skip triage state
                    # t232: Use centralized parse_pr_url() for URL parsing
                    local parsed_fastpath pr_number_fastpath repo_slug_fastpath
                    parsed_fastpath=$(parse_pr_url "$tpr") || parsed_fastpath=""
                    repo_slug_fastpath="${parsed_fastpath%%|*}"
                    pr_number_fastpath="${parsed_fastpath##*|}"
                    
                    if [[ -n "$pr_number_fastpath" && -n "$repo_slug_fastpath" ]]; then
                        local threads_json_fastpath
                        threads_json_fastpath=$(check_review_threads "$repo_slug_fastpath" "$pr_number_fastpath" 2>/dev/null || echo "[]")
                        local thread_count_fastpath
                        thread_count_fastpath=$(echo "$threads_json_fastpath" | jq 'length' 2>/dev/null || echo "0")
                        
                        if [[ "$thread_count_fastpath" -eq 0 ]]; then
                            log_info "Fast-path: CI green + zero review threads - skipping review_triage, going directly to merge${merge_note}"
                            if [[ "$dry_run" == "false" ]]; then
                                db "$SUPERVISOR_DB" "UPDATE tasks SET triage_result = '{\"action\":\"merge\",\"threads\":0,\"fast_path\":true,\"sonarcloud_unstable\":$(if [[ "$pr_status" == "unstable_sonarcloud" ]]; then echo "true"; else echo "false"; fi)}' WHERE id = '$escaped_id';"
                                cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
                            fi
                            tstatus="merging"
                        else
                            # Has review threads - go through normal triage
                            if [[ "$dry_run" == "false" ]]; then
                                cmd_transition "$task_id" "review_triage" 2>>"$SUPERVISOR_LOG" || true
                            fi
                            tstatus="review_triage"
                        fi
                    else
                        # Cannot parse PR URL - fall back to triage
                        if [[ "$dry_run" == "false" ]]; then
                            cmd_transition "$task_id" "review_triage" 2>>"$SUPERVISOR_LOG" || true
                        fi
                        tstatus="review_triage"
                    fi
                fi
                ;;
            already_merged)
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
                    cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
                fi
                tstatus="merged"
                ;;
            ci_pending)
                log_info "CI still pending for $task_id, will retry next pulse"
                # t219: Record timing even for early returns
                local stage_end
                stage_end=$(date +%s)
                stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s(ci_pending),"
                record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true
                return 0
                ;;
            ci_failed)
                log_warn "CI failed for $task_id"
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "blocked" --error "CI checks failed" 2>>"$SUPERVISOR_LOG" || true
                    send_task_notification "$task_id" "blocked" "CI checks failed on PR" 2>>"$SUPERVISOR_LOG" || true
                fi
                return 1
                ;;
            changes_requested)
                log_warn "Changes requested on PR for $task_id"
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "blocked" --error "PR changes requested" 2>>"$SUPERVISOR_LOG" || true
                    send_task_notification "$task_id" "blocked" "PR changes requested" 2>>"$SUPERVISOR_LOG" || true
                fi
                return 1
                ;;
            draft)
                # Auto-promote draft PRs when the worker is dead (t228)
                # Workers create draft PRs early for incremental commits. If the
                # worker ran out of context before running `gh pr ready`, the draft
                # is as complete as it's going to get — promote it automatically.
                local worker_pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
                local worker_alive=false
                if [[ -f "$worker_pid_file" ]]; then
                    local wpid
                    wpid=$(cat "$worker_pid_file")
                    if kill -0 "$wpid" 2>/dev/null; then
                        worker_alive=true
                    fi
                fi

                if [[ "$worker_alive" == "true" ]]; then
                    log_info "PR is draft but worker still running for $task_id — waiting"
                else
                    log_info "PR is draft and worker is dead for $task_id — auto-promoting to ready"
                    if [[ "$dry_run" == "false" ]]; then
                        # t232: Use centralized parse_pr_url() for URL parsing
                        local parsed_draft pr_num_draft repo_slug_draft
                        parsed_draft=$(parse_pr_url "$tpr") || parsed_draft=""
                        repo_slug_draft="${parsed_draft%%|*}"
                        pr_num_draft="${parsed_draft##*|}"
                        if [[ -n "$pr_num_draft" && -n "$repo_slug_draft" ]]; then
                            gh pr ready "$pr_num_draft" --repo "$repo_slug_draft" 2>>"$SUPERVISOR_LOG" || true
                            log_success "Auto-promoted draft PR #$pr_num_draft to ready for $task_id"
                        fi
                    fi
                fi
                # t219: Record timing even for early returns
                local stage_end
                stage_end=$(date +%s)
                stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s(draft),"
                record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true
                return 0
                ;;
            closed)
                log_warn "PR was closed without merge for $task_id"
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "blocked" --error "PR closed without merge" 2>>"$SUPERVISOR_LOG" || true
                fi
                return 1
                ;;
            no_pr)
                # Track consecutive no_pr failures to avoid infinite retry loop
                local no_pr_count
                no_pr_count=$(db "$SUPERVISOR_DB" "SELECT COALESCE(
                    (SELECT CAST(json_extract(error, '$.no_pr_retries') AS INTEGER)
                     FROM tasks WHERE id='$task_id'), 0);" 2>/dev/null || echo "0")
                no_pr_count=$((no_pr_count + 1))

                if [[ "$no_pr_count" -ge 5 ]]; then
                    log_warn "No PR found for $task_id after $no_pr_count attempts -- blocking"
                    if ! command -v gh &>/dev/null; then
                        log_warn "  ROOT CAUSE: 'gh' CLI not in PATH ($(echo "$PATH" | tr ':' '\n' | head -5 | tr '\n' ':'))"
                    fi
                    if [[ "$dry_run" == "false" ]]; then
                        cmd_transition "$task_id" "blocked" --error "PR unreachable after $no_pr_count attempts (gh in PATH: $(command -v gh 2>/dev/null || echo 'NOT FOUND'))" 2>>"$SUPERVISOR_LOG" || true
                    fi
                    return 1
                fi

                log_warn "No PR found for $task_id (attempt $no_pr_count/5)"
                # Store retry count in error field as JSON
                log_cmd "db-no-pr-retry" db "$SUPERVISOR_DB" "UPDATE tasks SET error = json_set(COALESCE(error, '{}'), '$.no_pr_retries', $no_pr_count), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$task_id';" || log_warn "Failed to persist no_pr retry count for $task_id"
                return 0
                ;;
        esac
        
        # t219: Record pr_review stage timing
        local stage_end
        stage_end=$(date +%s)
        stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s,"
    fi

    # Step 2b: Review triage - check unresolved threads and classify (t148)
    if [[ "$tstatus" == "review_triage" ]]; then
        local stage_start
        stage_start=$(date +%s)
        
        # Extract PR number and repo slug for GraphQL query (t232)
        local parsed_triage pr_number_triage repo_slug_triage
        parsed_triage=$(parse_pr_url "$tpr") || parsed_triage=""
        repo_slug_triage="${parsed_triage%%|*}"
        pr_number_triage="${parsed_triage##*|}"

        if [[ -z "$pr_number_triage" || -z "$repo_slug_triage" ]]; then
            log_warn "Cannot parse PR URL for triage: $tpr - skipping triage"
            if [[ "$dry_run" == "false" ]]; then
                cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
            fi
            tstatus="merging"
        else
            log_info "Checking unresolved review threads for $task_id (PR #$pr_number_triage)..."

            local threads_json
            threads_json=$(check_review_threads "$repo_slug_triage" "$pr_number_triage")

            local thread_count
            thread_count=$(echo "$threads_json" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$thread_count" -eq 0 ]]; then
                log_info "No unresolved review threads for $task_id - proceeding to merge"
                if [[ "$dry_run" == "false" ]]; then
                    db "$SUPERVISOR_DB" "UPDATE tasks SET triage_result = '{\"action\":\"merge\",\"threads\":0}' WHERE id = '$escaped_id';"
                    cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
                fi
                tstatus="merging"
            else
                log_info "Found $thread_count unresolved review thread(s) for $task_id - triaging..."

                local triage_result
                triage_result=$(triage_review_feedback "$threads_json")

                local triage_action
                triage_action=$(echo "$triage_result" | jq -r '.action' 2>/dev/null || echo "merge")

                local triage_summary
                triage_summary=$(echo "$triage_result" | jq -r '.summary | "critical:\(.critical) high:\(.high) medium:\(.medium) low:\(.low) dismiss:\(.dismiss)"' 2>/dev/null || echo "unknown")

                log_info "Triage result for $task_id: action=$triage_action ($triage_summary)"

                if [[ "$dry_run" == "true" ]]; then
                    log_info "[dry-run] Would take action: $triage_action"
                    return 0
                fi

                # Store triage result in DB
                local escaped_triage
                escaped_triage=$(sql_escape "$triage_result")
                db "$SUPERVISOR_DB" "UPDATE tasks SET triage_result = '$escaped_triage' WHERE id = '$escaped_id';"

                case "$triage_action" in
                    merge)
                        # Only low/dismiss threads - safe to merge
                        log_info "Review threads are low-severity/dismissible - proceeding to merge"
                        cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
                        tstatus="merging"
                        ;;
                    fix)
                        # High/medium threads need fixing - dispatch a worker
                        log_info "Dispatching review fix worker for $task_id ($triage_summary)"
                        if dispatch_review_fix_worker "$task_id" "$triage_result" 2>>"$SUPERVISOR_LOG"; then
                            # Worker dispatched - task is now running again
                            # When it completes, it will go through evaluate -> complete -> pr_review -> triage again
                            log_success "Review fix worker dispatched for $task_id"
                        else
                            log_error "Failed to dispatch review fix worker for $task_id"
                            cmd_transition "$task_id" "blocked" --error "Review fix dispatch failed ($triage_summary)" 2>>"$SUPERVISOR_LOG" || true
                            send_task_notification "$task_id" "blocked" "Review fix dispatch failed" 2>>"$SUPERVISOR_LOG" || true
                        fi
                        return 0
                        ;;
                    block)
                        # Critical threads - needs human review
                        log_warn "Critical review threads found for $task_id - blocking for human review"
                        cmd_transition "$task_id" "blocked" --error "Critical review threads: $triage_summary" 2>>"$SUPERVISOR_LOG" || true
                        send_task_notification "$task_id" "blocked" "Critical review threads require human attention: $triage_summary" 2>>"$SUPERVISOR_LOG" || true
                        return 1
                        ;;
                esac
            fi
        fi
        
        # t219: Record review_triage stage timing
        local stage_end
        stage_end=$(date +%s)
        stage_timings="${stage_timings}review_triage:$((stage_end - stage_start))s,"
    fi

    # Step 3: Merge
    if [[ "$tstatus" == "merging" ]]; then
        local stage_start
        stage_start=$(date +%s)
        
        if [[ "$dry_run" == "true" ]]; then
            log_info "[dry-run] Would merge PR for $task_id"
        else
            if merge_task_pr "$task_id" "$dry_run"; then
                cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
                tstatus="merged"

                # t225: Rebase sibling subtask PRs after merge to prevent
                # cascading conflicts. Best-effort — failures are logged
                # but don't block the merged task's lifecycle.
                rebase_sibling_prs_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
            else
                cmd_transition "$task_id" "blocked" --error "Merge failed" 2>>"$SUPERVISOR_LOG" || true
                send_task_notification "$task_id" "blocked" "PR merge failed" 2>>"$SUPERVISOR_LOG" || true
                return 1
            fi
        fi
        
        # t219: Record merging stage timing
        local stage_end
        stage_end=$(date +%s)
        stage_timings="${stage_timings}merging:$((stage_end - stage_start))s,"
    fi

    # Step 4: Postflight + Deploy
    # t219: This step already runs deploy + verify in same pulse (no change needed)
    if [[ "$tstatus" == "merged" ]]; then
        local stage_start
        stage_start=$(date +%s)
        
        if [[ "$dry_run" == "false" ]]; then
            cmd_transition "$task_id" "deploying" || log_warn "Failed to transition $task_id to deploying"

            # Pull main and run postflight (non-blocking: verification only)
            run_postflight_for_task "$task_id" "$trepo" || log_warn "Postflight issue for $task_id (non-blocking)"

            # Deploy (aidevops repos only) - failure blocks deployed transition
            if ! run_deploy_for_task "$task_id" "$trepo"; then
                log_error "Deploy failed for $task_id - transitioning to failed"
                cmd_transition "$task_id" "failed" --error "Deploy (setup.sh) failed" 2>>"$SUPERVISOR_LOG" || true
                send_task_notification "$task_id" "failed" "Deploy failed after merge" 2>>"$SUPERVISOR_LOG" || true
                return 1
            fi

            # Clean up worktree and branch (non-blocking: housekeeping)
            cleanup_after_merge "$task_id" || log_warn "Worktree cleanup issue for $task_id (non-blocking)"

            # Update TODO.md (non-blocking: housekeeping)
            update_todo_on_complete "$task_id" || log_warn "TODO.md update issue for $task_id (non-blocking)"

            # Populate VERIFY.md queue for post-merge verification (t180.2)
            populate_verify_queue "$task_id" "$tpr" "$trepo" 2>>"$SUPERVISOR_LOG" || log_warn "Verify queue population issue for $task_id (non-blocking)"

            # Final transition
            cmd_transition "$task_id" "deployed" || log_warn "Failed to transition $task_id to deployed"

            # Notify (best-effort, suppress errors)
            send_task_notification "$task_id" "deployed" "PR merged, deployed, worktree cleaned" 2>>"$SUPERVISOR_LOG" || true
            store_success_pattern "$task_id" "deployed" "" 2>>"$SUPERVISOR_LOG" || true
        else
            log_info "[dry-run] Would deploy and clean up for $task_id"
        fi
        
        # t219: Record deploying stage timing
        local stage_end
        stage_end=$(date +%s)
        stage_timings="${stage_timings}deploying:$((stage_end - stage_start))s,"
    fi

    # Step 4b: Auto-recover stuck deploying state (t222)
    # If a task is already in 'deploying' (from a prior pulse where the deploy
    # succeeded but the transition to 'deployed' failed), re-attempt the
    # transition and housekeeping steps. The deploy itself already completed
    # successfully — only the state transition was lost.
    if [[ "$tstatus" == "deploying" ]]; then
        local stage_start
        stage_start=$(date +%s)

        log_warn "Task $task_id stuck in deploying state — attempting auto-recovery (t222)"

        if [[ "$dry_run" == "false" ]]; then
            # Re-run housekeeping that may have been skipped when the prior
            # transition failed (all non-blocking, best-effort)
            cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || log_warn "Worktree cleanup issue for $task_id during recovery (non-blocking)"
            update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || log_warn "TODO.md update issue for $task_id during recovery (non-blocking)"
            populate_verify_queue "$task_id" "$tpr" "$trepo" 2>>"$SUPERVISOR_LOG" || log_warn "Verify queue population issue for $task_id during recovery (non-blocking)"

            # Attempt the transition that previously failed
            if cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG"; then
                log_success "Auto-recovered $task_id: deploying -> deployed (t222)"
                send_task_notification "$task_id" "deployed" "Auto-recovered from stuck deploying state" 2>>"$SUPERVISOR_LOG" || true
                store_success_pattern "$task_id" "deployed" "" 2>>"$SUPERVISOR_LOG" || true
                write_proof_log --task "$task_id" --event "auto_recover" --stage "deploying" \
                    --decision "deploying->deployed" --evidence "stuck_state_recovery" \
                    --maker "pr_lifecycle:t222" 2>/dev/null || true
            else
                log_error "Auto-recovery failed for $task_id — transition to deployed rejected"
                # If the transition itself is invalid, something is deeply wrong.
                # Transition to failed so the task doesn't stay stuck forever.
                cmd_transition "$task_id" "failed" --error "Auto-recovery failed: deploying->deployed transition rejected (t222)" 2>>"$SUPERVISOR_LOG" || true
                send_task_notification "$task_id" "failed" "Stuck in deploying, auto-recovery failed" 2>>"$SUPERVISOR_LOG" || true
            fi
        else
            log_info "[dry-run] Would auto-recover $task_id from deploying to deployed"
        fi

        # t222: Record recovery timing
        local stage_end
        stage_end=$(date +%s)
        stage_timings="${stage_timings}deploying_recovery:$((stage_end - stage_start))s,"
    fi

    # t219: Record total lifecycle timing and log to proof-log
    local lifecycle_end_time
    lifecycle_end_time=$(date +%s)
    local total_time
    total_time=$((lifecycle_end_time - lifecycle_start_time))
    stage_timings="${stage_timings}total:${total_time}s"
    
    log_success "Post-PR lifecycle complete for $task_id (status: $(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo 'unknown')) - timing: $stage_timings"
    
    # Record timing metrics to proof-log for pipeline latency analysis
    record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true
    
    return 0
}

#######################################
# Extract parent task ID from a subtask ID (t225)
# e.g., t215.3 -> t215, t100.1.2 -> t100.1, t50 -> "" (no parent)
#######################################
extract_parent_id() {
    local task_id="$1"
    if [[ "$task_id" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
    # No output for non-subtasks (intentional)
    return 0
}

#######################################
# Process post-PR lifecycle for all eligible tasks
# Called as Phase 3 of the pulse cycle
# Finds tasks in complete/pr_review/merging/merged states with PR URLs
#
# t225: Serial merge strategy for sibling subtasks
# When multiple subtasks share a parent (e.g., t215.1, t215.2, t215.3),
# only one sibling is allowed to merge per pulse cycle. After it merges,
# rebase_sibling_prs_after_merge() (called from cmd_pr_lifecycle) rebases
# the remaining siblings' branches onto the updated main. This prevents
# cascading merge conflicts that occur when parallel PRs all target main.
#######################################
process_post_pr_lifecycle() {
    local batch_id="${1:-}"

    ensure_db

    # Find tasks eligible for post-PR processing
    local where_clause="t.status IN ('complete', 'pr_review', 'review_triage', 'merging', 'merged', 'deploying')"
    if [[ -n "$batch_id" ]]; then
        where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
    fi

    local eligible_tasks
    eligible_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.status, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.updated_at ASC;
    ")

    if [[ -z "$eligible_tasks" ]]; then
        return 0
    fi

    local processed=0
    local merged_count=0
    local deployed_count=0
    local deferred_count=0

    # t225: Track which parent IDs have already had a sibling merge in this pulse.
    # Only one sibling per parent group is allowed to merge per cycle.
    # Use a simple string list (bash 3.2 compatible — no associative arrays).
    local merged_parents=""

    while IFS='|' read -r tid tstatus tpr; do
        # Skip tasks without PRs that are already complete
        if [[ "$tstatus" == "complete" && ( -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ) ]]; then
            # No PR - transition directly to deployed
            cmd_transition "$tid" "deployed" 2>>"$SUPERVISOR_LOG" || true
            deployed_count=$((deployed_count + 1))
            log_info "  $tid: no PR, marked deployed"
            continue
        fi

        # t225: Serial merge guard for sibling subtasks
        # If this task is a subtask and a sibling has already merged in this
        # pulse, defer it to the next cycle (after rebase completes).
        local parent_id
        parent_id=$(extract_parent_id "$tid")
        if [[ -n "$parent_id" ]]; then
            # Check if a sibling already merged in this pulse
            if [[ "$merged_parents" == *"|${parent_id}|"* ]]; then
                # A sibling already merged — defer this task to next pulse
                # so the rebase can land first and CI can re-run
                log_info "  $tid: deferred (sibling under $parent_id already merged this pulse — serial merge strategy)"
                deferred_count=$((deferred_count + 1))
                continue
            fi
        fi

        log_info "  $tid: processing post-PR lifecycle (status: $tstatus)"
        if cmd_pr_lifecycle "$tid" >> "$SUPERVISOR_DIR/post-pr.log" 2>&1; then
            local new_status
            new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
            case "$new_status" in
                merged|deploying|deployed)
                    merged_count=$((merged_count + 1))
                    # t225: Record that this parent group had a merge
                    if [[ -n "$parent_id" ]]; then
                        merged_parents="${merged_parents}|${parent_id}|"
                    fi
                    ;;
            esac
            if [[ "$new_status" == "deployed" ]]; then
                deployed_count=$((deployed_count + 1))
            fi
        fi
        processed=$((processed + 1))
    done <<< "$eligible_tasks"

    if [[ "$processed" -gt 0 || "$deferred_count" -gt 0 ]]; then
        log_info "Post-PR lifecycle: processed=$processed merged=$merged_count deployed=$deployed_count deferred=$deferred_count"
    fi

    return 0
}

#######################################
# Supervisor pulse - stateless check and dispatch cycle
# Designed to run via cron every 5 minutes
#######################################
cmd_pulse() {
    local batch_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --batch) [[ $# -lt 2 ]] && { log_error "--batch requires a value"; return 1; }; batch_id="$2"; shift 2 ;;
            --no-self-heal) export SUPERVISOR_SELF_HEAL="false"; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_db

    # Acquire pulse dispatch lock to prevent concurrent pulses from
    # independently dispatching workers and exceeding concurrency limits (t159)
    if ! acquire_pulse_lock; then
        log_warn "Another pulse is already running — skipping this invocation"
        return 0
    fi
    # Ensure lock is released on exit (normal, error, or signal)
    # shellcheck disable=SC2064
    trap "release_pulse_lock" EXIT INT TERM

    log_info "=== Supervisor Pulse $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

    # Pulse-level health check flag: once health is confirmed in this pulse,
    # skip subsequent checks to avoid 8-second probes per task
    _PULSE_HEALTH_VERIFIED=""

    # Phase 0: Auto-pickup new tasks from TODO.md (t128.5)
    # Scans for #auto-dispatch tags and Dispatch Queue section
    local all_repos
    all_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks;" 2>/dev/null || true)
    if [[ -n "$all_repos" ]]; then
        while IFS= read -r repo_path; do
            if [[ -f "$repo_path/TODO.md" ]]; then
                cmd_auto_pickup --repo "$repo_path" 2>>"$SUPERVISOR_LOG" || true
            fi
        done <<< "$all_repos"
    else
        # No tasks yet - try current directory
        if [[ -f "$(pwd)/TODO.md" ]]; then
            cmd_auto_pickup --repo "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
        fi
    fi

    # Phase 1: Check running workers for completion
    # Also check 'evaluating' tasks - AI eval may have timed out, leaving them stuck
    local running_tasks
    running_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, log_file FROM tasks
        WHERE status IN ('running', 'dispatched', 'evaluating')
        ORDER BY started_at ASC;
    ")

    local completed_count=0
    local failed_count=0
    local dispatched_count=0

    if [[ -n "$running_tasks" ]]; then
        while IFS='|' read -r tid tlog; do
            # Check if worker process is still alive
            local pid_file="$SUPERVISOR_DIR/pids/${tid}.pid"
            local is_alive=false

            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file")
                if kill -0 "$pid" 2>/dev/null; then
                    is_alive=true
                fi
            fi

            if [[ "$is_alive" == "true" ]]; then
                log_info "  $tid: still running"
                continue
            fi

            # Worker is done - evaluate outcome
            # Check current state to handle already-evaluating tasks (AI eval timeout)
            local current_task_state
            current_task_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

            if [[ "$current_task_state" == "evaluating" ]]; then
                log_info "  $tid: stuck in evaluating (AI eval likely timed out), re-evaluating without AI..."
            else
                log_info "  $tid: worker finished, evaluating..."
                # Transition to evaluating
                cmd_transition "$tid" "evaluating" 2>>"$SUPERVISOR_LOG" || true
            fi

            # Get task description for memory context (t128.6)
            local tid_desc
            tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

            # Skip AI eval for stuck tasks (it already timed out once)
            local skip_ai="false"
            if [[ "$current_task_state" == "evaluating" ]]; then
                skip_ai="true"
            fi

            local outcome
            outcome=$(evaluate_worker "$tid" "$skip_ai")
            local outcome_type="${outcome%%:*}"
            local outcome_detail="${outcome#*:}"

            # Proof-log: record evaluation outcome (t218)
            local _eval_duration
            _eval_duration=$(_proof_log_stage_duration "$tid" "evaluate")
            write_proof_log --task "$tid" --event "evaluate" --stage "evaluate" \
                --decision "$outcome" --evidence "skip_ai=$skip_ai" \
                --maker "evaluate_worker" \
                ${_eval_duration:+--duration "$_eval_duration"} 2>/dev/null || true

            # Eager orphaned PR scan (t216): if evaluation didn't find a PR,
            # immediately check GitHub before retrying/failing. This catches
            # PRs that evaluate_worker() missed (API timeout, non-standard
            # branch, etc.) without waiting for the Phase 6 throttled sweep.
            if [[ "$outcome_type" != "complete" ]]; then
                scan_orphaned_pr_for_task "$tid" 2>>"$SUPERVISOR_LOG" || true
                # Re-check: if the eager scan found a PR and transitioned
                # the task to complete, update our outcome to match
                local post_scan_status
                post_scan_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
                if [[ "$post_scan_status" == "complete" ]]; then
                    local post_scan_pr
                    post_scan_pr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
                    log_success "  $tid: COMPLETE via eager orphaned PR scan ($post_scan_pr)"
                    completed_count=$((completed_count + 1))
                    cleanup_worker_processes "$tid"
                    # Success pattern already stored by scan_orphaned_pr_for_task
                    handle_diagnostic_completion "$tid" 2>>"$SUPERVISOR_LOG" || true
                    continue
                fi
            fi

            case "$outcome_type" in
                complete)
                    # Quality gate check before accepting completion (t132.6)
                    local gate_result
                    gate_result=$(run_quality_gate "$tid" "${batch_id:-}" 2>>"$SUPERVISOR_LOG") || gate_result="pass"
                    local gate_type="${gate_result%%:*}"

                    if [[ "$gate_type" == "escalate" ]]; then
                        local escalated_model="${gate_result#escalate:}"
                        log_warn "  $tid: ESCALATING to $escalated_model (quality gate failed)"
                        # Proof-log: quality gate escalation (t218)
                        write_proof_log --task "$tid" --event "escalate" --stage "quality_gate" \
                            --decision "escalate:$escalated_model" \
                            --evidence "gate_result=$gate_result" \
                            --maker "quality_gate" 2>/dev/null || true
                        # run_quality_gate already set status=queued and updated model
                        # Clean up worker process tree before re-dispatch (t128.7)
                        cleanup_worker_processes "$tid"
                        store_failure_pattern "$tid" "escalated" "Quality gate -> $escalated_model" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                        send_task_notification "$tid" "escalated" "Re-queued with $escalated_model" 2>>"$SUPERVISOR_LOG" || true
                        continue
                    fi

                    log_success "  $tid: COMPLETE ($outcome_detail)"
                    # Proof-log: task completion (t218)
                    write_proof_log --task "$tid" --event "complete" --stage "evaluate" \
                        --decision "complete:$outcome_detail" \
                        --evidence "gate=$gate_result" \
                        --maker "pulse:phase1" \
                        --pr-url "$outcome_detail" 2>/dev/null || true
                    cmd_transition "$tid" "complete" --pr-url "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    completed_count=$((completed_count + 1))
                    # Clean up worker process tree and PID file (t128.7)
                    cleanup_worker_processes "$tid"
                    # Auto-update TODO.md and send notification (t128.4)
                    update_todo_on_complete "$tid" 2>>"$SUPERVISOR_LOG" || true
                    send_task_notification "$tid" "complete" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    # Store success pattern in memory (t128.6)
                    store_success_pattern "$tid" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                    # Self-heal: if this was a diagnostic task, re-queue the parent (t150)
                    handle_diagnostic_completion "$tid" 2>>"$SUPERVISOR_LOG" || true
                    ;;
                retry)
                    log_warn "  $tid: RETRY ($outcome_detail)"
                    # Proof-log: retry decision (t218)
                    write_proof_log --task "$tid" --event "retry" --stage "evaluate" \
                        --decision "retry:$outcome_detail" \
                        --maker "pulse:phase1" 2>/dev/null || true
                    cmd_transition "$tid" "retrying" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    # Clean up worker process tree before re-prompt (t128.7)
                    cleanup_worker_processes "$tid"
                    # Store failure pattern in memory (t128.6)
                    store_failure_pattern "$tid" "retry" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                    # Backend quota errors: defer re-prompt to next pulse (t095-diag-1).
                    # Quota resets take hours, not minutes. Immediate re-prompt wastes
                    # retry attempts. Leave in retrying state for deferred retry loop.
                    if [[ "$outcome_detail" == "backend_quota_error" || "$outcome_detail" == "backend_infrastructure_error" ]]; then
                        log_warn "  $tid: backend issue ($outcome_detail), deferring re-prompt to next pulse"
                        continue
                    fi
                    # Re-prompt in existing worktree (continues context)
                    local reprompt_rc=0
                    cmd_reprompt "$tid" 2>>"$SUPERVISOR_LOG" || reprompt_rc=$?
                    if [[ "$reprompt_rc" -eq 0 ]]; then
                        dispatched_count=$((dispatched_count + 1))
                        log_info "  $tid: re-prompted successfully"
                    elif [[ "$reprompt_rc" -eq 75 ]]; then
                        # EX_TEMPFAIL: backend unhealthy, task stays in retrying
                        # state for the next pulse to pick up (t153-pre-diag-1)
                        log_warn "  $tid: backend unhealthy, deferring re-prompt to next pulse"
                    else
                        # Re-prompt failed - check if max retries exceeded
                        local current_retries
                        current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
                        local max_retries_val
                        max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
                        if [[ "$current_retries" -ge "$max_retries_val" ]]; then
                            log_error "  $tid: max retries exceeded ($current_retries/$max_retries_val), marking blocked"
                            cmd_transition "$tid" "blocked" --error "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                            # Auto-update TODO.md and send notification (t128.4)
                            update_todo_on_blocked "$tid" "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                            send_task_notification "$tid" "blocked" "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                            # Store failure pattern in memory (t128.6)
                            store_failure_pattern "$tid" "blocked" "Max retries exceeded: $outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                            # Self-heal: attempt diagnostic subtask (t150)
                            attempt_self_heal "$tid" "blocked" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                        else
                            log_error "  $tid: re-prompt failed, marking failed"
                            cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                            failed_count=$((failed_count + 1))
                            # Auto-update TODO.md and send notification (t128.4)
                            update_todo_on_blocked "$tid" "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                            send_task_notification "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                            # Store failure pattern in memory (t128.6)
                            store_failure_pattern "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                            # Self-heal: attempt diagnostic subtask (t150)
                            attempt_self_heal "$tid" "failed" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                        fi
                    fi
                    ;;
                blocked)
                    log_warn "  $tid: BLOCKED ($outcome_detail)"
                    # Proof-log: blocked decision (t218)
                    write_proof_log --task "$tid" --event "blocked" --stage "evaluate" \
                        --decision "blocked:$outcome_detail" \
                        --maker "pulse:phase1" 2>/dev/null || true
                    cmd_transition "$tid" "blocked" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    # Clean up worker process tree and PID file (t128.7)
                    cleanup_worker_processes "$tid"
                    # Auto-update TODO.md and send notification (t128.4)
                    update_todo_on_blocked "$tid" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    send_task_notification "$tid" "blocked" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    # Store failure pattern in memory (t128.6)
                    store_failure_pattern "$tid" "blocked" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                    # Self-heal: attempt diagnostic subtask (t150)
                    attempt_self_heal "$tid" "blocked" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                    ;;
                failed)
                    log_error "  $tid: FAILED ($outcome_detail)"
                    # Proof-log: failed decision (t218)
                    write_proof_log --task "$tid" --event "failed" --stage "evaluate" \
                        --decision "failed:$outcome_detail" \
                        --maker "pulse:phase1" 2>/dev/null || true
                    cmd_transition "$tid" "failed" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    failed_count=$((failed_count + 1))
                    # Clean up worker process tree and PID file (t128.7)
                    cleanup_worker_processes "$tid"
                    # Auto-update TODO.md and send notification (t128.4)
                    update_todo_on_blocked "$tid" "FAILED: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    send_task_notification "$tid" "failed" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
                    # Store failure pattern in memory (t128.6)
                    store_failure_pattern "$tid" "failed" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
                    # Self-heal: attempt diagnostic subtask (t150)
                    attempt_self_heal "$tid" "failed" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                    ;;
            esac
        done <<< "$running_tasks"
    fi

    # Phase 1b: Re-prompt stale retrying tasks (t153-pre-diag-1)
    # Tasks left in 'retrying' state from a previous pulse where the backend was
    # unhealthy (health check returned EX_TEMPFAIL=75). Try re-prompting them now.
    local retrying_tasks
    retrying_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id FROM tasks
        WHERE status = 'retrying'
        AND retries < max_retries
        ORDER BY updated_at ASC;
    ")

    if [[ -n "$retrying_tasks" ]]; then
        while IFS='|' read -r tid; do
            [[ -z "$tid" ]] && continue
            log_info "  $tid: retrying (deferred from previous pulse)"
            local reprompt_rc=0
            cmd_reprompt "$tid" 2>>"$SUPERVISOR_LOG" || reprompt_rc=$?
            if [[ "$reprompt_rc" -eq 0 ]]; then
                dispatched_count=$((dispatched_count + 1))
                log_info "  $tid: re-prompted successfully"
            elif [[ "$reprompt_rc" -eq 75 ]]; then
                log_warn "  $tid: backend still unhealthy, deferring again"
            else
                log_error "  $tid: re-prompt failed (exit $reprompt_rc)"
                local current_retries
                current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
                local max_retries_val
                max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
                if [[ "$current_retries" -ge "$max_retries_val" ]]; then
                    cmd_transition "$tid" "blocked" --error "Max retries exceeded during deferred re-prompt" 2>>"$SUPERVISOR_LOG" || true
                    attempt_self_heal "$tid" "blocked" "Max retries exceeded during deferred re-prompt" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                else
                    cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed" 2>>"$SUPERVISOR_LOG" || true
                    attempt_self_heal "$tid" "failed" "Re-prompt dispatch failed" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                fi
            fi
        done <<< "$retrying_tasks"
    fi

    # Phase 2: Dispatch queued tasks up to concurrency limit

    if [[ -n "$batch_id" ]]; then
        local next_tasks
        next_tasks=$(cmd_next "$batch_id" 10)

        if [[ -n "$next_tasks" ]]; then
            while IFS=$'\t' read -r tid trepo tdesc tmodel; do
                # Guard: skip malformed task IDs (e.g., from embedded newlines
                # in diagnostic task descriptions containing EXIT:0 or markers)
                if [[ -z "$tid" || "$tid" =~ [[:space:]:] || ! "$tid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    log_warn "Skipping malformed task ID in cmd_next output: '${tid:0:40}'"
                    continue
                fi
                local dispatch_exit=0
                cmd_dispatch "$tid" --batch "$batch_id" || dispatch_exit=$?
                if [[ "$dispatch_exit" -eq 0 ]]; then
                    dispatched_count=$((dispatched_count + 1))
                elif [[ "$dispatch_exit" -eq 2 ]]; then
                    log_info "Concurrency limit reached, stopping dispatch"
                    break
                elif [[ "$dispatch_exit" -eq 3 ]]; then
                    log_warn "Provider unavailable for $tid, stopping dispatch until next pulse"
                    break
                else
                    log_warn "Dispatch failed for $tid (exit $dispatch_exit), trying next task"
                fi
            done <<< "$next_tasks"
        fi
    else
        # Global dispatch (no batch filter)
        local next_tasks
        next_tasks=$(cmd_next "" 10)

        if [[ -n "$next_tasks" ]]; then
            while IFS=$'\t' read -r tid trepo tdesc tmodel; do
                # Guard: skip malformed task IDs (same as batch dispatch above)
                if [[ -z "$tid" || "$tid" =~ [[:space:]:] || ! "$tid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    log_warn "Skipping malformed task ID in cmd_next output: '${tid:0:40}'"
                    continue
                fi
                local dispatch_exit=0
                cmd_dispatch "$tid" || dispatch_exit=$?
                if [[ "$dispatch_exit" -eq 0 ]]; then
                    dispatched_count=$((dispatched_count + 1))
                elif [[ "$dispatch_exit" -eq 2 ]]; then
                    log_info "Concurrency limit reached, stopping dispatch"
                    break
                elif [[ "$dispatch_exit" -eq 3 ]]; then
                    log_warn "Provider unavailable for $tid, stopping dispatch until next pulse"
                    break
                else
                    log_warn "Dispatch failed for $tid (exit $dispatch_exit), trying next task"
                fi
            done <<< "$next_tasks"
        fi
    fi

    # Phase 3: Post-PR lifecycle (t128.8)
    # Process tasks that workers completed (PR created) but still need merge/deploy
    process_post_pr_lifecycle "${batch_id:-}" 2>/dev/null || true

    # Phase 3b: Post-merge verification (t180.4)
    # Run check: directives from VERIFY.md for deployed tasks
    process_verify_queue "${batch_id:-}" 2>/dev/null || true

    # Phase 4: Worker health checks - detect dead, hung, and orphaned workers
    local worker_timeout_seconds="${SUPERVISOR_WORKER_TIMEOUT:-1800}"  # 30 min default

    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local health_pid
            health_pid=$(cat "$pid_file")
            local health_task
            health_task=$(basename "$pid_file" .pid)
            local health_status
            health_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")

            if ! kill -0 "$health_pid" 2>/dev/null; then
                # Dead worker: PID no longer exists
                rm -f "$pid_file"
                if [[ "$health_status" == "running" || "$health_status" == "dispatched" ]]; then
                    log_warn "  Dead worker for $health_task (PID $health_pid gone, was $health_status) — evaluating"
                    cmd_evaluate "$health_task" --no-ai 2>>"$SUPERVISOR_LOG" || {
                        # Evaluation failed — force transition so task doesn't stay stuck
                        cmd_transition "$health_task" "failed" --error "Worker process died (PID $health_pid)" 2>>"$SUPERVISOR_LOG" || true
                        failed_count=$((failed_count + 1))
                        attempt_self_heal "$health_task" "failed" "Worker process died" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                    }
                fi
            else
                # Alive worker: check for hung state (no log output for timeout period)
                if [[ "$health_status" == "running" ]]; then
                    local log_file
                    log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")
                    if [[ -n "$log_file" && -f "$log_file" ]]; then
                        local log_age_seconds=0
                        local log_mtime
                        log_mtime=$(stat -f %m "$log_file" 2>/dev/null || stat -c %Y "$log_file" 2>/dev/null || echo "0")
                        local now_epoch
                        now_epoch=$(date +%s)
                        log_age_seconds=$(( now_epoch - log_mtime ))
                        if [[ "$log_age_seconds" -gt "$worker_timeout_seconds" ]]; then
                            log_warn "  Hung worker for $health_task (no log output for ${log_age_seconds}s, timeout ${worker_timeout_seconds}s) — killing"
                            kill "$health_pid" 2>/dev/null || true
                            sleep 2
                            kill -9 "$health_pid" 2>/dev/null || true
                            rm -f "$pid_file"
                            cmd_transition "$health_task" "failed" --error "Worker hung (no output for ${log_age_seconds}s)" 2>>"$SUPERVISOR_LOG" || true
                            failed_count=$((failed_count + 1))
                            attempt_self_heal "$health_task" "failed" "Worker hung (no output for ${log_age_seconds}s)" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                        fi
                    fi
                fi
            fi
        done
    fi

    # Phase 4b: DB orphans — tasks marked running/dispatched with no PID file
    local db_orphans
    db_orphans=$(db "$SUPERVISOR_DB" "SELECT id FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo "")
    if [[ -n "$db_orphans" ]]; then
        while IFS= read -r orphan_id; do
            [[ -n "$orphan_id" ]] || continue
            local orphan_pid_file="$SUPERVISOR_DIR/pids/${orphan_id}.pid"
            if [[ ! -f "$orphan_pid_file" ]]; then
                log_warn "  DB orphan: $orphan_id marked running but no PID file — evaluating"
                cmd_evaluate "$orphan_id" --no-ai 2>>"$SUPERVISOR_LOG" || {
                    cmd_transition "$orphan_id" "failed" --error "No worker process found (DB orphan)" 2>>"$SUPERVISOR_LOG" || true
                    failed_count=$((failed_count + 1))
                    attempt_self_heal "$orphan_id" "failed" "No worker process found" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
                }
            fi
        done <<< "$db_orphans"
    fi

    # Phase 4c: Cancel stale diagnostic subtasks whose parent is already resolved
    # Diagnostic tasks (diagnostic_of != NULL) become stale when the parent task
    # reaches a terminal state (deployed, cancelled, failed) before the diagnostic
    # is dispatched. Cancel them to free queue slots.
    local stale_diags
    stale_diags=$(db "$SUPERVISOR_DB" "
        SELECT d.id, d.diagnostic_of, p.status AS parent_status
        FROM tasks d
        JOIN tasks p ON d.diagnostic_of = p.id
        WHERE d.diagnostic_of IS NOT NULL
          AND d.status IN ('queued', 'retrying')
          AND p.status IN ('deployed', 'cancelled', 'failed', 'complete', 'merged');
    " 2>/dev/null || echo "")

    if [[ -n "$stale_diags" ]]; then
        while IFS='|' read -r diag_id parent_id parent_status; do
            [[ -n "$diag_id" ]] || continue
            log_info "  Cancelling stale diagnostic $diag_id (parent $parent_id is $parent_status)"
            cmd_transition "$diag_id" "cancelled" --error "Parent task $parent_id already $parent_status" 2>>"$SUPERVISOR_LOG" || true
        done <<< "$stale_diags"
    fi

    # Phase 4d: Auto-recover stuck deploying tasks (t222)
    # Tasks can get stuck in 'deploying' if the deploy succeeds but the
    # transition to 'deployed' fails (e.g., DB write error, process killed
    # mid-transition). Detect tasks in 'deploying' state for longer than
    # the deploy timeout and auto-recover them via process_post_pr_lifecycle
    # (which now handles the deploying state in Step 4b of cmd_pr_lifecycle).
    local deploying_timeout_seconds="${SUPERVISOR_DEPLOY_TIMEOUT:-600}"  # 10 min default
    local stuck_deploying
    stuck_deploying=$(db "$SUPERVISOR_DB" "
        SELECT id, updated_at FROM tasks
        WHERE status = 'deploying'
        AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${deploying_timeout_seconds} seconds');
    " 2>/dev/null || echo "")

    if [[ -n "$stuck_deploying" ]]; then
        while IFS='|' read -r stuck_id stuck_updated; do
            [[ -n "$stuck_id" ]] || continue
            log_warn "  Stuck deploying: $stuck_id (last updated: ${stuck_updated:-unknown}, timeout: ${deploying_timeout_seconds}s) — triggering recovery (t222)"
            # process_post_pr_lifecycle will pick this up and run cmd_pr_lifecycle
            # which now handles the deploying state in Step 4b
            cmd_pr_lifecycle "$stuck_id" 2>>"$SUPERVISOR_LOG" || {
                log_error "  Recovery failed for stuck deploying task $stuck_id — forcing to deployed"
                cmd_transition "$stuck_id" "deployed" --error "Force-recovered from stuck deploying (t222)" 2>>"$SUPERVISOR_LOG" || true
            }
        done <<< "$stuck_deploying"
    fi

    # Phase 5: Summary
    local total_running
    total_running=$(cmd_running_count "${batch_id:-}")
    local total_queued
    total_queued=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'queued';")
    local total_complete
    total_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('complete', 'deployed', 'verified');")
    local total_pr_review
    total_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('pr_review', 'review_triage', 'merging', 'merged', 'deploying');")
    local total_verifying
    total_verifying=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('verifying', 'verify_failed');")

    local total_failed
    total_failed=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('failed', 'blocked');")
    local total_tasks
    total_tasks=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")

    # System resource snapshot (t135.15.3)
    local resource_output
    resource_output=$(check_system_load 2>/dev/null || echo "")
    local sys_load_1m sys_load_5m sys_cpu_cores sys_load_ratio sys_memory sys_proc_count sys_supervisor_procs sys_overloaded
    sys_load_1m=$(echo "$resource_output" | grep '^load_1m=' | cut -d= -f2)
    sys_load_5m=$(echo "$resource_output" | grep '^load_5m=' | cut -d= -f2)
    sys_cpu_cores=$(echo "$resource_output" | grep '^cpu_cores=' | cut -d= -f2)
    sys_load_ratio=$(echo "$resource_output" | grep '^load_ratio=' | cut -d= -f2)
    sys_memory=$(echo "$resource_output" | grep '^memory_pressure=' | cut -d= -f2)
    sys_proc_count=$(echo "$resource_output" | grep '^process_count=' | cut -d= -f2)
    sys_supervisor_procs=$(echo "$resource_output" | grep '^supervisor_process_count=' | cut -d= -f2)
    sys_overloaded=$(echo "$resource_output" | grep '^overloaded=' | cut -d= -f2)

    echo ""
    log_info "Pulse summary:"
    log_info "  Evaluated:  $((completed_count + failed_count)) workers"
    log_info "  Completed:  $completed_count"
    log_info "  Failed:     $failed_count"
    log_info "  Dispatched: $dispatched_count new"
    log_info "  Running:    $total_running"
    log_info "  Queued:     $total_queued"
    log_info "  Post-PR:    $total_pr_review"
    log_info "  Verifying:  $total_verifying"
    log_info "  Total done: $total_complete / $total_tasks"

    # Resource stats (t135.15.3)
    if [[ -n "$sys_load_1m" ]]; then
        local load_color="$GREEN"
        if [[ "$sys_overloaded" == "true" ]]; then
            load_color="$RED"
        elif [[ -n "$sys_load_ratio" && "$sys_load_ratio" -gt 100 ]]; then
            load_color="$YELLOW"
        fi
        local mem_color="$GREEN"
        if [[ "$sys_memory" == "high" ]]; then
            mem_color="$RED"
        elif [[ "$sys_memory" == "medium" ]]; then
            mem_color="$YELLOW"
        fi
        echo ""
        log_info "System resources:"
        echo -e "  ${BLUE}[SUPERVISOR]${NC}   CPU:      ${load_color}${sys_load_ratio}%${NC} used (${sys_cpu_cores} cores, load avg: ${sys_load_1m}/${sys_load_5m})"
        echo -e "  ${BLUE}[SUPERVISOR]${NC}   Memory:   ${mem_color}${sys_memory}${NC}"
        echo -e "  ${BLUE}[SUPERVISOR]${NC}   Procs:    ${sys_proc_count} total, ${sys_supervisor_procs} supervisor"
        # Show adaptive concurrency for the active batch
        if [[ -n "$batch_id" ]]; then
            local display_base display_max display_load_factor display_adaptive
            local escaped_display_batch
            escaped_display_batch=$(sql_escape "$batch_id")
            display_base=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "?")
            display_max=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "0")
            display_load_factor=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_load_factor, 2) FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "2")
            display_adaptive=$(calculate_adaptive_concurrency "${display_base:-4}" "${display_load_factor:-2}" "${display_max:-0}")
            local adaptive_label="base:${display_base}"
            if [[ "$display_adaptive" -gt "${display_base:-0}" ]]; then
                adaptive_label="${adaptive_label} ${GREEN}scaled:${display_adaptive}${NC}"
            elif [[ "$display_adaptive" -lt "${display_base:-0}" ]]; then
                adaptive_label="${adaptive_label} ${YELLOW}throttled:${display_adaptive}${NC}"
            else
                adaptive_label="${adaptive_label} effective:${display_adaptive}"
            fi
            local cap_display="auto"
            [[ "${display_max:-0}" -gt 0 ]] && cap_display="$display_max"
            echo -e "  ${BLUE}[SUPERVISOR]${NC}   Workers:  ${adaptive_label} (cap:${cap_display})"
        fi
        if [[ "$sys_overloaded" == "true" ]]; then
            echo -e "  ${BLUE}[SUPERVISOR]${NC}   ${RED}OVERLOADED${NC} - adaptive throttling active"
        fi
    fi

    # macOS notification on progress (when something changed this pulse)
    if [[ $((completed_count + failed_count + dispatched_count)) -gt 0 ]]; then
        local batch_label="${batch_id:-all tasks}"
        notify_batch_progress "$total_complete" "$total_tasks" "$total_failed" "$batch_label" 2>/dev/null || true
    fi

    # Phase 4: Periodic process hygiene - clean up orphaned worker processes
    # Runs every pulse to prevent accumulation between cleanup calls
    local orphan_killed=0
    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local cleanup_tid
            cleanup_tid=$(basename "$pid_file" .pid)
            local cleanup_status
            cleanup_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$cleanup_tid")';" 2>/dev/null || echo "")
            case "$cleanup_status" in
                complete|failed|cancelled|blocked|deployed|verified|verify_failed|pr_review|review_triage|merging|merged|deploying|verifying)
                    cleanup_worker_processes "$cleanup_tid" 2>/dev/null || true
                    orphan_killed=$((orphan_killed + 1))
                    ;;
            esac
        done
    fi
    if [[ "$orphan_killed" -gt 0 ]]; then
        log_info "  Cleaned:    $orphan_killed stale worker processes"
    fi

    # Phase 6: Orphaned PR scanner — broad sweep (t210, t216)
    # Detect PRs that workers created but the supervisor missed during evaluation.
    # Throttled internally (10-minute interval) to avoid excessive GH API calls.
    # Note: Phase 1 now runs an eager per-task scan immediately after evaluation
    # (scan_orphaned_pr_for_task), so this broad sweep mainly catches edge cases
    # like tasks that were already in failed/blocked state before the eager scan
    # was introduced, or tasks evaluated by Phase 4b DB orphan detection.
    scan_orphaned_prs "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true

    # Phase 7: Reconcile TODO.md for any stale tasks (t160)
    # Runs when completed tasks exist and nothing is actively running/queued
    if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 && "$total_complete" -gt 0 ]]; then
        cmd_reconcile_todo ${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
    fi

    # Phase 8: Issue-sync reconciliation (t179.3)
    # Close stale GitHub issues and fix ref:GH# drift.
    # Runs periodically (every ~50 min) when no workers active, to avoid
    # excessive GH API calls. Uses a timestamp file to throttle.
    if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 ]]; then
        local issue_sync_interval=3000  # seconds (~50 min)
        local issue_sync_stamp="$SUPERVISOR_DIR/issue-sync-last-run"
        local now_epoch
        now_epoch=$(date +%s)
        local last_run=0
        if [[ -f "$issue_sync_stamp" ]]; then
            last_run=$(cat "$issue_sync_stamp" 2>/dev/null || echo 0)
        fi
        local elapsed=$((now_epoch - last_run))
        if [[ "$elapsed" -ge "$issue_sync_interval" ]]; then
            log_info "  Phase 8: Issue-sync reconciliation (${elapsed}s since last run)"
            # Find a repo with TODO.md to run against
            local sync_repo=""
            sync_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
            if [[ -z "$sync_repo" ]]; then
                sync_repo="$(pwd)"
            fi
            local issue_sync_script="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/issue-sync-helper.sh"
            if [[ -f "$issue_sync_script" && -f "$sync_repo/TODO.md" ]]; then
                # Run reconcile to fix ref:GH# drift
                bash "$issue_sync_script" reconcile --verbose 2>>"$SUPERVISOR_LOG" || true
                # Run close to close stale issues for completed tasks
                bash "$issue_sync_script" close --verbose 2>>"$SUPERVISOR_LOG" || true
                echo "$now_epoch" > "$issue_sync_stamp"
                log_info "  Phase 8: Issue-sync complete"
            else
                log_verbose "  Phase 8: Skipped (issue-sync-helper.sh or TODO.md not found)"
            fi
        else
            local remaining=$((issue_sync_interval - elapsed))
            log_verbose "  Phase 8: Skipped (${remaining}s until next run)"
        fi
    fi

    # Phase 9: Memory audit pulse (t185)
    # Runs dedup, prune, graduate, and opportunity scan.
    # The audit script self-throttles (24h interval), so calling every pulse is safe.
    local audit_script="${SCRIPT_DIR}/memory-audit-pulse.sh"
    if [[ -x "$audit_script" ]]; then
        log_verbose "  Phase 9: Memory audit pulse"
        "$audit_script" run --quiet 2>>"$SUPERVISOR_LOG" || true
    fi

    # Phase 10: CodeRabbit daily pulse (t166.1)
    # Triggers a full codebase review via CodeRabbit CLI or GitHub API.
    # The pulse script self-throttles (24h cooldown), so calling every pulse is safe.
    local coderabbit_pulse_script="${SCRIPT_DIR}/coderabbit-pulse-helper.sh"
    if [[ -x "$coderabbit_pulse_script" ]]; then
        log_verbose "  Phase 10: CodeRabbit daily pulse"
        local pulse_repo=""
        pulse_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
        if [[ -z "$pulse_repo" ]]; then
            pulse_repo="$(pwd)"
        fi
        bash "$coderabbit_pulse_script" run --repo "$pulse_repo" --quiet 2>>"$SUPERVISOR_LOG" || true
    fi

    # Release pulse dispatch lock (t159)
    release_pulse_lock
    # Reset trap to avoid interfering with other commands in the same process
    trap - EXIT INT TERM

    return 0
}

#######################################
# Clean up worktrees for completed/failed tasks
#######################################
cmd_cleanup() {
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_db

    # Find tasks with worktrees that are in terminal states
    local terminal_tasks
    terminal_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, worktree, repo, status FROM tasks
        WHERE worktree IS NOT NULL AND worktree != ''
        AND status IN ('deployed', 'verified', 'merged', 'failed', 'cancelled');
    ")

    if [[ -z "$terminal_tasks" ]]; then
        log_info "No worktrees to clean up"
        return 0
    fi

    local cleaned=0
    while IFS='|' read -r tid tworktree trepo tstatus; do
        if [[ ! -d "$tworktree" ]]; then
            log_info "  $tid: worktree already removed ($tworktree)"
            # Clear worktree field in DB
            db "$SUPERVISOR_DB" "
                UPDATE tasks SET worktree = NULL WHERE id = '$(sql_escape "$tid")';
            "
            continue
        fi

        if [[ "$dry_run" == "true" ]]; then
            log_info "  [dry-run] Would remove: $tworktree ($tid, $tstatus)"
        else
            log_info "  Removing worktree: $tworktree ($tid)"
            cleanup_task_worktree "$tworktree" "$trepo"
            db "$SUPERVISOR_DB" "
                UPDATE tasks SET worktree = NULL WHERE id = '$(sql_escape "$tid")';
            "
            cleaned=$((cleaned + 1))
        fi
    done <<< "$terminal_tasks"

    # Clean up worker processes and stale PID files (t128.7)
    local process_cleaned=0
    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local task_id_from_pid
            task_id_from_pid=$(basename "$pid_file" .pid)
            local pid
            pid=$(cat "$pid_file")

            # Check task state - only clean up terminal-state tasks
            local task_state
            task_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id_from_pid")';" 2>/dev/null || echo "unknown")

            case "$task_state" in
                complete|failed|cancelled|blocked)
                    if [[ "$dry_run" == "true" ]]; then
                        local alive_status="dead"
                        kill -0 "$pid" 2>/dev/null && alive_status="alive"
                        log_info "  [dry-run] Would clean up $task_id_from_pid process tree (PID: $pid, $alive_status)"
                    else
                        cleanup_worker_processes "$task_id_from_pid"
                        process_cleaned=$((process_cleaned + 1))
                    fi
                    ;;
                running|dispatched)
                    # Active task - check if PID is actually dead (stale)
                    if ! kill -0 "$pid" 2>/dev/null; then
                        if [[ "$dry_run" == "true" ]]; then
                            log_info "  [dry-run] Would remove stale PID for active task $task_id_from_pid"
                        else
                            rm -f "$pid_file"
                            log_warn "  Removed stale PID file for $task_id_from_pid (task still $task_state but process dead)"
                        fi
                    fi
                    ;;
                *)
                    # Unknown task or not in DB - clean up if process is dead
                    if ! kill -0 "$pid" 2>/dev/null; then
                        if [[ "$dry_run" == "true" ]]; then
                            log_info "  [dry-run] Would remove orphaned PID: $pid_file"
                        else
                            rm -f "$pid_file"
                        fi
                    fi
                    ;;
            esac
        done
    fi

    # Prune stale registry entries (t189)
    if [[ "$dry_run" == "false" ]]; then
        prune_worktree_registry
        log_success "Cleaned up $cleaned worktrees, $process_cleaned worker processes"
    fi

    return 0
}

#######################################
# Create a GitHub issue for a task
# Delegates to issue-sync-helper.sh push tNNN for rich issue bodies (t020.6).
# Returns the issue number on success, empty on failure.
# Also adds ref:GH#N to TODO.md and commits/pushes the change.
# Requires: gh CLI authenticated, repo with GitHub remote
#######################################
create_github_issue() {
    local task_id="$1"
    local description="$2"
    local repo_path="$3"

    # t165: Callers are responsible for gating (cmd_add uses --with-issue flag).
    # This function always attempts creation when called.

    # Verify gh CLI is available and authenticated
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not found, skipping GitHub issue creation"
        return 0
    fi

    if ! check_gh_auth; then
        log_warn "gh CLI not authenticated, skipping GitHub issue creation"
        return 0
    fi

    # Detect repo slug from git remote
    local repo_slug
    local remote_url
    remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
    remote_url="${remote_url%.git}"
    repo_slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
    if [[ -z "$repo_slug" ]]; then
        log_warn "Could not detect GitHub repo slug, skipping issue creation"
        return 0
    fi

    # Check if an issue with this task ID prefix already exists
    local existing_issue
    existing_issue=$(gh issue list --repo "$repo_slug" --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>>"$SUPERVISOR_LOG" || echo "")
    if [[ -n "$existing_issue" && "$existing_issue" != "null" ]]; then
        log_info "GitHub issue #${existing_issue} already exists for $task_id"
        echo "$existing_issue"
        return 0
    fi

    # Delegate to issue-sync-helper.sh push tNNN (t020.6: single source of truth)
    # The helper handles: TODO.md parsing, rich body composition, label mapping,
    # issue creation via gh CLI, and adding ref:GH#N to TODO.md.
    local issue_sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
    if [[ ! -x "$issue_sync_helper" ]]; then
        log_warn "issue-sync-helper.sh not found at $issue_sync_helper, skipping issue creation"
        return 0
    fi

    log_info "Delegating issue creation to issue-sync-helper.sh for $task_id"
    local push_output
    # Run from repo_path so find_project_root() locates TODO.md
    push_output=$(cd "$repo_path" && "$issue_sync_helper" push "$task_id" --repo "$repo_slug" 2>>"$SUPERVISOR_LOG" || echo "")

    # Extract issue number from push output (format: "[SUCCESS] Created #NNN: title")
    local issue_number
    issue_number=$(echo "$push_output" | grep -oE 'Created #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")

    if [[ -z "$issue_number" ]]; then
        log_warn "issue-sync-helper.sh did not return an issue number for $task_id"
        return 0
    fi

    log_success "Created GitHub issue #${issue_number} for $task_id via issue-sync-helper.sh"

    # Update supervisor DB with issue URL
    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local escaped_url="https://github.com/${repo_slug}/issues/${issue_number}"
    escaped_url=$(sql_escape "$escaped_url")
    db "$SUPERVISOR_DB" "UPDATE tasks SET issue_url = '$escaped_url' WHERE id = '$escaped_id';"

    # issue-sync-helper.sh already added ref:GH#N to TODO.md — commit and push it
    commit_and_push_todo "$repo_path" "chore: add GH#${issue_number} ref to $task_id in TODO.md"

    echo "$issue_number"
    return 0
}

# update_todo_with_issue_ref() removed in t020.6 — ref:GH#N is now added by
# issue-sync-helper.sh push (called from create_github_issue) and committed
# by commit_and_push_todo within create_github_issue itself.

#######################################
# Commit and push TODO.md with pull-rebase retry
# Handles concurrent push conflicts from parallel workers
# Args: $1=repo_path $2=commit_message $3=max_retries (default 3)
#######################################
commit_and_push_todo() {
    local repo_path="$1"
    local commit_msg="$2"
    local max_retries="${3:-3}"

    if git -C "$repo_path" diff --quiet -- TODO.md 2>>"$SUPERVISOR_LOG"; then
        log_info "No changes to commit (TODO.md unchanged)"
        return 0
    fi

    git -C "$repo_path" add TODO.md

    local attempt=0
    while [[ "$attempt" -lt "$max_retries" ]]; do
        attempt=$((attempt + 1))

        # Pull-rebase to incorporate any concurrent TODO.md pushes
        if ! git -C "$repo_path" pull --rebase --autostash 2>>"$SUPERVISOR_LOG"; then
            log_warn "Pull-rebase failed (attempt $attempt/$max_retries)"
            # Abort rebase if in progress and retry
            git -C "$repo_path" rebase --abort 2>>"$SUPERVISOR_LOG" || true
            sleep "$attempt"
            continue
        fi

        # Re-stage TODO.md (rebase may have resolved it)
        if ! git -C "$repo_path" diff --quiet -- TODO.md 2>>"$SUPERVISOR_LOG"; then
            git -C "$repo_path" add TODO.md
        fi

        # Check if our change survived the rebase (may have been applied by another worker)
        if git -C "$repo_path" diff --cached --quiet -- TODO.md 2>>"$SUPERVISOR_LOG"; then
            log_info "TODO.md change already applied (likely by another worker)"
            return 0
        fi

        # Commit
        if ! git -C "$repo_path" commit -m "$commit_msg" -- TODO.md 2>>"$SUPERVISOR_LOG"; then
            log_warn "Commit failed (attempt $attempt/$max_retries)"
            sleep "$attempt"
            continue
        fi

        # Push
        if git -C "$repo_path" push 2>>"$SUPERVISOR_LOG"; then
            log_success "Committed and pushed TODO.md update"
            return 0
        fi

        log_warn "Push failed (attempt $attempt/$max_retries) - will pull-rebase and retry"
        sleep "$attempt"
    done

    log_error "Failed to push TODO.md after $max_retries attempts"
    return 1
}

#######################################
# Verify task has real deliverables before marking complete (t163.4)
# Checks: merged PR exists with substantive file changes (not just TODO.md)
# Returns 0 if verified, 1 if not
#######################################
verify_task_deliverables() {
    local task_id="$1"
    local pr_url="${2:-}"
    local repo="${3:-}"

    # Skip verification for diagnostic subtasks (they fix process, not deliverables)
    if [[ "$task_id" == *-diag-* ]]; then
        log_info "Skipping deliverable verification for diagnostic task $task_id"
        return 0
    fi

    # If no PR URL, task cannot be verified
    if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
        log_warn "Task $task_id has no PR URL ($pr_url) - cannot verify deliverables"
        return 1
    fi

    # Extract repo slug and PR number from URL (t232)
    local parsed_verify repo_slug pr_number
    parsed_verify=$(parse_pr_url "$pr_url") || parsed_verify=""
    if [[ -z "$parsed_verify" ]]; then
        log_warn "Cannot parse PR URL for $task_id: $pr_url"
        return 1
    fi
    repo_slug="${parsed_verify%%|*}"
    pr_number="${parsed_verify##*|}"

    # Pre-flight: verify gh CLI is available and authenticated
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not found; cannot verify deliverables for $task_id"
        return 1
    fi
    if ! check_gh_auth; then
        log_warn "gh CLI not authenticated; cannot verify deliverables for $task_id"
        return 1
    fi

    # Cross-contamination guard (t223): verify PR references this task ID
    # in its title or branch name before accepting it as a deliverable.
    local deliverable_validated
    deliverable_validated=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$pr_url") || deliverable_validated=""
    if [[ -z "$deliverable_validated" ]]; then
        log_warn "verify_task_deliverables: PR #$pr_number does not reference $task_id — rejecting (cross-contamination guard)"
        return 1
    fi

    # Check PR is actually merged
    local pr_state
    if ! pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state' 2>>"$SUPERVISOR_LOG"); then
        log_warn "Failed to fetch PR state for $task_id (#$pr_number)"
        return 1
    fi
    if [[ "$pr_state" != "MERGED" ]]; then
        log_warn "PR #$pr_number for $task_id is not merged (state: ${pr_state:-unknown})"
        return 1
    fi

    # Check PR has substantive file changes (not just TODO.md or planning files)
    local changed_files
    if ! changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>>"$SUPERVISOR_LOG"); then
        log_warn "Failed to fetch PR files for $task_id (#$pr_number)"
        return 1
    fi
    local substantive_files
    substantive_files=$(echo "$changed_files" | grep -vE '^(TODO\.md$|todo/|\.github/workflows/)' || true)

    if [[ -z "$substantive_files" ]]; then
        log_warn "PR #$pr_number for $task_id has no substantive file changes (only planning/workflow files)"
        return 1
    fi

    local file_count
    file_count=$(echo "$substantive_files" | wc -l | tr -d ' ')
    # Proof-log: deliverable verification passed (t218)
    write_proof_log --task "$task_id" --event "deliverable_verified" --stage "complete" \
        --decision "verified:PR#$pr_number" \
        --evidence "pr_state=$pr_state,file_count=$file_count,pr_number=$pr_number" \
        --maker "verify_task_deliverables" \
        --pr-url "$pr_url" 2>/dev/null || true
    log_info "Verified $task_id: PR #$pr_number merged with $file_count substantive file(s)"
    return 0
}

#######################################
# Populate VERIFY.md queue after PR merge (t180.2)
# Extracts changed files from the PR and generates check: directives
# based on file types (shellcheck for .sh, file-exists for new files, etc.)
# Appends a new entry to the VERIFY-QUEUE in todo/VERIFY.md
#######################################
populate_verify_queue() {
    local task_id="$1"
    local pr_url="${2:-}"
    local repo="${3:-}"

    if [[ -z "$repo" ]]; then
        log_warn "populate_verify_queue: no repo for $task_id"
        return 1
    fi

    local verify_file="$repo/todo/VERIFY.md"
    if [[ ! -f "$verify_file" ]]; then
        log_info "No VERIFY.md at $verify_file — skipping verify queue population"
        return 0
    fi

    # Extract PR number and repo slug (t232)
    local parsed_populate pr_number repo_slug
    parsed_populate=$(parse_pr_url "$pr_url") || parsed_populate=""
    if [[ -z "$parsed_populate" ]]; then
        log_warn "populate_verify_queue: cannot parse PR URL for $task_id: $pr_url"
        return 1
    fi
    repo_slug="${parsed_populate%%|*}"
    pr_number="${parsed_populate##*|}"

    # Check if this task already has a verify entry (idempotency)
    if grep -q "^- \[.\] v[0-9]* $task_id " "$verify_file" 2>/dev/null; then
        log_info "Verify entry already exists for $task_id in VERIFY.md"
        return 0
    fi

    # Get changed files from PR
    local changed_files
    if ! changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>>"$SUPERVISOR_LOG"); then
        log_warn "populate_verify_queue: failed to fetch PR files for $task_id (#$pr_number)"
        return 1
    fi

    if [[ -z "$changed_files" ]]; then
        log_info "No files changed in PR #$pr_number for $task_id"
        return 0
    fi

    # Filter to substantive files (skip TODO.md, planning files)
    local substantive_files
    substantive_files=$(echo "$changed_files" | grep -vE '^(TODO\.md$|todo/)' || true)

    if [[ -z "$substantive_files" ]]; then
        log_info "No substantive files in PR #$pr_number for $task_id — skipping verify"
        return 0
    fi

    # Get task description from DB
    local task_desc
    task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "$task_id")
    # Truncate long descriptions
    if [[ ${#task_desc} -gt 60 ]]; then
        task_desc="${task_desc:0:57}..."
    fi

    # Determine next verify ID
    local last_vnum
    last_vnum=$(grep -oE 'v[0-9]+' "$verify_file" | grep -oE '[0-9]+' | sort -n | tail -1 || echo "0")
    local next_vnum=$((last_vnum + 1))
    local verify_id
    verify_id=$(printf "v%03d" "$next_vnum")

    local today
    today=$(date +%Y-%m-%d)

    # Build the verify entry
    local entry=""
    entry+="- [ ] $verify_id $task_id $task_desc | PR #$pr_number | merged:$today"
    entry+=$'\n'
    entry+="  files: $(echo "$substantive_files" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"

    # Generate check directives based on file types
    local checks=""
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        case "$file" in
            *.sh)
                checks+=$'\n'"  check: shellcheck $file"
                checks+=$'\n'"  check: file-exists $file"
                ;;
            *.md)
                checks+=$'\n'"  check: file-exists $file"
                ;;
            *.toon)
                checks+=$'\n'"  check: file-exists $file"
                ;;
            *.yml|*.yaml)
                checks+=$'\n'"  check: file-exists $file"
                ;;
            *.json)
                checks+=$'\n'"  check: file-exists $file"
                ;;
            *)
                checks+=$'\n'"  check: file-exists $file"
                ;;
        esac
    done <<< "$substantive_files"

    # Also add subagent-index check if any .md files in .agents/ were changed
    if echo "$substantive_files" | grep -qE '\.agents/.*\.md$'; then
        local base_names
        base_names=$(echo "$substantive_files" | grep -E '\.agents/.*\.md$' | xargs -I{} basename {} .md || true)
        while IFS= read -r bname; do
            [[ -z "$bname" ]] && continue
            # Only check for subagent-index entries for tool/service/workflow files
            if echo "$substantive_files" | grep -qE "\.agents/(tools|services|workflows)/.*${bname}\.md$"; then
                checks+=$'\n'"  check: rg \"$bname\" .agents/subagent-index.toon"
            fi
        done <<< "$base_names"
    fi

    entry+="$checks"

    # Append to VERIFY.md before the end marker
    if grep -q '<!-- VERIFY-QUEUE-END -->' "$verify_file"; then
        # Insert before the end marker
        local temp_file
        temp_file=$(mktemp)
        _save_cleanup_scope; trap '_run_cleanups' RETURN
        push_cleanup "rm -f '${temp_file}'"
        awk -v entry="$entry" '
            /<!-- VERIFY-QUEUE-END -->/ {
                print entry
                print ""
            }
            { print }
        ' "$verify_file" > "$temp_file"
        mv "$temp_file" "$verify_file"
    else
        # No end marker — append to end of file
        echo "" >> "$verify_file"
        echo "$entry" >> "$verify_file"
    fi

    log_success "Added verify entry $verify_id for $task_id to VERIFY.md"
    return 0
}

#######################################
# Run verification checks for a task from VERIFY.md (t180.3)
# Parses the verify entry, executes each check: directive, and
# marks the entry as [x] (pass) or [!] (fail)
# Returns 0 if all checks pass, 1 if any fail
#######################################
run_verify_checks() {
    local task_id="$1"
    local repo="${2:-}"

    if [[ -z "$repo" ]]; then
        log_warn "run_verify_checks: no repo for $task_id"
        return 1
    fi

    local verify_file="$repo/todo/VERIFY.md"
    if [[ ! -f "$verify_file" ]]; then
        log_info "No VERIFY.md at $verify_file — nothing to verify"
        return 0
    fi

    # Find the verify entry for this task (pending entries only)
    local entry_line
    entry_line=$(grep -n "^- \[ \] v[0-9]* $task_id " "$verify_file" | head -1 || echo "")

    if [[ -z "$entry_line" ]]; then
        log_info "No pending verify entry for $task_id in VERIFY.md"
        return 0
    fi

    local line_num="${entry_line%%:*}"
    local verify_id
    verify_id=$(echo "$entry_line" | grep -oE 'v[0-9]+' | head -1 || echo "")

    log_info "Running verification checks for $task_id ($verify_id)..."

    # Extract check: directives from subsequent indented lines
    local checks=()
    local check_line=$((line_num + 1))
    local total_lines
    total_lines=$(wc -l < "$verify_file")

    while [[ "$check_line" -le "$total_lines" ]]; do
        local line
        line=$(sed -n "${check_line}p" "$verify_file")
        # Stop at next entry or blank line (entries are separated by blank lines)
        if [[ -z "$line" || "$line" =~ ^-\ \[ ]]; then
            break
        fi
        # Extract check: directives
        if [[ "$line" =~ ^[[:space:]]*check:[[:space:]]*(.*) ]]; then
            checks+=("${BASH_REMATCH[1]}")
        fi
        check_line=$((check_line + 1))
    done

    if [[ ${#checks[@]} -eq 0 ]]; then
        log_info "No check: directives found for $task_id — marking verified"
        mark_verify_entry "$verify_file" "$task_id" "pass" ""
        return 0
    fi

    local all_passed=true
    local failures=()

    for check_cmd in "${checks[@]}"; do
        local check_type="${check_cmd%% *}"
        local check_arg="${check_cmd#* }"

        log_info "  check: $check_cmd"

        case "$check_type" in
            file-exists)
                if [[ -f "$repo/$check_arg" ]]; then
                    log_success "    PASS: $check_arg exists"
                else
                    log_error "    FAIL: $check_arg not found"
                    all_passed=false
                    failures+=("file-exists: $check_arg not found")
                fi
                ;;
            shellcheck)
                if command -v shellcheck &>/dev/null; then
                    if shellcheck "$repo/$check_arg" 2>>"$SUPERVISOR_LOG"; then
                        log_success "    PASS: shellcheck $check_arg"
                    else
                        log_error "    FAIL: shellcheck $check_arg"
                        all_passed=false
                        failures+=("shellcheck: $check_arg has violations")
                    fi
                else
                    log_warn "    SKIP: shellcheck not installed"
                fi
                ;;
            rg)
                # rg "pattern" file — check pattern exists in file
                local rg_pattern rg_file
                # Parse: rg "pattern" file or rg 'pattern' file
                if [[ "$check_arg" =~ ^[\"\'](.+)[\"\'][[:space:]]+(.+)$ ]]; then
                    rg_pattern="${BASH_REMATCH[1]}"
                    rg_file="${BASH_REMATCH[2]}"
                else
                    # Fallback: first word is pattern, rest is file
                    rg_pattern="${check_arg%% *}"
                    rg_file="${check_arg#* }"
                fi
                if rg -q "$rg_pattern" "$repo/$rg_file" 2>/dev/null; then
                    log_success "    PASS: rg \"$rg_pattern\" $rg_file"
                else
                    log_error "    FAIL: pattern \"$rg_pattern\" not found in $rg_file"
                    all_passed=false
                    failures+=("rg: \"$rg_pattern\" not found in $rg_file")
                fi
                ;;
            bash)
                if (cd "$repo" && bash "$check_arg" 2>>"$SUPERVISOR_LOG"); then
                    log_success "    PASS: bash $check_arg"
                else
                    log_error "    FAIL: bash $check_arg"
                    all_passed=false
                    failures+=("bash: $check_arg failed")
                fi
                ;;
            *)
                log_warn "    SKIP: unknown check type '$check_type'"
                ;;
        esac
    done

    local today
    today=$(date +%Y-%m-%d)

    if [[ "$all_passed" == "true" ]]; then
        mark_verify_entry "$verify_file" "$task_id" "pass" "$today"
        # Proof-log: verification passed (t218)
        local _verify_duration
        _verify_duration=$(_proof_log_stage_duration "$task_id" "verifying")
        write_proof_log --task "$task_id" --event "verify_pass" --stage "verifying" \
            --decision "verified" \
            --evidence "checks=${#checks[@]},all_passed=true,verify_id=$verify_id" \
            --maker "run_verify_checks" \
            ${_verify_duration:+--duration "$_verify_duration"} 2>/dev/null || true
        log_success "All verification checks passed for $task_id ($verify_id)"
        return 0
    else
        local failure_reason
        failure_reason=$(printf '%s; ' "${failures[@]}")
        failure_reason="${failure_reason%; }"
        mark_verify_entry "$verify_file" "$task_id" "fail" "$today" "$failure_reason"
        # Proof-log: verification failed (t218)
        local _verify_duration
        _verify_duration=$(_proof_log_stage_duration "$task_id" "verifying")
        write_proof_log --task "$task_id" --event "verify_fail" --stage "verifying" \
            --decision "verify_failed" \
            --evidence "checks=${#checks[@]},failures=${#failures[@]},reason=${failure_reason:0:200}" \
            --maker "run_verify_checks" \
            ${_verify_duration:+--duration "$_verify_duration"} 2>/dev/null || true
        log_error "Verification failed for $task_id ($verify_id): $failure_reason"
        return 1
    fi
}

#######################################
# Mark a verify entry as passed [x] or failed [!] in VERIFY.md (t180.3)
#######################################
mark_verify_entry() {
    local verify_file="$1"
    local task_id="$2"
    local result="$3"
    local today="${4:-$(date +%Y-%m-%d)}"
    local reason="${5:-}"

    if [[ "$result" == "pass" ]]; then
        # Mark [x] and add verified:date
        sed -i.bak "s/^- \[ \] \(v[0-9]* $task_id .*\)/- [x] \1 verified:$today/" "$verify_file"
    else
        # Mark [!] and add failed:date reason:description
        local escaped_reason
        escaped_reason=$(echo "$reason" | sed 's/[&/\]/\\&/g' | head -c 200)
        sed -i.bak "s/^- \[ \] \(v[0-9]* $task_id .*\)/- [!] \1 failed:$today reason:$escaped_reason/" "$verify_file"
    fi
    rm -f "${verify_file}.bak"

    return 0
}

#######################################
# Process verification queue — run checks for deployed tasks (t180.3)
# Scans VERIFY.md for pending entries, runs checks, updates states
# Called from pulse Phase 6
#######################################
process_verify_queue() {
    local batch_id="${1:-}"

    ensure_db

    # Find deployed tasks that need verification
    local deployed_tasks
    local where_clause="t.status = 'deployed'"
    if [[ -n "$batch_id" ]]; then
        where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
    fi

    deployed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.repo, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.updated_at ASC;
    ")

    if [[ -z "$deployed_tasks" ]]; then
        return 0
    fi

    local verified_count=0
    local failed_count=0

    while IFS='|' read -r tid trepo tpr; do
        [[ -z "$tid" ]] && continue

        local verify_file="$trepo/todo/VERIFY.md"
        if [[ ! -f "$verify_file" ]]; then
            continue
        fi

        # Check if there's a pending verify entry for this task
        if ! grep -q "^- \[ \] v[0-9]* $tid " "$verify_file" 2>/dev/null; then
            continue
        fi

        log_info "  $tid: running verification checks"
        cmd_transition "$tid" "verifying" 2>>"$SUPERVISOR_LOG" || {
            log_warn "  $tid: failed to transition to verifying"
            continue
        }

        if run_verify_checks "$tid" "$trepo"; then
            cmd_transition "$tid" "verified" 2>>"$SUPERVISOR_LOG" || true
            verified_count=$((verified_count + 1))
            log_success "  $tid: VERIFIED"
        else
            cmd_transition "$tid" "verify_failed" 2>>"$SUPERVISOR_LOG" || true
            failed_count=$((failed_count + 1))
            log_warn "  $tid: VERIFY FAILED"
            send_task_notification "$tid" "verify_failed" "Post-merge verification failed" 2>>"$SUPERVISOR_LOG" || true
        fi
    done <<< "$deployed_tasks"

    if [[ $((verified_count + failed_count)) -gt 0 ]]; then
        log_info "Verification: $verified_count passed, $failed_count failed"
    fi

    return 0
}

#######################################
# Command: verify — manually run verification for a task (t180.3)
#######################################
cmd_verify() {
    local task_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh verify <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tstatus trepo tpr
    IFS='|' read -r tstatus trepo tpr <<< "$task_row"

    # Allow verify from deployed or verify_failed states
    if [[ "$tstatus" != "deployed" && "$tstatus" != "verify_failed" ]]; then
        log_error "Task $task_id is in state '$tstatus' — must be 'deployed' or 'verify_failed' to verify"
        return 1
    fi

    cmd_transition "$task_id" "verifying" 2>>"$SUPERVISOR_LOG" || {
        log_error "Failed to transition $task_id to verifying"
        return 1
    }

    if run_verify_checks "$task_id" "$trepo"; then
        cmd_transition "$task_id" "verified" 2>>"$SUPERVISOR_LOG" || true
        log_success "Task $task_id: VERIFIED"

        # Commit and push VERIFY.md changes
        commit_verify_changes "$trepo" "$task_id" "pass" 2>>"$SUPERVISOR_LOG" || true
        return 0
    else
        cmd_transition "$task_id" "verify_failed" 2>>"$SUPERVISOR_LOG" || true
        log_error "Task $task_id: VERIFY FAILED"

        # Commit and push VERIFY.md changes
        commit_verify_changes "$trepo" "$task_id" "fail" 2>>"$SUPERVISOR_LOG" || true
        return 1
    fi
}

#######################################
# Commit and push VERIFY.md changes after verification (t180.3)
#######################################
commit_verify_changes() {
    local repo="$1"
    local task_id="$2"
    local result="$3"

    local verify_file="$repo/todo/VERIFY.md"
    if [[ ! -f "$verify_file" ]]; then
        return 0
    fi

    # Check if there are changes to commit
    if ! git -C "$repo" diff --quiet -- "todo/VERIFY.md" 2>/dev/null; then
        local msg="chore: mark $task_id verification $result in VERIFY.md [skip ci]"
        git -C "$repo" add "todo/VERIFY.md" 2>>"$SUPERVISOR_LOG" || return 1
        git -C "$repo" commit -m "$msg" 2>>"$SUPERVISOR_LOG" || return 1
        git -C "$repo" push origin main 2>>"$SUPERVISOR_LOG" || return 1
        log_info "Committed VERIFY.md update for $task_id ($result)"
    fi

    return 0
}

#######################################
# Update TODO.md when a task completes
# Marks the task checkbox as [x], adds completed:YYYY-MM-DD
# Then commits and pushes the change
# Guard (t163): requires verified deliverables before marking [x]
#######################################
update_todo_on_complete() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, description, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local trepo tdesc tpr_url
    IFS='|' read -r trepo tdesc tpr_url <<< "$task_row"

    # Verify deliverables before marking complete (t163.4)
    if ! verify_task_deliverables "$task_id" "$tpr_url" "$trepo"; then
        log_warn "Task $task_id failed deliverable verification - NOT marking [x] in TODO.md"
        log_warn "  To manually verify: add 'verified:$(date +%Y-%m-%d)' to the task line"
        return 1
    fi

    local todo_file="$trepo/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        log_warn "TODO.md not found at $todo_file"
        return 1
    fi

    local today
    today=$(date +%Y-%m-%d)

    # Match the task line (open checkbox with task ID)
    # Handles both top-level and indented subtasks
    if ! grep -qE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file"; then
        log_warn "Task $task_id not found as open in $todo_file (may already be completed)"
        return 0
    fi

    # Mark as complete: [ ] -> [x], append completed:date
    # Use sed to match the line and transform it
    local sed_pattern="s/^([[:space:]]*- )\[ \] (${task_id} .*)$/\1[x] \2 completed:${today}/"

    sed_inplace -E "$sed_pattern" "$todo_file"

    # Verify the change was made
    if ! grep -qE "^[[:space:]]*- \[x\] ${task_id} " "$todo_file"; then
        log_error "Failed to update TODO.md for $task_id"
        return 1
    fi

    log_success "Updated TODO.md: $task_id marked complete ($today)"

    local commit_msg="chore: mark $task_id complete in TODO.md"
    if [[ -n "$tpr_url" ]]; then
        commit_msg="chore: mark $task_id complete in TODO.md (${tpr_url})"
    fi
    commit_and_push_todo "$trepo" "$commit_msg"
    return $?
}

#######################################
# Generate a VERIFY.md entry for a deployed task (t180.4)
# Auto-creates check directives based on PR files:
#   - .sh files: shellcheck + bash -n + file-exists
#   - .md files: file-exists
#   - test files: bash <test>
#   - other: file-exists
# Appends entry before <!-- VERIFY-QUEUE-END --> marker
# $1: task_id
#######################################
generate_verify_entry() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, description, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_warn "generate_verify_entry: task not found: $task_id"
        return 1
    fi

    local trepo tdesc tpr_url
    IFS='|' read -r trepo tdesc tpr_url <<< "$task_row"

    local verify_file="$trepo/todo/VERIFY.md"
    if [[ ! -f "$verify_file" ]]; then
        log_warn "generate_verify_entry: VERIFY.md not found at $verify_file"
        return 1
    fi

    # Check if entry already exists for this task
    local task_id_escaped
    task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')
    if grep -qE "^- \[.\] v[0-9]+ ${task_id_escaped} " "$verify_file"; then
        log_info "generate_verify_entry: entry already exists for $task_id"
        return 0
    fi

    # Get next vNNN number
    local last_v
    last_v=$(grep -oE '^- \[.\] v([0-9]+)' "$verify_file" | grep -oE '[0-9]+' | sort -n | tail -1 || echo "0")
    local next_v=$((last_v + 1))
    local vid
    vid=$(printf "v%03d" "$next_v")

    # Extract PR number
    local pr_number=""
    if [[ "$tpr_url" =~ /pull/([0-9]+) ]]; then
        pr_number="${BASH_REMATCH[1]}"
    fi

    local today
    today=$(date +%Y-%m-%d)

    # Get files changed in PR (requires gh CLI)
    local files_list=""
    local -a check_lines=()

    if [[ -n "$pr_number" ]] && command -v gh &>/dev/null && check_gh_auth; then
        local repo_slug=""
        repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
        if [[ -n "$repo_slug" ]]; then
            files_list=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

            # Generate check directives based on file types
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                case "$fpath" in
                    tests/*.sh|test-*.sh)
                        check_lines+=("  check: bash $fpath")
                        ;;
                    *.sh)
                        check_lines+=("  check: file-exists $fpath")
                        check_lines+=("  check: shellcheck $fpath")
                        check_lines+=("  check: bash -n $fpath")
                        ;;
                    *.md)
                        check_lines+=("  check: file-exists $fpath")
                        ;;
                    *)
                        check_lines+=("  check: file-exists $fpath")
                        ;;
                esac
            done < <(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>/dev/null)
        fi
    fi

    # Fallback: if no checks generated, add basic file-exists for PR
    if [[ ${#check_lines[@]} -eq 0 && -n "$pr_number" ]]; then
        check_lines+=("  check: rg \"$task_id\" $trepo/TODO.md")
    fi

    # Build the entry
    local entry_header="- [ ] $vid $task_id ${tdesc%% *} | PR #${pr_number:-unknown} | merged:$today"
    local entry_body=""
    if [[ -n "$files_list" ]]; then
        entry_body+="  files: $files_list"$'\n'
    fi
    for cl in "${check_lines[@]}"; do
        entry_body+="$cl"$'\n'
    done

    # Insert before <!-- VERIFY-QUEUE-END -->
    local marker="<!-- VERIFY-QUEUE-END -->"
    if ! grep -q "$marker" "$verify_file"; then
        log_warn "generate_verify_entry: VERIFY-QUEUE-END marker not found"
        return 1
    fi

    # Build full entry text
    local full_entry
    full_entry=$(printf '%s\n%s\n' "$entry_header" "$entry_body")

    # Insert before marker using temp file (portable across macOS/Linux)
    local tmp_file
    tmp_file=$(mktemp)
    _save_cleanup_scope; trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${tmp_file}'"
    awk -v entry="$full_entry" -v mark="$marker" '{
        if (index($0, mark) > 0) { print entry; }
        print;
    }' "$verify_file" > "$tmp_file" && mv "$tmp_file" "$verify_file"

    log_success "Generated verify entry $vid for $task_id (PR #${pr_number:-unknown})"

    # Commit and push
    commit_and_push_todo "$trepo" "chore: add verify entry $vid for $task_id" 2>>"$SUPERVISOR_LOG" || true

    return 0
}

#######################################
# Process pending verifications from VERIFY.md (t180.4)
# Called as Phase 3b of the pulse cycle.
# Runs verify-run-helper.sh on pending entries, then transitions
# tasks from deployed -> verified or verify_failed.
# $1: batch_id (optional, for filtering)
#######################################
process_verify_queue() {
    local batch_id="${1:-}"

    ensure_db

    # Find deployed tasks that need verification
    local where_clause="t.status = 'deployed'"
    if [[ -n "$batch_id" ]]; then
        where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
    fi

    local deployed_tasks
    deployed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.repo FROM tasks t
        WHERE $where_clause
        ORDER BY t.completed_at ASC
        LIMIT 5;
    ")

    if [[ -z "$deployed_tasks" ]]; then
        return 0
    fi

    local verify_script="${SCRIPT_DIR}/verify-run-helper.sh"
    if [[ ! -x "$verify_script" ]]; then
        log_verbose "  Phase 3b: verify-run-helper.sh not found"
        return 0
    fi

    local verified_count=0
    local failed_count=0

    while IFS='|' read -r tid trepo; do
        local verify_file="$trepo/todo/VERIFY.md"
        [[ -f "$verify_file" ]] || continue

        # Find the verify entry for this task
        local task_id_escaped
        task_id_escaped=$(printf '%s' "$tid" | sed 's/\./\\./g')
        local vid=""
        vid=$(grep -oE "^- \[ \] (v[0-9]+) ${task_id_escaped} " "$verify_file" | grep -oE 'v[0-9]+' | head -1 || echo "")

        if [[ -z "$vid" ]]; then
            # No pending verify entry -- generate one
            generate_verify_entry "$tid" 2>>"$SUPERVISOR_LOG" || continue
            vid=$(grep -oE "^- \[ \] (v[0-9]+) ${task_id_escaped} " "$verify_file" | grep -oE 'v[0-9]+' | head -1 || echo "")
            [[ -z "$vid" ]] && continue
        fi

        # Run verification
        log_info "  Phase 3b: Verifying $tid ($vid)"
        if (cd "$trepo" && bash "$verify_script" run "$vid" 2>>"$SUPERVISOR_LOG"); then
            # Check if it passed (entry marked [x])
            if grep -qE "^- \[x\] $vid " "$verify_file"; then
                cmd_transition "$tid" "verified" 2>>"$SUPERVISOR_LOG" || true
                verified_count=$((verified_count + 1))
                log_success "  $tid: verified ($vid passed)"
            elif grep -qE "^- \[!\] $vid " "$verify_file"; then
                cmd_transition "$tid" "verify_failed" 2>>"$SUPERVISOR_LOG" || true
                failed_count=$((failed_count + 1))
                log_warn "  $tid: verification failed ($vid)"
            fi
        else
            log_warn "  $tid: verify-run-helper.sh failed for $vid"
        fi
    done <<< "$deployed_tasks"

    if [[ $((verified_count + failed_count)) -gt 0 ]]; then
        log_info "  Phase 3b: Verified $verified_count, failed $failed_count"
        # Commit verify results
        local first_repo
        first_repo=$(echo "$deployed_tasks" | head -1 | cut -d'|' -f2)
        if [[ -n "$first_repo" ]]; then
            commit_and_push_todo "$first_repo" "chore: verify results (${verified_count} passed, ${failed_count} failed)" 2>>"$SUPERVISOR_LOG" || true
        fi
    fi

    return 0
}

#######################################
# Update TODO.md when a task is blocked or failed
# Adds Notes line with blocked reason
# Then commits and pushes the change
#######################################
update_todo_on_blocked() {
    local task_id="$1"
    local reason="${2:-unknown}"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local trepo
    trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';")

    if [[ -z "$trepo" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local todo_file="$trepo/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        log_warn "TODO.md not found at $todo_file"
        return 1
    fi

    # Find the task line number
    local line_num
    line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1)

    if [[ -z "$line_num" ]]; then
        log_warn "Task $task_id not found as open in $todo_file"
        return 0
    fi

    # Detect indentation of the task line for proper Notes alignment
    local task_line
    task_line=$(sed -n "${line_num}p" "$todo_file")
    local indent=""
    indent=$(echo "$task_line" | sed -E 's/^([[:space:]]*).*/\1/')

    # Check if a Notes line already exists below the task
    local next_line_num=$((line_num + 1))
    local next_line
    next_line=$(sed -n "${next_line_num}p" "$todo_file" 2>/dev/null || echo "")

    # Sanitize reason for safe insertion (escape special sed chars)
    local safe_reason
    safe_reason=$(echo "$reason" | sed 's/[&/\]/\\&/g' | head -c 200)

    if echo "$next_line" | grep -qE "^[[:space:]]*- Notes:"; then
        # Append to existing Notes line
        local append_text=" BLOCKED: ${safe_reason}"
        sed_inplace "${next_line_num}s/$/${append_text}/" "$todo_file"
    else
        # Insert a new Notes line after the task
        local notes_line="${indent}  - Notes: BLOCKED by supervisor: ${safe_reason}"
        sed_append_after "$line_num" "$notes_line" "$todo_file"
    fi

    log_success "Updated TODO.md: $task_id marked blocked ($reason)"

    commit_and_push_todo "$trepo" "chore: mark $task_id blocked in TODO.md"
    return $?
}

#######################################
# Send notification about task state change
# Uses mail-helper.sh and optionally matrix-dispatch-helper.sh
#######################################
send_task_notification() {
    local task_id="$1"
    local event_type="$2"  # complete, blocked, failed
    local detail="${3:-}"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT description, repo, pr_url, error FROM tasks WHERE id = '$escaped_id';
    ")

    local tdesc trepo tpr terror
    IFS='|' read -r tdesc trepo tpr terror <<< "$task_row"

    local message=""
    case "$event_type" in
        complete)
            message="Task $task_id completed: ${tdesc:-no description}"
            if [[ -n "$tpr" ]]; then
                message="$message | PR: $tpr"
            fi
            ;;
        blocked)
            message="Task $task_id BLOCKED: ${detail:-${terror:-unknown reason}} | ${tdesc:-no description}"
            ;;
        failed)
            message="Task $task_id FAILED: ${detail:-${terror:-unknown reason}} | ${tdesc:-no description}"
            ;;
        *)
            message="Task $task_id [$event_type]: ${detail:-${tdesc:-no description}}"
            ;;
    esac

    # Send via mail-helper.sh (inter-agent mailbox)
    if [[ -x "$MAIL_HELPER" ]]; then
        local priority="normal"
        if [[ "$event_type" == "blocked" || "$event_type" == "failed" ]]; then
            priority="high"
        fi
        "$MAIL_HELPER" send \
            --to coordinator \
            --type status_report \
            --priority "$priority" \
            --payload "$message" 2>/dev/null || true
        log_info "Notification sent via mail: $event_type for $task_id"
    fi

    # Send via Matrix if configured
    local matrix_helper="${SCRIPT_DIR}/matrix-dispatch-helper.sh"
    if [[ -x "$matrix_helper" ]]; then
        local matrix_room
        matrix_room=$("$matrix_helper" mappings 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d ' ' || true)
        if [[ -n "$matrix_room" ]]; then
            "$matrix_helper" test --room "$matrix_room" --message "$message" 2>/dev/null || true
            log_info "Notification sent via Matrix: $event_type for $task_id"
        fi
    fi

    # macOS audio alerts via afplay (reliable across all process contexts)
    # TTS (say) requires Accessibility permissions for Tabby/terminal app -
    # enable in System Settings > Privacy & Security > Accessibility
    if [[ "$(uname)" == "Darwin" ]]; then
        case "$event_type" in
            complete) afplay /System/Library/Sounds/Glass.aiff 2>/dev/null & ;;
            blocked)  afplay /System/Library/Sounds/Basso.aiff 2>/dev/null & ;;
            failed)   afplay /System/Library/Sounds/Sosumi.aiff 2>/dev/null & ;;
        esac
    fi

    return 0
}

#######################################
# Send a macOS notification for batch progress milestones
# Called from pulse summary when notable progress occurs
#######################################
notify_batch_progress() {
    local completed="$1"
    local total="$2"
    local failed="${3:-0}"
    local batch_name="${4:-batch}"

    [[ "$(uname)" != "Darwin" ]] && return 0

    local remaining=$((total - completed - failed))
    local message="${completed}/${total} done"
    if [[ "$failed" -gt 0 ]]; then
        message="$message, $failed failed"
    fi
    if [[ "$remaining" -gt 0 ]]; then
        message="$message, $remaining remaining"
    fi

    if [[ "$completed" -eq "$total" && "$failed" -eq 0 ]]; then
        message="All $total tasks complete!"
        nohup afplay /System/Library/Sounds/Hero.aiff &>/dev/null &
        nohup say "Batch complete. All $total tasks finished successfully." &>/dev/null &
    elif [[ "$remaining" -eq 0 ]]; then
        message="Batch finished: $message"
        nohup afplay /System/Library/Sounds/Purr.aiff &>/dev/null &
        nohup say "Batch finished. $completed of $total done. $failed failed." &>/dev/null &
    else
        nohup afplay /System/Library/Sounds/Pop.aiff &>/dev/null &
    fi

    return 0
}

#######################################
# Recall relevant memories for a task before dispatch
# Returns memory context as text (empty string if none found)
# Used to inject prior learnings into the worker prompt
#######################################
recall_task_memories() {
    local task_id="$1"
    local description="${2:-}"

    if [[ ! -x "$MEMORY_HELPER" ]]; then
        return 0
    fi

    # Build search query from task ID and description
    local query="$task_id"
    if [[ -n "$description" ]]; then
        query="$description"
    fi

    # Recall memories relevant to this task (limit 5, auto-captured preferred)
    local memories=""
    memories=$("$MEMORY_HELPER" recall --query "$query" --limit 5 --format text 2>/dev/null || echo "")

    # Also check for failure patterns from previous attempts of this specific task
    local task_memories=""
    task_memories=$("$MEMORY_HELPER" recall --query "supervisor $task_id failure" --limit 3 --auto-only --format text 2>/dev/null || echo "")

    local result=""
    if [[ -n "$memories" && "$memories" != *"No memories found"* ]]; then
        result="## Relevant Memories (from prior sessions)
$memories"
    fi

    if [[ -n "$task_memories" && "$task_memories" != *"No memories found"* ]]; then
        if [[ -n "$result" ]]; then
            result="$result

## Prior Failure Patterns for $task_id
$task_memories"
        else
            result="## Prior Failure Patterns for $task_id
$task_memories"
        fi
    fi

    echo "$result"
    return 0
}

#######################################
# Store a failure pattern in memory after evaluation
# Called when a task fails, is blocked, or retries
# Tags with supervisor context for future recall
# Uses FAILURE_PATTERN type for pattern-tracker integration (t102.3)
#######################################
store_failure_pattern() {
    local task_id="$1"
    local outcome_type="$2"
    local outcome_detail="$3"
    local description="${4:-}"

    if [[ ! -x "$MEMORY_HELPER" ]]; then
        return 0
    fi

    # Only store meaningful failure patterns (not transient retries)
    case "$outcome_type" in
        blocked|failed)
            true  # Always store these
            ;;
        retry)
            # Only store retry patterns if they indicate a recurring issue
            # Skip transient ones like rate_limited, timeout, interrupted
            # Skip clean_exit_no_signal retries — infrastructure noise (t230)
            # The blocked/failed outcomes above still capture the final state
            case "$outcome_detail" in
                rate_limited|timeout|interrupted_sigint|killed_sigkill|terminated_sigterm|clean_exit_no_signal)
                    return 0
                    ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac

    # Rate-limit: skip if 3+ entries with the same outcome_detail exist in last 24h (t230)
    # Prevents memory pollution from repetitive infrastructure failures
    local recent_count=0
    local escaped_detail
    escaped_detail="$(sql_escape "$outcome_detail")"
    if [[ -r "$MEMORY_DB" ]]; then
        recent_count=$(sqlite3 "$MEMORY_DB" \
            "SELECT COUNT(*) FROM learnings WHERE type = 'FAILURE_PATTERN' AND content LIKE '%${escaped_detail}%' AND created_at > datetime('now', '-1 day');" \
            2>/dev/null || echo "0")
    fi
    if [[ "$recent_count" -ge 3 ]]; then
        log_info "Skipping failure pattern storage: $outcome_detail already has $recent_count entries in last 24h (t230)"
        return 0
    fi

    # Look up model tier from task record for pattern routing (t102.3)
    local model_tier=""
    local task_model
    task_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
    if [[ -n "$task_model" ]]; then
        # Extract tier name from model string (e.g., "anthropic/claude-opus-4-6" -> "opus")
        case "$task_model" in
            *haiku*) model_tier="haiku" ;;
            *flash*) model_tier="flash" ;;
            *sonnet*) model_tier="sonnet" ;;
            *opus*)  model_tier="opus" ;;
            *pro*)   model_tier="pro" ;;
        esac
    fi

    # Build structured content for pattern-tracker compatibility
    local content="Supervisor task $task_id ($outcome_type): $outcome_detail"
    if [[ -n "$description" ]]; then
        content="[task:feature] $content | Task: $description"
    fi
    [[ -n "$model_tier" ]] && content="$content [model:$model_tier]"

    # Build tags with model info for pattern-tracker queries
    local tags="supervisor,pattern,$task_id,$outcome_type,$outcome_detail"
    [[ -n "$model_tier" ]] && tags="$tags,model:$model_tier"

    "$MEMORY_HELPER" store \
        --auto \
        --type "FAILURE_PATTERN" \
        --content "$content" \
        --tags "$tags" \
        2>/dev/null || true

    log_info "Stored failure pattern in memory: $task_id ($outcome_type: $outcome_detail)"
    return 0
}

#######################################
# Store a success pattern in memory after task completion
# Records what worked for future reference
# Uses SUCCESS_PATTERN type for pattern-tracker integration (t102.3)
#######################################
store_success_pattern() {
    local task_id="$1"
    local detail="${2:-}"
    local description="${3:-}"

    if [[ ! -x "$MEMORY_HELPER" ]]; then
        return 0
    fi

    # Look up model tier and timing from task record (t102.3)
    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local model_tier=""
    local task_model duration_info retries
    task_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")

    # Calculate duration if timestamps available
    local started completed duration_secs=""
    started=$(db "$SUPERVISOR_DB" "SELECT started_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    completed=$(db "$SUPERVISOR_DB" "SELECT completed_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    if [[ -n "$started" && -n "$completed" ]]; then
        local start_epoch end_epoch
        start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" "+%s" 2>/dev/null || date -d "$started" "+%s" 2>/dev/null || echo "")
        end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$completed" "+%s" 2>/dev/null || date -d "$completed" "+%s" 2>/dev/null || echo "")
        if [[ -n "$start_epoch" && -n "$end_epoch" ]]; then
            duration_secs=$((end_epoch - start_epoch))
        fi
    fi

    # Extract tier name from model string
    if [[ -n "$task_model" ]]; then
        case "$task_model" in
            *haiku*) model_tier="haiku" ;;
            *flash*) model_tier="flash" ;;
            *sonnet*) model_tier="sonnet" ;;
            *opus*)  model_tier="opus" ;;
            *pro*)   model_tier="pro" ;;
        esac
    fi

    # Build structured content for pattern-tracker compatibility
    local content="Supervisor task $task_id completed successfully"
    if [[ -n "$detail" && "$detail" != "no_pr" ]]; then
        content="$content | PR: $detail"
    fi
    if [[ -n "$description" ]]; then
        content="[task:feature] $content | Task: $description"
    fi
    [[ -n "$model_tier" ]] && content="$content [model:$model_tier]"
    [[ -n "$duration_secs" ]] && content="$content [duration:${duration_secs}s]"
    if [[ "$retries" -gt 0 ]]; then
        content="$content [retries:$retries]"
    fi

    # Task tool parallelism tracking (t217): check if worker used Task tool
    # for sub-agent parallelism. Logged as a quality signal for pattern analysis.
    local log_file task_tool_count=0
    log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    if [[ -n "$log_file" && -f "$log_file" ]]; then
        task_tool_count=$(grep -c 'mcp_task\|"tool_name":"task"\|"name":"task"' "$log_file" 2>/dev/null || echo 0)
    fi
    if [[ "$task_tool_count" -gt 0 ]]; then
        content="$content [task_tool:$task_tool_count]"
    fi

    # Build tags with model and duration info for pattern-tracker queries
    local tags="supervisor,pattern,$task_id,complete"
    [[ -n "$model_tier" ]] && tags="$tags,model:$model_tier"
    [[ -n "$duration_secs" ]] && tags="$tags,duration:$duration_secs"
    [[ "$retries" -gt 0 ]] && tags="$tags,retries:$retries"
    [[ "$task_tool_count" -gt 0 ]] && tags="$tags,task_tool:$task_tool_count"

    "$MEMORY_HELPER" store \
        --auto \
        --type "SUCCESS_PATTERN" \
        --content "$content" \
        --tags "$tags" \
        2>/dev/null || true

    log_info "Stored success pattern in memory: $task_id"
    return 0
}

#######################################
# Self-healing: determine if a failed/blocked task is eligible for
# automatic diagnostic subtask creation (t150)
# Returns 0 if eligible, 1 if not
#######################################
is_self_heal_eligible() {
    local task_id="$1"
    local failure_reason="$2"

    # Check global toggle (env var or default on)
    if [[ "${SUPERVISOR_SELF_HEAL:-true}" == "false" ]]; then
        return 1
    fi

    # Skip failures that require human intervention - no diagnostic can fix these
    # Note (t183): no_log_file removed from exclusion list. With enhanced dispatch
    # error capture, log files now contain diagnostic metadata even when workers
    # fail to start, making self-healing viable for these failures.
    case "$failure_reason" in
        auth_error|merge_conflict|out_of_memory|max_retries)
            return 1
            ;;
    esac

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Skip if this task is itself a diagnostic subtask (prevent recursive healing)
    local is_diagnostic
    is_diagnostic=$(db "$SUPERVISOR_DB" "SELECT diagnostic_of FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
    if [[ -n "$is_diagnostic" ]]; then
        return 1
    fi

    # Skip if a diagnostic subtask already exists for this task (max 1 per task)
    local existing_diag
    existing_diag=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE diagnostic_of = '$escaped_id';" 2>/dev/null || echo "0")
    if [[ "$existing_diag" -gt 0 ]]; then
        return 1
    fi

    return 0
}

#######################################
# Self-healing: create a diagnostic subtask for a failed/blocked task (t150)
# The diagnostic task analyzes the failure log and attempts to fix the issue.
# On completion, the original task is re-queued.
#
# Args: task_id, failure_reason, batch_id (optional)
# Returns: diagnostic task ID on stdout, 0 on success, 1 on failure
#######################################
create_diagnostic_subtask() {
    local task_id="$1"
    local failure_reason="$2"
    local batch_id="${3:-}"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Get original task details
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, description, log_file, error, model
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local trepo tdesc tlog terror tmodel
    IFS='|' read -r trepo tdesc tlog terror tmodel <<< "$task_row"

    # Generate diagnostic task ID: {parent}-diag-{N}
    local diag_count
    diag_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE id LIKE '$(sql_escape "$task_id")-diag-%';" 2>/dev/null || echo "0")
    local diag_num=$((diag_count + 1))
    local diag_id="${task_id}-diag-${diag_num}"

    # Extract failure context from log (last 100 lines)
    # CRITICAL: Replace newlines with spaces. The description is stored in SQLite
    # and returned by cmd_next as tab-separated output parsed with `read`. Embedded
    # newlines (e.g., EXIT:0 from log tail) would be parsed as separate task rows,
    # causing malformed task IDs like "EXIT:0" or "DIAGNOSTIC_CONTEXT_END".
    local failure_context=""
    if [[ -n "$tlog" && -f "$tlog" ]]; then
        failure_context=$(tail -100 "$tlog" 2>/dev/null | head -c 4000 | tr '\n' ' ' | tr '\t' ' ' || echo "")
    fi

    # Build diagnostic task description (single line - no embedded newlines)
    local diag_desc="Diagnose and fix failure in ${task_id}: ${failure_reason}."
    diag_desc="${diag_desc} Original task: ${tdesc:-unknown}."
    if [[ -n "$terror" ]]; then
        diag_desc="${diag_desc} Error: $(echo "$terror" | tr '\n' ' ' | head -c 200)"
    fi
    diag_desc="${diag_desc} Analyze the failure log, identify root cause, and apply a fix."
    diag_desc="${diag_desc} If the fix requires code changes, make them and create a PR."
    diag_desc="${diag_desc} DIAGNOSTIC_CONTEXT_START"
    if [[ -n "$failure_context" ]]; then
        diag_desc="${diag_desc} LOG_TAIL: ${failure_context}"
    fi
    diag_desc="${diag_desc} DIAGNOSTIC_CONTEXT_END"

    # Add diagnostic task to supervisor
    local escaped_diag_id
    escaped_diag_id=$(sql_escape "$diag_id")
    local escaped_diag_desc
    escaped_diag_desc=$(sql_escape "$diag_desc")
    local escaped_repo
    escaped_repo=$(sql_escape "$trepo")
    local escaped_model
    escaped_model=$(sql_escape "$tmodel")

    db "$SUPERVISOR_DB" "
        INSERT INTO tasks (id, repo, description, model, max_retries, diagnostic_of)
        VALUES ('$escaped_diag_id', '$escaped_repo', '$escaped_diag_desc', '$escaped_model', 2, '$escaped_id');
    "

    # Log the creation
    db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_diag_id', '', 'queued', 'Self-heal diagnostic for $task_id ($failure_reason)');
    "

    # Add to same batch if applicable
    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")
        local max_pos
        max_pos=$(db "$SUPERVISOR_DB" "SELECT COALESCE(MAX(position), 0) + 1 FROM batch_tasks WHERE batch_id = '$escaped_batch';" 2>/dev/null || echo "0")
        db "$SUPERVISOR_DB" "
            INSERT OR IGNORE INTO batch_tasks (batch_id, task_id, position)
            VALUES ('$escaped_batch', '$escaped_diag_id', $max_pos);
        " 2>/dev/null || true
    fi

    log_success "Created diagnostic subtask: $diag_id for $task_id ($failure_reason)"
    echo "$diag_id"
    return 0
}

#######################################
# Self-healing: attempt to create a diagnostic subtask for a failed/blocked task (t150)
# Called from pulse cycle. Checks eligibility before creating.
#
# Args: task_id, outcome_type (blocked/failed), failure_reason, batch_id (optional)
# Returns: 0 if diagnostic created, 1 if skipped
#######################################
attempt_self_heal() {
    local task_id="$1"
    local outcome_type="$2"
    local failure_reason="$3"
    local batch_id="${4:-}"

    if ! is_self_heal_eligible "$task_id" "$failure_reason"; then
        log_info "Self-heal skipped for $task_id ($failure_reason): not eligible"
        return 1
    fi

    local diag_id
    diag_id=$(create_diagnostic_subtask "$task_id" "$failure_reason" "$batch_id") || return 1

    log_info "Self-heal: created $diag_id to investigate $task_id"

    # Store self-heal event in memory
    if [[ -x "$MEMORY_HELPER" ]]; then
        "$MEMORY_HELPER" store \
            --auto \
            --type "ERROR_FIX" \
            --content "Supervisor self-heal: created $diag_id to diagnose $task_id ($failure_reason)" \
            --tags "supervisor,self-heal,$task_id,$diag_id" \
            2>/dev/null || true
    fi

    return 0
}

#######################################
# Self-healing: check if a completed diagnostic task should re-queue its parent (t150)
# Called from pulse cycle after a task completes.
#
# Args: task_id (the completed task)
# Returns: 0 if parent was re-queued, 1 if not applicable
#######################################
handle_diagnostic_completion() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")

    # Check if this is a diagnostic task
    local parent_id
    parent_id=$(db "$SUPERVISOR_DB" "SELECT diagnostic_of FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

    if [[ -z "$parent_id" ]]; then
        return 1
    fi

    # Check parent task status - only re-queue if still blocked/failed
    local parent_status
    parent_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$parent_id")';" 2>/dev/null || echo "")

    case "$parent_status" in
        blocked|failed)
            log_info "Diagnostic $task_id completed - re-queuing parent $parent_id"
            cmd_reset "$parent_id" 2>/dev/null || {
                log_warn "Failed to reset parent task $parent_id"
                return 1
            }
            # Log the re-queue
            db "$SUPERVISOR_DB" "
                INSERT INTO state_log (task_id, from_state, to_state, reason)
                VALUES ('$(sql_escape "$parent_id")', '$parent_status', 'queued',
                        'Re-queued after diagnostic $task_id completed');
            " 2>/dev/null || true
            log_success "Re-queued $parent_id after diagnostic $task_id completed"
            return 0
            ;;
        *)
            log_info "Diagnostic $task_id completed but parent $parent_id is in '$parent_status' (not re-queueing)"
            return 1
            ;;
    esac
}

#######################################
# Command: self-heal - manually create a diagnostic subtask for a task
#######################################
cmd_self_heal() {
    local task_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh self-heal <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local task_row
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, error FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tstatus terror
    IFS='|' read -r tstatus terror <<< "$task_row"

    if [[ "$tstatus" != "blocked" && "$tstatus" != "failed" ]]; then
        log_error "Task $task_id is in '$tstatus' state. Self-heal only works on blocked/failed tasks."
        return 1
    fi

    local failure_reason="${terror:-unknown}"

    # Find batch for this task (if any)
    local batch_id
    batch_id=$(db "$SUPERVISOR_DB" "SELECT batch_id FROM batch_tasks WHERE task_id = '$escaped_id' LIMIT 1;" 2>/dev/null || echo "")

    local diag_id
    diag_id=$(create_diagnostic_subtask "$task_id" "$failure_reason" "$batch_id") || return 1

    echo -e "${BOLD}Created diagnostic subtask:${NC} $diag_id"
    echo "  Parent task: $task_id ($tstatus)"
    echo "  Reason:      $failure_reason"
    echo "  Batch:       ${batch_id:-none}"
    echo ""
    echo "The diagnostic task will be dispatched on the next pulse cycle."
    echo "When it completes, $task_id will be automatically re-queued."
    return 0
}

#######################################
# Run a retrospective after batch completion
# Analyzes outcomes across all tasks in a batch and stores insights
#######################################
run_batch_retrospective() {
    local batch_id="$1"

    if [[ ! -x "$MEMORY_HELPER" ]]; then
        log_warn "Memory helper not available, skipping retrospective"
        return 0
    fi

    ensure_db

    local escaped_batch
    escaped_batch=$(sql_escape "$batch_id")

    # Get batch info
    local batch_name
    batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")

    # Gather statistics
    local total_tasks complete_count failed_count blocked_count cancelled_count
    total_tasks=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks WHERE batch_id = '$escaped_batch';
    ")
    complete_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'complete';
    ")
    failed_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'failed';
    ")
    blocked_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'blocked';
    ")
    cancelled_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'cancelled';
    ")

    # Gather common error patterns
    local error_patterns
    error_patterns=$(db "$SUPERVISOR_DB" "
        SELECT error, count(*) as cnt FROM tasks t
        JOIN batch_tasks bt ON t.id = bt.task_id
        WHERE bt.batch_id = '$escaped_batch'
        AND t.error IS NOT NULL AND t.error != ''
        GROUP BY error ORDER BY cnt DESC LIMIT 5;
    " 2>/dev/null || echo "")

    # Calculate total retries
    local total_retries
    total_retries=$(db "$SUPERVISOR_DB" "
        SELECT COALESCE(SUM(t.retries), 0) FROM tasks t
        JOIN batch_tasks bt ON t.id = bt.task_id
        WHERE bt.batch_id = '$escaped_batch';
    ")

    # Build retrospective summary
    local success_rate=0
    if [[ "$total_tasks" -gt 0 ]]; then
        success_rate=$(( (complete_count * 100) / total_tasks ))
    fi

    local retro_content="Batch retrospective: $batch_name ($batch_id) | "
    retro_content+="$complete_count/$total_tasks completed (${success_rate}%) | "
    retro_content+="Failed: $failed_count, Blocked: $blocked_count, Cancelled: $cancelled_count | "
    retro_content+="Total retries: $total_retries"

    if [[ -n "$error_patterns" ]]; then
        retro_content+=" | Common errors: $(echo "$error_patterns" | tr '\n' '; ' | head -c 200)"
    fi

    # Store the retrospective
    "$MEMORY_HELPER" store \
        --auto \
        --type "CODEBASE_PATTERN" \
        --content "$retro_content" \
        --tags "supervisor,retrospective,$batch_name,batch" \
        2>/dev/null || true

    # Store individual failure patterns if there are recurring errors
    if [[ -n "$error_patterns" ]]; then
        while IFS='|' read -r error_msg error_count; do
            if [[ "$error_count" -gt 1 && -n "$error_msg" ]]; then
                "$MEMORY_HELPER" store \
                    --auto \
                    --type "FAILED_APPROACH" \
                    --content "Recurring error in batch $batch_name ($error_count occurrences): $error_msg" \
                    --tags "supervisor,retrospective,$batch_name,recurring_error" \
                    2>/dev/null || true
            fi
        done <<< "$error_patterns"
    fi

    log_success "Batch retrospective stored for $batch_name"
    echo ""
    echo -e "${BOLD}=== Batch Retrospective: $batch_name ===${NC}"
    echo "  Total tasks:  $total_tasks"
    echo "  Completed:    $complete_count (${success_rate}%)"
    echo "  Failed:       $failed_count"
    echo "  Blocked:      $blocked_count"
    echo "  Cancelled:    $cancelled_count"
    echo "  Total retries: $total_retries"
    if [[ -n "$error_patterns" ]]; then
        echo ""
        echo "  Common errors:"
        echo "$error_patterns" | while IFS='|' read -r emsg ecnt; do
            echo "    [$ecnt] $emsg"
        done
    fi

    return 0
}

#######################################
# Run session review and distillation after batch completion (t128.9)
# Gathers session context via session-review-helper.sh and extracts
# learnings via session-distill-helper.sh for cross-session memory.
# Also suggests agent-review for post-batch improvement opportunities.
#######################################
run_session_review() {
    local batch_id="$1"

    ensure_db

    local escaped_batch
    escaped_batch=$(sql_escape "$batch_id")
    local batch_name
    batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")

    # Phase 1: Session review - gather context snapshot
    if [[ -x "$SESSION_REVIEW_HELPER" ]]; then
        log_info "Running session review for batch $batch_name..."
        local review_output=""

        # Get repo from first task in batch (session-review runs in repo context)
        local batch_repo
        batch_repo=$(db "$SUPERVISOR_DB" "
            SELECT t.repo FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            ORDER BY bt.position LIMIT 1;
        " 2>/dev/null || echo "")

        if [[ -n "$batch_repo" && -d "$batch_repo" ]]; then
            review_output=$(cd "$batch_repo" && "$SESSION_REVIEW_HELPER" json 2>>"$SUPERVISOR_LOG") || true
        else
            review_output=$("$SESSION_REVIEW_HELPER" json 2>>"$SUPERVISOR_LOG") || true
        fi

        if [[ -n "$review_output" ]]; then
            # Store session review snapshot in memory
            if [[ -x "$MEMORY_HELPER" ]]; then
                local review_summary
                review_summary=$(echo "$review_output" | jq -r '
                    "Session review for batch '"$batch_name"': branch=" + .branch +
                    " todo=" + (.todo | tostring) +
                    " changes=" + (.changes | tostring)
                ' 2>/dev/null || echo "Session review completed for batch $batch_name")

                "$MEMORY_HELPER" store \
                    --auto \
                    --type "CONTEXT" \
                    --content "$review_summary" \
                    --tags "supervisor,session-review,$batch_name,batch" \
                    2>/dev/null || true
            fi
            log_success "Session review captured for batch $batch_name"
        else
            log_warn "Session review produced no output for batch $batch_name"
        fi
    else
        log_warn "session-review-helper.sh not found, skipping session review"
    fi

    # Phase 2: Session distillation - extract and store learnings
    if [[ -x "$SESSION_DISTILL_HELPER" ]]; then
        log_info "Running session distillation for batch $batch_name..."

        local batch_repo
        # Re-resolve in case it wasn't set above (defensive)
        batch_repo=$(db "$SUPERVISOR_DB" "
            SELECT t.repo FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            ORDER BY bt.position LIMIT 1;
        " 2>/dev/null || echo "")

        if [[ -n "$batch_repo" && -d "$batch_repo" ]]; then
            (cd "$batch_repo" && "$SESSION_DISTILL_HELPER" auto 2>>"$SUPERVISOR_LOG") || true
        else
            "$SESSION_DISTILL_HELPER" auto 2>>"$SUPERVISOR_LOG" || true
        fi

        log_success "Session distillation complete for batch $batch_name"
    else
        log_warn "session-distill-helper.sh not found, skipping distillation"
    fi

    # Phase 3: Suggest agent-review (non-blocking recommendation)
    echo ""
    echo -e "${BOLD}=== Post-Batch Recommendations ===${NC}"
    echo "  Batch '$batch_name' is complete. Consider running:"
    echo "    @agent-review  - Review and improve agents used in this batch"
    echo "    /session-review - Full interactive session review"
    echo ""

    return 0
}

#######################################
# Command: release - manually trigger a release for a batch (t128.10)
# Can also enable/disable release_on_complete for an existing batch
#######################################
cmd_release() {
    local batch_id="" release_type="" enable_flag="" dry_run="false"

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        batch_id="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) [[ $# -lt 2 ]] && { log_error "--type requires a value"; return 1; }; release_type="$2"; shift 2 ;;
            --enable) enable_flag="enable"; shift ;;
            --disable) enable_flag="disable"; shift ;;
            --dry-run) dry_run="true"; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$batch_id" ]]; then
        # Find the most recently completed batch
        ensure_db
        batch_id=$(db "$SUPERVISOR_DB" "
            SELECT id FROM batches WHERE status = 'complete'
            ORDER BY updated_at DESC LIMIT 1;
        " 2>/dev/null || echo "")

        if [[ -z "$batch_id" ]]; then
            log_error "No batch specified and no completed batches found."
            log_error "Usage: supervisor-helper.sh release <batch_id> [--type patch|minor|major] [--enable|--disable] [--dry-run]"
            return 1
        fi
        log_info "Using most recently completed batch: $batch_id"
    fi

    ensure_db

    local escaped_batch
    escaped_batch=$(sql_escape "$batch_id")

    # Look up batch (by ID or name)
    local batch_row
    batch_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, name, status, release_on_complete, release_type
        FROM batches WHERE id = '$escaped_batch' OR name = '$escaped_batch'
        LIMIT 1;
    ")

    if [[ -z "$batch_row" ]]; then
        log_error "Batch not found: $batch_id"
        return 1
    fi

    local bid bname bstatus brelease_flag brelease_type
    IFS='|' read -r bid bname bstatus brelease_flag brelease_type <<< "$batch_row"
    escaped_batch=$(sql_escape "$bid")

    # Handle enable/disable mode
    if [[ -n "$enable_flag" ]]; then
        if [[ "$enable_flag" == "enable" ]]; then
            local new_type="${release_type:-${brelease_type:-patch}}"
            db "$SUPERVISOR_DB" "
                UPDATE batches SET release_on_complete = 1, release_type = '$(sql_escape "$new_type")',
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch';
            "
            log_success "Enabled release_on_complete for batch $bname (type: $new_type)"
        else
            db "$SUPERVISOR_DB" "
                UPDATE batches SET release_on_complete = 0,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch';
            "
            log_success "Disabled release_on_complete for batch $bname"
        fi
        return 0
    fi

    # Manual release trigger mode
    if [[ -z "$release_type" ]]; then
        release_type="${brelease_type:-patch}"
    fi

    # Validate release_type
    case "$release_type" in
        major|minor|patch) ;;
        *) log_error "Invalid release type: $release_type"; return 1 ;;
    esac

    # Get repo from first task in batch
    local batch_repo
    batch_repo=$(db "$SUPERVISOR_DB" "
        SELECT t.repo FROM batch_tasks bt
        JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch'
        ORDER BY bt.position LIMIT 1;
    " 2>/dev/null || echo "")

    if [[ -z "$batch_repo" ]]; then
        log_error "No tasks found in batch $bname - cannot determine repo"
        return 1
    fi

    echo -e "${BOLD}=== Batch Release: $bname ===${NC}"
    echo "  Batch:   $bid"
    echo "  Status:  $bstatus"
    echo "  Type:    $release_type"
    echo "  Repo:    $batch_repo"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] Would trigger $release_type release for batch $bname from $batch_repo"
        return 0
    fi

    trigger_batch_release "$bid" "$release_type" "$batch_repo"
    return $?
}

#######################################
# Command: retrospective - run batch retrospective
#######################################
cmd_retrospective() {
    local batch_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        batch_id="$1"
        shift
    fi

    if [[ -z "$batch_id" ]]; then
        # Find the most recently completed batch
        ensure_db
        batch_id=$(db "$SUPERVISOR_DB" "
            SELECT id FROM batches WHERE status = 'complete'
            ORDER BY updated_at DESC LIMIT 1;
        " 2>/dev/null || echo "")

        if [[ -z "$batch_id" ]]; then
            log_error "No completed batches found. Usage: supervisor-helper.sh retrospective [batch_id]"
            return 1
        fi
        log_info "Using most recently completed batch: $batch_id"
    fi

    run_batch_retrospective "$batch_id"
    return 0
}

#######################################
# Command: recall - recall memories relevant to a task
#######################################
cmd_recall() {
    local task_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh recall <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local tdesc
    tdesc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

    if [[ -z "$tdesc" ]]; then
        # Try looking up from TODO.md in current repo
        tdesc=$(grep -E "^[[:space:]]*- \[( |x|-)\] $task_id " TODO.md 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*- \[( |x|-)\] [^ ]* //' || true)
    fi

    local memories
    memories=$(recall_task_memories "$task_id" "$tdesc")

    if [[ -n "$memories" ]]; then
        echo "$memories"
    else
        log_info "No relevant memories found for $task_id"
    fi

    return 0
}

#######################################
# Command: update-todo - manually trigger TODO.md update for a task
#######################################
cmd_update_todo() {
    local task_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh update-todo <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local tstatus
    tstatus=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

    if [[ -z "$tstatus" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    case "$tstatus" in
        complete|deployed|merged|verified)
            update_todo_on_complete "$task_id"
            ;;
        blocked)
            local terror
            terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")
            update_todo_on_blocked "$task_id" "${terror:-blocked by supervisor}"
            ;;
        failed)
            local terror
            terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")
            update_todo_on_blocked "$task_id" "FAILED: ${terror:-unknown}"
            ;;
        *)
            log_warn "Task $task_id is in '$tstatus' state - TODO update only applies to complete/deployed/merged/blocked/failed tasks"
            return 1
            ;;
    esac

    return 0
}

#######################################
# Command: reconcile-todo - bulk-update TODO.md for all completed/deployed tasks
# Finds tasks in supervisor DB that are complete/deployed/merged but still
# show as open [ ] in TODO.md, and updates them.
# Handles the case where concurrent push failures left TODO.md stale.
#######################################
cmd_reconcile_todo() {
    local repo_path=""
    local dry_run="false"
    local batch_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo_path="$2"; shift 2 ;;
            --batch) batch_id="$2"; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            *) shift ;;
        esac
    done

    ensure_db

    # Find completed/deployed/merged/verified tasks
    local where_clause="t.status IN ('complete', 'deployed', 'merged', 'verified')"
    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")
        where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$escaped_batch')"
    fi

    local completed_tasks
    completed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.repo, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.id;
    ")

    if [[ -z "$completed_tasks" ]]; then
        log_info "No completed tasks found in supervisor DB"
        return 0
    fi

    local stale_count=0
    local updated_count=0
    local stale_tasks=""

    while IFS='|' read -r tid trepo tpr_url; do
        [[ -z "$tid" ]] && continue

        # Use provided repo or task's repo
        local check_repo="${repo_path:-$trepo}"
        local todo_file="$check_repo/TODO.md"

        if [[ ! -f "$todo_file" ]]; then
            continue
        fi

        # Check if task is still open in TODO.md
        if grep -qE "^[[:space:]]*- \[ \] ${tid}( |$)" "$todo_file"; then
            stale_count=$((stale_count + 1))
            stale_tasks="${stale_tasks}${stale_tasks:+, }${tid}"

            if [[ "$dry_run" == "true" ]]; then
                log_warn "[dry-run] $tid: deployed in DB but open in TODO.md"
            else
                log_info "Reconciling $tid..."
                if update_todo_on_complete "$tid"; then
                    updated_count=$((updated_count + 1))
                else
                    log_warn "Failed to reconcile $tid"
                fi
            fi
        fi
    done <<< "$completed_tasks"

    if [[ "$stale_count" -eq 0 ]]; then
        log_success "TODO.md is in sync with supervisor DB (no stale tasks)"
    elif [[ "$dry_run" == "true" ]]; then
        log_warn "$stale_count stale task(s) found: $stale_tasks"
        log_info "Run without --dry-run to fix"
    else
        log_success "Reconciled $updated_count/$stale_count stale tasks"
        if [[ "$updated_count" -lt "$stale_count" ]]; then
            log_warn "$((stale_count - updated_count)) task(s) could not be reconciled"
        fi
    fi

    return 0
}

#######################################
# Command: notify - manually send notification for a task
#######################################
cmd_notify() {
    local task_id=""

    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        task_id="$1"
        shift
    fi

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh notify <task_id>"
        return 1
    fi

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local tstatus
    tstatus=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

    if [[ -z "$tstatus" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local terror
    terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")

    send_task_notification "$task_id" "$tstatus" "${terror:-}"
    return 0
}

#######################################
# Scan TODO.md for tasks tagged #auto-dispatch or in a
# "Dispatch Queue" section. Auto-adds them to supervisor
# if not already tracked, then queues them for dispatch.
#######################################
cmd_auto_pickup() {
    local repo=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) [[ $# -lt 2 ]] && { log_error "--repo requires a value"; return 1; }; repo="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        repo="$(pwd)"
    fi

    local todo_file="$repo/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        log_warn "TODO.md not found at $todo_file"
        return 1
    fi

    ensure_db

    local picked_up=0

    # Strategy 1: Find tasks tagged #auto-dispatch
    # Matches: - [ ] tXXX description #auto-dispatch ...
    local tagged_tasks
    tagged_tasks=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+(\.[0-9]+)*) .*#auto-dispatch' "$todo_file" 2>/dev/null || true)

    if [[ -n "$tagged_tasks" ]]; then
        while IFS= read -r line; do
            local task_id
            task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
            if [[ -z "$task_id" ]]; then
                continue
            fi

            # Check if already in supervisor
            local existing
            existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)
            if [[ -n "$existing" ]]; then
                if [[ "$existing" == "complete" || "$existing" == "cancelled" ]]; then
                    continue
                fi
                log_info "  $task_id: already tracked (status: $existing)"
                continue
            fi

            # Pre-pickup check: skip tasks with merged PRs (t224).
            # cmd_add also checks, but checking here provides better logging.
            if check_task_already_done "$task_id" "$repo"; then
                log_info "  $task_id: already completed (merged PR) — skipping auto-pickup"
                continue
            fi

            # Add to supervisor
            if cmd_add "$task_id" --repo "$repo" 2>/dev/null; then
                picked_up=$((picked_up + 1))
                log_success "  Auto-picked: $task_id (tagged #auto-dispatch)"
            fi
        done <<< "$tagged_tasks"
    fi

    # Strategy 2: Find tasks in "Dispatch Queue" section
    # Looks for a markdown section header containing "Dispatch Queue"
    # and picks up all open tasks under it until the next section header
    local in_dispatch_section=false
    local section_tasks=""

    while IFS= read -r line; do
        # Detect section headers (## or ###)
        if echo "$line" | grep -qE '^#{1,3} '; then
            if echo "$line" | grep -qi 'dispatch.queue'; then
                in_dispatch_section=true
                continue
            else
                in_dispatch_section=false
                continue
            fi
        fi

        if [[ "$in_dispatch_section" == "true" ]]; then
            # Match open task lines
            if echo "$line" | grep -qE '^[[:space:]]*- \[ \] t[0-9]+'; then
                section_tasks+="$line"$'\n'
            fi
        fi
    done < "$todo_file"

    if [[ -n "$section_tasks" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local task_id
            task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
            if [[ -z "$task_id" ]]; then
                continue
            fi

            local existing
            existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)
            if [[ -n "$existing" ]]; then
                if [[ "$existing" == "complete" || "$existing" == "cancelled" ]]; then
                    continue
                fi
                log_info "  $task_id: already tracked (status: $existing)"
                continue
            fi

            # Pre-pickup check: skip tasks with merged PRs (t224).
            if check_task_already_done "$task_id" "$repo"; then
                log_info "  $task_id: already completed (merged PR) — skipping auto-pickup"
                continue
            fi

            if cmd_add "$task_id" --repo "$repo" 2>/dev/null; then
                picked_up=$((picked_up + 1))
                log_success "  Auto-picked: $task_id (Dispatch Queue section)"
            fi
        done <<< "$section_tasks"
    fi

    if [[ "$picked_up" -eq 0 ]]; then
        log_info "No new tasks to pick up"
    else
        log_success "Picked up $picked_up new tasks"
    fi

    return 0
}

#######################################
# Manage cron-based pulse scheduling
# Installs/uninstalls a crontab entry that runs pulse every N minutes
#######################################
cmd_cron() {
    local action="${1:-status}"
    shift || true

    local interval=5
    local batch_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval) [[ $# -lt 2 ]] && { log_error "--interval requires a value"; return 1; }; interval="$2"; shift 2 ;;
            --batch) [[ $# -lt 2 ]] && { log_error "--batch requires a value"; return 1; }; batch_arg="--batch $2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supervisor-helper.sh"
    local cron_marker="# aidevops-supervisor-pulse"
    local cron_cmd="*/${interval} * * * * ${script_path} pulse ${batch_arg} >> ${SUPERVISOR_DIR}/cron.log 2>&1 ${cron_marker}"

    case "$action" in
        install)
            # Ensure supervisor dir exists for log file
            mkdir -p "$SUPERVISOR_DIR"

            # Check if already installed
            if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
                log_warn "Supervisor cron already installed. Use 'cron uninstall' first to change settings."
                cmd_cron status
                return 0
            fi

            # Add to crontab (preserve existing entries)
            local existing_cron
            existing_cron=$(crontab -l 2>/dev/null || true)
            if [[ -n "$existing_cron" ]]; then
                echo "${existing_cron}"$'\n'"${cron_cmd}" | crontab -
            else
                echo "$cron_cmd" | crontab -
            fi

            log_success "Installed supervisor cron (every ${interval} minutes)"
            log_info "Log: ${SUPERVISOR_DIR}/cron.log"
            if [[ -n "$batch_arg" ]]; then
                log_info "Batch filter: $batch_arg"
            fi
            return 0
            ;;

        uninstall)
            if ! crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
                log_info "No supervisor cron entry found"
                return 0
            fi

            # Remove the supervisor line from crontab
            crontab -l 2>/dev/null | grep -vF "$cron_marker" | crontab - 2>/dev/null || {
                # If crontab is now empty, remove it entirely
                crontab -r 2>/dev/null || true
            }

            log_success "Uninstalled supervisor cron"
            return 0
            ;;

        status)
            echo -e "${BOLD}=== Supervisor Cron Status ===${NC}"

            if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
                local cron_line
                cron_line=$(crontab -l 2>/dev/null | grep -F "$cron_marker")
                echo -e "  Status:   ${GREEN}installed${NC}"
                echo "  Schedule: $cron_line"
            else
                echo -e "  Status:   ${YELLOW}not installed${NC}"
                echo "  Install:  supervisor-helper.sh cron install [--interval N] [--batch id]"
            fi

            # Show cron log tail if it exists
            local cron_log="${SUPERVISOR_DIR}/cron.log"
            if [[ -f "$cron_log" ]]; then
                local log_size
                log_size=$(wc -c < "$cron_log" | tr -d ' ')
                echo "  Log:      $cron_log ($log_size bytes)"
                echo ""
                echo "  Last 5 log lines:"
                tail -5 "$cron_log" 2>/dev/null | while IFS= read -r line; do
                    echo "    $line"
                done
            fi

            return 0
            ;;

        *)
            log_error "Usage: supervisor-helper.sh cron [install|uninstall|status] [--interval N] [--batch id]"
            return 1
            ;;
    esac
}

#######################################
# Watch TODO.md for changes using fswatch
# Triggers auto-pickup + pulse on file modification
# Alternative to cron for real-time responsiveness
#######################################
cmd_watch() {
    local repo=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) [[ $# -lt 2 ]] && { log_error "--repo requires a value"; return 1; }; repo="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        repo="$(pwd)"
    fi

    local todo_file="$repo/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        log_error "TODO.md not found at $todo_file"
        return 1
    fi

    # Check for fswatch
    if ! command -v fswatch &>/dev/null; then
        log_error "fswatch not found. Install with: brew install fswatch"
        log_info "Alternative: use 'supervisor-helper.sh cron install' for cron-based scheduling"
        return 1
    fi

    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supervisor-helper.sh"

    log_info "Watching $todo_file for changes..."
    log_info "Press Ctrl+C to stop"
    log_info "On change: auto-pickup + pulse"

    # Use fswatch with a 2-second latency to debounce rapid edits
    fswatch --latency 2 -o "$todo_file" | while read -r _count; do
        log_info "TODO.md changed, running auto-pickup + pulse..."
        "$script_path" auto-pickup --repo "$repo" 2>&1 || true
        "$script_path" pulse 2>&1 || true
        echo ""
    done

    return 0
}

#######################################
# TUI Dashboard - live-updating terminal UI for supervisor monitoring (t068.8)
#
# Renders a full-screen dashboard with:
#   - Header: batch name, uptime, refresh interval
#   - Task table: ID, status (color-coded), description, retries, PR URL
#   - Batch progress bar
#   - System resources: load, memory, worker processes
#   - Keyboard controls: q=quit, p=pause/resume, r=refresh, j/k=scroll
#
# Zero dependencies beyond bash + sqlite3 + tput (standard on macOS/Linux).
# Refreshes every N seconds (default 2). Reads from supervisor.db.
#######################################
cmd_dashboard() {
    local refresh_interval=2
    local batch_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval) [[ $# -lt 2 ]] && { log_error "--interval requires a value"; return 1; }; refresh_interval="$2"; shift 2 ;;
            --batch) [[ $# -lt 2 ]] && { log_error "--batch requires a value"; return 1; }; batch_filter="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_db

    # Terminal setup
    local term_cols term_rows
    term_cols=$(tput cols 2>/dev/null || echo 120)
    term_rows=$(tput lines 2>/dev/null || echo 40)

    # State
    local paused=false
    local scroll_offset=0
    local start_time
    start_time=$(date +%s)

    # Save terminal state and hide cursor
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    stty -echo -icanon min 0 time 0 2>/dev/null || true

    # Cleanup on exit
    _dashboard_cleanup() {
        tput rmcup 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        stty echo icanon 2>/dev/null || true
    }
    trap _dashboard_cleanup EXIT INT TERM

    # Color helpers using tput for portability
    local c_reset c_bold c_dim c_red c_green c_yellow c_blue c_cyan c_magenta c_white c_bg_black
    c_reset=$(tput sgr0 2>/dev/null || printf '\033[0m')
    c_bold=$(tput bold 2>/dev/null || printf '\033[1m')
    c_dim=$(tput dim 2>/dev/null || printf '\033[2m')
    c_red=$(tput setaf 1 2>/dev/null || printf '\033[31m')
    c_green=$(tput setaf 2 2>/dev/null || printf '\033[32m')
    c_yellow=$(tput setaf 3 2>/dev/null || printf '\033[33m')
    c_blue=$(tput setaf 4 2>/dev/null || printf '\033[34m')
    c_cyan=$(tput setaf 6 2>/dev/null || printf '\033[36m')
    c_white=$(tput setaf 7 2>/dev/null || printf '\033[37m')

    # Format elapsed time as Xh Xm Xs
    _fmt_elapsed() {
        local secs="$1"
        local h=$((secs / 3600))
        local m=$(( (secs % 3600) / 60 ))
        local s=$((secs % 60))
        if [[ "$h" -gt 0 ]]; then
            printf '%dh %dm %ds' "$h" "$m" "$s"
        elif [[ "$m" -gt 0 ]]; then
            printf '%dm %ds' "$m" "$s"
        else
            printf '%ds' "$s"
        fi
    }

    # Render a progress bar: _render_bar <current> <total> <width>
    _render_bar() {
        local current="$1" total="$2" width="${3:-30}"
        local filled=0
        if [[ "$total" -gt 0 ]]; then
            filled=$(( (current * width) / total ))
        fi
        local empty=$((width - filled))
        local pct=0
        if [[ "$total" -gt 0 ]]; then
            pct=$(( (current * 100) / total ))
        fi
        printf '%s' "${c_green}"
        local i
        for ((i = 0; i < filled; i++)); do printf '%s' "█"; done
        printf '%s' "${c_dim}"
        for ((i = 0; i < empty; i++)); do printf '%s' "░"; done
        printf '%s %3d%%' "${c_reset}" "$pct"
    }

    # Color for a task status
    _status_color() {
        local status="$1"
        case "$status" in
            running|dispatched) printf '%s' "${c_green}" ;;
            evaluating|retrying|pr_review|review_triage|merging|deploying|verifying) printf '%s' "${c_yellow}" ;;
            blocked|failed|verify_failed) printf '%s' "${c_red}" ;;
            complete|merged) printf '%s' "${c_cyan}" ;;
            deployed) printf '%s' "${c_green}${c_bold}" ;;
            verified) printf '%s' "${c_green}${c_bold}" ;;
            queued) printf '%s' "${c_white}" ;;
            cancelled) printf '%s' "${c_dim}" ;;
            *) printf '%s' "${c_reset}" ;;
        esac
    }

    # Status icon
    _status_icon() {
        local status="$1"
        case "$status" in
            running) printf '%s' ">" ;;
            dispatched) printf '%s' "~" ;;
            evaluating) printf '%s' "?" ;;
            retrying) printf '%s' "!" ;;
            complete) printf '%s' "+" ;;
            pr_review) printf '%s' "R" ;;
            review_triage) printf '%s' "T" ;;
            merging) printf '%s' "M" ;;
            merged) printf '%s' "=" ;;
            deploying) printf '%s' "D" ;;
            deployed) printf '%s' "*" ;;
            verifying) printf '%s' "V" ;;
            verified) printf '%s' "#" ;;
            verify_failed) printf '%s' "!" ;;
            blocked) printf '%s' "X" ;;
            failed) printf '%s' "x" ;;
            queued) printf '%s' "." ;;
            cancelled) printf '%s' "-" ;;
            *) printf '%s' " " ;;
        esac
    }

    # Truncate string to width
    _trunc() {
        local str="$1" max="$2"
        if [[ "${#str}" -gt "$max" ]]; then
            printf '%s' "${str:0:$((max - 1))}…"
        else
            printf '%-*s' "$max" "$str"
        fi
    }

    # Render one frame
    _render_frame() {
        # Refresh terminal size
        term_cols=$(tput cols 2>/dev/null || echo 120)
        term_rows=$(tput lines 2>/dev/null || echo 40)

        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        # Move cursor to top-left, clear screen
        tput home 2>/dev/null || printf '\033[H'
        tput ed 2>/dev/null || printf '\033[J'

        local line=0
        local max_lines=$((term_rows - 1))

        # === HEADER ===
        local header_left="SUPERVISOR DASHBOARD"
        local header_right
        if [[ "$paused" == "true" ]]; then
            header_right="[PAUSED] $(date '+%H:%M:%S') | up $(_fmt_elapsed "$elapsed")"
        else
            header_right="$(date '+%H:%M:%S') | up $(_fmt_elapsed "$elapsed") | refresh ${refresh_interval}s"
        fi
        local header_pad=$((term_cols - ${#header_left} - ${#header_right}))
        [[ "$header_pad" -lt 1 ]] && header_pad=1
        printf '%s%s%s%*s%s%s\n' "${c_bold}${c_cyan}" "$header_left" "${c_reset}" "$header_pad" "" "${c_dim}" "$header_right${c_reset}"
        line=$((line + 1))

        # Separator
        printf '%s' "${c_dim}"
        printf '%*s' "$term_cols" '' | tr ' ' '─'
        printf '%s\n' "${c_reset}"
        line=$((line + 1))

        # === BATCH SUMMARY ===
        local batch_where=""
        if [[ -n "$batch_filter" ]]; then
            batch_where="AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_filter")')"
        fi

        local counts
        counts=$(db "$SUPERVISOR_DB" "
            SELECT
                count(*) as total,
                sum(CASE WHEN t.status = 'queued' THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status IN ('dispatched','running') THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status = 'evaluating' THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status = 'retrying' THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status IN ('complete','pr_review','review_triage','merging','merged','deploying','deployed') THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status IN ('blocked','failed') THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status = 'cancelled' THEN 1 ELSE 0 END)
            FROM tasks t WHERE 1=1 $batch_where;
        " 2>/dev/null)

        local total queued active evaluating retrying finished errored cancelled
        IFS='|' read -r total queued active evaluating retrying finished errored cancelled <<< "$counts"
        total=${total:-0}; queued=${queued:-0}; active=${active:-0}
        evaluating=${evaluating:-0}; retrying=${retrying:-0}
        finished=${finished:-0}; errored=${errored:-0}; cancelled=${cancelled:-0}

        # Batch info line
        local batch_label="All Tasks"
        if [[ -n "$batch_filter" ]]; then
            local batch_name
            batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$(sql_escape "$batch_filter")';" 2>/dev/null || echo "$batch_filter")
            batch_label="Batch: ${batch_name:-$batch_filter}"
        fi

        printf ' %s%s%s  ' "${c_bold}" "$batch_label" "${c_reset}"
        printf '%s%d total%s | ' "${c_white}" "$total" "${c_reset}"
        printf '%s%d queued%s | ' "${c_white}" "$queued" "${c_reset}"
        printf '%s%d active%s | ' "${c_green}" "$active" "${c_reset}"
        printf '%s%d eval%s | ' "${c_yellow}" "$evaluating" "${c_reset}"
        printf '%s%d retry%s | ' "${c_yellow}" "$retrying" "${c_reset}"
        printf '%s%d done%s | ' "${c_cyan}" "$finished" "${c_reset}"
        printf '%s%d err%s' "${c_red}" "$errored" "${c_reset}"
        if [[ "$cancelled" -gt 0 ]]; then
            printf ' | %s%d cancel%s' "${c_dim}" "$cancelled" "${c_reset}"
        fi
        printf '\n'
        line=$((line + 1))

        # Progress bar
        local completed_for_bar=$((finished + cancelled))
        printf ' Progress: '
        _render_bar "$completed_for_bar" "$total" 40
        printf '  (%d/%d)\n' "$completed_for_bar" "$total"
        line=$((line + 1))

        # Separator
        printf '%s' "${c_dim}"
        printf '%*s' "$term_cols" '' | tr ' ' '─'
        printf '%s\n' "${c_reset}"
        line=$((line + 1))

        # === TASK TABLE ===
        # Column widths (adaptive to terminal width)
        local col_icon=3 col_id=8 col_status=12 col_retry=7 col_pr=0 col_error=0
        local col_desc_min=20
        local remaining=$((term_cols - col_icon - col_id - col_status - col_retry - 8))

        # Allocate PR column if any tasks have PR URLs
        local has_prs
        has_prs=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE pr_url IS NOT NULL AND pr_url != '' $batch_where;" 2>/dev/null || echo 0)
        if [[ "$has_prs" -gt 0 ]]; then
            col_pr=12
            remaining=$((remaining - col_pr))
        fi

        # Allocate error column if any tasks have errors
        local has_errors
        has_errors=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE error IS NOT NULL AND error != '' $batch_where;" 2>/dev/null || echo 0)
        if [[ "$has_errors" -gt 0 ]]; then
            col_error=25
            remaining=$((remaining - col_error))
        fi

        local col_desc=$remaining
        [[ "$col_desc" -lt "$col_desc_min" ]] && col_desc=$col_desc_min

        # Table header
        printf ' %s' "${c_bold}${c_dim}"
        printf '%-*s' "$col_icon" " "
        printf '%-*s' "$col_id" "TASK"
        printf '%-*s' "$col_status" "STATUS"
        printf '%-*s' "$col_desc" "DESCRIPTION"
        printf '%-*s' "$col_retry" "RETRY"
        [[ "$col_pr" -gt 0 ]] && printf '%-*s' "$col_pr" "PR"
        [[ "$col_error" -gt 0 ]] && printf '%-*s' "$col_error" "ERROR"
        printf '%s\n' "${c_reset}"
        line=$((line + 1))

        # Fetch tasks
        local tasks
        tasks=$(db -separator '	' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries,
                   COALESCE(t.pr_url, ''), COALESCE(t.error, '')
            FROM tasks t
            WHERE 1=1 $batch_where
            ORDER BY
                CASE t.status
                    WHEN 'running' THEN 1
                    WHEN 'dispatched' THEN 2
                    WHEN 'evaluating' THEN 3
                    WHEN 'retrying' THEN 4
                    WHEN 'queued' THEN 5
                    WHEN 'pr_review' THEN 6
                    WHEN 'review_triage' THEN 7
                    WHEN 'merging' THEN 8
                    WHEN 'deploying' THEN 9
                    WHEN 'blocked' THEN 10
                    WHEN 'failed' THEN 11
                    WHEN 'complete' THEN 12
                    WHEN 'merged' THEN 13
                    WHEN 'deployed' THEN 14
                    WHEN 'cancelled' THEN 15
                END, t.created_at ASC;
        " 2>/dev/null)

        local task_count=0
        local visible_start=$scroll_offset
        local visible_rows=$((max_lines - line - 6))
        [[ "$visible_rows" -lt 3 ]] && visible_rows=3

        if [[ -n "$tasks" ]]; then
            local task_idx=0
            while IFS='	' read -r tid tstatus tdesc tretries tmax tpr terror; do
                task_count=$((task_count + 1))
                if [[ "$task_idx" -lt "$visible_start" ]]; then
                    task_idx=$((task_idx + 1))
                    continue
                fi
                if [[ "$task_idx" -ge $((visible_start + visible_rows)) ]]; then
                    task_idx=$((task_idx + 1))
                    continue
                fi

                local sc
                sc=$(_status_color "$tstatus")
                local si
                si=$(_status_icon "$tstatus")

                printf ' %s%s%s ' "$sc" "$si" "${c_reset}"
                printf '%-*s' "$col_id" "$tid"
                printf '%s%-*s%s' "$sc" "$col_status" "$tstatus" "${c_reset}"
                _trunc "${tdesc:-}" "$col_desc"
                printf ' '
                if [[ "$tretries" -gt 0 ]]; then
                    printf '%s%d/%d%s' "${c_yellow}" "$tretries" "$tmax" "${c_reset}"
                    local pad=$((col_retry - ${#tretries} - ${#tmax} - 1))
                    [[ "$pad" -gt 0 ]] && printf '%*s' "$pad" ''
                else
                    printf '%-*s' "$col_retry" "0/$tmax"
                fi
                if [[ "$col_pr" -gt 0 ]]; then
                    if [[ -n "$tpr" ]]; then
                        local pr_num
                        pr_num=$(echo "$tpr" | grep -oE '[0-9]+$' || echo "$tpr")
                        printf ' %s#%-*s%s' "${c_blue}" $((col_pr - 2)) "$pr_num" "${c_reset}"
                    else
                        printf ' %-*s' "$col_pr" ""
                    fi
                fi
                if [[ "$col_error" -gt 0 && -n "$terror" ]]; then
                    printf ' %s' "${c_red}"
                    _trunc "$terror" "$col_error"
                    printf '%s' "${c_reset}"
                fi
                printf '\n'
                line=$((line + 1))
                task_idx=$((task_idx + 1))
            done <<< "$tasks"
        else
            printf ' %s(no tasks)%s\n' "${c_dim}" "${c_reset}"
            line=$((line + 1))
        fi

        # Scroll indicator
        if [[ "$task_count" -gt "$visible_rows" ]]; then
            local scroll_end=$((scroll_offset + visible_rows))
            [[ "$scroll_end" -gt "$task_count" ]] && scroll_end=$task_count
            printf ' %s[%d-%d of %d tasks]%s\n' "${c_dim}" "$((scroll_offset + 1))" "$scroll_end" "$task_count" "${c_reset}"
            line=$((line + 1))
        fi

        # === SYSTEM RESOURCES ===
        # Only show if we have room
        if [[ "$line" -lt $((max_lines - 4)) ]]; then
            printf '%s' "${c_dim}"
            printf '%*s' "$term_cols" '' | tr ' ' '─'
            printf '%s\n' "${c_reset}"
            line=$((line + 1))

            local load_output
            load_output=$(check_system_load 2>/dev/null || echo "")

            if [[ -n "$load_output" ]]; then
                local sys_cores sys_load1 sys_load5 sys_load15 sys_procs sys_sup_procs sys_mem sys_overloaded
                sys_cores=$(echo "$load_output" | grep '^cpu_cores=' | cut -d= -f2)
                sys_load1=$(echo "$load_output" | grep '^load_1m=' | cut -d= -f2)
                sys_load5=$(echo "$load_output" | grep '^load_5m=' | cut -d= -f2)
                sys_load15=$(echo "$load_output" | grep '^load_15m=' | cut -d= -f2)
                sys_procs=$(echo "$load_output" | grep '^process_count=' | cut -d= -f2)
                sys_sup_procs=$(echo "$load_output" | grep '^supervisor_process_count=' | cut -d= -f2)
                sys_mem=$(echo "$load_output" | grep '^memory_pressure=' | cut -d= -f2)
                sys_overloaded=$(echo "$load_output" | grep '^overloaded=' | cut -d= -f2)

                printf ' %sSYSTEM%s  ' "${c_bold}" "${c_reset}"
                printf 'Load: %s%s%s %s %s (%s cores)  ' \
                    "$([[ "$sys_overloaded" == "true" ]] && printf '%s' "${c_red}${c_bold}" || printf '%s' "${c_green}")" \
                    "$sys_load1" "${c_reset}" "$sys_load5" "$sys_load15" "$sys_cores"
                printf 'Procs: %s (%s supervisor)  ' "$sys_procs" "$sys_sup_procs"
                printf 'Mem: %s%s%s' \
                    "$([[ "$sys_mem" == "high" ]] && printf '%s' "${c_red}" || ([[ "$sys_mem" == "medium" ]] && printf '%s' "${c_yellow}" || printf '%s' "${c_green}"))" \
                    "$sys_mem" "${c_reset}"
                if [[ "$sys_overloaded" == "true" ]]; then
                    printf '  %s!! OVERLOADED !!%s' "${c_red}${c_bold}" "${c_reset}"
                fi
                printf '\n'
                line=$((line + 1))
            fi

            # Active workers with PIDs
            if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
                local worker_info=""
                local worker_count=0
                for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
                    [[ -f "$pid_file" ]] || continue
                    local wpid wtask_id
                    wpid=$(cat "$pid_file")
                    wtask_id=$(basename "$pid_file" .pid)
                    if kill -0 "$wpid" 2>/dev/null; then
                        worker_count=$((worker_count + 1))
                        if [[ -n "$worker_info" ]]; then
                            worker_info="$worker_info, "
                        fi
                        worker_info="${worker_info}${wtask_id}(pid:${wpid})"
                    fi
                done
                if [[ "$worker_count" -gt 0 ]]; then
                    printf ' %sWORKERS%s %d active: %s\n' "${c_bold}" "${c_reset}" "$worker_count" "$worker_info"
                    line=$((line + 1))
                fi
            fi
        fi

        # === FOOTER ===
        # Move to last line
        local footer_line=$((max_lines))
        tput cup "$footer_line" 0 2>/dev/null || printf '\033[%d;0H' "$footer_line"
        printf '%s q%s=quit  %sp%s=pause  %sr%s=refresh  %sj/k%s=scroll  %s?%s=help' \
            "${c_bold}" "${c_reset}" "${c_bold}" "${c_reset}" "${c_bold}" "${c_reset}" \
            "${c_bold}" "${c_reset}" "${c_bold}" "${c_reset}"
    }

    # Main loop
    while true; do
        if [[ "$paused" != "true" ]]; then
            _render_frame
        fi

        # Read keyboard input (non-blocking)
        local key=""
        local wait_count=0
        local wait_max=$((refresh_interval * 10))

        while [[ "$wait_count" -lt "$wait_max" ]]; do
            key=""
            read -rsn1 -t 0.1 key 2>/dev/null || true

            case "$key" in
                q|Q)
                    return 0
                    ;;
                p|P)
                    if [[ "$paused" == "true" ]]; then
                        paused=false
                    else
                        paused=true
                        # Show paused indicator
                        tput cup 0 $((term_cols - 10)) 2>/dev/null || true
                        printf '%s[PAUSED]%s' "${c_yellow}${c_bold}" "${c_reset}"
                    fi
                    ;;
                r|R)
                    _render_frame
                    wait_count=0
                    ;;
                j|J)
                    local max_task_count
                    max_task_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;" 2>/dev/null || echo 0)
                    if [[ "$scroll_offset" -lt $((max_task_count - 1)) ]]; then
                        scroll_offset=$((scroll_offset + 1))
                        _render_frame
                    fi
                    ;;
                k|K)
                    if [[ "$scroll_offset" -gt 0 ]]; then
                        scroll_offset=$((scroll_offset - 1))
                        _render_frame
                    fi
                    ;;
                '?')
                    tput home 2>/dev/null || printf '\033[H'
                    tput ed 2>/dev/null || printf '\033[J'
                    printf '%s%sSupervisor Dashboard Help%s\n\n' "${c_bold}" "${c_cyan}" "${c_reset}"
                    printf '  %sq%s     Quit dashboard\n' "${c_bold}" "${c_reset}"
                    printf '  %sp%s     Pause/resume auto-refresh\n' "${c_bold}" "${c_reset}"
                    printf '  %sr%s     Force refresh now\n' "${c_bold}" "${c_reset}"
                    printf '  %sj/k%s   Scroll task list down/up\n' "${c_bold}" "${c_reset}"
                    printf '  %s?%s     Show this help\n\n' "${c_bold}" "${c_reset}"
                    printf '%sStatus Icons:%s\n' "${c_bold}" "${c_reset}"
                    printf '  %s>%s running  %s~%s dispatched  %s?%s evaluating  %s!%s retrying\n' \
                        "${c_green}" "${c_reset}" "${c_green}" "${c_reset}" "${c_yellow}" "${c_reset}" "${c_yellow}" "${c_reset}"
                    printf '  %s+%s complete %s=%s merged      %s*%s deployed    %s.%s queued\n' \
                        "${c_cyan}" "${c_reset}" "${c_cyan}" "${c_reset}" "${c_green}" "${c_reset}" "${c_white}" "${c_reset}"
                    printf '  %sX%s blocked  %sx%s failed      %s-%s cancelled   %sR%s pr_review\n' \
                        "${c_red}" "${c_reset}" "${c_red}" "${c_reset}" "${c_dim}" "${c_reset}" "${c_yellow}" "${c_reset}"
                    printf '  %sT%s triage   %sM%s merging     %sD%s deploying\n\n' \
                        "${c_yellow}" "${c_reset}" "${c_yellow}" "${c_reset}" "${c_yellow}" "${c_reset}"
                    printf 'Press any key to return...'
                    read -rsn1 _ 2>/dev/null || true
                    _render_frame
                    wait_count=0
                    ;;
            esac

            wait_count=$((wait_count + 1))
        done
    done
}

#######################################
# Command: proof-log — query and export proof-logs (t218)
#
# Usage:
#   supervisor-helper.sh proof-log <task_id>              Show proof-log for a task
#   supervisor-helper.sh proof-log <task_id> --json       Export as JSON
#   supervisor-helper.sh proof-log <task_id> --timeline   Show stage timing timeline
#   supervisor-helper.sh proof-log --recent [N]           Show N most recent entries (default 20)
#   supervisor-helper.sh proof-log --stats                Show aggregate statistics
#######################################
cmd_proof_log() {
    local task_id="" format="table" mode="task" limit_n=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) format="json"; shift ;;
            --timeline) mode="timeline"; shift ;;
            --recent) mode="recent"; shift ;;
            --stats) mode="stats"; shift ;;
            --limit) limit_n="${2:-20}"; shift 2 ;;
            -*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$task_id" ]]; then
                    # Check if it's a number (for --recent N)
                    if [[ "$mode" == "recent" && "$1" =~ ^[0-9]+$ ]]; then
                        limit_n="$1"
                    else
                        task_id="$1"
                    fi
                fi
                shift
                ;;
        esac
    done

    ensure_db

    # Check if proof_logs table exists
    local has_table
    has_table=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='proof_logs';" 2>/dev/null || echo "0")
    if [[ "$has_table" -eq 0 ]]; then
        log_warn "No proof_logs table found. Run a pulse cycle to initialize."
        return 1
    fi

    case "$mode" in
        stats)
            echo "=== Proof-Log Statistics ==="
            echo ""
            local total_entries
            total_entries=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM proof_logs;" 2>/dev/null || echo "0")
            echo "Total entries: $total_entries"
            echo ""
            echo "Events by type:"
            db -column -header "$SUPERVISOR_DB" "
                SELECT event, count(*) as count
                FROM proof_logs
                GROUP BY event
                ORDER BY count DESC;
            " 2>/dev/null || true
            echo ""
            echo "Average stage durations (seconds):"
            db -column -header "$SUPERVISOR_DB" "
                SELECT stage, count(*) as samples,
                       CAST(avg(duration_secs) AS INTEGER) as avg_secs,
                       min(duration_secs) as min_secs,
                       max(duration_secs) as max_secs
                FROM proof_logs
                WHERE duration_secs IS NOT NULL AND duration_secs > 0
                GROUP BY stage
                ORDER BY avg_secs DESC;
            " 2>/dev/null || true
            echo ""
            echo "Tasks with most proof-log entries:"
            db -column -header "$SUPERVISOR_DB" "
                SELECT task_id, count(*) as entries,
                       min(timestamp) as first_event,
                       max(timestamp) as last_event
                FROM proof_logs
                GROUP BY task_id
                ORDER BY entries DESC
                LIMIT 10;
            " 2>/dev/null || true
            ;;

        recent)
            if [[ "$format" == "json" ]]; then
                echo "["
                local first=true
                while IFS='|' read -r pid ptask pevent pstage pdecision pevidence pmaker ppr pdur pmeta pts; do
                    [[ -z "$pid" ]] && continue
                    if [[ "$first" != "true" ]]; then echo ","; fi
                    first=false
                    local _esc_evidence="${pevidence:-}"
                    _esc_evidence="${_esc_evidence//\"/\\\"}"
                    local _esc_meta="${pmeta:-}"
                    _esc_meta="${_esc_meta//\"/\\\"}"
                    printf '  {"id":%s,"task_id":"%s","event":"%s","stage":"%s","decision":"%s","evidence":"%s","decision_maker":"%s","pr_url":"%s","duration_secs":%s,"metadata":"%s","timestamp":"%s"}' \
                        "$pid" "$ptask" "$pevent" "${pstage:-}" "${pdecision:-}" \
                        "$_esc_evidence" \
                        "${pmaker:-}" "${ppr:-}" "${pdur:-null}" \
                        "$_esc_meta" "$pts"
                done < <(db -separator '|' "$SUPERVISOR_DB" "
                    SELECT id, task_id, event, stage, decision, evidence,
                           decision_maker, pr_url, duration_secs, metadata, timestamp
                    FROM proof_logs
                    ORDER BY id DESC
                    LIMIT $limit_n;
                " 2>/dev/null)
                echo ""
                echo "]"
            else
                db -column -header "$SUPERVISOR_DB" "
                    SELECT id, task_id, event, stage, decision, decision_maker, duration_secs, timestamp
                    FROM proof_logs
                    ORDER BY id DESC
                    LIMIT $limit_n;
                " 2>/dev/null || true
            fi
            ;;

        timeline)
            if [[ -z "$task_id" ]]; then
                log_error "Usage: proof-log <task_id> --timeline"
                return 1
            fi
            local escaped_id
            escaped_id=$(sql_escape "$task_id")
            echo "=== Pipeline Timeline: $task_id ==="
            echo ""
            local entry_count=0
            while IFS='|' read -r pts pstage pevent pdecision pdur; do
                [[ -z "$pts" ]] && continue
                entry_count=$((entry_count + 1))
                local duration_label=""
                if [[ -n "$pdur" && "$pdur" != "" ]]; then
                    duration_label=" (${pdur}s)"
                fi
                printf "  %s  %-18s  %-15s  %s%s\n" "$pts" "${pstage:-—}" "$pevent" "${pdecision:-}" "$duration_label"
            done < <(db -separator '|' "$SUPERVISOR_DB" "
                SELECT timestamp, stage, event, decision, duration_secs
                FROM proof_logs
                WHERE task_id = '$escaped_id'
                ORDER BY id ASC;
            " 2>/dev/null)
            if [[ "$entry_count" -eq 0 ]]; then
                echo "  No proof-log entries found for $task_id"
            fi
            echo ""
            # Show total pipeline duration
            local first_ts last_ts
            first_ts=$(db "$SUPERVISOR_DB" "SELECT timestamp FROM proof_logs WHERE task_id = '$escaped_id' ORDER BY id ASC LIMIT 1;" 2>/dev/null || echo "")
            last_ts=$(db "$SUPERVISOR_DB" "SELECT timestamp FROM proof_logs WHERE task_id = '$escaped_id' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
            if [[ -n "$first_ts" && -n "$last_ts" && "$first_ts" != "$last_ts" ]]; then
                local first_epoch last_epoch
                first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_ts" "+%s" 2>/dev/null || date -d "$first_ts" "+%s" 2>/dev/null || echo "")
                last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null || date -d "$last_ts" "+%s" 2>/dev/null || echo "")
                if [[ -n "$first_epoch" && -n "$last_epoch" ]]; then
                    local total_secs=$((last_epoch - first_epoch))
                    local total_min=$((total_secs / 60))
                    echo "  Total pipeline duration: ${total_min}m ${total_secs}s (${total_secs}s)"
                fi
            fi
            ;;

        task)
            if [[ -z "$task_id" ]]; then
                log_error "Usage: proof-log <task_id> [--json|--timeline]"
                log_error "       proof-log --recent [N]"
                log_error "       proof-log --stats"
                return 1
            fi
            local escaped_id
            escaped_id=$(sql_escape "$task_id")

            if [[ "$format" == "json" ]]; then
                echo "["
                local first=true
                while IFS='|' read -r pid pevent pstage pdecision pevidence pmaker ppr pdur pmeta pts; do
                    [[ -z "$pid" ]] && continue
                    if [[ "$first" != "true" ]]; then echo ","; fi
                    first=false
                    local _esc_evidence="${pevidence:-}"
                    _esc_evidence="${_esc_evidence//\"/\\\"}"
                    local _esc_meta="${pmeta:-}"
                    _esc_meta="${_esc_meta//\"/\\\"}"
                    printf '  {"id":%s,"event":"%s","stage":"%s","decision":"%s","evidence":"%s","decision_maker":"%s","pr_url":"%s","duration_secs":%s,"metadata":"%s","timestamp":"%s"}' \
                        "$pid" "$pevent" "${pstage:-}" "${pdecision:-}" \
                        "$_esc_evidence" \
                        "${pmaker:-}" "${ppr:-}" "${pdur:-null}" \
                        "$_esc_meta" "$pts"
                done < <(db -separator '|' "$SUPERVISOR_DB" "
                    SELECT id, event, stage, decision, evidence,
                           decision_maker, pr_url, duration_secs, metadata, timestamp
                    FROM proof_logs
                    WHERE task_id = '$escaped_id'
                    ORDER BY id ASC;
                " 2>/dev/null)
                echo ""
                echo "]"
            else
                echo "=== Proof-Log: $task_id ==="
                echo ""
                db -column -header "$SUPERVISOR_DB" "
                    SELECT id, event, stage, decision, decision_maker, duration_secs, timestamp
                    FROM proof_logs
                    WHERE task_id = '$escaped_id'
                    ORDER BY id ASC;
                " 2>/dev/null || true
                echo ""
                local entry_count
                entry_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM proof_logs WHERE task_id = '$escaped_id';" 2>/dev/null || echo "0")
                echo "Total entries: $entry_count"
            fi
            ;;
    esac

    return 0
}

#######################################
# Show usage
#######################################
show_usage() {
    cat << 'EOF'
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
  supervisor-helper.sh self-heal <task_id>            Create diagnostic subtask for failed/blocked task
  supervisor-helper.sh worker-status <task_id>       Check worker process status
  supervisor-helper.sh cleanup [--dry-run]           Clean up completed worktrees
  supervisor-helper.sh update-todo <task_id>         Update TODO.md for completed/blocked task
  supervisor-helper.sh reconcile-todo [--batch id] [--dry-run]  Bulk-fix stale TODO.md entries
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
  supervisor-helper.sh cron [install|uninstall|status] Manage cron-based pulse scheduling
  supervisor-helper.sh watch [--repo path]            Watch TODO.md for changes (fswatch)
  supervisor-helper.sh dashboard [--batch id] [--interval N] Live TUI dashboard
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
  SUPERVISOR_AUTO_ISSUE       Enable/disable GitHub issue creation (default: true)
  SUPERVISOR_SKIP_REVIEW_TRIAGE Skip review triage before merge (default: false)
  SUPERVISOR_WORKER_TIMEOUT   Seconds before a hung worker is killed (default: 1800)
  AIDEVOPS_SUPERVISOR_DIR     Override supervisor data directory

Database: ~/.aidevops/.agent-workspace/supervisor/supervisor.db

Integration:
  - Workers: opencode run in worktrees (via full-loop)
  - Coordinator: coordinator-helper.sh (extends, doesn't replace)
  - Mail: mail-helper.sh for escalation
  - Memory: memory-helper.sh for cross-batch learning
  - Git: wt/worktree-helper.sh for isolation
  - TODO: auto-updates TODO.md on task completion/failure
  - GitHub: auto-creates issues on task add (t149)
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
  Disable: --no-issue flag on add, or SUPERVISOR_AUTO_ISSUE=false globally.

Cron Integration & Auto-Pickup (t128.5):
  Auto-pickup scans TODO.md for tasks to automatically queue:
    1. Tasks tagged with #auto-dispatch anywhere in the line
    2. Tasks listed under a "## Dispatch Queue" section header
  Both strategies skip tasks already tracked by the supervisor.

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
        self-heal) cmd_self_heal "$@" ;;
        worker-status) cmd_worker_status "$@" ;;
        cleanup) cmd_cleanup "$@" ;;
        kill-workers) cmd_kill_workers "$@" ;;
        update-todo) cmd_update_todo "$@" ;;
        reconcile-todo) cmd_reconcile_todo "$@" ;;
        notify) cmd_notify "$@" ;;
        auto-pickup) cmd_auto_pickup "$@" ;;
        cron) cmd_cron "$@" ;;
        watch) cmd_watch "$@" ;;
        dashboard) cmd_dashboard "$@" ;;
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
        help|--help|-h) show_usage ;;
        *) log_error "Unknown command: $command"; show_usage; return 1 ;;
    esac
}

main "$@"
