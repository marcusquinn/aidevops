#!/usr/bin/env bash
# mail-helper.sh - TOON-based inter-agent mailbox system
# Enables asynchronous communication between parallel agent sessions
#
# Usage:
#   mail-helper.sh send --to <agent-id> --type <type> --payload "message" [--priority high|normal|low] [--convoy <id>]
#   mail-helper.sh check [--agent <id>] [--unread-only]
#   mail-helper.sh read <message-id>
#   mail-helper.sh archive <message-id>
#   mail-helper.sh prune [--older-than-days 7] [--dry-run]
#   mail-helper.sh status [--agent <id>]
#   mail-helper.sh register --agent <id> --role <role> [--branch <branch>] [--worktree <path>]
#   mail-helper.sh deregister --agent <id>
#   mail-helper.sh agents [--active-only]
#
# Message Types:
#   task_dispatch   - Coordinator assigns work to agent
#   status_report   - Agent reports progress/completion
#   discovery       - Agent shares a finding with others
#   request         - Agent requests help/info from another
#   broadcast       - Message to all agents
#
# Lifecycle: send → check → read → archive → (7-day prune with memory capture)

set -euo pipefail

# Configuration
readonly MAIL_DIR="${AIDEVOPS_MAIL_DIR:-$HOME/.aidevops/.agent-workspace/mail}"
readonly INBOX_DIR="$MAIL_DIR/inbox"
readonly OUTBOX_DIR="$MAIL_DIR/outbox"
readonly ARCHIVE_DIR="$MAIL_DIR/archive"
readonly REGISTRY_FILE="$MAIL_DIR/registry.toon"
readonly DEFAULT_PRUNE_DAYS=7
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[MAIL]${NC} $*"; }
log_success() { echo -e "${GREEN}[MAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[MAIL]${NC} $*"; }
log_error() { echo -e "${RED}[MAIL]${NC} $*" >&2; }

#######################################
# Ensure mail directories exist
#######################################
ensure_dirs() {
    mkdir -p "$INBOX_DIR" "$OUTBOX_DIR" "$ARCHIVE_DIR"
}

#######################################
# Generate unique message ID
# Format: msg-YYYYMMDD-HHMMSS-RANDOM
#######################################
generate_id() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local random
    random=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "msg-${timestamp}-${random}"
}

#######################################
# Get current agent ID (from env or generate)
#######################################
get_agent_id() {
    if [[ -n "${AIDEVOPS_AGENT_ID:-}" ]]; then
        echo "$AIDEVOPS_AGENT_ID"
        return 0
    fi
    # Derive from worktree/branch name
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    local worktree_name
    worktree_name=$(basename "$(pwd)" | sed 's/^aidevops[.-]//')
    if [[ "$worktree_name" != "aidevops" && "$worktree_name" != "." ]]; then
        echo "agent-${worktree_name}"
    else
        echo "agent-${branch}"
    fi
}

#######################################
# Write TOON message file
# Args: $1=filepath, $2=id, $3=from, $4=to, $5=type, $6=priority, $7=convoy, $8=payload
#######################################
write_message() {
    local filepath="$1"
    local id="$2"
    local from="$3"
    local to="$4"
    local msg_type="$5"
    local priority="$6"
    local convoy="$7"
    local payload="$8"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    cat > "$filepath" << EOF
<!--TOON:message{id,from,to,type,priority,convoy,timestamp,status}:
${id},${from},${to},${msg_type},${priority},${convoy:-none},${timestamp},unread
-->

${payload}
EOF
}

#######################################
# Parse TOON message file
# Returns: id|from|to|type|priority|convoy|timestamp|status|payload
#######################################
parse_message() {
    local filepath="$1"
    if [[ ! -f "$filepath" ]]; then
        log_error "Message file not found: $filepath"
        return 1
    fi

    local header
    header=$(grep -A1 'TOON:message{' "$filepath" | tail -1)
    local payload
    payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$filepath" | sed '/^$/d')

    echo "${header}|${payload}"
}

