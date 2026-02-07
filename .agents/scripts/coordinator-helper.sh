#!/usr/bin/env bash
# coordinator-helper.sh - Stateless multi-agent coordinator (pulse pattern)
#
# Unlike Gas Town's persistent Mayor, this coordinator is STATELESS:
# - Reads current state from SQLite (agents, messages)
# - Makes dispatch decisions
# - Sends inbox messages via mail-helper.sh
# - Exits immediately (~20K token budget per pulse)
#
# Usage:
#   coordinator-helper.sh pulse              # Run one coordination cycle
#   coordinator-helper.sh status             # Show current orchestration state
#   coordinator-helper.sh dispatch --task "description" [--to <agent>] [--priority high]
#   coordinator-helper.sh convoy --name "group" --tasks "t001,t002,t003"
#   coordinator-helper.sh watch [--interval 30]  # Watch mode (poll or fswatch)
#
# Trigger methods:
#   1. Manual: coordinator-helper.sh pulse
#   2. Cron: */5 * * * * coordinator-helper.sh pulse
#   3. Watch: coordinator-helper.sh watch (uses fswatch if available)

set -euo pipefail

# Configuration - resolve relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly MAIL_HELPER="${SCRIPT_DIR}/mail-helper.sh"
readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"
readonly MAIL_DIR="${AIDEVOPS_MAIL_DIR:-$HOME/.aidevops/.agent-workspace/mail}"
readonly MAIL_DB="$MAIL_DIR/mailbox.db"
readonly COORDINATOR_ID="coordinator"

log_info() { echo -e "${BLUE}[COORD]${NC} $*"; }
log_success() { echo -e "${GREEN}[COORD]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[COORD]${NC} $*"; }
log_error() { echo -e "${RED}[COORD]${NC} $*" >&2; }

#######################################
# Ensure mailbox DB exists
#######################################
ensure_db() {
    if [[ ! -f "$MAIL_DB" ]]; then
        "$MAIL_HELPER" status > /dev/null 2>&1
    fi
    return 0
}

#######################################
# Read active agents from SQLite
# Output: id,role,branch,status lines
#######################################
get_active_agents() {
    ensure_db
    sqlite3 -separator ',' "$MAIL_DB" "
        SELECT id, role, branch, worktree, status, registered, last_seen
        FROM agents WHERE status = 'active';
    " 2>/dev/null || true
}

#######################################
# Read unprocessed status reports
# Output: from: payload lines
#######################################
get_worker_reports() {
    ensure_db
    sqlite3 -separator '|' "$MAIL_DB" "
        SELECT from_agent, payload FROM messages
        WHERE type = 'status_report' AND status = 'unread'
        ORDER BY created_at ASC;
    " 2>/dev/null | while IFS='|' read -r from payload; do
        echo "$from: $payload"
    done
}

#######################################
# Mark status reports as read and archive them
#######################################
process_reports() {
    ensure_db
    sqlite3 "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE type = 'status_report' AND status = 'unread';
    "
}

#######################################
# Get ready tasks from TODO.md
# Output: task lines with no blockers
#######################################
get_ready_tasks() {
    local todo_file="${1:-TODO.md}"
    if [[ ! -f "$todo_file" ]]; then
        return 0
    fi

    grep '^- \[ \]' "$todo_file" | grep -v 'blocked-by:' | head -5 || true
}

#######################################
# Get idle workers (active agents with no unread messages)
#######################################
get_idle_workers() {
    ensure_db
    sqlite3 "$MAIL_DB" "
        SELECT a.id FROM agents a
        WHERE a.status = 'active' AND a.role = 'worker'
        AND NOT EXISTS (
            SELECT 1 FROM messages m
            WHERE m.to_agent = a.id AND m.status = 'unread'
        );
    " 2>/dev/null || true
}

