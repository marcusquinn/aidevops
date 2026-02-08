#!/usr/bin/env bash
# supervisor-helper.sh - Autonomous supervisor for multi-task orchestration
#
# Manages long-running parallel objectives from dispatch through completion.
# Token-efficient: bash + SQLite only, AI invoked only for evaluation decisions.
#
# Usage:
#   supervisor-helper.sh init                          Initialize supervisor database
#   supervisor-helper.sh add <task_id> [--repo path] [--description "desc"] [--model model] [--max-retries N]
#   supervisor-helper.sh batch <name> [--concurrency N] [--tasks "t001,t002,t003"]
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
#   supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
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
# Outcome evaluation (3-tier):
#   1. Deterministic: FULL_LOOP_COMPLETE/TASK_COMPLETE signals, EXIT codes
#   2. Heuristic: error pattern matching (rate limit, auth, conflict, OOM)
#   3. AI eval: Sonnet dispatch (~30s) for ambiguous outcomes
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
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    [[ -d "$_p" && ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
done
unset _p

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
export MAIL_HELPER MEMORY_HELPER SESSION_REVIEW_HELPER SESSION_DISTILL_HELPER

# Valid states for the state machine
readonly VALID_STATES="queued dispatched running evaluating retrying complete pr_review review_triage merging merged deploying deployed blocked failed cancelled"

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
    "deployed:cancelled"
)

readonly BOLD='\033[1m'

log_info() { echo -e "${BLUE}[SUPERVISOR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUPERVISOR]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[SUPERVISOR]${NC} $*"; }
log_error() { echo -e "${RED}[SUPERVISOR]${NC} $*" >&2; }

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
    # Check for stale lock before attempting acquisition
    if [[ -d "$PULSE_LOCK_DIR" ]]; then
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
            log_warn "Stale pulse lock detected (age: ${lock_age}s > timeout: ${PULSE_LOCK_TIMEOUT}s) — breaking lock"
            rm -rf "$PULSE_LOCK_DIR"
        fi
    fi

    # Atomic lock acquisition — mkdir is atomic on POSIX filesystems
    if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
        # Write PID for debugging
        echo $$ > "$PULSE_LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    # Lock held by another process — check if that process is still alive
    local holder_pid
    holder_pid=$(cat "$PULSE_LOCK_DIR/pid" 2>/dev/null || echo "")
    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
        log_warn "Pulse lock held by dead process (PID $holder_pid) — breaking lock"
        rm -rf "$PULSE_LOCK_DIR"
        if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
            echo $$ > "$PULSE_LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi
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
#   load_ratio                   - load_1m / cpu_cores (x100 for integer math)
#   process_count                - Total system processes
#   supervisor_process_count     - Processes spawned by supervisor workers
#   memory_pressure              - low|medium|high (macOS) or free MB (Linux)
#   overloaded                   - true|false (load_1m > cores * max_load_factor)
#
# $1 (optional): max load factor (default: 2, meaning load > cores*2 = overloaded)
#######################################
check_system_load() {
    local max_load_factor="${1:-2}"

    local cpu_cores
    cpu_cores=$(get_cpu_cores)
    echo "cpu_cores=$cpu_cores"

    # Load averages (cross-platform)
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

    # Load ratio (x100 for integer comparison: 200 = load is 2x cores)
    local load_ratio=0
    if [[ "$cpu_cores" -gt 0 ]]; then
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

    # Overloaded check: load_1m > cores * max_load_factor
    local threshold=$((cpu_cores * max_load_factor * 100))
    if [[ "$load_ratio" -gt "$threshold" ]]; then
        echo "overloaded=true"
    else
        echo "overloaded=false"
    fi

    return 0
}

#######################################
# Calculate adaptive concurrency based on system load (t135.15.2)
# Returns the recommended concurrency limit on stdout
#
# Strategy:
#   - If load < cores: full concurrency (no throttle)
#   - If load > cores but < cores*2: reduce by 50%
#   - If load > cores*2: reduce to minimum floor
#   - If memory pressure is high: reduce to minimum floor
#   - Minimum floor is 6 (macOS load averages are inflated by I/O-waiting
#     threads, so low minimums starve dispatch even at moderate CPU usage)
#
# $1: base concurrency (from batch or global default)
# $2: max load factor (default: 2)
#######################################
calculate_adaptive_concurrency() {
    local base_concurrency="${1:-4}"
    local max_load_factor="${2:-2}"
    local min_concurrency=6

    local load_output
    load_output=$(check_system_load "$max_load_factor")

    local cpu_cores load_ratio memory_pressure overloaded
    cpu_cores=$(echo "$load_output" | grep '^cpu_cores=' | cut -d= -f2)
    load_ratio=$(echo "$load_output" | grep '^load_ratio=' | cut -d= -f2)
    memory_pressure=$(echo "$load_output" | grep '^memory_pressure=' | cut -d= -f2)
    overloaded=$(echo "$load_output" | grep '^overloaded=' | cut -d= -f2)

    local effective_concurrency="$base_concurrency"

    # High memory pressure: drop to minimum floor
    if [[ "$memory_pressure" == "high" ]]; then
        effective_concurrency="$min_concurrency"
        echo "$effective_concurrency"
        return 0
    fi

    if [[ "$overloaded" == "true" ]]; then
        # Severely overloaded: minimum floor
        effective_concurrency="$min_concurrency"
    elif [[ "$load_ratio" -gt $((cpu_cores * 100)) ]]; then
        # Moderately loaded (load > cores but < cores*factor): halve concurrency
        effective_concurrency=$(( (base_concurrency + 1) / 2 ))
    fi

    # Enforce minimum floor
    if [[ "$effective_concurrency" -lt "$min_concurrency" ]]; then
        effective_concurrency="$min_concurrency"
    fi

    echo "$effective_concurrency"
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
# Backup supervisor database before destructive operations (t162)
# Creates timestamped copy in supervisor dir. Keeps last 5 backups.
# Usage: backup_db [reason]
#######################################
backup_db() {
    local reason="${1:-manual}"

    if [[ ! -f "$SUPERVISOR_DB" ]]; then
        log_warn "No database to backup at: $SUPERVISOR_DB"
        return 1
    fi

    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local backup_file="$SUPERVISOR_DIR/supervisor-backup-${timestamp}-${reason}.db"

    # Use SQLite .backup for consistency (handles WAL correctly)
    if sqlite3 "$SUPERVISOR_DB" ".backup '$backup_file'" 2>/dev/null; then
        log_success "Database backed up: $backup_file"
    else
        # Fallback to file copy if .backup fails
        if cp "$SUPERVISOR_DB" "$backup_file" 2>/dev/null; then
            # Also copy WAL/SHM if present
            [[ -f "${SUPERVISOR_DB}-wal" ]] && cp "${SUPERVISOR_DB}-wal" "${backup_file}-wal" 2>/dev/null || true
            [[ -f "${SUPERVISOR_DB}-shm" ]] && cp "${SUPERVISOR_DB}-shm" "${backup_file}-shm" 2>/dev/null || true
            log_success "Database backed up (file copy): $backup_file"
        else
            log_error "Failed to backup database"
            return 1
        fi
    fi

    # Prune old backups: keep last 5
    local backup_count
    # shellcheck disable=SC2012
    backup_count=$(ls -1 "$SUPERVISOR_DIR"/supervisor-backup-*.db 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$backup_count" -gt 5 ]]; then
        local to_remove
        to_remove=$((backup_count - 5))
        # shellcheck disable=SC2012
        ls -1t "$SUPERVISOR_DIR"/supervisor-backup-*.db 2>/dev/null | tail -n "$to_remove" | while IFS= read -r old_backup; do
            rm -f "$old_backup" "${old_backup}-wal" "${old_backup}-shm" 2>/dev/null || true
        done
        log_info "Pruned $to_remove old backup(s)"
    fi

    echo "$backup_file"
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
    local check_sql
    check_sql=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
    if [[ -n "$check_sql" ]] && ! echo "$check_sql" | grep -q 'pr_review'; then
        log_info "Migrating database schema for post-PR lifecycle states (t128.8)..."
        backup_db "pre-migrate-t128.8" >/dev/null 2>&1 || log_warn "Backup failed, proceeding with migration"

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
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','blocked','failed','cancelled')),
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
        log_success "Database schema migrated for post-PR lifecycle states"
    fi

    # Backup before ALTER TABLE migrations if any are needed (t162)
    local needs_alter_migration=false
    local has_max_load has_release_on_complete has_diagnostic_of has_issue_url
    has_max_load=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='max_load_factor';" 2>/dev/null || echo "0")
    has_release_on_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='release_on_complete';" 2>/dev/null || echo "0")
    has_diagnostic_of=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='diagnostic_of';" 2>/dev/null || echo "0")
    has_issue_url=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='issue_url';" 2>/dev/null || echo "0")
    if [[ "$has_max_load" -eq 0 || "$has_release_on_complete" -eq 0 || "$has_diagnostic_of" -eq 0 || "$has_issue_url" -eq 0 ]]; then
        needs_alter_migration=true
    fi
    if [[ "$needs_alter_migration" == "true" ]]; then
        backup_db "pre-migrate-alter-columns" >/dev/null 2>&1 || log_warn "Backup failed, proceeding with migrations"
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
        backup_db "pre-migrate-t148" >/dev/null 2>&1 || log_warn "Backup failed, proceeding with migration"
        db "$SUPERVISOR_DB" << 'MIGRATE_T148'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old_t148;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','blocked','failed','cancelled')),
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
        log_success "Database schema migrated for review_triage state"
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
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','blocked','failed','cancelled')),
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

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);

CREATE TABLE IF NOT EXISTS batches (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    concurrency     INTEGER NOT NULL DEFAULT 4,
    max_load_factor INTEGER NOT NULL DEFAULT 2,
    release_on_complete INTEGER NOT NULL DEFAULT 0,
    release_type    TEXT NOT NULL DEFAULT 'patch'
                    CHECK(release_type IN ('major','minor','patch')),
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
    local skip_issue=false

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
            --no-issue) skip_issue=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

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
            description=$(grep -E "^- \[( |x|-)\] $task_id " "$todo_file" 2>/dev/null | head -1 | sed -E 's/^- \[( |x|-)\] [^ ]* //' || true)
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

    # Create GitHub issue unless opted out (t149)
    if [[ "$skip_issue" == "false" ]]; then
        local issue_number
        issue_number=$(create_github_issue "$task_id" "$description" "$repo")
        if [[ -n "$issue_number" ]]; then
            update_todo_with_issue_ref "$task_id" "$issue_number" "$repo"
        fi
    fi

    return 0
}

#######################################
# Create or manage a batch
#######################################
cmd_batch() {
    local name="" concurrency=4 tasks="" max_load_factor=2
    local release_on_complete=0 release_type="patch"

    # First positional arg is batch name
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        name="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --concurrency) [[ $# -lt 2 ]] && { log_error "--concurrency requires a value"; return 1; }; concurrency="$2"; shift 2 ;;
            --tasks) [[ $# -lt 2 ]] && { log_error "--tasks requires a value"; return 1; }; tasks="$2"; shift 2 ;;
            --max-load) [[ $# -lt 2 ]] && { log_error "--max-load requires a value"; return 1; }; max_load_factor="$2"; shift 2 ;;
            --release-on-complete) release_on_complete=1; shift ;;
            --release-type) [[ $# -lt 2 ]] && { log_error "--release-type requires a value"; return 1; }; release_type="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$name" ]]; then
        log_error "Usage: supervisor-helper.sh batch <name> [--concurrency N] [--tasks \"t001,t002\"] [--release-on-complete] [--release-type patch|minor|major]"
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
        INSERT INTO batches (id, name, concurrency, max_load_factor, release_on_complete, release_type)
        VALUES ('$escaped_id', '$escaped_name', $concurrency, $max_load_factor, $release_on_complete, '$escaped_release_type');
    "

    local release_info=""
    if [[ "$release_on_complete" -eq 1 ]]; then
        release_info=", release: $release_type on complete"
    fi
    log_success "Created batch: $name (id: $batch_id, concurrency: $concurrency, max-load: $max_load_factor${release_info})"

    # Add tasks to batch if provided
    if [[ -n "$tasks" ]]; then
        local position=0
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
    if [[ "$new_state" == "complete" || "$new_state" == "deployed" || "$new_state" == "failed" || "$new_state" == "cancelled" ]]; then
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
            AND t.status NOT IN ('complete', 'deployed', 'merged', 'failed', 'cancelled');
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
                evaluating|retrying|pr_review|review_triage|merging|deploying) color="$YELLOW" ;;
                blocked|failed) color="$RED" ;;
                complete|merged) color="$CYAN" ;;
                deployed) color="$GREEN" ;;
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
        local brelease_flag brelease_type
        IFS='|' read -r bid bname bconc bstatus bcreated brelease_flag brelease_type <<< "$batch_row"
        echo -e "${BOLD}=== Batch: $bname ===${NC}"
        echo "  ID:          $bid"
        echo "  Status:      $bstatus"
        echo "  Concurrency: $bconc"
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
                evaluating|retrying|pr_review|review_triage|merging|deploying) color="$YELLOW" ;;
                blocked|failed) color="$RED" ;;
                complete|merged) color="$CYAN" ;;
                deployed) color="$GREEN" ;;
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
                evaluating|retrying|pr_review|review_triage|merging|deploying) color="$YELLOW" ;;
                blocked|failed) color="$RED" ;;
                complete|merged) color="$CYAN" ;;
                deployed) color="$GREEN" ;;
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
# Claim a task via GitHub Issue assignee (t164)
# Uses GitHub as distributed lock — works across machines
#######################################
cmd_claim() {
    local task_id="${1:-}"

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh claim <task_id>"
        return 1
    fi

    # Find the GitHub issue number from TODO.md
    local project_root
    project_root=$(find_project_root 2>/dev/null || echo ".")
    local todo_file="$project_root/TODO.md"
    local issue_number=""

    if [[ -f "$todo_file" ]]; then
        local task_line
        task_line=$(grep -E "^\- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
    fi

    if [[ -z "$issue_number" ]]; then
        log_error "No GitHub issue found for $task_id (missing ref:GH# in TODO.md)"
        return 1
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")
    if [[ -z "$repo_slug" ]]; then
        log_error "Cannot detect repo slug"
        return 1
    fi

    # Check current assignee
    local current_assignee
    current_assignee=$(gh api "repos/$repo_slug/issues/$issue_number" --jq '.assignee.login // empty' 2>/dev/null || echo "")

    if [[ -n "$current_assignee" ]]; then
        local my_login
        my_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
        if [[ "$current_assignee" == "$my_login" ]]; then
            log_info "$task_id already claimed by you (GH#$issue_number)"
            return 0
        fi
        log_error "$task_id is claimed by @$current_assignee (GH#$issue_number)"
        return 1
    fi

    # Assign to self
    if gh issue edit "$issue_number" --repo "$repo_slug" --add-assignee "@me" 2>/dev/null; then
        log_success "Claimed $task_id (GH#$issue_number assigned to you)"

        # Add status label if it exists
        gh issue edit "$issue_number" --repo "$repo_slug" --add-label "status:claimed" --remove-label "status:available" 2>/dev/null || true

        return 0
    else
        log_error "Failed to claim $task_id (GH#$issue_number)"
        return 1
    fi
}

#######################################
# Release a claimed task (t164)
#######################################
cmd_unclaim() {
    local task_id="${1:-}"

    if [[ -z "$task_id" ]]; then
        log_error "Usage: supervisor-helper.sh unclaim <task_id>"
        return 1
    fi

    local project_root
    project_root=$(find_project_root 2>/dev/null || echo ".")
    local todo_file="$project_root/TODO.md"
    local issue_number=""

    if [[ -f "$todo_file" ]]; then
        local task_line
        task_line=$(grep -E "^\- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
    fi

    if [[ -z "$issue_number" ]]; then
        log_error "No GitHub issue found for $task_id"
        return 1
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")

    local my_login
    my_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

    if gh issue edit "$issue_number" --repo "$repo_slug" --remove-assignee "$my_login" 2>/dev/null; then
        log_success "Released $task_id (GH#$issue_number unassigned)"
        gh issue edit "$issue_number" --repo "$repo_slug" --add-label "status:available" --remove-label "status:claimed" 2>/dev/null || true
        return 0
    else
        log_error "Failed to release $task_id"
        return 1
    fi
}

#######################################
# Check if a task is claimed by someone else (t164)
# Returns 0 if free or claimed by self, 1 if claimed by another
#######################################
check_task_claimed() {
    local task_id="${1:-}"
    local project_root="${2:-.}"
    local todo_file="$project_root/TODO.md"
    local issue_number=""

    if [[ -f "$todo_file" ]]; then
        local task_line
        task_line=$(grep -E "^\- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
    fi

    # No issue = no claim mechanism = free
    if [[ -z "$issue_number" ]]; then
        return 0
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")
    if [[ -z "$repo_slug" ]]; then
        return 0
    fi

    local current_assignee
    current_assignee=$(gh api "repos/$repo_slug/issues/$issue_number" --jq '.assignee.login // empty' 2>/dev/null || echo "")

    if [[ -z "$current_assignee" ]]; then
        return 0
    fi

    local my_login
    my_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

    if [[ "$current_assignee" == "$my_login" ]]; then
        return 0
    fi

    echo "$current_assignee"
    return 1
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
#######################################
cmd_next() {
    local batch_id="${1:-}" limit="${2:-1}"

    ensure_db

    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")

        # Check concurrency limit with adaptive load awareness (t151)
        local base_concurrency max_load_factor
        base_concurrency=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
        max_load_factor=$(db "$SUPERVISOR_DB" "SELECT max_load_factor FROM batches WHERE id = '$escaped_batch';")
        local concurrency
        concurrency=$(calculate_adaptive_concurrency "${base_concurrency:-4}" "${max_load_factor:-2}")
        local active_count
        active_count=$(cmd_running_count "$batch_id")

        local available=$((concurrency - active_count))
        if [[ "$available" -le 0 ]]; then
            return 0
        fi
        if [[ "$available" -lt "$limit" ]]; then
            limit="$available"
        fi

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
# Priority: Anthropic SOTA via opencode (only supported CLI)
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

    case "$tier" in
        coding)
            # Best Anthropic model - primary for all code tasks
            echo "anthropic/claude-opus-4-6"
            ;;
        eval|health)
            # Fast + cheap for evaluation and health probes
            # Note: OpenCode requires full model IDs (e.g., claude-sonnet-4-5, not claude-sonnet-4)
            echo "anthropic/claude-sonnet-4-5"
            ;;
    esac

    return 0
}

#######################################
# Pre-dispatch model health check
# Sends a trivial prompt to verify the model/provider is responding.
# Returns 0 if healthy, 1 if unhealthy. Timeout: 15 seconds.
# Result is cached for 5 minutes to avoid repeated probes.
#######################################
check_model_health() {
    local ai_cli="$1"
    local model="${2:-}"

    # Pulse-level fast path: if health was already verified in this pulse
    # invocation, skip the probe entirely (avoids 8s per task)
    if [[ -n "${_PULSE_HEALTH_VERIFIED:-}" ]]; then
        log_info "Model health: pulse-verified OK (skipping probe)"
        return 0
    fi

    # Cache key: cli + model, stored as a file with timestamp
    local cache_dir="$SUPERVISOR_DIR/health"
    mkdir -p "$cache_dir"
    local cache_key="${ai_cli}-${model//\//_}"
    local cache_file="$cache_dir/${cache_key}"

    # Check cache (valid for 300 seconds / 5 minutes)
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

    # Resolve timeout command (macOS lacks coreutils timeout)
    local timeout_cmd=""
    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout"
    fi

    # Send a trivial prompt
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
            # Fallback: background process with manual kill after 15s
            local probe_pid probe_tmpfile
            probe_tmpfile=$(mktemp)
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
                probe_exit=124  # Simulate timeout exit code
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

    # Check for known failure patterns
    # NOTE: Patterns must not match inside JSON fields (e.g. timestamps contain digits
    # like "1770503..." which falsely matched bare "503"). Use word boundaries or
    # anchored patterns. The probe returns JSON lines from opencode run --format json.
    if echo "$probe_result" | grep -qiE 'endpoints failed|Quota protection|over[_ -]?usage|quota reset|"status":[[:space:]]*503|HTTP 503|503 Service|service unavailable' 2>/dev/null; then
        log_warn "Model health check FAILED: provider error detected"
        return 1
    fi

    # Timeout (exit 124) = unhealthy
    if [[ "$probe_exit" -eq 124 ]]; then
        log_warn "Model health check FAILED: timeout (15s)"
        return 1
    fi

    # Empty response with non-zero exit = unhealthy
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
    local prompt="/full-loop $task_id"
    if [[ -n "$description" ]]; then
        prompt="/full-loop $task_id -- $description"
    fi
    if [[ -n "$memory_context" ]]; then
        prompt="$prompt

$memory_context"
    fi

    if [[ "$ai_cli" == "opencode" ]]; then
        echo "opencode"
        echo "run"
        echo "--format"
        echo "json"
        if [[ -n "$model" ]]; then
            echo "-m"
            echo "$model"
        fi
        echo "--title"
        echo "$task_id"
        echo "$prompt"
    else
        # claude CLI
        echo "claude"
        echo "-p"
        echo "$prompt"
        if [[ -n "$model" ]]; then
            echo "--model"
            echo "$model"
        fi
        echo "--output-format"
        echo "json"
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

    local branch_name="feature/${task_id}"
    # Derive worktree path: ~/Git/repo-name.feature-tXXX (matches wt convention)
    local repo_basename
    repo_basename=$(basename "$repo")
    local repo_parent
    repo_parent=$(dirname "$repo")
    local worktree_path="${repo_parent}/${repo_basename}.feature-${task_id}"

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        log_info "Worktree already exists: $worktree_path" >&2
        echo "$worktree_path"
        return 0
    fi

    # Try wt first (redirect its verbose output to stderr)
    if command -v wt &>/dev/null; then
        if wt switch -c "$branch_name" -C "$repo" >&2 2>&1; then
            echo "$worktree_path"
            return 0
        fi
    fi

    # Fallback: raw git worktree add (quiet, reliable)
    if git -C "$repo" worktree add "$worktree_path" -b "$branch_name" >&2 2>&1; then
        echo "$worktree_path"
        return 0
    fi

    # Branch may already exist (retry without -b)
    if git -C "$repo" worktree add "$worktree_path" "$branch_name" >&2 2>&1; then
        echo "$worktree_path"
        return 0
    fi

    log_error "Failed to create worktree for $task_id at $worktree_path"
    return 1
}

#######################################
# Clean up a worktree for a completed/failed task
#######################################
cleanup_task_worktree() {
    local worktree_path="$1"
    local repo="$2"

    if [[ ! -d "$worktree_path" ]]; then
        return 0
    fi

    # Try wt prune first
    if command -v wt &>/dev/null; then
        wt remove -C "$repo" "$worktree_path" 2>>"$SUPERVISOR_LOG" && return 0
    fi

    # Fallback: git worktree remove
    git -C "$repo" worktree remove "$worktree_path" --force 2>>"$SUPERVISOR_LOG" || true
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

    # Check if task is claimed by someone else on GitHub (t164)
    local claimed_by=""
    claimed_by=$(check_task_claimed "$task_id" "${trepo:-.}" 2>/dev/null) || true
    if [[ -n "$claimed_by" ]]; then
        log_warn "Task $task_id is claimed by @$claimed_by on GitHub — skipping dispatch"
        return 2
    fi

    # Claim the task on GitHub before dispatching (t164)
    cmd_claim "$task_id" 2>/dev/null || log_verbose "Could not claim $task_id on GitHub (no issue ref or gh unavailable)"

    # Check concurrency limit with adaptive load awareness (t151)
    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")
        local base_concurrency max_load_factor
        base_concurrency=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
        max_load_factor=$(db "$SUPERVISOR_DB" "SELECT max_load_factor FROM batches WHERE id = '$escaped_batch';")
        local concurrency
        concurrency=$(calculate_adaptive_concurrency "${base_concurrency:-4}" "${max_load_factor:-2}")
        local active_count
        active_count=$(cmd_running_count "$batch_id")

        if [[ "$active_count" -ge "$concurrency" ]]; then
            log_warn "Concurrency limit reached ($active_count/$concurrency, base:$base_concurrency) for batch $batch_id"
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

    # Pre-dispatch model health check - use cheap health-tier model to verify
    # the provider is responding before creating worktrees and burning retries
    local health_model
    health_model=$(resolve_model "health" "$ai_cli")
    if ! check_model_health "$ai_cli" "$health_model"; then
        log_error "Provider health check failed for $task_id ($health_model via $ai_cli)"
        log_error "Provider may be down or quota exhausted. Skipping dispatch."
        return 3  # Return 3 = provider unavailable (distinct from concurrency limit 2)
    fi

    # Create worktree
    log_info "Creating worktree for $task_id..."
    local worktree_path
    worktree_path=$(create_task_worktree "$task_id" "$trepo") || {
        log_error "Failed to create worktree for $task_id"
        cmd_transition "$task_id" "failed" --error "Worktree creation failed"
        return 1
    }

    local branch_name="feature/${task_id}"

    # Set up log file
    local log_dir="$SUPERVISOR_DIR/logs"
    mkdir -p "$log_dir"
    local log_file
    log_file="$log_dir/${task_id}-$(date +%Y%m%d%H%M%S).log"

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

    log_info "Dispatching $task_id via $ai_cli ($dispatch_mode mode)"
    log_info "Worktree: $worktree_path"
    log_info "Log: $log_file"

    # Build and execute dispatch command
    local -a cmd_parts=()
    while IFS= read -r part; do
        cmd_parts+=("$part")
    done < <(build_dispatch_cmd "$task_id" "$worktree_path" "$log_file" "$ai_cli" "$memory_context" "$tmodel" "$tdesc")

    # Ensure PID directory exists before dispatch
    mkdir -p "$SUPERVISOR_DIR/pids"

    if [[ "$dispatch_mode" == "tabby" ]]; then
        # Tabby: attempt to open in a new tab via OSC 1337 escape sequence
        log_info "Opening Tabby tab for $task_id..."
        local tab_cmd
        tab_cmd="cd '${worktree_path}' && ${cmd_parts[*]} > '${log_file}' 2>&1; echo \"EXIT:\$?\" >> '${log_file}'"
        printf '\e]1337;NewTab=%s\a' "$tab_cmd" 2>/dev/null || true
        # Also start background process as fallback (Tabby may not support OSC 1337)
        # Use nohup + disown to survive parent (cron) exit
        nohup bash -c "cd '${worktree_path}' && $(printf '%q ' "${cmd_parts[@]}") > '${log_file}' 2>&1; echo \"EXIT:\$?\" >> '${log_file}'" &>/dev/null &
    else
        # Headless: background process
        # Use nohup + disown to survive parent (cron) exit — without this,
        # workers die after ~2 minutes when the cron pulse script exits
        nohup bash -c "cd '${worktree_path}' && $(printf '%q ' "${cmd_parts[@]}") > '${log_file}' 2>&1; echo \"EXIT:\$?\" >> '${log_file}'" &>/dev/null &
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

    # Completion signals
    if grep -q 'FULL_LOOP_COMPLETE' "$log_file" 2>/dev/null; then
        echo "signal=FULL_LOOP_COMPLETE"
    elif grep -q 'TASK_COMPLETE' "$log_file" 2>/dev/null; then
        echo "signal=TASK_COMPLETE"
    else
        echo "signal=none"
    fi

    # PR URL: NOT extracted from log content (t151)
    # Log grep picks up any PR URL mentioned in worker context (memory recalls,
    # TODO reads, git log), causing wrong PR URLs on tasks. Authoritative lookup
    # via gh pr list --head is done in evaluate_worker() and check_pr_status().
    echo "pr_url="

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
    backend_error_count=$(grep -ci 'endpoints failed\|Antigravity\|gateway[[:space:]].*error\|service unavailable\|HTTP 503\|503 Service\|"status":[[:space:]]*503\|Quota protection\|over[_ -]\{0,1\}usage\|quota reset' "$log_tail_file" 2>/dev/null || echo 0)

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
# Evaluate a completed worker's outcome using log analysis
# Returns: complete:<detail>, retry:<reason>, blocked:<reason>, failed:<reason>
#
# Three-tier evaluation:
#   1. Deterministic: check for known signals and error patterns
#   2. Heuristic: analyze exit codes and error counts
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
        SELECT status, log_file, retries, max_retries, session_id
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tstatus tlog tretries tmax_retries tsession
    IFS='|' read -r tstatus tlog tretries tmax_retries tsession <<< "$task_row"

    if [[ -z "$tlog" || ! -f "$tlog" ]]; then
        echo "failed:no_log_file"
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

    # Fallback PR URL detection: if log didn't contain a PR URL, check GitHub
    # for a PR matching the task's branch. Tries the DB branch column first
    # (actual worktree branch), then falls back to feature/${task_id} convention.
    # This fixes the clean_exit_no_signal retry loop (t161): workers that create
    # a PR and exit 0 were retried because the branch name didn't match the
    # hardcoded feature/${task_id} pattern.
    if [[ -z "$meta_pr_url" ]]; then
        local task_repo task_branch
        task_repo=$(sqlite3 "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
        task_branch=$(sqlite3 "$SUPERVISOR_DB" "SELECT branch FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
        if [[ -n "$task_repo" ]]; then
            local repo_slug_detect
            repo_slug_detect=$(git -C "$task_repo" remote get-url origin 2>/dev/null | grep -oE '[^/:]+/[^/.]+' | tail -1 || echo "")
            if [[ -n "$repo_slug_detect" ]]; then
                # Try DB branch first (actual worktree branch name)
                if [[ -n "$task_branch" ]]; then
                    meta_pr_url=$(gh pr list --repo "$repo_slug_detect" --head "$task_branch" --json url --jq '.[0].url' 2>>"$SUPERVISOR_LOG" || echo "")
                fi
                # Fallback to convention: feature/${task_id}
                if [[ -z "$meta_pr_url" ]]; then
                    meta_pr_url=$(gh pr list --repo "$repo_slug_detect" --head "feature/${task_id}" --json url --jq '.[0].url' 2>>"$SUPERVISOR_LOG" || echo "")
                fi
            fi
        fi
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
    if [[ "$meta_signal" == "TASK_COMPLETE" && "$meta_exit_code" == "0" ]]; then
        echo "complete:task_only"
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
    # Antigravity down). A short log (< 10 lines) with backend errors means the
    # worker never started - this is NOT content discussion, it's a real failure.
    # Must be checked BEFORE clean_exit_no_signal to avoid wasting retries.
    if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
        local meta_log_lines
        meta_log_lines=$(_meta_get "log_lines" "0")
        if [[ "$meta_backend_error_count" -gt 0 && "$meta_log_lines" -lt 10 ]]; then
            echo "retry:backend_quota_error"
            return 0
        fi
    fi

    # Clean exit with no completion signal and no PR = likely incomplete
    # but NOT an error - the agent finished cleanly, just didn't emit a signal.
    # This should retry (agent may have run out of context or hit a soft limit).
    if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
        echo "retry:clean_exit_no_signal"
        return 0
    fi

    # --- Tier 2: Heuristic error pattern matching ---
    # ONLY applied when exit code is non-zero or missing.
    # When exit=0, the agent finished cleanly - any "error" strings in the log
    # are content (e.g., subagents documenting auth flows), not real failures.

    if [[ "$meta_exit_code" != "0" ]]; then
        # Backend infrastructure error (Antigravity, quota, API gateway) = transient retry
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

    # Pre-reprompt health check: avoid wasting retry attempts on dead backends
    # (t153-pre-diag-1: retries 1+2 failed instantly with "All Antigravity
    # endpoints failed" because reprompt skipped the health check that
    # cmd_dispatch performs)
    local health_model
    health_model=$(resolve_model "health" "$ai_cli")
    if ! check_model_health "$ai_cli" "$health_model"; then
        log_error "Provider health check failed for $task_id re-prompt ($health_model via $ai_cli) — deferring retry"
        # Task is already in 'retrying' state with counter incremented.
        # Do NOT transition again (would double-increment). Return 75 (EX_TEMPFAIL)
        # so the pulse cycle can distinguish transient backend failures from real
        # reprompt failures and leave the task in retrying state for the next pulse.
        return 75
    fi

    # Build re-prompt message with context about the failure
    local reprompt_msg
    if [[ -n "$prompt_override" ]]; then
        reprompt_msg="$prompt_override"
    else
        reprompt_msg="The previous attempt for task $task_id encountered an issue: ${terror:-unknown error}.

Please continue the /full-loop for $task_id. Pick up where the previous attempt left off.
If the task was partially completed, verify what's done and continue from there.
If it failed entirely, start fresh with /full-loop $task_id.

Task description: ${tdesc:-$task_id}"
    fi

    # Set up log file for this retry attempt
    local log_dir="$SUPERVISOR_DIR/logs"
    mkdir -p "$log_dir"
    local new_log_file
    new_log_file="$log_dir/${task_id}-retry${tretries}-$(date +%Y%m%d%H%M%S).log"

    # Determine working directory
    local work_dir="$trepo"
    if [[ -n "$tworktree" && -d "$tworktree" ]]; then
        work_dir="$tworktree"
    fi

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

    # Use nohup + disown to survive parent (cron) exit
    nohup bash -c "cd '${work_dir}' && $(printf '%q ' "${cmd_parts[@]}") > '${new_log_file}' 2>&1; echo \"EXIT:\$?\" >> '${new_log_file}'" &>/dev/null &
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

    # Set up log file
    local log_dir="$SUPERVISOR_DIR/logs"
    mkdir -p "$log_dir"
    local log_file
    log_file="$log_dir/${task_id}-review-fix-$(date +%Y%m%d%H%M%S).log"

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

    nohup bash -c "cd '${work_dir}' && $(printf '%q ' "${cmd_parts[@]}") > '${log_file}' 2>&1; echo \"EXIT:\$?\" >> '${log_file}'" &>/dev/null &
    local worker_pid=$!
    disown "$worker_pid" 2>/dev/null || true

    echo "$worker_pid" > "$SUPERVISOR_DIR/pids/${task_id}.pid"

    cmd_transition "$task_id" "running" --session "pid:$worker_pid" 2>>"$SUPERVISOR_LOG" || true

    log_success "Dispatched review fix worker for $task_id (PID: $worker_pid, $fix_count threads)"
    return 0
}

#######################################
# Check PR CI and review status for a task
# Returns: ready_to_merge, ci_pending, ci_failed, changes_requested, draft, no_pr
#######################################
check_pr_status() {
    local task_id="$1"

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$task_id")
    local pr_url
    pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';")

    # If no PR URL stored, try to find one via branch name lookup.
    # Check DB branch column first (actual worktree branch), then fall back
    # to feature/${task_id} convention. Mirrors evaluate_worker() fix (t161).
    if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
        local task_repo_check
        task_repo_check=$(sqlite3 "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
        if [[ -n "$task_repo_check" ]]; then
            local repo_slug_check
            repo_slug_check=$(git -C "$task_repo_check" remote get-url origin 2>/dev/null | grep -oE '[^/:]+/[^/.]+' | tail -1 || echo "")
            if [[ -n "$repo_slug_check" ]]; then
                local found_pr_url
                # Try DB branch first (actual worktree branch name)
                local task_branch_check
                task_branch_check=$(sqlite3 "$SUPERVISOR_DB" "SELECT branch FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
                if [[ -n "$task_branch_check" ]]; then
                    found_pr_url=$(gh pr list --repo "$repo_slug_check" --head "$task_branch_check" --json url --jq '.[0].url' 2>>"$SUPERVISOR_LOG" || echo "")
                fi
                # Fallback to convention: feature/${task_id}
                if [[ -z "${found_pr_url:-}" ]]; then
                    found_pr_url=$(gh pr list --repo "$repo_slug_check" --head "feature/${task_id}" --json url --jq '.[0].url' 2>>"$SUPERVISOR_LOG" || echo "")
                fi
                if [[ -n "$found_pr_url" ]]; then
                    pr_url="$found_pr_url"
                    log_cmd "db-update-pr-url" sqlite3 "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$found_pr_url")' WHERE id = '$escaped_id';" || log_warn "Failed to persist PR URL for $task_id"
                else
                    echo "no_pr"
                    return 0
                fi
            else
                echo "no_pr"
                return 0
            fi
        else
            echo "no_pr"
            return 0
        fi
    fi

    # Extract owner/repo and PR number from URL
    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
    local repo_slug
    repo_slug=$(echo "$pr_url" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||' || echo "")

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
            ci_status="failed"
        elif [[ "$has_pending" -gt 0 ]]; then
            ci_status="pending"
        fi
    fi

    if [[ "$ci_status" == "failed" ]]; then
        echo "ci_failed"
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
        echo "changes_requested"
        return 0
    fi

    # CI passed, no blocking reviews
    echo "ready_to_merge"
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

    local pr_number
    pr_number=$(echo "$tpr" | grep -oE '[0-9]+$' || echo "")
    local repo_slug
    repo_slug=$(echo "$tpr" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||' || echo "")

    if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
        log_error "Cannot parse PR URL: $tpr"
        return 1
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] Would merge PR #$pr_number in $repo_slug (squash)"
        return 0
    fi

    log_info "Merging PR #$pr_number in $repo_slug (squash)..."

    # Squash merge without --delete-branch (worktree handles branch cleanup)
    local merge_output
    if ! merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash 2>&1); then
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
# Run deploy for a task (aidevops repos only: setup.sh)
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

    if [[ ! -x "$repo/setup.sh" ]]; then
        log_warn "setup.sh not found or not executable in $repo"
        return 0
    fi

    log_info "Running setup.sh for $task_id (timeout: 300s)..."
    local deploy_output deploy_log
    deploy_log="$SUPERVISOR_DIR/logs/${task_id}-deploy-$(date +%Y%m%d%H%M%S).log"
    mkdir -p "$SUPERVISOR_DIR/logs"

    # Portable timeout: prefer timeout/gtimeout, fall back to background+kill
    local timeout_cmd=""
    if command -v timeout &>/dev/null; then
        timeout_cmd="timeout 300"
    elif command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout 300"
    fi

    if [[ -n "$timeout_cmd" ]]; then
        if ! deploy_output=$(cd "$repo" && $timeout_cmd ./setup.sh 2>&1); then
            log_warn "Deploy (setup.sh) returned non-zero for $task_id (see $deploy_log)"
            echo "$deploy_output" > "$deploy_log" 2>/dev/null || true
            return 1
        fi
    else
        # Fallback: background process with manual timeout
        (cd "$repo" && ./setup.sh > "$deploy_log" 2>&1) &
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
# Command: pr-lifecycle - handle full post-PR lifecycle for a task
# Checks CI, triages review threads, merges, runs postflight, deploys, cleans up worktree
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

    echo -e "${BOLD}=== Post-PR Lifecycle: $task_id ===${NC}"
    echo "  Status:   $tstatus"
    echo "  PR:       ${tpr:-none}"
    echo "  Repo:     $trepo"
    echo "  Worktree: ${tworktree:-none}"

    # Step 1: Transition to pr_review if still in complete
    if [[ "$tstatus" == "complete" ]]; then
        if [[ -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ]]; then
            # Before marking deployed, try to find a PR via gh pr list
            local found_pr=""
            if [[ -n "$trepo" ]]; then
                local repo_slug_lifecycle
                repo_slug_lifecycle=$(git -C "$trepo" remote get-url origin 2>/dev/null | grep -oE '[^/:]+/[^/.]+' | tail -1 || echo "")
                if [[ -n "$repo_slug_lifecycle" ]]; then
                    found_pr=$(gh pr list --repo "$repo_slug_lifecycle" --head "feature/${task_id}" --json url --jq '.[0].url' 2>>"$SUPERVISOR_LOG" || echo "")
                fi
            fi
            if [[ -n "$found_pr" ]]; then
                log_info "Found PR for $task_id via branch lookup: $found_pr"
                if [[ "$dry_run" == "false" ]]; then
                    sqlite3 "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$found_pr")' WHERE id = '$escaped_id';"
                    tpr="$found_pr"
                fi
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
        local pr_status
        pr_status=$(check_pr_status "$task_id")
        log_info "PR status: $pr_status"

        case "$pr_status" in
            ready_to_merge)
                # CI passed and no CHANGES_REQUESTED - but bot reviews post as
                # COMMENTED, so we need to check unresolved threads directly (t148)
                if [[ "$skip_review_triage" == "true" ]]; then
                    log_info "Review triage skipped (--skip-review-triage) for $task_id"
                    if [[ "$dry_run" == "false" ]]; then
                        cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
                    fi
                    tstatus="merging"
                else
                    if [[ "$dry_run" == "false" ]]; then
                        cmd_transition "$task_id" "review_triage" 2>>"$SUPERVISOR_LOG" || true
                    fi
                    tstatus="review_triage"
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
                log_info "PR is still a draft for $task_id"
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
    fi

    # Step 2b: Review triage - check unresolved threads and classify (t148)
    if [[ "$tstatus" == "review_triage" ]]; then
        # Extract PR number and repo slug for GraphQL query
        local pr_number_triage
        pr_number_triage=$(echo "$tpr" | grep -oE '[0-9]+$' || echo "")
        local repo_slug_triage
        repo_slug_triage=$(echo "$tpr" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||' || echo "")

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
    fi

    # Step 3: Merge
    if [[ "$tstatus" == "merging" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[dry-run] Would merge PR for $task_id"
        else
            if merge_task_pr "$task_id" "$dry_run"; then
                cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
                tstatus="merged"
            else
                cmd_transition "$task_id" "blocked" --error "Merge failed" 2>>"$SUPERVISOR_LOG" || true
                send_task_notification "$task_id" "blocked" "PR merge failed" 2>>"$SUPERVISOR_LOG" || true
                return 1
            fi
        fi
    fi

    # Step 4: Postflight + Deploy
    if [[ "$tstatus" == "merged" ]]; then
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

            # Final transition
            cmd_transition "$task_id" "deployed" || log_warn "Failed to transition $task_id to deployed"

            # Notify (best-effort, suppress errors)
            send_task_notification "$task_id" "deployed" "PR merged, deployed, worktree cleaned" 2>>"$SUPERVISOR_LOG" || true
            store_success_pattern "$task_id" "deployed" "" 2>>"$SUPERVISOR_LOG" || true
        else
            log_info "[dry-run] Would deploy and clean up for $task_id"
        fi
    fi

    log_success "Post-PR lifecycle complete for $task_id (status: $(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo 'unknown'))"
    return 0
}

#######################################
# Process post-PR lifecycle for all eligible tasks
# Called as Phase 4 of the pulse cycle
# Finds tasks in complete/pr_review/merging/merged states with PR URLs
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

    while IFS='|' read -r tid tstatus tpr; do
        # Skip tasks without PRs that are already complete
        if [[ "$tstatus" == "complete" && ( -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ) ]]; then
            # No PR - transition directly to deployed
            cmd_transition "$tid" "deployed" 2>>"$SUPERVISOR_LOG" || true
            deployed_count=$((deployed_count + 1))
            log_info "  $tid: no PR, marked deployed"
            continue
        fi

        log_info "  $tid: processing post-PR lifecycle (status: $tstatus)"
        if cmd_pr_lifecycle "$tid" >> "$SUPERVISOR_DIR/post-pr.log" 2>&1; then
            local new_status
            new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
            case "$new_status" in
                merged) merged_count=$((merged_count + 1)) ;;
                deployed) deployed_count=$((deployed_count + 1)) ;;
            esac
        fi
        processed=$((processed + 1))
    done <<< "$eligible_tasks"

    if [[ "$processed" -gt 0 ]]; then
        log_info "Post-PR lifecycle: processed $processed tasks (merged: $merged_count, deployed: $deployed_count)"
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

            case "$outcome_type" in
                complete)
                    log_success "  $tid: COMPLETE ($outcome_detail)"
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

    # Phase 5: Summary
    local total_running
    total_running=$(cmd_running_count "${batch_id:-}")
    local total_queued
    total_queued=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'queued';")
    local total_complete
    total_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('complete', 'deployed');")
    local total_pr_review
    total_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('pr_review', 'review_triage', 'merging', 'merged', 'deploying');")

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
        echo -e "  ${BLUE}[SUPERVISOR]${NC}   Load:     ${load_color}${sys_load_1m}${NC} / ${sys_load_5m} (${sys_cpu_cores} cores, ratio: ${sys_load_ratio}%)"
        echo -e "  ${BLUE}[SUPERVISOR]${NC}   Memory:   ${mem_color}${sys_memory}${NC}"
        echo -e "  ${BLUE}[SUPERVISOR]${NC}   Procs:    ${sys_proc_count} total, ${sys_supervisor_procs} supervisor"
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
                complete|failed|cancelled|blocked|deployed|pr_review|review_triage|merging|merged|deploying)
                    cleanup_worker_processes "$cleanup_tid" 2>/dev/null || true
                    orphan_killed=$((orphan_killed + 1))
                    ;;
            esac
        done
    fi
    if [[ "$orphan_killed" -gt 0 ]]; then
        log_info "  Cleaned:    $orphan_killed stale worker processes"
    fi

    # Phase 7: Reconcile TODO.md for any stale tasks (t160)
    # Runs when completed tasks exist and nothing is actively running/queued
    if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 && "$total_complete" -gt 0 ]]; then
        cmd_reconcile_todo ${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
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
        AND status IN ('deployed', 'merged', 'failed', 'cancelled');
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

    if [[ "$dry_run" == "false" ]]; then
        log_success "Cleaned up $cleaned worktrees, $process_cleaned worker processes"
    fi

    return 0
}

