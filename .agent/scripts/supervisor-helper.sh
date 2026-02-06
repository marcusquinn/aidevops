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
#   supervisor-helper.sh cleanup [--dry-run]           Clean up completed worktrees
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
#                                   -> retrying   -> reprompt -> dispatched (retry cycle)
#                                   -> blocked    (needs human input / max retries)
#                                   -> failed     (dispatch failure / unrecoverable)
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
# Build the dispatch command for a task
# Outputs the command array elements, one per line
#######################################
build_dispatch_cmd() {
    local task_id="$1"
    local worktree_path="$2"
    local log_file="$3"
    local ai_cli="$4"

    if [[ "$ai_cli" == "opencode" ]]; then
        echo "opencode"
        echo "run"
        echo "--format"
        echo "json"
        echo "--title"
        echo "$task_id"
        echo "/full-loop $task_id"
    else
        # claude CLI
        echo "claude"
        echo "-p"
        echo "/full-loop $task_id"
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
    task_row=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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
        concurrency=$(sqlite3 "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
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

    log_info "Dispatching $task_id via $ai_cli ($dispatch_mode mode)"
    log_info "Worktree: $worktree_path"
    log_info "Log: $log_file"

    # Build and execute dispatch command
    local -a cmd_parts=()
    while IFS= read -r part; do
        cmd_parts+=("$part")
    done < <(build_dispatch_cmd "$task_id" "$worktree_path" "$log_file" "$ai_cli")

    # Ensure PID directory exists before dispatch
    mkdir -p "$SUPERVISOR_DIR/pids"

    if [[ "$dispatch_mode" == "tabby" ]]; then
        # Tabby: attempt to open in a new tab via OSC 1337 escape sequence
        log_info "Opening Tabby tab for $task_id..."
        local tab_cmd
        tab_cmd="cd '${worktree_path}' && ${cmd_parts[*]} > '${log_file}' 2>&1; echo \"EXIT:\$?\" >> '${log_file}'"
        printf '\e]1337;NewTab=%s\a' "$tab_cmd" 2>/dev/null || true
        # Also start background process as fallback (Tabby may not support OSC 1337)
        (cd "$worktree_path" && "${cmd_parts[@]}" > "$log_file" 2>&1; echo "EXIT:$?" >> "$log_file") &
    else
        # Headless: background process
        (cd "$worktree_path" && "${cmd_parts[@]}" > "$log_file" 2>&1; echo "EXIT:$?" >> "$log_file") &
    fi

    local worker_pid=$!

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
    task_row=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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

    # Error patterns (count occurrences for severity assessment)
    local rate_limit_count=0 auth_error_count=0 conflict_count=0 timeout_count=0 oom_count=0
    rate_limit_count=$(grep -ci 'rate.limit\|429\|too many requests' "$log_file" 2>/dev/null || echo 0)
    auth_error_count=$(grep -ci 'permission denied\|unauthorized\|403\|401' "$log_file" 2>/dev/null || echo 0)
    conflict_count=$(grep -ci 'merge conflict\|CONFLICT\|conflict marker' "$log_file" 2>/dev/null || echo 0)
    timeout_count=$(grep -ci 'timeout\|timed out\|ETIMEDOUT' "$log_file" 2>/dev/null || echo 0)
    oom_count=$(grep -ci 'out of memory\|OOM\|heap.*exceeded\|ENOMEM' "$log_file" 2>/dev/null || echo 0)

    echo "rate_limit_count=$rate_limit_count"
    echo "auth_error_count=$auth_error_count"
    echo "conflict_count=$conflict_count"
    echo "timeout_count=$timeout_count"
    echo "oom_count=$oom_count"

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
    task_row=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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

    # Parse structured metadata from log
    local -A meta=()
    while IFS='=' read -r key value; do
        meta["$key"]="$value"
    done < <(extract_log_metadata "$tlog")

    # FULL_LOOP_COMPLETE = definitive success
    if [[ "${meta[signal]:-}" == "FULL_LOOP_COMPLETE" ]]; then
        echo "complete:${meta[pr_url]:-no_pr}"
        return 0
    fi

    # TASK_COMPLETE with clean exit = partial success (PR phase may have failed)
    if [[ "${meta[signal]:-}" == "TASK_COMPLETE" && "${meta[exit_code]:-}" == "0" ]]; then
        echo "complete:task_only"
        return 0
    fi

    # --- Tier 2: Heuristic error pattern matching ---

    # Auth errors are always blocking (human must fix credentials)
    if [[ "${meta[auth_error_count]:-0}" -gt 0 ]]; then
        echo "blocked:auth_error"
        return 0
    fi

    # Merge conflicts require human resolution
    if [[ "${meta[conflict_count]:-0}" -gt 0 ]]; then
        echo "blocked:merge_conflict"
        return 0
    fi

    # OOM is infrastructure - blocking
    if [[ "${meta[oom_count]:-0}" -gt 0 ]]; then
        echo "blocked:out_of_memory"
        return 0
    fi

    # Rate limiting is transient - retry with backoff
    if [[ "${meta[rate_limit_count]:-0}" -gt 0 ]]; then
        echo "retry:rate_limited"
        return 0
    fi

    # Timeout is transient - retry
    if [[ "${meta[timeout_count]:-0}" -gt 0 ]]; then
        echo "retry:timeout"
        return 0
    fi

    # Clean exit with no completion signal = likely interrupted or incomplete
    if [[ "${meta[exit_code]:-}" == "0" && "${meta[signal]:-}" == "none" ]]; then
        echo "retry:clean_exit_no_signal"
        return 0
    fi

    # Non-zero exit with known code
    if [[ -n "${meta[exit_code]:-}" && "${meta[exit_code]:-}" != "0" ]]; then
        # Exit code 130 = SIGINT (Ctrl+C), 137 = SIGKILL, 143 = SIGTERM
        case "${meta[exit_code]:-}" in
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
    task_desc=$(sqlite3 "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

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

    if [[ "$ai_cli" == "opencode" ]]; then
        ai_result=$(timeout "$eval_timeout" opencode run \
            -m "anthropic/claude-sonnet-4-20250514" \
            --format text \
            --title "eval-${task_id}" \
            "$eval_prompt" 2>/dev/null || echo "")
    else
        ai_result=$(timeout "$eval_timeout" claude \
            -p "$eval_prompt" \
            --model claude-sonnet-4-20250514 \
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
        sqlite3 "$SUPERVISOR_DB" "
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
    task_row=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
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

    (cd "$work_dir" && "${cmd_parts[@]}" > "$new_log_file" 2>&1; echo "EXIT:$?" >> "$new_log_file") &
    local worker_pid=$!

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
    tlog=$(sqlite3 "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';")

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

    # Phase 1: Check running workers for completion
    local running_tasks
    running_tasks=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
        SELECT id, log_file FROM tasks
        WHERE status IN ('running', 'dispatched')
        ORDER BY started_at ASC;
    ")

    local completed_count=0
    local failed_count=0

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
            log_info "  $tid: worker finished, evaluating..."

            # Transition to evaluating
            cmd_transition "$tid" "evaluating" 2>/dev/null || true

            local outcome
            outcome=$(evaluate_worker "$tid")
            local outcome_type="${outcome%%:*}"
            local outcome_detail="${outcome#*:}"

            case "$outcome_type" in
                complete)
                    log_success "  $tid: COMPLETE ($outcome_detail)"
                    cmd_transition "$tid" "complete" --pr-url "$outcome_detail" 2>/dev/null || true
                    completed_count=$((completed_count + 1))
                    # Clean up PID file
                    rm -f "$pid_file"
                    ;;
                retry)
                    log_warn "  $tid: RETRY ($outcome_detail)"
                    cmd_transition "$tid" "retrying" --error "$outcome_detail" 2>/dev/null || true
                    rm -f "$pid_file"
                    # Re-prompt in existing worktree (continues context)
                    if cmd_reprompt "$tid" 2>/dev/null; then
                        dispatched_count=$((dispatched_count + 1))
                        log_info "  $tid: re-prompted successfully"
                    else
                        # Re-prompt failed - check if max retries exceeded
                        local current_retries
                        current_retries=$(sqlite3 "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
                        local max_retries_val
                        max_retries_val=$(sqlite3 "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
                        if [[ "$current_retries" -ge "$max_retries_val" ]]; then
                            log_error "  $tid: max retries exceeded ($current_retries/$max_retries_val), marking blocked"
                            cmd_transition "$tid" "blocked" --error "Max retries exceeded: $outcome_detail" 2>/dev/null || true
                            # Send escalation
                            if [[ -x "$MAIL_HELPER" ]]; then
                                "$MAIL_HELPER" send \
                                    --to coordinator \
                                    --type status_report \
                                    --payload "Task $tid blocked after $current_retries retries: $outcome_detail" 2>/dev/null || true
                            fi
                        else
                            log_error "  $tid: re-prompt failed, marking failed"
                            cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed: $outcome_detail" 2>/dev/null || true
                            failed_count=$((failed_count + 1))
                        fi
                    fi
                    ;;
                blocked)
                    log_warn "  $tid: BLOCKED ($outcome_detail)"
                    cmd_transition "$tid" "blocked" --error "$outcome_detail" 2>/dev/null || true
                    rm -f "$pid_file"
                    # Send escalation via mail
                    if [[ -x "$MAIL_HELPER" ]]; then
                        "$MAIL_HELPER" send \
                            --to coordinator \
                            --type status_report \
                            --payload "Task $tid blocked: $outcome_detail" 2>/dev/null || true
                    fi
                    ;;
                failed)
                    log_error "  $tid: FAILED ($outcome_detail)"
                    cmd_transition "$tid" "failed" --error "$outcome_detail" 2>/dev/null || true
                    failed_count=$((failed_count + 1))
                    rm -f "$pid_file"
                    ;;
            esac
        done <<< "$running_tasks"
    fi

    # Phase 2: Dispatch queued tasks up to concurrency limit
    local dispatched_count=0

    if [[ -n "$batch_id" ]]; then
        local next_tasks
        next_tasks=$(cmd_next "$batch_id" 10)

        if [[ -n "$next_tasks" ]]; then
            while IFS='|' read -r tid trepo tdesc tmodel; do
                if cmd_dispatch "$tid" --batch "$batch_id" 2>/dev/null; then
                    dispatched_count=$((dispatched_count + 1))
                else
                    local dispatch_exit=$?
                    if [[ "$dispatch_exit" -eq 2 ]]; then
                        # Concurrency limit reached
                        log_info "Concurrency limit reached, stopping dispatch"
                        break
                    fi
                fi
            done <<< "$next_tasks"
        fi
    else
        # Global dispatch (no batch filter)
        local next_tasks
        next_tasks=$(cmd_next "" 10)

        if [[ -n "$next_tasks" ]]; then
            while IFS='|' read -r tid trepo tdesc tmodel; do
                if cmd_dispatch "$tid" 2>/dev/null; then
                    dispatched_count=$((dispatched_count + 1))
                else
                    local dispatch_exit=$?
                    if [[ "$dispatch_exit" -eq 2 ]]; then
                        log_info "Concurrency limit reached, stopping dispatch"
                        break
                    fi
                fi
            done <<< "$next_tasks"
        fi
    fi

    # Phase 3: Summary
    local total_running
    total_running=$(cmd_running_count "${batch_id:-}")
    local total_queued
    total_queued=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'queued';")
    local total_complete
    total_complete=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'complete';")

    echo ""
    log_info "Pulse summary:"
    log_info "  Evaluated:  $((completed_count + failed_count)) workers"
    log_info "  Completed:  $completed_count"
    log_info "  Failed:     $failed_count"
    log_info "  Dispatched: $dispatched_count new"
    log_info "  Running:    $total_running"
    log_info "  Queued:     $total_queued"
    log_info "  Total done: $total_complete"

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
    terminal_tasks=$(sqlite3 -separator '|' "$SUPERVISOR_DB" "
        SELECT id, worktree, repo, status FROM tasks
        WHERE worktree IS NOT NULL AND worktree != ''
        AND status IN ('complete', 'failed', 'cancelled');
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
            sqlite3 "$SUPERVISOR_DB" "
                UPDATE tasks SET worktree = NULL WHERE id = '$(sql_escape "$tid")';
            "
            continue
        fi

        if [[ "$dry_run" == "true" ]]; then
            log_info "  [dry-run] Would remove: $tworktree ($tid, $tstatus)"
        else
            log_info "  Removing worktree: $tworktree ($tid)"
            cleanup_task_worktree "$tworktree" "$trepo"
            sqlite3 "$SUPERVISOR_DB" "
                UPDATE tasks SET worktree = NULL WHERE id = '$(sql_escape "$tid")';
            "
            cleaned=$((cleaned + 1))
        fi
    done <<< "$terminal_tasks"

    # Also clean up stale PID files
    if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
        local stale_pids=0
        for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            pid=$(cat "$pid_file")
            if ! kill -0 "$pid" 2>/dev/null; then
                if [[ "$dry_run" == "true" ]]; then
                    log_info "  [dry-run] Would remove stale PID: $pid_file"
                else
                    rm -f "$pid_file"
                    stale_pids=$((stale_pids + 1))
                fi
            fi
        done
        if [[ "$stale_pids" -gt 0 ]]; then
            log_info "Removed $stale_pids stale PID files"
        fi
    fi

    if [[ "$dry_run" == "false" ]]; then
        log_success "Cleaned up $cleaned worktrees"
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
  supervisor-helper.sh dispatch <task_id> [options]  Dispatch a task (worktree + worker)
  supervisor-helper.sh reprompt <task_id> [options]  Re-prompt a retrying task
  supervisor-helper.sh evaluate <task_id> [--no-ai]  Evaluate a worker's outcome
  supervisor-helper.sh pulse [--batch id]            Run supervisor pulse cycle
  supervisor-helper.sh worker-status <task_id>       Check worker process status
  supervisor-helper.sh cleanup [--dry-run]           Clean up completed worktrees
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
                                  -> retrying   -> reprompt -> dispatched -> running (retry cycle)
                                  -> blocked    (needs human input / max retries exceeded)
                                  -> failed     (dispatch failure / unrecoverable)

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
        worker-status) cmd_worker_status "$@" ;;
        cleanup) cmd_cleanup "$@" ;;
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
