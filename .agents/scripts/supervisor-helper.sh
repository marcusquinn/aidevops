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
#   supervisor-helper.sh notify <task_id>              Send notification about task state
#   supervisor-helper.sh recall <task_id>              Recall memories relevant to a task
#   supervisor-helper.sh retrospective [batch_id]      Run batch retrospective and store insights
#   supervisor-helper.sh status [task_id|batch_id]     Show task/batch/overall status
#   supervisor-helper.sh transition <task_id> <new_state> [--error "reason"]
#   supervisor-helper.sh list [--state queued|running|...] [--batch name] [--format json]
#   supervisor-helper.sh reset <task_id>               Reset task to queued state
#   supervisor-helper.sh cancel <task_id|batch_id>     Cancel task or batch
#   supervisor-helper.sh auto-pickup [--repo path]      Scan TODO.md for #auto-dispatch tasks
#   supervisor-helper.sh cron [install|uninstall|status] Manage cron-based pulse scheduling
#   supervisor-helper.sh watch [--repo path]            Watch TODO.md for changes (fswatch)
#   supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] Handle post-PR merge/deploy lifecycle
#   supervisor-helper.sh pr-check <task_id>             Check PR CI/review status
#   supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
#   supervisor-helper.sh db [sql]                      Direct SQLite access
#   supervisor-helper.sh help
#
# State machine:
#   queued -> dispatched -> running -> evaluating -> complete
#                                   -> retrying   -> reprompt -> dispatched (retry cycle)
#                                   -> blocked    (needs human input / max retries)
#                                   -> failed     (dispatch failure / unrecoverable)
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

set -euo pipefail