#######################################
# Create a GitHub issue for a task
# Delegates to issue-sync-helper.sh for rich issue bodies with PLANS.md context.
# Falls back to inline creation if helper is unavailable.
# Returns the issue number on success, empty on failure
# Requires: gh CLI authenticated, repo with GitHub remote
#######################################
create_github_issue() {
    local task_id="$1"
    local description="$2"
    local repo_path="$3"

    # Check if auto-issue is disabled
    if [[ "${SUPERVISOR_AUTO_ISSUE:-true}" == "false" ]]; then
        log_info "GitHub issue creation disabled (SUPERVISOR_AUTO_ISSUE=false)"
        return 0
    fi

    # Verify gh CLI is available and authenticated
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not found, skipping GitHub issue creation"
        return 0
    fi

    if ! gh auth status &>/dev/null 2>&1; then
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

    # Try delegating to issue-sync-helper.sh for rich issue bodies
    local issue_sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
    if [[ -x "$issue_sync_helper" ]]; then
        log_info "Delegating issue creation to issue-sync-helper.sh for $task_id"
        local push_output
        push_output=$("$issue_sync_helper" push "$task_id" --repo "$repo_slug" 2>>"$SUPERVISOR_LOG" || echo "")
        # Extract issue number from push output (looks for "Created #NNN:")
        local issue_number
        issue_number=$(echo "$push_output" | grep -oE 'Created #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
        if [[ -n "$issue_number" ]]; then
            log_success "Created GitHub issue #${issue_number} for $task_id via issue-sync-helper.sh"
            local escaped_id
            escaped_id=$(sql_escape "$task_id")
            local escaped_url="https://github.com/${repo_slug}/issues/${issue_number}"
            escaped_url=$(sql_escape "$escaped_url")
            db "$SUPERVISOR_DB" "UPDATE tasks SET issue_url = '$escaped_url' WHERE id = '$escaped_id';"
            echo "$issue_number"
            return 0
        fi
        log_warn "issue-sync-helper.sh did not return issue number, falling back to inline creation"
    fi

    # Fallback: inline issue creation (bare-bones body)
    local issue_title="${task_id}: ${description}"
    local issue_body="Created by supervisor-helper.sh during task dispatch."
    local todo_file="$repo_path/TODO.md"
    if [[ -f "$todo_file" ]]; then
        local todo_context
        todo_context=$(grep -E "^[[:space:]]*- \[( |x|-)\] ${task_id}( |$)" "$todo_file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$todo_context" ]]; then
            issue_body="From TODO.md:\n\n\`\`\`\n${todo_context}\n\`\`\`\n\nCreated by supervisor-helper.sh during task dispatch."
        fi
    fi

    local labels=""
    if echo "$description" | grep -qiE "bug|fix"; then
        labels="bug"
    elif echo "$description" | grep -qiE "feat|enhancement|add"; then
        labels="enhancement"
    fi

    local gh_args=("issue" "create" "--repo" "$repo_slug" "--title" "$issue_title" "--body" "$(printf '%b' "$issue_body")")
    if [[ -n "$labels" ]]; then
        gh_args+=("--label" "$labels")
    fi

    local issue_url
    issue_url=$(gh "${gh_args[@]}" 2>>"$SUPERVISOR_LOG" || echo "")

    if [[ -z "$issue_url" ]]; then
        log_warn "Failed to create GitHub issue for $task_id"
        return 0
    fi

    local issue_number
    issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")

    if [[ -n "$issue_number" ]]; then
        log_success "Created GitHub issue #${issue_number} for $task_id: $issue_url"
        local escaped_id
        escaped_id=$(sql_escape "$task_id")
        local escaped_url
        escaped_url=$(sql_escape "$issue_url")
        db "$SUPERVISOR_DB" "UPDATE tasks SET issue_url = '$escaped_url' WHERE id = '$escaped_id';"
        echo "$issue_number"
    fi

    return 0
}