#######################################
# Pulse: One coordination cycle
# Reads state → makes decisions → dispatches → exits
#######################################
cmd_pulse() {
    log_info "Coordinator pulse starting..."

    ensure_db

    # 1. Read current state
    local active_agents
    active_agents=$(get_active_agents)
    local agent_count=0
    if [[ -n "$active_agents" ]]; then
        agent_count=$(echo "$active_agents" | wc -l | tr -d ' ')
    fi

    log_info "Active agents: $agent_count"

    # 2. Process worker reports
    local reports
    reports=$(get_worker_reports)
    local report_count=0
    if [[ -n "$reports" ]]; then
        report_count=$(echo "$reports" | wc -l | tr -d ' ')
        log_info "Worker reports ($report_count):"
        echo "$reports" | while IFS= read -r report; do
            echo "  $report"
        done

        # Store notable reports to memory
        if [[ -x "$MEMORY_HELPER" ]]; then
            echo "$reports" | while IFS= read -r report; do
                if [[ -n "$report" ]]; then
                    "$MEMORY_HELPER" store \
                        --content "Coordinator received: $report" \
                        --type CONTEXT \
                        --tags "coordinator,status_report" 2>/dev/null || true
                fi
            done
        fi

        # Archive processed reports
        process_reports
    fi

    # 3. Find idle workers
    local idle_workers
    idle_workers=$(get_idle_workers)

    # 4. Find ready tasks to dispatch
    local ready_tasks
    ready_tasks=$(get_ready_tasks)
    local ready_count=0
    if [[ -n "$ready_tasks" ]]; then
        ready_count=$(echo "$ready_tasks" | wc -l | tr -d ' ')
    fi

    local dispatch_count=0
    if [[ -n "$ready_tasks" && -n "$idle_workers" ]]; then
        log_info "Dispatching tasks to idle workers..."
        local first_idle
        first_idle=$(echo "$idle_workers" | head -1)
        local first_task
        first_task=$(echo "$ready_tasks" | head -1)

        if [[ -n "$first_idle" && -n "$first_task" ]]; then
            "$MAIL_HELPER" send \
                --from "$COORDINATOR_ID" \
                --to "$first_idle" \
                --type task_dispatch \
                --payload "$first_task" \
                --priority normal 2>/dev/null || true
            log_success "Dispatched to $first_idle: $(echo "$first_task" | head -c 80)"
            dispatch_count=1
        fi
    elif [[ -z "$active_agents" ]]; then
        log_info "No active agents registered. Nothing to coordinate."
    elif [[ -z "$ready_tasks" ]]; then
        log_info "No ready tasks to dispatch."
    else
        log_info "All agents busy. Waiting for reports."
    fi

    # 5. Summary
    echo ""
    echo "<!--TOON:pulse_summary{agents,reports,dispatched,ready_tasks,timestamp}:"
    echo "${agent_count},${report_count},${dispatch_count},${ready_count},$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "-->"

    log_success "Pulse complete."
}

