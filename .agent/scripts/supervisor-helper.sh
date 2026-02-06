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
#   supervisor-helper.sh status [task_id|batch_id]     Show task/batch/overall status
#   supervisor-helper.sh transition <task_id> <new_state> [--error "reason"]
#   supervisor-helper.sh list [--state queued|running|...] [--batch name] [--format json]
#   supervisor-helper.sh reset <task_id>               Reset task to queued state
#   supervisor-helper.sh cancel <task_id|batch_id>     Cancel task or batch
#   supervisor-helper.sh db [sql]                      Direct SQLite access
#   supervisor-helper.sh help
#
# State machine:
#   queued -> dispatched -> running -> evaluating -> complete
#                                   -> retrying   -> dispatched (retry cycle)
#                                   -> blocked    (needs human input)
#                                   -> failed     (max retries exceeded)
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

# Configuration - resolve relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
readonly SUPERVISOR_DB="$SUPERVISOR_DIR/supervisor.db"
readonly MAIL_HELPER="${SCRIPT_DIR}/mail-helper.sh"       # Used by pulse command (t128.2)
readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"   # Used by pulse command (t128.6)
export MAIL_HELPER MEMORY_HELPER

# Valid states for the state machine
readonly VALID_STATES="queued dispatched running evaluating retrying complete blocked failed cancelled"

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

#######################################
# Escape single quotes for SQL
#######################################
sql_escape() {
    local input="$1"
    echo "${input//\'/\'\'}"
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
    has_tasks=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='tasks';")
    if [[ "$has_tasks" -eq 0 ]]; then
        init_db
    fi

    return 0
}