#######################################
# Update TODO.md to add ref:GH#N for a task
# Appends the GitHub issue reference to the task line
# Then commits and pushes the change
#######################################
update_todo_with_issue_ref() {
    local task_id="$1"
    local issue_number="$2"
    local repo_path="$3"

    local todo_file="$repo_path/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        log_warn "TODO.md not found at $todo_file"
        return 0
    fi

    # Check if ref:GH# already exists on this task line
    if grep -qE "^[[:space:]]*- \[( |x|-)\] ${task_id} .*ref:GH#" "$todo_file"; then
        log_info "Task $task_id already has a GitHub issue reference in TODO.md"
        return 0
    fi

    # Find the task line and append ref:GH#N
    # Insert before any trailing date fields or at end of line
    local line_num
    line_num=$(grep -nE "^[[:space:]]*- \[( |x|-)\] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1)

    if [[ -z "$line_num" ]]; then
        log_warn "Task $task_id not found in $todo_file"
        return 0
    fi

    # Append ref:GH#N to the task line (before any logged: or started: timestamps if present)
    local task_line
    task_line=$(sed -n "${line_num}p" "$todo_file")

    local new_line
    if echo "$task_line" | grep -qE " logged:"; then
        # Insert ref:GH#N before logged:
        new_line=$(echo "$task_line" | sed -E "s/ logged:/ ref:GH#${issue_number} logged:/")
    elif echo "$task_line" | grep -qE " started:"; then
        # Insert ref:GH#N before started:
        new_line=$(echo "$task_line" | sed -E "s/ started:/ ref:GH#${issue_number} started:/")
    else
        # Append at end
        new_line="${task_line} ref:GH#${issue_number}"
    fi

    sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"

    # Verify the change
    if ! grep -qE "^[[:space:]]*- \[( |x|-)\] ${task_id} .*ref:GH#${issue_number}" "$todo_file"; then
        log_warn "Failed to add ref:GH#${issue_number} to $task_id in TODO.md"
        return 0
    fi

    log_success "Added ref:GH#${issue_number} to $task_id in TODO.md"

    commit_and_push_todo "$repo_path" "chore: add GH#${issue_number} ref to $task_id in TODO.md"
    return $?
}

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
# Update TODO.md when a task completes
# Marks the task checkbox as [x], adds completed:YYYY-MM-DD
# Then commits and pushes the change
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
            local memory_type="FAILED_APPROACH"
            ;;
        retry)
            # Only store retry patterns if they indicate a recurring issue
            # Skip transient ones like rate_limited, timeout, interrupted
            case "$outcome_detail" in
                rate_limited|timeout|interrupted_sigint|killed_sigkill|terminated_sigterm)
                    return 0
                    ;;
            esac
            local memory_type="ERROR_FIX"
            ;;
        *)
            return 0
            ;;
    esac

    local content="Supervisor task $task_id ($outcome_type): $outcome_detail"
    if [[ -n "$description" ]]; then
        content="$content | Task: $description"
    fi

    "$MEMORY_HELPER" store \
        --auto \
        --type "$memory_type" \
        --content "$content" \
        --tags "supervisor,$task_id,$outcome_type,$outcome_detail" \
        2>/dev/null || true

    log_info "Stored failure pattern in memory: $task_id ($outcome_type: $outcome_detail)"
    return 0
}