# Ensure common tool paths are available (cron has minimal PATH: /usr/bin:/bin)
# Without this, gh, opencode, node, etc. are unreachable from cron-triggered pulses
if [[ -z "${HOMEBREW_PREFIX:-}" ]]; then
    for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.cargo/bin"; do
        [[ -d "$_p" && ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
    done
    unset _p
fi

# Configuration - resolve relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
readonly SUPERVISOR_DB="$SUPERVISOR_DIR/supervisor.db"
readonly MAIL_HELPER="${SCRIPT_DIR}/mail-helper.sh"       # Used by pulse command (t128.2)
readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"   # Used by pulse command (t128.6)
export MAIL_HELPER MEMORY_HELPER

# Valid states for the state machine
readonly VALID_STATES="queued dispatched running evaluating retrying complete pr_review merging merged deploying deployed blocked failed cancelled"

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
    "pr_review:merging"
    "pr_review:blocked"
    "pr_review:cancelled"
    "merging:merged"
    "merging:blocked"
    "merging:failed"
    "merged:deploying"
    "merged:deployed"
    "deploying:deployed"
    "deploying:failed"
    "deployed:cancelled"
)

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[SUPERVISOR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUPERVISOR]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[SUPERVISOR]${NC} $*"; }
log_error() { echo -e "${RED}[SUPERVISOR]${NC} $*" >&2; }

# Cross-platform sed in-place edit (macOS vs GNU/Linux)
sed_inplace() { if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

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

    # Supervisor worker process count (opencode/claude spawned by supervisor)
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
        # macOS: use memory_pressure command or vm_stat
        local pressure="low"
        local vm_output
        vm_output=$(vm_stat 2>/dev/null || echo "")
        if [[ -n "$vm_output" ]]; then
            local pages_free pages_active pages_inactive page_size
            page_size=$(vm_stat 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "16384")
            pages_free=$(echo "$vm_output" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
            pages_active=$(echo "$vm_output" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
            pages_inactive=$(echo "$vm_output" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
            local free_mb=0
            if [[ -n "$pages_free" && -n "$page_size" ]]; then
                free_mb=$(( (pages_free * page_size) / 1048576 ))
            fi
            if [[ "$free_mb" -lt 512 ]]; then
                pressure="high"
            elif [[ "$free_mb" -lt 2048 ]]; then
                pressure="medium"
            fi
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
#   - If load > cores*2: reduce to 1 (minimum)
#   - If memory pressure is high: reduce to 1
#
# $1: base concurrency (from batch or global default)
# $2: max load factor (default: 2)
#######################################
calculate_adaptive_concurrency() {
    local base_concurrency="${1:-4}"
    local max_load_factor="${2:-2}"

    local load_output
    load_output=$(check_system_load "$max_load_factor")

    local cpu_cores load_ratio memory_pressure overloaded
    cpu_cores=$(echo "$load_output" | grep '^cpu_cores=' | cut -d= -f2)
    load_ratio=$(echo "$load_output" | grep '^load_ratio=' | cut -d= -f2)
    memory_pressure=$(echo "$load_output" | grep '^memory_pressure=' | cut -d= -f2)
    overloaded=$(echo "$load_output" | grep '^overloaded=' | cut -d= -f2)

    local effective_concurrency="$base_concurrency"

    # High memory pressure: drop to 1
    if [[ "$memory_pressure" == "high" ]]; then
        effective_concurrency=1
        echo "$effective_concurrency"
        return 0
    fi

    if [[ "$overloaded" == "true" ]]; then
        # Severely overloaded: minimum concurrency
        effective_concurrency=1
    elif [[ "$load_ratio" -gt $((cpu_cores * 100)) ]]; then
        # Moderately loaded (load > cores but < cores*factor): halve concurrency
        effective_concurrency=$(( (base_concurrency + 1) / 2 ))
        if [[ "$effective_concurrency" -lt 1 ]]; then
            effective_concurrency=1
        fi
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
        db "$SUPERVISOR_DB" << 'MIGRATE'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','merging','merged','deploying','deployed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks SELECT * FROM tasks_old;
DROP TABLE tasks_old;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE
        log_success "Database schema migrated for post-PR lifecycle states"
    fi

    # Migrate: add max_load_factor column to batches if missing (t135.15.4)
    local has_max_load
    has_max_load=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='max_load_factor';" 2>/dev/null || echo "0")
    if [[ "$has_max_load" -eq 0 ]]; then
        log_info "Migrating batches table: adding max_load_factor column (t135.15.4)..."
        db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN max_load_factor INTEGER NOT NULL DEFAULT 2;" 2>/dev/null || true
        log_success "Added max_load_factor column to batches"
    fi

    # Ensure WAL mode for existing databases created before t135.3
    local current_mode
    current_mode=$(db "$SUPERVISOR_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
    if [[ "$current_mode" != "wal" ]]; then
        db "$SUPERVISOR_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || true
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
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','merging','merged','deploying','deployed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);

CREATE TABLE IF NOT EXISTS batches (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    concurrency     INTEGER NOT NULL DEFAULT 4,
    max_load_factor INTEGER NOT NULL DEFAULT 2,
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
# Add a task to the supervisor
#######################################
cmd_add() {
    local task_id="" repo="" description="" model="anthropic/claude-opus-4-6" max_retries=3

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
    return 0
}

#######################################
# Create or manage a batch
#######################################
cmd_batch() {
    local name="" concurrency=4 tasks="" max_load_factor=2

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
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$name" ]]; then
        log_error "Usage: supervisor-helper.sh batch <name> [--concurrency N] [--tasks \"t001,t002\"]"
        return 1
    fi

    ensure_db

    local batch_id
    batch_id="batch-$(date +%Y%m%d%H%M%S)-$$"
    local escaped_id
    escaped_id=$(sql_escape "$batch_id")
    local escaped_name
    escaped_name=$(sql_escape "$name")

    db "$SUPERVISOR_DB" "
        INSERT INTO batches (id, name, concurrency, max_load_factor)
        VALUES ('$escaped_id', '$escaped_name', $concurrency, $max_load_factor);
    "

    log_success "Created batch: $name (id: $batch_id, concurrency: $concurrency, max-load: $max_load_factor)"

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
            run_batch_retrospective "$batch_id" 2>/dev/null || true
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
                WHEN 'blocked' THEN 6
                WHEN 'failed' THEN 7
                WHEN 'complete' THEN 8
                WHEN 'cancelled' THEN 9
            END;
        " 2>/dev/null | while IFS=': ' read -r state count; do
            local color="$NC"
            case "$state" in
                running|dispatched) color="$GREEN" ;;
                evaluating|retrying|pr_review|merging|deploying) color="$YELLOW" ;;
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
                    WHERE bt.batch_id = b.id AND t.status = 'complete') as done_count
            FROM batches b ORDER BY b.created_at DESC LIMIT 10;
        ")

        if [[ -n "$batches" ]]; then
            while IFS='|' read -r bid bname bconc bstatus btotal bdone; do
                echo -e "  ${CYAN}$bname${NC} ($bid) [$bstatus] $bdone/$btotal tasks, concurrency:$bconc"
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
        SELECT id, name, concurrency, status, created_at
        FROM batches WHERE id = '$(sql_escape "$target")' OR name = '$(sql_escape "$target")';
    ")

    if [[ -n "$batch_row" ]]; then
        IFS='|' read -r bid bname bconc bstatus bcreated <<< "$batch_row"
        echo -e "${BOLD}=== Batch: $bname ===${NC}"
        echo "  ID:          $bid"
        echo "  Status:      $bstatus"
        echo "  Concurrency: $bconc"
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
                evaluating|retrying|pr_review|merging|deploying) color="$YELLOW" ;;
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
                    WHEN 'blocked' THEN 6
                    WHEN 'failed' THEN 7
                    WHEN 'complete' THEN 8
                    WHEN 'cancelled' THEN 9
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
                evaluating|retrying|pr_review|merging|deploying) color="$YELLOW" ;;
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

        # Check concurrency limit
        local concurrency
        concurrency=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
        local active_count
        active_count=$(cmd_running_count "$batch_id")

        local available=$((concurrency - active_count))
        if [[ "$available" -le 0 ]]; then
            return 0
        fi
        if [[ "$available" -lt "$limit" ]]; then
            limit="$available"
        fi

        db -separator '|' "$SUPERVISOR_DB" "
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
        db -separator '|' "$SUPERVISOR_DB" "
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
# Prefers opencode, falls back to claude
#######################################
resolve_ai_cli() {
    # Prefer opencode (supports Anthropic auth + zen free models as fallback)
    if command -v opencode &>/dev/null; then
        echo "opencode"
        return 0
    fi
    if command -v claude &>/dev/null; then
        echo "claude"
        return 0
    fi
    log_error "Neither opencode nor claude CLI found. Install one to dispatch workers."
    return 1
}

#######################################
# Resolve the best available model for a given task tier
# Priority: Anthropic SOTA via opencode > claude CLI > opencode zen free
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
    if echo "$probe_result" | grep -qi 'endpoints failed\|Quota protection\|over.*usage\|quota reset\|503\|service unavailable' 2>/dev/null; then
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

    local prompt="/full-loop $task_id"
    if [[ -n "$memory_context" ]]; then
        prompt="/full-loop $task_id

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
        wt remove -C "$repo" "$worktree_path" 2>/dev/null && return 0
    fi

    # Fallback: git worktree remove
    git -C "$repo" worktree remove "$worktree_path" --force 2>/dev/null || true
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
# Finds opencode/claude processes with PPID=1 that match supervisor patterns
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

    # Find orphaned opencode/claude processes (PPID=1, not in any terminal session)
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
    task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, model, retries, max_retries
        FROM tasks WHERE id = '$escaped_id';
    ")

    if [[ -z "$task_row" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    local tid trepo tdesc tstatus tmodel tretries tmax_retries
    IFS='|' read -r tid trepo tdesc tstatus tmodel tretries tmax_retries <<< "$task_row"

    # Validate task is in dispatchable state
    if [[ "$tstatus" != "queued" ]]; then
        log_error "Task $task_id is in '$tstatus' state, must be 'queued' to dispatch"
        return 1
    fi

    # Check concurrency limit if in a batch
    if [[ -n "$batch_id" ]]; then
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")
        local concurrency
        concurrency=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
        local active_count
        active_count=$(cmd_running_count "$batch_id")

        if [[ "$active_count" -ge "$concurrency" ]]; then
            log_warn "Concurrency limit reached ($active_count/$concurrency) for batch $batch_id"
            return 2
        fi
    else
        # Global concurrency check (default 4)
        local global_concurrency="${SUPERVISOR_MAX_CONCURRENCY:-4}"
        local global_active
        global_active=$(cmd_running_count)
        if [[ "$global_active" -ge "$global_concurrency" ]]; then
            log_warn "Global concurrency limit reached ($global_active/$global_concurrency)"
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
    done < <(build_dispatch_cmd "$task_id" "$worktree_path" "$log_file" "$ai_cli" "$memory_context" "$tmodel")

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

        # Check for PR URL
        local pr_url
        pr_url=$(grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' "$tlog" 2>/dev/null | tail -1 || true)
        if [[ -n "$pr_url" ]]; then
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

    # Completion signals
    if grep -q 'FULL_LOOP_COMPLETE' "$log_file" 2>/dev/null; then
        echo "signal=FULL_LOOP_COMPLETE"
    elif grep -q 'TASK_COMPLETE' "$log_file" 2>/dev/null; then
        echo "signal=TASK_COMPLETE"
    else
        echo "signal=none"
    fi

    # PR URL (GitHub or GitLab)
    local pr_url
    pr_url=$(grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' "$log_file" 2>/dev/null | tail -1 || true)
    if [[ -z "$pr_url" ]]; then
        pr_url=$(grep -oE 'https://gitlab\.[^/]+/[^/]+/[^/]+/-/merge_requests/[0-9]+' "$log_file" 2>/dev/null | tail -1 || true)
    fi
    echo "pr_url=${pr_url:-}"

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

    # Backend infrastructure errors - search FULL log (these are short error-only logs,
    # not content false positives). Must be before rm of tail file.
    local backend_error_count=0
    backend_error_count=$(grep -ci 'endpoints failed\|Antigravity\|gateway.*error\|service unavailable\|503\|Quota protection\|over.*usage\|quota reset' "$log_file" 2>/dev/null || echo 0)

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
    # for a PR matching the task's branch (feature/tXXX)
    if [[ -z "$meta_pr_url" ]]; then
        local task_repo
        task_repo=$(sqlite3 "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
        if [[ -n "$task_repo" ]]; then
            local repo_slug_detect
            repo_slug_detect=$(git -C "$task_repo" remote get-url origin 2>/dev/null | grep -oE '[^/:]+/[^/.]+' | tail -1 || echo "")
            if [[ -n "$repo_slug_detect" ]]; then
                meta_pr_url=$(gh pr list --repo "$repo_slug_detect" --head "feature/${task_id}" --json url --jq '.[0].url' 2>/dev/null || echo "")
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

    # Backend infrastructure error (Antigravity, quota, API gateway) = transient retry
    # Checked AFTER success signals: a task can hit a backend error early, recover,
    # and complete successfully. Only triggers if no success signal was found.
    if [[ "$meta_backend_error_count" -gt 0 ]]; then
        echo "retry:backend_infrastructure_error"
        return 0
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

    # If no PR URL stored, try to find one via branch name lookup
    if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
        local task_repo_check
        task_repo_check=$(sqlite3 "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
        if [[ -n "$task_repo_check" ]]; then
            local repo_slug_check
            repo_slug_check=$(git -C "$task_repo_check" remote get-url origin 2>/dev/null | grep -oE '[^/:]+/[^/.]+' | tail -1 || echo "")
            if [[ -n "$repo_slug_check" ]]; then
                local found_pr_url
                found_pr_url=$(gh pr list --repo "$repo_slug_check" --head "feature/${task_id}" --json url --jq '.[0].url' 2>/dev/null || echo "")
                if [[ -n "$found_pr_url" ]]; then
                    pr_url="$found_pr_url"
                    sqlite3 "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$found_pr_url")' WHERE id = '$escaped_id';" 2>/dev/null || true
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
    pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json state,isDraft,reviewDecision,statusCheckRollup 2>/dev/null || echo "")

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
    if ! git -C "$repo" pull origin main --ff-only 2>/dev/null; then
        git -C "$repo" pull origin main 2>/dev/null || true
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

    log_info "Running setup.sh for $task_id..."
    local deploy_output
    if ! deploy_output=$(cd "$repo" && ./setup.sh 2>&1); then
        log_warn "Deploy (setup.sh) returned non-zero for $task_id. Output:"
        log_warn "$deploy_output"
        return 1
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
        git -C "$trepo" push origin --delete "$tbranch" 2>/dev/null || true
        git -C "$trepo" branch -d "$tbranch" 2>/dev/null || true
        log_info "Cleaned up branch: $tbranch"
    fi

    # Prune worktrees
    if command -v wt &>/dev/null; then
        wt prune -C "$trepo" 2>/dev/null || true
    else
        git -C "$trepo" worktree prune 2>/dev/null || true
    fi

    return 0
}

#######################################
# Command: pr-lifecycle - handle full post-PR lifecycle for a task
# Checks CI, merges, runs postflight, deploys, cleans up worktree
#######################################
cmd_pr_lifecycle() {
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
        log_error "Usage: supervisor-helper.sh pr-lifecycle <task_id> [--dry-run]"
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
                    found_pr=$(gh pr list --repo "$repo_slug_lifecycle" --head "feature/${task_id}" --json url --jq '.[0].url' 2>/dev/null || echo "")
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
                    cmd_transition "$task_id" "deployed" 2>/dev/null || true
                fi
                return 0
            fi
        fi
        if [[ "$dry_run" == "false" ]]; then
            cmd_transition "$task_id" "pr_review" 2>/dev/null || true
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
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "merging" 2>/dev/null || true
                fi
                tstatus="merging"
                ;;
            already_merged)
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "merging" 2>/dev/null || true
                    cmd_transition "$task_id" "merged" 2>/dev/null || true
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
                    cmd_transition "$task_id" "blocked" --error "CI checks failed" 2>/dev/null || true
                    send_task_notification "$task_id" "blocked" "CI checks failed on PR" 2>/dev/null || true
                fi
                return 1
                ;;
            changes_requested)
                log_warn "Changes requested on PR for $task_id"
                if [[ "$dry_run" == "false" ]]; then
                    cmd_transition "$task_id" "blocked" --error "PR changes requested" 2>/dev/null || true
                    send_task_notification "$task_id" "blocked" "PR changes requested" 2>/dev/null || true
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
                    cmd_transition "$task_id" "blocked" --error "PR closed without merge" 2>/dev/null || true
                fi
                return 1
                ;;
            no_pr)
                # Track consecutive no_pr failures to avoid infinite retry loop
                local no_pr_key="no_pr_retries_${task_id}"
                local no_pr_count
                no_pr_count=$(db "SELECT COALESCE(
                    (SELECT CAST(json_extract(error, '$.no_pr_retries') AS INTEGER)
                     FROM tasks WHERE id='$task_id'), 0);" 2>/dev/null || echo "0")
                no_pr_count=$((no_pr_count + 1))

                if [[ "$no_pr_count" -ge 5 ]]; then
                    log_warn "No PR found for $task_id after $no_pr_count attempts -- blocking"
                    if ! command -v gh &>/dev/null; then
                        log_warn "  ROOT CAUSE: 'gh' CLI not in PATH ($(echo "$PATH" | tr ':' '\n' | head -5 | tr '\n' ':'))"
                    fi
                    if [[ "$dry_run" == "false" ]]; then
                        cmd_transition "$task_id" "blocked" --error "PR unreachable after $no_pr_count attempts (gh in PATH: $(command -v gh 2>/dev/null || echo 'NOT FOUND'))" 2>/dev/null || true
                    fi
                    return 1
                fi

                log_warn "No PR found for $task_id (attempt $no_pr_count/5)"
                # Store retry count in error field as JSON
                db "UPDATE tasks SET error = json_set(COALESCE(error, '{}'), '$.no_pr_retries', $no_pr_count), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$task_id';" 2>/dev/null || true
                return 0
                ;;
        esac
    fi

    # Step 3: Merge
    if [[ "$tstatus" == "merging" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[dry-run] Would merge PR for $task_id"
        else
            if merge_task_pr "$task_id" "$dry_run"; then
                cmd_transition "$task_id" "merged" 2>/dev/null || true
                tstatus="merged"
            else
                cmd_transition "$task_id" "blocked" --error "Merge failed" 2>/dev/null || true
                send_task_notification "$task_id" "blocked" "PR merge failed" 2>/dev/null || true
                return 1
            fi
        fi
    fi

    # Step 4: Postflight + Deploy
    if [[ "$tstatus" == "merged" ]]; then
        if [[ "$dry_run" == "false" ]]; then
            cmd_transition "$task_id" "deploying" || log_warn "Failed to transition $task_id to deploying"

            # Pull main and run postflight
            run_postflight_for_task "$task_id" "$trepo" || log_warn "Postflight issue for $task_id (non-blocking)"

            # Deploy (aidevops repos only)
            run_deploy_for_task "$task_id" "$trepo" || log_warn "Deploy issue for $task_id (non-blocking)"

            # Clean up worktree and branch
            cleanup_after_merge "$task_id" || log_warn "Worktree cleanup issue for $task_id (non-blocking)"

            # Update TODO.md
            update_todo_on_complete "$task_id" || log_warn "TODO.md update issue for $task_id (non-blocking)"

            # Final transition
            cmd_transition "$task_id" "deployed" || log_warn "Failed to transition $task_id to deployed"

            # Notify (best-effort, suppress errors)
            send_task_notification "$task_id" "deployed" "PR merged, deployed, worktree cleaned" 2>/dev/null || true
            store_success_pattern "$task_id" "deployed" "" 2>/dev/null || true
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
    local where_clause="t.status IN ('complete', 'pr_review', 'merging', 'merged', 'deploying')"
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
            cmd_transition "$tid" "deployed" 2>/dev/null || true
            deployed_count=$((deployed_count + 1))
            log_info "  $tid: no PR, marked deployed"
            continue
        fi

        log_info "  $tid: processing post-PR lifecycle (status: $tstatus)"
        if cmd_pr_lifecycle "$tid" 2>/dev/null; then
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
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_db

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
                cmd_auto_pickup --repo "$repo_path" 2>/dev/null || true
            fi
        done <<< "$all_repos"
    else
        # No tasks yet - try current directory
        if [[ -f "$(pwd)/TODO.md" ]]; then
            cmd_auto_pickup --repo "$(pwd)" 2>/dev/null || true
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
                cmd_transition "$tid" "evaluating" 2>/dev/null || true
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
                    cmd_transition "$tid" "complete" --pr-url "$outcome_detail" 2>/dev/null || true
                    completed_count=$((completed_count + 1))
                    # Clean up worker process tree and PID file (t128.7)
                    cleanup_worker_processes "$tid"
                    # Auto-update TODO.md and send notification (t128.4)
                    update_todo_on_complete "$tid" 2>/dev/null || true
                    send_task_notification "$tid" "complete" "$outcome_detail" 2>/dev/null || true
                    # Store success pattern in memory (t128.6)
                    store_success_pattern "$tid" "$outcome_detail" "$tid_desc" 2>/dev/null || true
                    ;;
                retry)
                    log_warn "  $tid: RETRY ($outcome_detail)"
                    cmd_transition "$tid" "retrying" --error "$outcome_detail" 2>/dev/null || true
                    # Clean up worker process tree before re-prompt (t128.7)
                    cleanup_worker_processes "$tid"
                    # Store failure pattern in memory (t128.6)
                    store_failure_pattern "$tid" "retry" "$outcome_detail" "$tid_desc" 2>/dev/null || true
                    # Re-prompt in existing worktree (continues context)
                    if cmd_reprompt "$tid" 2>/dev/null; then
                        dispatched_count=$((dispatched_count + 1))
                        log_info "  $tid: re-prompted successfully"
                    else
                        # Re-prompt failed - check if max retries exceeded
                        local current_retries
                        current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
                        local max_retries_val
                        max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
                        if [[ "$current_retries" -ge "$max_retries_val" ]]; then
                            log_error "  $tid: max retries exceeded ($current_retries/$max_retries_val), marking blocked"
                            cmd_transition "$tid" "blocked" --error "Max retries exceeded: $outcome_detail" 2>/dev/null || true
                            # Auto-update TODO.md and send notification (t128.4)
                            update_todo_on_blocked "$tid" "Max retries exceeded: $outcome_detail" 2>/dev/null || true
                            send_task_notification "$tid" "blocked" "Max retries exceeded: $outcome_detail" 2>/dev/null || true
                            # Store failure pattern in memory (t128.6)
                            store_failure_pattern "$tid" "blocked" "Max retries exceeded: $outcome_detail" "$tid_desc" 2>/dev/null || true
                        else
                            log_error "  $tid: re-prompt failed, marking failed"
                            cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed: $outcome_detail" 2>/dev/null || true
                            failed_count=$((failed_count + 1))
                            # Auto-update TODO.md and send notification (t128.4)
                            update_todo_on_blocked "$tid" "Re-prompt dispatch failed: $outcome_detail" 2>/dev/null || true
                            send_task_notification "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" 2>/dev/null || true
                            # Store failure pattern in memory (t128.6)
                            store_failure_pattern "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" "$tid_desc" 2>/dev/null || true
                        fi
                    fi
                    ;;
                blocked)
                    log_warn "  $tid: BLOCKED ($outcome_detail)"
                    cmd_transition "$tid" "blocked" --error "$outcome_detail" 2>/dev/null || true
                    # Clean up worker process tree and PID file (t128.7)
                    cleanup_worker_processes "$tid"
                    # Auto-update TODO.md and send notification (t128.4)
                    update_todo_on_blocked "$tid" "$outcome_detail" 2>/dev/null || true
                    send_task_notification "$tid" "blocked" "$outcome_detail" 2>/dev/null || true
                    # Store failure pattern in memory (t128.6)
                    store_failure_pattern "$tid" "blocked" "$outcome_detail" "$tid_desc" 2>/dev/null || true
                    ;;
                failed)
                    log_error "  $tid: FAILED ($outcome_detail)"
                    cmd_transition "$tid" "failed" --error "$outcome_detail" 2>/dev/null || true
                    failed_count=$((failed_count + 1))
                    # Clean up worker process tree and PID file (t128.7)
                    cleanup_worker_processes "$tid"
                    # Auto-update TODO.md and send notification (t128.4)
                    update_todo_on_blocked "$tid" "FAILED: $outcome_detail" 2>/dev/null || true
                    send_task_notification "$tid" "failed" "$outcome_detail" 2>/dev/null || true
                    # Store failure pattern in memory (t128.6)
                    store_failure_pattern "$tid" "failed" "$outcome_detail" "$tid_desc" 2>/dev/null || true
                    ;;
            esac
        done <<< "$running_tasks"
    fi

    # Phase 2: Dispatch queued tasks up to concurrency limit

    if [[ -n "$batch_id" ]]; then
        local next_tasks
        next_tasks=$(cmd_next "$batch_id" 10)

        if [[ -n "$next_tasks" ]]; then
            while IFS='|' read -r tid trepo tdesc tmodel; do
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
            while IFS='|' read -r tid trepo tdesc tmodel; do
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

    # Phase 4: Process hygiene - clean up orphaned processes
    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local stale_pid
            stale_pid=$(cat "$pid_file")
            if ! kill -0 "$stale_pid" 2>/dev/null; then
                local stale_task
                stale_task=$(basename "$pid_file" .pid)
                local stale_status
                stale_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$stale_task")';" 2>/dev/null || echo "")
                # Only clean up PIDs for tasks still marked as running/dispatched
                if [[ "$stale_status" == "running" || "$stale_status" == "dispatched" ]]; then
                    log_warn "  Orphaned process for $stale_task (PID $stale_pid dead, status $stale_status)"
                fi
                rm -f "$pid_file"
            fi
        done
    fi

    # Phase 5: Summary
    local total_running
    total_running=$(cmd_running_count "${batch_id:-}")
    local total_queued
    total_queued=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'queued';")
    local total_complete
    total_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('complete', 'deployed');")
    local total_pr_review
    total_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('pr_review', 'merging', 'merged', 'deploying');")

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
                complete|failed|cancelled|blocked|deployed|pr_review|merging|merged|deploying)
                    cleanup_worker_processes "$cleanup_tid" 2>/dev/null || true
                    orphan_killed=$((orphan_killed + 1))
                    ;;
            esac
        done
    fi
    if [[ "$orphan_killed" -gt 0 ]]; then
        log_info "  Cleaned:    $orphan_killed stale worker processes"
    fi

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

    # Commit and push from the main repo (TODO.md lives on main)
    if git -C "$trepo" diff --quiet -- TODO.md 2>/dev/null; then
        log_info "No changes to commit (TODO.md unchanged)"
        return 0
    fi

    git -C "$trepo" add TODO.md
    local commit_msg="chore: mark $task_id complete in TODO.md"
    if [[ -n "$tpr_url" ]]; then
        commit_msg="chore: mark $task_id complete in TODO.md (${tpr_url})"
    fi
    git -C "$trepo" commit -m "$commit_msg" -- TODO.md 2>/dev/null || {
        log_warn "Failed to commit TODO.md update (may need manual commit)"
        return 1
    }

    git -C "$trepo" push 2>/dev/null || {
        log_warn "Failed to push TODO.md update (may need manual push)"
        return 1
    }

    log_success "Committed and pushed TODO.md update for $task_id"
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
        # sed append syntax differs between BSD and GNU - sed_inplace can't abstract this
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "${line_num}a\\
${notes_line}" "$todo_file"
        else
            sed -i "${line_num}a\\${notes_line}" "$todo_file"
        fi
    fi

    log_success "Updated TODO.md: $task_id marked blocked ($reason)"

    # Commit and push
    if git -C "$trepo" diff --quiet -- TODO.md 2>/dev/null; then
        log_info "No changes to commit (TODO.md unchanged)"
        return 0
    fi

    git -C "$trepo" add TODO.md
    git -C "$trepo" commit -m "chore: mark $task_id blocked in TODO.md" -- TODO.md 2>/dev/null || {
        log_warn "Failed to commit TODO.md update"
        return 1
    }

    git -C "$trepo" push 2>/dev/null || {
        log_warn "Failed to push TODO.md update"
        return 1
    }

    log_success "Committed and pushed TODO.md blocked update for $task_id"
    return 0
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
  supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] Handle post-PR merge/deploy lifecycle
  supervisor-helper.sh pr-check <task_id>             Check PR CI/review status
  supervisor-helper.sh pr-merge <task_id> [--dry-run]  Merge PR (squash)
  supervisor-helper.sh worker-status <task_id>       Check worker process status
  supervisor-helper.sh cleanup [--dry-run]           Clean up completed worktrees
  supervisor-helper.sh update-todo <task_id>         Update TODO.md for completed/blocked task
  supervisor-helper.sh notify <task_id>              Send notification about task state
  supervisor-helper.sh recall <task_id>              Recall memories relevant to a task
  supervisor-helper.sh retrospective [batch_id]      Run batch retrospective and store insights
  supervisor-helper.sh transition <id> <state>       Transition task state
  supervisor-helper.sh status [task_id|batch_id]     Show status
  supervisor-helper.sh list [--state X] [--batch Y]  List tasks
  supervisor-helper.sh next [batch_id] [limit]       Get next dispatchable tasks
  supervisor-helper.sh running-count [batch_id]      Count active tasks
  supervisor-helper.sh reset <task_id>               Reset task to queued
  supervisor-helper.sh cancel <task_id|batch_id>     Cancel task or batch
  supervisor-helper.sh auto-pickup [--repo path]      Scan TODO.md for auto-dispatch tasks
  supervisor-helper.sh cron [install|uninstall|status] Manage cron-based pulse scheduling
  supervisor-helper.sh watch [--repo path]            Watch TODO.md for changes (fswatch)
  supervisor-helper.sh db [sql]                      Direct SQLite access
  supervisor-helper.sh help                          Show this help