#######################################
# Show orchestration status
#######################################
cmd_status() {
    echo "=== Coordinator Status ==="
    echo ""

    ensure_db

    # Agent registry with inbox counts from SQLite
    local agents
    agents=$(sqlite3 -separator '|' "$MAIL_DB" "
        SELECT a.id, a.role, a.branch, a.status, a.last_seen,
               COALESCE(m.inbox_count, 0), COALESCE(m.unread_count, 0)
        FROM agents a
        LEFT JOIN (
            SELECT to_agent,
                   count(*) as inbox_count,
                   sum(CASE WHEN status = 'unread' THEN 1 ELSE 0 END) as unread_count
            FROM messages WHERE status != 'archived'
            GROUP BY to_agent
        ) m ON a.id = m.to_agent
        ORDER BY a.status DESC, a.last_seen DESC;
    " 2>/dev/null)

    if [[ -n "$agents" ]]; then
        echo "Registered Agents:"
        while IFS='|' read -r id role branch status last_seen inbox_count unread_count; do
            echo -e "  ${CYAN}$id${NC} ($role) [$status] branch:$branch inbox:$inbox_count($unread_count unread) last:$last_seen"
        done <<< "$agents"
    else
        echo "  No agents registered"
    fi

    echo ""

    # Mailbox status
    if [[ -x "$MAIL_HELPER" ]]; then
        "$MAIL_HELPER" status 2>/dev/null
    fi
}

#######################################
# Dispatch a specific task to an agent
#######################################
cmd_dispatch() {
    local task="" to="" priority="normal" convoy=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) [[ $# -lt 2 ]] && { log_error "--task requires a value"; return 1; }; task="$2"; shift 2 ;;
            --to) [[ $# -lt 2 ]] && { log_error "--to requires a value"; return 1; }; to="$2"; shift 2 ;;
            --priority) [[ $# -lt 2 ]] && { log_error "--priority requires a value"; return 1; }; priority="$2"; shift 2 ;;
            --convoy) [[ $# -lt 2 ]] && { log_error "--convoy requires a value"; return 1; }; convoy="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$task" ]]; then
        log_error "Missing --task <description>"
        return 1
    fi

    # If no target specified, find first idle worker
    if [[ -z "$to" ]]; then
        to=$(get_idle_workers | head -1)
        if [[ -z "$to" ]]; then
            log_error "No idle workers available. Register agents first."
            return 1
        fi
    fi

    local -a send_args=(
        --from "$COORDINATOR_ID"
        --to "$to"
        --type task_dispatch
        --payload "$task"
        --priority "$priority"
    )
    if [[ -n "$convoy" ]]; then
        send_args+=(--convoy "$convoy")
    fi

    "$MAIL_HELPER" send "${send_args[@]}"
}

#######################################
# Create a convoy (group of related tasks)
#######################################
cmd_convoy() {
    local name="" tasks=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) [[ $# -lt 2 ]] && { log_error "--name requires a value"; return 1; }; name="$2"; shift 2 ;;
            --tasks) [[ $# -lt 2 ]] && { log_error "--tasks requires a value"; return 1; }; tasks="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$name" || -z "$tasks" ]]; then
        log_error "Usage: coordinator-helper.sh convoy --name <group> --tasks <t001,t002>"
        return 1
    fi

    log_info "Creating convoy: $name"

    IFS=',' read -ra task_array <<< "$tasks"
    for task_id in "${task_array[@]}"; do
        local task_desc
        task_desc=$(grep "^- \[ \] $task_id " TODO.md 2>/dev/null | head -1 || echo "$task_id")

        cmd_dispatch --task "$task_desc" --convoy "$name" --priority normal
    done

    log_success "Convoy '$name' created with ${#task_array[@]} tasks"
}

#######################################
# Watch mode: trigger pulse on DB changes or interval
#######################################
cmd_watch() {
    local interval="${1:-30}"

    if [[ "$interval" == "--interval" ]]; then
        interval="${2:-30}"
    fi

    log_info "Watch mode: polling every ${interval}s (Ctrl+C to stop)"

    # fswatch on the DB file for near-instant triggers
    if command -v fswatch &>/dev/null; then
        log_info "Using fswatch for event-driven coordination"
        fswatch -o "$MAIL_DB" "$MAIL_DB-wal" 2>/dev/null | while read -r _; do
            cmd_pulse
        done
    else
        while true; do
            cmd_pulse
            sleep "$interval"
        done
    fi
}

#######################################
# Show usage
#######################################
show_usage() {
    cat << 'EOF'
coordinator-helper.sh - Stateless multi-agent coordinator (pulse pattern)

Usage:
  coordinator-helper.sh pulse                    Run one coordination cycle
  coordinator-helper.sh status                   Show orchestration state
  coordinator-helper.sh dispatch --task "desc"   Dispatch task to agent
  coordinator-helper.sh convoy --name "g" --tasks "t1,t2"  Group tasks
  coordinator-helper.sh watch [--interval 30]    Watch mode (poll/fswatch)

The coordinator is STATELESS - it reads state, dispatches, and exits.
Each pulse uses ~20K tokens of context (reads files, no conversation history).

Backend: SQLite (shared with mail-helper.sh via mailbox.db)

Trigger methods:
  Manual:  coordinator-helper.sh pulse
  Cron:    */5 * * * * ~/.aidevops/agents/scripts/coordinator-helper.sh pulse
  Watch:   coordinator-helper.sh watch (uses fswatch if available)

Environment:
  AIDEVOPS_MAIL_DIR    Override mail directory location
EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        pulse) cmd_pulse "$@" ;;
        status) cmd_status "$@" ;;
        dispatch) cmd_dispatch "$@" ;;
        convoy) cmd_convoy "$@" ;;
        watch) cmd_watch "$@" ;;
        help|--help|-h) show_usage ;;
        *) log_error "Unknown command: $command"; show_usage; return 1 ;;
    esac
}

main "$@"