#######################################
# Store a success pattern in memory after task completion
# Records what worked for future reference
#######################################
store_success_pattern() {
    local task_id="$1"
    local detail="${2:-}"
    local description="${3:-}"

    if [[ ! -x "$MEMORY_HELPER" ]]; then
        return 0
    fi

    local content="Supervisor task $task_id completed successfully"
    if [[ -n "$detail" && "$detail" != "no_pr" ]]; then
        content="$content | PR: $detail"
    fi
    if [[ -n "$description" ]]; then
        content="$content | Task: $description"
    fi

    # Get retry count for context
    local retries=0
    retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo 0)
    if [[ "$retries" -gt 0 ]]; then
        content="$content | Succeeded after $retries retries"
    fi

    "$MEMORY_HELPER" store \
        --auto \
        --type "WORKING_SOLUTION" \
        --content "$content" \
        --tags "supervisor,$task_id,complete" \
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
    case "$failure_reason" in
        auth_error|merge_conflict|out_of_memory|no_log_file|max_retries)
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
        complete|deployed|merged)
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

    # Find completed/deployed/merged tasks
    local where_clause="t.status IN ('complete', 'deployed', 'merged')"
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
            evaluating|retrying|pr_review|review_triage|merging|deploying) printf '%s' "${c_yellow}" ;;
            blocked|failed) printf '%s' "${c_red}" ;;
            complete|merged) printf '%s' "${c_cyan}" ;;
            deployed) printf '%s' "${c_green}${c_bold}" ;;
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
  supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
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