#######################################
# Send a message
#######################################
cmd_send() {
    local to="" msg_type="" payload="" priority="normal" convoy=""
    local from
    from=$(get_agent_id)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) [[ $# -lt 2 ]] && { log_error "--to requires a value"; return 1; }; to="$2"; shift 2 ;;
            --type) [[ $# -lt 2 ]] && { log_error "--type requires a value"; return 1; }; msg_type="$2"; shift 2 ;;
            --payload) [[ $# -lt 2 ]] && { log_error "--payload requires a value"; return 1; }; payload="$2"; shift 2 ;;
            --priority) [[ $# -lt 2 ]] && { log_error "--priority requires a value"; return 1; }; priority="$2"; shift 2 ;;
            --convoy) [[ $# -lt 2 ]] && { log_error "--convoy requires a value"; return 1; }; convoy="$2"; shift 2 ;;
            --from) [[ $# -lt 2 ]] && { log_error "--from requires a value"; return 1; }; from="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Validate required fields
    if [[ -z "$to" ]]; then
        log_error "Missing --to <agent-id>"
        return 1
    fi
    if [[ -z "$msg_type" ]]; then
        log_error "Missing --type <message-type>"
        return 1
    fi
    if [[ -z "$payload" ]]; then
        log_error "Missing --payload <message>"
        return 1
    fi

    # Validate type
    local valid_types="task_dispatch status_report discovery request broadcast"
    if ! echo "$valid_types" | grep -qw "$msg_type"; then
        log_error "Invalid type: $msg_type (valid: $valid_types)"
        return 1
    fi

    # Validate priority
    if ! echo "high normal low" | grep -qw "$priority"; then
        log_error "Invalid priority: $priority (valid: high, normal, low)"
        return 1
    fi

    ensure_dirs

    local msg_id
    msg_id=$(generate_id)

    # Write to sender's outbox
    write_message "$OUTBOX_DIR/${msg_id}.toon" "$msg_id" "$from" "$to" "$msg_type" "$priority" "$convoy" "$payload"

    # Write to recipient's inbox (or broadcast to all)
    if [[ "$to" == "all" || "$msg_type" == "broadcast" ]]; then
        # Broadcast: copy to all registered agents' inboxes
        if [[ -f "$REGISTRY_FILE" ]]; then
            local agents
            agents=$(grep -v '^<!--' "$REGISTRY_FILE" | grep -v '^$' | grep -v '^-->' | cut -d',' -f1)
            local count=0
            while IFS= read -r agent_id; do
                if [[ -n "$agent_id" && "$agent_id" != "$from" ]]; then
                    local agent_inbox="$INBOX_DIR/$agent_id"
                    mkdir -p "$agent_inbox"
                    write_message "$agent_inbox/${msg_id}.toon" "$msg_id" "$from" "$agent_id" "$msg_type" "$priority" "$convoy" "$payload"
                    count=$((count + 1))
                fi
            done <<< "$agents"
            log_success "Broadcast sent: $msg_id (to $count agents)"
        else
            # No registry, write to general inbox
            write_message "$INBOX_DIR/${msg_id}.toon" "$msg_id" "$from" "$to" "$msg_type" "$priority" "$convoy" "$payload"
            log_success "Sent: $msg_id → $to (no registry, general inbox)"
        fi
    else
        # Direct message: write to recipient's inbox
        local recipient_inbox="$INBOX_DIR/$to"
        mkdir -p "$recipient_inbox"
        write_message "$recipient_inbox/${msg_id}.toon" "$msg_id" "$from" "$to" "$msg_type" "$priority" "$convoy" "$payload"
        log_success "Sent: $msg_id → $to (priority: $priority)"
    fi

    echo "$msg_id"
}

#######################################
# Check inbox for messages
#######################################
cmd_check() {
    local agent_id="" unread_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -lt 2 ]] && { log_error "--agent requires a value"; return 1; }; agent_id="$2"; shift 2 ;;
            --unread-only) unread_only=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$agent_id" ]]; then
        agent_id=$(get_agent_id)
    fi

    ensure_dirs

    local inbox_path="$INBOX_DIR/$agent_id"
    if [[ ! -d "$inbox_path" ]]; then
        echo "No messages for $agent_id"
        return 0
    fi

    local count=0
    local unread=0

    echo "<!--TOON:inbox{id,from,type,priority,convoy,timestamp,status}:"
    for msg_file in "$inbox_path"/*.toon; do
        [[ -f "$msg_file" ]] || continue
        local header
        header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1)
        if [[ -n "$header" ]]; then
            local status
            status=$(echo "$header" | cut -d',' -f8)
            if [[ "$unread_only" == true && "$status" != "unread" ]]; then
                continue
            fi
            # Output: id,from,type,priority,convoy,timestamp,status
            local id from msg_type priority convoy timestamp
            id=$(echo "$header" | cut -d',' -f1)
            from=$(echo "$header" | cut -d',' -f2)
            msg_type=$(echo "$header" | cut -d',' -f4)
            priority=$(echo "$header" | cut -d',' -f5)
            convoy=$(echo "$header" | cut -d',' -f6)
            timestamp=$(echo "$header" | cut -d',' -f7)
            echo "${id},${from},${msg_type},${priority},${convoy},${timestamp},${status}"
            count=$((count + 1))
            if [[ "$status" == "unread" ]]; then
                unread=$((unread + 1))
            fi
        fi
    done
    echo "-->"
    echo ""
    echo "Total: $count messages ($unread unread) for $agent_id"
}

#######################################
# Read a specific message (marks as read)
#######################################
cmd_read_msg() {
    local msg_id="" agent_id=""
    # Parse args: support both positional and --agent flag
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -lt 2 ]] && { log_error "--agent requires a value"; return 1; }; agent_id="$2"; shift 2 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) msg_id="$1"; shift ;;
        esac
    done
    if [[ -z "$msg_id" ]]; then
        log_error "Usage: mail-helper.sh read <message-id> [--agent <id>]"
        return 1
    fi

    if [[ -z "$agent_id" ]]; then
        agent_id=$(get_agent_id)
    fi
    local msg_file="$INBOX_DIR/$agent_id/${msg_id}.toon"

    if [[ ! -f "$msg_file" ]]; then
        # Try general inbox
        msg_file="$INBOX_DIR/${msg_id}.toon"
    fi

    if [[ ! -f "$msg_file" ]]; then
        log_error "Message not found: $msg_id"
        return 1
    fi

    # Mark as read
    if command -v sed &>/dev/null; then
        sed -i.bak 's/,unread$/,read/' "$msg_file" && rm -f "${msg_file}.bak"
    fi

    cat "$msg_file"
}

#######################################
# Archive a message
#######################################
cmd_archive() {
    local msg_id="" agent_id=""
    # Parse args: support both positional and --agent flag
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -lt 2 ]] && { log_error "--agent requires a value"; return 1; }; agent_id="$2"; shift 2 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) msg_id="$1"; shift ;;
        esac
    done
    if [[ -z "$msg_id" ]]; then
        log_error "Usage: mail-helper.sh archive <message-id> [--agent <id>]"
        return 1
    fi

    if [[ -z "$agent_id" ]]; then
        agent_id=$(get_agent_id)
    fi
    local msg_file="$INBOX_DIR/$agent_id/${msg_id}.toon"

    if [[ ! -f "$msg_file" ]]; then
        msg_file="$INBOX_DIR/${msg_id}.toon"
    fi

    if [[ ! -f "$msg_file" ]]; then
        log_error "Message not found: $msg_id"
        return 1
    fi

    ensure_dirs
    local archive_subdir
    archive_subdir="$ARCHIVE_DIR/$(date +%Y-%m)"
    mkdir -p "$archive_subdir"

    mv "$msg_file" "$archive_subdir/"
    log_success "Archived: $msg_id → $archive_subdir/"
}

#######################################
# Prune old archived messages (with memory capture)
#######################################
cmd_prune() {
    local older_than_days="$DEFAULT_PRUNE_DAYS"
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --older-than-days) [[ $# -lt 2 ]] && { log_error "--older-than-days requires a value"; return 1; }; older_than_days="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_dirs

    local pruned=0
    local remembered=0

    # Find archived messages older than threshold
    while IFS= read -r msg_file; do
        [[ -f "$msg_file" ]] || continue

        if [[ "$dry_run" == true ]]; then
            log_info "Would prune: $msg_file"
            pruned=$((pruned + 1))
            continue
        fi

        # Before pruning, capture notable messages to memory
        local msg_type
        msg_type=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1 | cut -d',' -f4)
        local payload
        payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

        # Remember discoveries and important status reports
        if [[ ("$msg_type" == "discovery" || "$msg_type" == "status_report") && -x "$MEMORY_HELPER" && -n "$payload" ]]; then
            "$MEMORY_HELPER" store \
                --content "Mailbox ($msg_type): $payload" \
                --type CONTEXT \
                --tags "mailbox,${msg_type},archived" 2>/dev/null && remembered=$((remembered + 1))
        fi

        rm -f "$msg_file"
        pruned=$((pruned + 1))
    done < <(find "$ARCHIVE_DIR" -name "*.toon" -mtime +"$older_than_days" 2>/dev/null)

    if [[ "$dry_run" == true ]]; then
        log_info "Dry run: would prune $pruned messages"
    else
        log_success "Pruned $pruned archived messages ($remembered captured to memory)"
    fi
}

#######################################
# Show mailbox status
#######################################
cmd_status() {
    local agent_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -lt 2 ]] && { log_error "--agent requires a value"; return 1; }; agent_id="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_dirs

    if [[ -n "$agent_id" ]]; then
        # Status for specific agent
        local inbox_count=0 unread_count=0
        local inbox_path="$INBOX_DIR/$agent_id"
        if [[ -d "$inbox_path" ]]; then
            inbox_count=$(find "$inbox_path" -name "*.toon" 2>/dev/null | wc -l | tr -d ' ')
            unread_count=$(grep -rl ',unread$' "$inbox_path" 2>/dev/null | wc -l | tr -d ' ')
        fi
        echo "Agent: $agent_id"
        echo "  Inbox: $inbox_count messages ($unread_count unread)"
    else
        # Global status
        local total_inbox=0 total_outbox=0 total_archive=0 total_agents=0

        # Count per-agent inboxes
        if [[ -d "$INBOX_DIR" ]]; then
            for agent_dir in "$INBOX_DIR"/*/; do
                [[ -d "$agent_dir" ]] || continue
                local count
                count=$(find "$agent_dir" -name "*.toon" 2>/dev/null | wc -l | tr -d ' ')
                total_inbox=$((total_inbox + count))
                total_agents=$((total_agents + 1))
            done
            # Also count general inbox messages
            local general
            general=$(find "$INBOX_DIR" -maxdepth 1 -name "*.toon" 2>/dev/null | wc -l | tr -d ' ')
            total_inbox=$((total_inbox + general))
        fi

        if [[ -d "$OUTBOX_DIR" ]]; then
            total_outbox=$(find "$OUTBOX_DIR" -name "*.toon" 2>/dev/null | wc -l | tr -d ' ')
        fi

        if [[ -d "$ARCHIVE_DIR" ]]; then
            total_archive=$(find "$ARCHIVE_DIR" -name "*.toon" 2>/dev/null | wc -l | tr -d ' ')
        fi

        echo "<!--TOON:mail_status{inbox,outbox,archive,agents}:"
        echo "${total_inbox},${total_outbox},${total_archive},${total_agents}"
        echo "-->"
        echo ""
        echo "Mailbox Status:"
        echo "  Inbox:   $total_inbox messages across $total_agents agents"
        echo "  Outbox:  $total_outbox messages"
        echo "  Archive: $total_archive messages"

        # Show registry if exists
        if [[ -f "$REGISTRY_FILE" ]]; then
            echo ""
            echo "Registered Agents:"
            cat "$REGISTRY_FILE"
        fi
    fi
}

#######################################
# Register an agent in the registry
#######################################
cmd_register() {
    local agent_id="" role="" branch="" worktree=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -lt 2 ]] && { log_error "--agent requires a value"; return 1; }; agent_id="$2"; shift 2 ;;
            --role) [[ $# -lt 2 ]] && { log_error "--role requires a value"; return 1; }; role="$2"; shift 2 ;;
            --branch) [[ $# -lt 2 ]] && { log_error "--branch requires a value"; return 1; }; branch="$2"; shift 2 ;;
            --worktree) [[ $# -lt 2 ]] && { log_error "--worktree requires a value"; return 1; }; worktree="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$agent_id" ]]; then
        agent_id=$(get_agent_id)
    fi
    if [[ -z "$role" ]]; then
        role="worker"
    fi
    if [[ -z "$branch" ]]; then
        branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    fi
    if [[ -z "$worktree" ]]; then
        worktree=$(pwd)
    fi

    ensure_dirs

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Create or update registry (with file locking to prevent race conditions)
    local lock_file="${REGISTRY_FILE}.lock"
    local lock_acquired=false
    for _attempt in 1 2 3 4 5; do
        if (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null; then
            lock_acquired=true
            break
        fi
        sleep 0.2
    done
    if [[ "$lock_acquired" != "true" ]]; then
        log_warn "Could not acquire registry lock (stale lock?). Removing and retrying."
        rm -f "$lock_file"
        (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null || true
    fi
    # shellcheck disable=SC2064
    trap "rm -f '$lock_file'" RETURN

    if [[ ! -f "$REGISTRY_FILE" ]]; then
        cat > "$REGISTRY_FILE" << EOF
<!--TOON:agents{id,role,branch,worktree,status,registered,last_seen}:
${agent_id},${role},${branch},${worktree},active,${timestamp},${timestamp}
-->
EOF
    else
        # Check if agent already registered
        if grep -q "^${agent_id}," "$REGISTRY_FILE" 2>/dev/null; then
            # Update last_seen and status
            if command -v sed &>/dev/null; then
                sed -i.bak "s|^${agent_id},.*|${agent_id},${role},${branch},${worktree},active,$(grep "^${agent_id}," "$REGISTRY_FILE" | cut -d',' -f6),${timestamp}|" "$REGISTRY_FILE"
                rm -f "${REGISTRY_FILE}.bak"
            fi
            log_info "Updated agent: $agent_id (last_seen: $timestamp)"
        else
            # Add new agent before closing -->
            if command -v sed &>/dev/null; then
                sed -i.bak "/^-->$/i\\
${agent_id},${role},${branch},${worktree},active,${timestamp},${timestamp}" "$REGISTRY_FILE"
                rm -f "${REGISTRY_FILE}.bak"
            fi
            log_success "Registered agent: $agent_id (role: $role, branch: $branch)"
        fi
    fi

    # Create agent's inbox directory
    mkdir -p "$INBOX_DIR/$agent_id"
}

#######################################
# Deregister an agent
#######################################
cmd_deregister() {
    local agent_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -lt 2 ]] && { log_error "--agent requires a value"; return 1; }; agent_id="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$agent_id" ]]; then
        agent_id=$(get_agent_id)
    fi

    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_warn "No registry file found"
        return 0
    fi

    # Acquire lock before modifying registry
    local lock_file="${REGISTRY_FILE}.lock"
    local lock_acquired=false
    for _attempt in 1 2 3 4 5; do
        if (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null; then
            lock_acquired=true
            break
        fi
        sleep 0.2
    done
    if [[ "$lock_acquired" != "true" ]]; then
        rm -f "$lock_file"
        (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null || true
    fi
    # shellcheck disable=SC2064
    trap "rm -f '$lock_file'" RETURN

    # Mark as inactive (don't remove - preserves history)
    if command -v sed &>/dev/null; then
        sed -i.bak "s|^\(${agent_id},.*\),active,|\\1,inactive,|" "$REGISTRY_FILE"
        rm -f "${REGISTRY_FILE}.bak"
    fi

    log_success "Deregistered agent: $agent_id (marked inactive)"
}

#######################################
# List registered agents
#######################################
cmd_agents() {
    local active_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --active-only) active_only=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo "No agents registered"
        return 0
    fi

    if [[ "$active_only" == true ]]; then
        echo "Active Agents:"
        grep ',active,' "$REGISTRY_FILE" 2>/dev/null | while IFS=',' read -r id role branch _worktree _status _registered last_seen; do
            echo "  ${CYAN}$id${NC} ($role) on $branch - last seen: $last_seen"
        done
    else
        cat "$REGISTRY_FILE"
    fi
}

#######################################
# Show usage
#######################################
show_usage() {
    cat << 'EOF'
mail-helper.sh - TOON-based inter-agent mailbox system

Usage:
  mail-helper.sh send --to <agent-id> --type <type> --payload "message" [options]
  mail-helper.sh check [--agent <id>] [--unread-only]
  mail-helper.sh read <message-id>
  mail-helper.sh archive <message-id>
  mail-helper.sh prune [--older-than-days 7] [--dry-run]
  mail-helper.sh status [--agent <id>]
  mail-helper.sh register --agent <id> --role <role> [--branch <branch>]
  mail-helper.sh deregister --agent <id>
  mail-helper.sh agents [--active-only]

Message Types:
  task_dispatch   Coordinator assigns work to agent
  status_report   Agent reports progress/completion
  discovery       Agent shares a finding with others
  request         Agent requests help/info from another
  broadcast       Message to all agents

Options:
  --priority      high|normal|low (default: normal)
  --convoy        Group related messages by convoy ID

Environment:
  AIDEVOPS_AGENT_ID    Override auto-detected agent identity
  AIDEVOPS_MAIL_DIR    Override mail directory location

Lifecycle:
  send → check → read → archive → prune (7-day, with memory capture)
EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        send) cmd_send "$@" ;;
        check) cmd_check "$@" ;;
        read) cmd_read_msg "$@" ;;
        archive) cmd_archive "$@" ;;
        prune) cmd_prune "$@" ;;
        status) cmd_status "$@" ;;
        register) cmd_register "$@" ;;
        deregister) cmd_deregister "$@" ;;
        agents) cmd_agents "$@" ;;
        help|--help|-h) show_usage ;;
        *) log_error "Unknown command: $command"; show_usage; return 1 ;;
    esac
}

main "$@"