#######################################
# Initialize SQLite database with schema
#######################################
init_db() {
    mkdir -p "$SUPERVISOR_DIR"

    sqlite3 "$SUPERVISOR_DB" << 'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','blocked','failed','cancelled')),
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
    task_count=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
    local batch_count
    batch_count=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM batches;")

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
    existing=$(sqlite3 "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';")
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

    sqlite3 "$SUPERVISOR_DB" "
        INSERT INTO tasks (id, repo, description, model, max_retries)
        VALUES ('$escaped_id', '$escaped_repo', '$escaped_desc', '$escaped_model', $max_retries);
    "

    # Log the initial state
    sqlite3 "$SUPERVISOR_DB" "
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
    local name="" concurrency=4 tasks=""

    # First positional arg is batch name
    if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        name="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --concurrency) [[ $# -lt 2 ]] && { log_error "--concurrency requires a value"; return 1; }; concurrency="$2"; shift 2 ;;
            --tasks) [[ $# -lt 2 ]] && { log_error "--tasks requires a value"; return 1; }; tasks="$2"; shift 2 ;;
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

    sqlite3 "$SUPERVISOR_DB" "
        INSERT INTO batches (id, name, concurrency)
        VALUES ('$escaped_id', '$escaped_name', $concurrency);
    "

    log_success "Created batch: $name (id: $batch_id, concurrency: $concurrency)"

    # Add tasks to batch if provided
    if [[ -n "$tasks" ]]; then
        local position=0
        IFS=',' read -ra task_array <<< "$tasks"
        for task_id in "${task_array[@]}"; do
            task_id=$(echo "$task_id" | tr -d ' ')

            # Ensure task exists in tasks table (auto-add if not)
            local task_exists
            task_exists=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE id = '$(sql_escape "$task_id")';")
            if [[ "$task_exists" -eq 0 ]]; then
                cmd_add "$task_id"
            fi

            local escaped_task
            escaped_task=$(sql_escape "$task_id")
            sqlite3 "$SUPERVISOR_DB" "
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
    current_state=$(sqlite3 "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

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
    if [[ "$new_state" == "complete" || "$new_state" == "failed" || "$new_state" == "cancelled" ]]; then
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

    sqlite3 "$SUPERVISOR_DB" "
        UPDATE tasks SET $update_sql WHERE id = '$escaped_id';
    "

    # Log the transition
    local escaped_reason
    escaped_reason=$(sql_escape "${error_msg:-State transition}")
    sqlite3 "$SUPERVISOR_DB" "
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
    batch_ids=$(sqlite3 "$SUPERVISOR_DB" "
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
        incomplete=$(sqlite3 "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status NOT IN ('complete', 'failed', 'cancelled');
        ")

        if [[ "$incomplete" -eq 0 ]]; then
            sqlite3 "$SUPERVISOR_DB" "
                UPDATE batches SET status = 'complete', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch' AND status = 'active';
            "
            log_success "Batch $batch_id is now complete"
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
        sqlite3 -separator ': ' "$SUPERVISOR_DB" "
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
                evaluating|retrying) color="$YELLOW" ;;
                blocked|failed) color="$RED" ;;
                complete) color="$CYAN" ;;
            esac
            echo -e "  ${color}${state}${NC}: $count"
        done

        local total
        total=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
        echo "  total: $total"
        echo ""

        # Active batches
        echo "Batches:"
        local batches
        batches=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
    task_row=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
        sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
        batch_membership=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
    batch_row=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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

        sqlite3 -separator '|' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries
            FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$(sql_escape "$bid")'
            ORDER BY bt.position;
        " | while IFS='|' read -r tid tstatus tdesc tretries tmax; do
            local color="$NC"
            case "$tstatus" in
                running|dispatched) color="$GREEN" ;;
                evaluating|retrying) color="$YELLOW" ;;
                blocked|failed) color="$RED" ;;
                complete) color="$CYAN" ;;
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
        sqlite3 -json "$SUPERVISOR_DB" "
            SELECT t.id, t.repo, t.description, t.status, t.retries, t.max_retries,
                   t.model, t.error, t.pr_url, t.session_id, t.worktree, t.branch,
                   t.created_at, t.started_at, t.completed_at
            FROM tasks t $where_sql
            ORDER BY t.created_at DESC;
        "
    else
        local results
        results=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
                evaluating|retrying) color="$YELLOW" ;;
                blocked|failed) color="$RED" ;;
                complete) color="$CYAN" ;;
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
    current_state=$(sqlite3 "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

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

    sqlite3 "$SUPERVISOR_DB" "
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

    sqlite3 "$SUPERVISOR_DB" "
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
    task_status=$(sqlite3 "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_target';")

    if [[ -n "$task_status" ]]; then
        if [[ "$task_status" == "complete" || "$task_status" == "cancelled" || "$task_status" == "failed" ]]; then
            log_warn "Task $target is already in terminal state: $task_status"
            return 0
        fi

        # Check if transition is valid
        if ! validate_transition "$task_status" "cancelled"; then
            log_error "Cannot cancel task in '$task_status' state"
            return 1
        fi

        sqlite3 "$SUPERVISOR_DB" "
            UPDATE tasks SET
                status = 'cancelled',
                completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = '$escaped_target';
        "

        sqlite3 "$SUPERVISOR_DB" "
            INSERT INTO state_log (task_id, from_state, to_state, reason)
            VALUES ('$escaped_target', '$task_status', 'cancelled', 'Manual cancellation');
        "

        log_success "Cancelled task: $target"
        return 0
    fi

    # Try as batch
    local batch_status
    batch_status=$(sqlite3 "$SUPERVISOR_DB" "SELECT status FROM batches WHERE id = '$escaped_target' OR name = '$escaped_target';")

    if [[ -n "$batch_status" ]]; then
        local batch_id
        batch_id=$(sqlite3 "$SUPERVISOR_DB" "SELECT id FROM batches WHERE id = '$escaped_target' OR name = '$escaped_target';")
        local escaped_batch
        escaped_batch=$(sql_escape "$batch_id")

        sqlite3 "$SUPERVISOR_DB" "
            UPDATE batches SET status = 'cancelled', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = '$escaped_batch';
        "

        # Cancel all non-terminal tasks in the batch
        local cancelled_count
        cancelled_count=$(sqlite3 "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status NOT IN ('complete', 'failed', 'cancelled');
        ")

        sqlite3 "$SUPERVISOR_DB" "
            UPDATE tasks SET
                status = 'cancelled',
                completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id IN (
                SELECT task_id FROM batch_tasks WHERE batch_id = '$escaped_batch'
            ) AND status NOT IN ('complete', 'failed', 'cancelled');
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
        sqlite3 -column -header "$SUPERVISOR_DB"
    else
        sqlite3 -column -header "$SUPERVISOR_DB" "$*"
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
        sqlite3 "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$(sql_escape "$batch_id")'
            AND t.status IN ('dispatched', 'running', 'evaluating');
        "
    else
        sqlite3 "$SUPERVISOR_DB" "
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
        concurrency=$(sqlite3 "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
        local active_count
        active_count=$(cmd_running_count "$batch_id")

        local available=$((concurrency - active_count))
        if [[ "$available" -le 0 ]]; then
            return 0
        fi
        if [[ "$available" -lt "$limit" ]]; then
            limit="$available"
        fi

        sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
        sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
# Show usage
#######################################
show_usage() {
    cat << 'EOF'
supervisor-helper.sh - Autonomous supervisor for multi-task orchestration

Usage:
  supervisor-helper.sh init                          Initialize supervisor database
  supervisor-helper.sh add <task_id> [options]       Add a task
  supervisor-helper.sh batch <name> [options]        Create a batch of tasks
  supervisor-helper.sh transition <id> <state>       Transition task state
  supervisor-helper.sh status [task_id|batch_id]     Show status
  supervisor-helper.sh list [--state X] [--batch Y]  List tasks
  supervisor-helper.sh next [batch_id] [limit]       Get next dispatchable tasks
  supervisor-helper.sh running-count [batch_id]      Count active tasks
  supervisor-helper.sh reset <task_id>               Reset task to queued
  supervisor-helper.sh cancel <task_id|batch_id>     Cancel task or batch
  supervisor-helper.sh db [sql]                      Direct SQLite access
  supervisor-helper.sh help                          Show this help

State Machine:
  queued -> dispatched -> running -> evaluating -> complete
                                  -> retrying   -> dispatched (retry cycle)
                                  -> blocked    (needs human input)
                                  -> failed     (max retries exceeded)

Options for 'add':
  --repo <path>          Repository path (default: current directory)
  --description "desc"   Task description (auto-detected from TODO.md)
  --model <model>        AI model (default: anthropic/claude-opus-4-6)
  --max-retries <N>      Max retry attempts (default: 3)

Options for 'batch':
  --concurrency <N>      Max parallel workers (default: 4)
  --tasks "t001,t002"    Comma-separated task IDs to add

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

Database: ~/.aidevops/.agent-workspace/supervisor/supervisor.db

Integration:
  - Workers: opencode run in worktrees (via full-loop)
  - Coordinator: coordinator-helper.sh (extends, doesn't replace)
  - Mail: mail-helper.sh for escalation
  - Memory: memory-helper.sh for cross-batch learning
  - Git: wt/worktree-helper.sh for isolation
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