Outcome Evaluation (3-tier):
  1. Deterministic: FULL_LOOP_COMPLETE/TASK_COMPLETE signals, EXIT codes
  2. Heuristic: error pattern matching (rate limit, auth, conflict, OOM, timeout)
  3. AI eval: Sonnet dispatch (~30s) for ambiguous outcomes

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

Options for 'add':
  --repo <path>          Repository path (default: current directory)
  --description "desc"   Task description (auto-detected from TODO.md)
  --model <model>        AI model (default: anthropic/claude-opus-4-6)
  --max-retries <N>      Max retry attempts (default: 3)
  --no-issue             Skip GitHub issue creation for this task

Options for 'batch':
  --concurrency <N>      Max parallel workers (default: 4)
  --tasks "t001,t002"    Comma-separated task IDs to add
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

  Automatic: pulse cycle Phase 3 processes all eligible tasks each run
  Manual commands:
    supervisor-helper.sh pr-check <task_id>              # Check CI/review status
    supervisor-helper.sh pr-merge <task_id> [--dry-run]  # Merge PR
    supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage] # Full lifecycle

  CI pending tasks are retried on the next pulse (no state change).
  CI failures and review rejections transition to 'blocked' for human action.

Options for 'pr-lifecycle':
  --dry-run              Show what would happen without executing

Options for 'pr-check':
  (no options)           Shows PR CI and review status

Options for 'pr-merge':
  --dry-run              Show what would happen without executing

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
        pr-merge) cmd_pr_merge "$@" ;;
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