State Machine (worker lifecycle):
  queued -> dispatched -> running -> evaluating -> complete
                                  -> retrying   -> reprompt -> dispatched -> running (retry cycle)
                                  -> blocked    (needs human input / max retries exceeded)
                                  -> failed     (dispatch failure / unrecoverable)

Post-PR Lifecycle (t128.8 - supervisor handles directly, no worker needed):
  complete -> pr_review -> merging -> merged -> deploying -> deployed
  Workers exit after PR creation. Supervisor detects complete tasks with PR URLs
  and handles: CI wait, merge (squash), postflight, deploy, worktree cleanup.

Outcome Evaluation (3-tier):
  1. Deterministic: FULL_LOOP_COMPLETE/TASK_COMPLETE signals, EXIT codes
  2. Heuristic: error pattern matching (rate limit, auth, conflict, OOM, timeout)
  3. AI eval: Sonnet dispatch (~30s) for ambiguous outcomes

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

Options for 'batch':
  --concurrency <N>      Max parallel workers (default: 4)
  --tasks "t001,t002"    Comma-separated task IDs to add

Options for 'dispatch':
  --batch <batch_id>     Dispatch within batch concurrency limits

Options for 'reprompt':
  --prompt "text"        Custom re-prompt message (default: auto-generated with failure context)

