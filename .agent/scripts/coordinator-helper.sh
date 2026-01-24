#!/usr/bin/env bash
# coordinator-helper.sh - Stateless multi-agent coordinator (pulse pattern)
#
# Unlike Gas Town's persistent Mayor, this coordinator is STATELESS:
# - Reads current state (registry, outbox, TODO.md)
# - Makes dispatch decisions
# - Writes inbox messages
# - Exits immediately (~20K token budget per pulse)
#
# Usage:
#   coordinator-helper.sh pulse              # Run one coordination cycle
#   coordinator-helper.sh status             # Show current orchestration state
#   coordinator-helper.sh dispatch --task "description" [--to <agent>] [--priority high]
#   coordinator-helper.sh convoy --name "group" --tasks "t001,t002,t003"
#   coordinator-helper.sh watch [--interval 30]  # Watch mode (fswatch on outbox)
#
# Trigger methods:
#   1. Manual: coordinator-helper.sh pulse
#   2. Cron: */5 * * * * coordinator-helper.sh pulse
#   3. Watch: coordinator-helper.sh watch (fswatch on outbox/)

set -euo pipefail

# Configuration
readonly MAIL_HELPER="$HOME/.aidevops/agents/scripts/mail-helper.sh"
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"
readonly MAIL_DIR="${AIDEVOPS_MAIL_DIR:-$HOME/.aidevops/.agent-workspace/mail}"
readonly REGISTRY_FILE="$MAIL_DIR/registry.toon"
readonly COORDINATOR_ID="coordinator"

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[COORD]${NC} $*"; }
log_success() { echo -e "${GREEN}[COORD]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[COORD]${NC} $*"; }
log_error() { echo -e "${RED}[COORD]${NC} $*" >&2; }

#######################################
# Read active agents from registry
# Output: agent_id,role,branch,status lines
#######################################
get_active_agents() {
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        return 0
    fi
    grep ',active,' "$REGISTRY_FILE" 2>/dev/null | grep -v '^<!--' | grep -v '^-->' || true
}