Options for 'evaluate':
  --no-ai                Skip AI evaluation tier (deterministic + heuristic only)

Options for 'pulse':
  --batch <batch_id>     Only pulse tasks in this batch

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
  AIDEVOPS_SUPERVISOR_DIR     Override supervisor data directory

Database: ~/.aidevops/.agent-workspace/supervisor/supervisor.db

Integration:
  - Workers: opencode run in worktrees (via full-loop)
  - Coordinator: coordinator-helper.sh (extends, doesn't replace)
  - Mail: mail-helper.sh for escalation
  - Memory: memory-helper.sh for cross-batch learning
  - Git: wt/worktree-helper.sh for isolation
  - TODO: auto-updates TODO.md on task completion/failure

TODO.md Auto-Update (t128.4):
  On task completion: marks [ ] -> [x], adds completed:YYYY-MM-DD, commits+pushes
  On task blocked/failed: adds Notes line with reason, commits+pushes
  Notifications sent via mail-helper.sh and Matrix (if configured)
  Triggered automatically during pulse cycle, or manually via update-todo command

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

Post-PR Lifecycle (t128.8):
  Workers exit after PR creation (context limit). The supervisor detects
  tasks in 'complete' state with PR URLs and handles remaining stages:
    1. pr_review: Wait for CI checks to pass and reviews to approve
    2. merging: Squash merge the PR via gh pr merge --squash
    3. merged: Pull main, run postflight verification
    4. deploying: Run setup.sh (aidevops repos only)
    5. deployed: Clean up worktree and branch, update TODO.md

  Automatic: pulse cycle Phase 3 processes all eligible tasks each run
  Manual commands:
    supervisor-helper.sh pr-check <task_id>              # Check CI/review status
    supervisor-helper.sh pr-merge <task_id> [--dry-run]  # Merge PR
    supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] # Full lifecycle

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
        worker-status) cmd_worker_status "$@" ;;
        cleanup) cmd_cleanup "$@" ;;
        kill-workers) cmd_kill_workers "$@" ;;
        update-todo) cmd_update_todo "$@" ;;
        notify) cmd_notify "$@" ;;
        auto-pickup) cmd_auto_pickup "$@" ;;
        cron) cmd_cron "$@" ;;
        watch) cmd_watch "$@" ;;
        recall) cmd_recall "$@" ;;
        retrospective) cmd_retrospective "$@" ;;
        transition) cmd_transition "$@" ;;
        status) cmd_status "$@" ;;
        list) cmd_list "$@" ;;
        next) cmd_next "$@" ;;
        running-count) cmd_running_count "$@" ;;
        reset) cmd_reset "$@" ;;
        cancel) cmd_cancel "$@" ;;
        db) cmd_db "$@" ;;
        help|--help|-h) show_usage ;;
        *) log_error "Unknown command: $command"; show_usage; return 1 ;;
    esac
}

main "$@"