#######################################
# Read unprocessed outbox messages (status reports from workers)
# Output: TOON message content
#######################################
get_worker_reports() {
    local outbox_dir="$MAIL_DIR/outbox"
    if [[ ! -d "$outbox_dir" ]]; then
        return 0
    fi
    
    for msg_file in "$outbox_dir"/*.toon; do
        [[ -f "$msg_file" ]] || continue
        local msg_type
        msg_type=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1 | cut -d',' -f4)
        if [[ "$msg_type" == "status_report" ]]; then
            local from
            from=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1 | cut -d',' -f2)
            local payload
            payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')
            echo "$from: $payload"
        fi
    done
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
    
    # Find unchecked tasks without blocked-by (or with all blockers completed)
    grep '^- \[ \]' "$todo_file" | grep -v 'blocked-by:' | head -5 || true
}

#######################################
# Pulse: One coordination cycle
# Reads state → makes decisions → dispatches → exits
#######################################
cmd_pulse() {
    log_info "Coordinator pulse starting..."
    
    # 1. Read current state
    local active_agents
    active_agents=$(get_active_agents)
    local agent_count=0
    if [[ -n "$active_agents" ]]; then
        agent_count=$(echo "$active_agents" | wc -l | tr -d ' ')
    fi
    
    log_info "Active agents: $agent_count"
    
    # 2. Process worker reports (archive after reading)
    local reports
    reports=$(get_worker_reports)
    if [[ -n "$reports" ]]; then
        log_info "Worker reports:"
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
        
        # Archive processed outbox messages
        local outbox_dir="$MAIL_DIR/outbox"
        if [[ -d "$outbox_dir" ]]; then
            for msg_file in "$outbox_dir"/*.toon; do
                [[ -f "$msg_file" ]] || continue
                local msg_type
                msg_type=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1 | cut -d',' -f4)
                if [[ "$msg_type" == "status_report" ]]; then
                    local msg_id
                    msg_id=$(basename "$msg_file" .toon)
                    "$MAIL_HELPER" archive "$msg_id" 2>/dev/null || true
                fi
            done
        fi
    fi
    
    # 3. Check for idle agents that could take new work
    local idle_agents=""
    if [[ -n "$active_agents" ]]; then
        while IFS=',' read -r agent_id role _branch _worktree _status _registered _last_seen; do
            # Check if agent has unread messages (busy) or not (idle)
            local inbox_dir="$MAIL_DIR/inbox/$agent_id"
            local unread=0
            if [[ -d "$inbox_dir" ]]; then
                unread=$(grep -rl ',unread$' "$inbox_dir" 2>/dev/null | wc -l | tr -d ' ')
            fi
            if [[ "$unread" -eq 0 && "$role" == "worker" ]]; then
                idle_agents="${idle_agents}${agent_id},"
            fi
        done <<< "$active_agents"
    fi
    
    # 4. Find ready tasks to dispatch
    local ready_tasks
    ready_tasks=$(get_ready_tasks)
    
    if [[ -n "$ready_tasks" && -n "$idle_agents" ]]; then
        log_info "Dispatching tasks to idle workers..."
        local first_idle
        first_idle=$(echo "$idle_agents" | cut -d',' -f1)
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
        fi
    elif [[ -z "$active_agents" ]]; then
        log_info "No active agents registered. Nothing to coordinate."
    elif [[ -z "$ready_tasks" ]]; then
        log_info "No ready tasks to dispatch."
    else
        log_info "All agents busy. Waiting for reports."
    fi
    
    # 5. Summary
    local report_count=0 dispatch_count=0 ready_count=0
    if [[ -n "$reports" ]]; then
        report_count=$(echo "$reports" | grep -c '.' 2>/dev/null || echo 0)
    fi
    if [[ -n "$idle_agents" ]]; then
        dispatch_count=$(echo "$idle_agents" | tr -cd ',' | wc -c | tr -d ' ')
    fi
    if [[ -n "$ready_tasks" ]]; then
        ready_count=$(echo "$ready_tasks" | grep -c '.' 2>/dev/null || echo 0)
    fi
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
    
    # Agent registry
    if [[ -f "$REGISTRY_FILE" ]]; then
        echo "Registered Agents:"
        while IFS=',' read -r agent_id role branch _worktree status _registered last_seen; do
            [[ "$agent_id" == "<!--"* || "$agent_id" == "-->"* || -z "$agent_id" ]] && continue
            local inbox_count=0
            if [[ -d "$MAIL_DIR/inbox/$agent_id" ]]; then
                inbox_count=$(find "$MAIL_DIR/inbox/$agent_id" -name "*.toon" 2>/dev/null | wc -l | tr -d ' ')
            fi
            echo -e "  ${CYAN}$agent_id${NC} ($role) [$status] branch:$branch inbox:$inbox_count last:$last_seen"
        done < "$REGISTRY_FILE"
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
            --task) task="$2"; shift 2 ;;
            --to) to="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            --convoy) convoy="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    
    if [[ -z "$task" ]]; then
        log_error "Missing --task <description>"
        return 1
    fi
    
    # If no target specified, find first idle worker
    if [[ -z "$to" ]]; then
        local active_agents
        active_agents=$(get_active_agents)
        if [[ -n "$active_agents" ]]; then
            to=$(echo "$active_agents" | grep ',worker,' | head -1 | cut -d',' -f1)
        fi
        if [[ -z "$to" ]]; then
            log_error "No idle workers available. Register agents first."
            return 1
        fi
    fi
    
    local -a extra_args=()
    if [[ -n "$convoy" ]]; then
        extra_args+=(--convoy "$convoy")
    fi
    
    "$MAIL_HELPER" send \
        --from "$COORDINATOR_ID" \
        --to "$to" \
        --type task_dispatch \
        --payload "$task" \
        --priority "$priority" \
        "${extra_args[@]}"
}

#######################################
# Create a convoy (group of related tasks)
#######################################
cmd_convoy() {
    local name="" tasks=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --tasks) tasks="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    
    if [[ -z "$name" || -z "$tasks" ]]; then
        log_error "Usage: coordinator-helper.sh convoy --name <group> --tasks <t001,t002>"
        return 1
    fi
    
    log_info "Creating convoy: $name"
    
    # Dispatch each task with convoy grouping
    IFS=',' read -ra task_array <<< "$tasks"
    for task_id in "${task_array[@]}"; do
        # Look up task description from TODO.md
        local task_desc
        task_desc=$(grep "^- \[ \] $task_id " TODO.md 2>/dev/null | head -1 || echo "$task_id")
        
        cmd_dispatch --task "$task_desc" --convoy "$name" --priority normal
    done
    
    log_success "Convoy '$name' created with ${#task_array[@]} tasks"
}

#######################################
# Watch mode: trigger pulse on outbox changes
#######################################
cmd_watch() {
    local interval="${1:-30}"
    
    # Remove --interval flag if present
    if [[ "$interval" == "--interval" ]]; then
        interval="${2:-30}"
    fi
    
    log_info "Watch mode: polling every ${interval}s (Ctrl+C to stop)"
    log_info "Tip: Install fswatch for event-driven triggers"
    
    # Check if fswatch is available for event-driven mode
    if command -v fswatch &>/dev/null; then
        log_info "Using fswatch for event-driven coordination"
        mkdir -p "$MAIL_DIR/outbox"
        fswatch -o "$MAIL_DIR/outbox" | while read -r _; do
            cmd_pulse
        done
    else
        # Fallback: polling
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
