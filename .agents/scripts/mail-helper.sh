#!/usr/bin/env bash
# mail-helper.sh - SQLite-backed inter-agent mailbox system
# Enables asynchronous communication between parallel agent sessions
#
# Usage:
#   mail-helper.sh send --to <agent-id> --type <type> --payload "message" [--priority high|normal|low] [--convoy <id>]
#   mail-helper.sh check [--agent <id>] [--unread-only]
#   mail-helper.sh read <message-id> [--agent <id>]
#   mail-helper.sh archive <message-id> [--agent <id>]
#   mail-helper.sh prune [--older-than-days 7] [--force]
#   mail-helper.sh status [--agent <id>]
#   mail-helper.sh register --agent <id> --role <role> [--branch <branch>] [--worktree <path>]
#   mail-helper.sh deregister --agent <id>
#   mail-helper.sh agents [--active-only]
#   mail-helper.sh migrate                          # Migrate TOON files to SQLite
#
# Message Types:
#   task_dispatch   - Coordinator assigns work to agent
#   status_report   - Agent reports progress/completion
#   discovery       - Agent shares a finding with others
#   request         - Agent requests help/info from another
#   broadcast       - Message to all agents
#
# Lifecycle: send → check → read → archive (prune is manual with storage report)
#
# Performance: SQLite WAL mode handles thousands of messages with <10ms queries.
# Previous TOON file-based system: ~25ms per message (2.5s for 100 messages).
# SQLite: <1ms per query regardless of message count.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly MAIL_DIR="${AIDEVOPS_MAIL_DIR:-$HOME/.aidevops/.agent-workspace/mail}"
readonly MAIL_DB="$MAIL_DIR/mailbox.db"
readonly DEFAULT_PRUNE_DAYS=7
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[MAIL]${NC} $*"; }
log_success() { echo -e "${GREEN}[MAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[MAIL]${NC} $*"; }
log_error() { echo -e "${RED}[MAIL]${NC} $*" >&2; }

#######################################
# SQLite wrapper: sets busy_timeout on every connection (t135.3)
# busy_timeout is per-connection and must be set each time
#######################################
db() {
    sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Ensure database exists and is initialized
#######################################
ensure_db() {
    mkdir -p "$MAIL_DIR"

    if [[ ! -f "$MAIL_DB" ]]; then
        init_db
        return 0
    fi

    # Check if schema needs upgrade (agents table might be missing)
    local has_agents
    has_agents=$(db "$MAIL_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='agents';")
    if [[ "$has_agents" -eq 0 ]]; then
        init_db
    fi

    # Ensure WAL mode for existing databases created before t135.3
    local current_mode
    current_mode=$(db "$MAIL_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
    if [[ "$current_mode" != "wal" ]]; then
        db "$MAIL_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || echo "[WARN] Failed to enable WAL mode for mail DB" >&2
    fi

    return 0
}

#######################################
# Initialize SQLite database with schema
#######################################
init_db() {
    db "$MAIL_DB" << 'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS messages (
    id          TEXT PRIMARY KEY,
    from_agent  TEXT NOT NULL,
    to_agent    TEXT NOT NULL,
    type        TEXT NOT NULL CHECK(type IN ('task_dispatch','status_report','discovery','request','broadcast')),
    priority    TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('high','normal','low')),
    convoy      TEXT DEFAULT 'none',
    payload     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'unread' CHECK(status IN ('unread','read','archived')),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at     TEXT,
    archived_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_to_status ON messages(to_agent, status);
CREATE INDEX IF NOT EXISTS idx_messages_to_unread ON messages(to_agent) WHERE status = 'unread';
CREATE INDEX IF NOT EXISTS idx_messages_type ON messages(type);
CREATE INDEX IF NOT EXISTS idx_messages_convoy ON messages(convoy) WHERE convoy != 'none';
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_archived ON messages(archived_at) WHERE status = 'archived';

CREATE TABLE IF NOT EXISTS agents (
    id          TEXT PRIMARY KEY,
    role        TEXT NOT NULL DEFAULT 'worker',
    branch      TEXT,
    worktree    TEXT,
    status      TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','inactive')),
    registered  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    last_seen   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
SQL

    log_info "Initialized mailbox database: $MAIL_DB"
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
# Get current agent ID (from env or derive)
#######################################
get_agent_id() {
    if [[ -n "${AIDEVOPS_AGENT_ID:-}" ]]; then
        echo "$AIDEVOPS_AGENT_ID"
        return 0
    fi
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
# Escape single quotes for SQL
#######################################
sql_escape() {
    local input="$1"
    echo "${input//\'/\'\'}"
}

#######################################
# Send a message
#######################################
cmd_send() {
    local to="" msg_type="" payload="" priority="normal" convoy="none"
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

    local valid_types="task_dispatch status_report discovery request broadcast"
    if ! echo "$valid_types" | grep -qw "$msg_type"; then
        log_error "Invalid type: $msg_type (valid: $valid_types)"
        return 1
    fi

    if ! echo "high normal low" | grep -qw "$priority"; then
        log_error "Invalid priority: $priority (valid: high, normal, low)"
        return 1
    fi

    ensure_db

    local msg_id
    msg_id=$(generate_id)
    local escaped_payload
    escaped_payload=$(sql_escape "$payload")
    local escaped_convoy
    escaped_convoy=$(sql_escape "$convoy")

    if [[ "$to" == "all" || "$msg_type" == "broadcast" ]]; then
        # Broadcast: insert one message per active agent (excluding sender)
        local count
        count=$(db "$MAIL_DB" "
            SELECT count(*) FROM agents WHERE status='active' AND id != '$(sql_escape "$from")';
        ")

        local agents_list
        agents_list=$(db "$MAIL_DB" "
            SELECT id FROM agents WHERE status='active' AND id != '$(sql_escape "$from")';
        ")

        if [[ -n "$agents_list" ]]; then
            while IFS= read -r agent_id; do
                local broadcast_id
                broadcast_id=$(generate_id)
                db "$MAIL_DB" "
                    INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
                    VALUES ('$broadcast_id', '$(sql_escape "$from")', '$(sql_escape "$agent_id")', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
                "
            done <<< "$agents_list"
            log_success "Broadcast sent: $msg_id (to $count agents)"
        else
            # No agents registered, insert as general broadcast
            db "$MAIL_DB" "
                INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
                VALUES ('$msg_id', '$(sql_escape "$from")', 'all', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
            "
            log_success "Sent: $msg_id → all (no agents registered)"
        fi
    else
        db "$MAIL_DB" "
            INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
            VALUES ('$msg_id', '$(sql_escape "$from")', '$(sql_escape "$to")', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
        "
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

    ensure_db

    local escaped_id
    escaped_id=$(sql_escape "$agent_id")
    local where_clause="to_agent = '${escaped_id}' AND status != 'archived'"
    if [[ "$unread_only" == true ]]; then
        where_clause="to_agent = '${escaped_id}' AND status = 'unread'"
    fi

    local results
    results=$(db -separator ',' "$MAIL_DB" "
        SELECT id, from_agent, type, priority, convoy, created_at, status
        FROM messages
        WHERE $where_clause
        ORDER BY
            CASE priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 WHEN 'low' THEN 2 END,
            created_at DESC;
    ")

    local total unread
    total=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent = '$(sql_escape "$agent_id")' AND status != 'archived';")
    unread=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent = '$(sql_escape "$agent_id")' AND status = 'unread';")

    echo "<!--TOON:inbox{id,from,type,priority,convoy,timestamp,status}:"
    if [[ -n "$results" ]]; then
        echo "$results"
    fi
    echo "-->"
    echo ""
    echo "Total: $total messages ($unread unread) for $agent_id"
}

#######################################
# Read a specific message (marks as read)
#######################################
cmd_read_msg() {
    local msg_id="" agent_id=""

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

    ensure_db

    local row
    row=$(db -separator '|' "$MAIL_DB" "
        SELECT id, from_agent, to_agent, type, priority, convoy, created_at, status, payload
        FROM messages WHERE id = '$(sql_escape "$msg_id")';
    ")

    if [[ -z "$row" ]]; then
        log_error "Message not found: $msg_id"
        return 1
    fi

    # Mark as read
    db "$MAIL_DB" "
        UPDATE messages SET status = 'read', read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$msg_id")' AND status = 'unread';
    "

    # Output in TOON format for backward compatibility
    local id from_agent to_agent msg_type priority convoy created_at status payload
    IFS='|' read -r id from_agent to_agent msg_type priority convoy created_at status payload <<< "$row"
    echo "<!--TOON:message{id,from,to,type,priority,convoy,timestamp,status}:"
    echo "${id},${from_agent},${to_agent},${msg_type},${priority},${convoy},${created_at},read"
    echo "-->"
    echo ""
    echo "$payload"
}

#######################################
# Archive a message
#######################################
cmd_archive() {
    local msg_id="" agent_id=""

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

    ensure_db

    local updated
    updated=$(db "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$msg_id")' AND status != 'archived';
        SELECT changes();
    ")

    if [[ "$updated" -eq 0 ]]; then
        log_error "Message not found or already archived: $msg_id"
        return 1
    fi

    log_success "Archived: $msg_id"
}

#######################################
# Prune: manual deletion with storage report
# By default shows storage report. Use --force to actually delete.
#######################################
cmd_prune() {
    local older_than_days="$DEFAULT_PRUNE_DAYS"
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --older-than-days) [[ $# -lt 2 ]] && { log_error "--older-than-days requires a value"; return 1; }; older_than_days="$2"; shift 2 ;;
            --force) force=true; shift ;;
            # Keep --dry-run as alias for default behavior (backward compat)
            --dry-run) shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
        log_error "Invalid value for --older-than-days: must be a positive integer"
        return 1
    fi

    ensure_db

    # Storage report
    local db_size_bytes
    db_size_bytes=$(stat -f%z "$MAIL_DB" 2>/dev/null || stat -c%s "$MAIL_DB" 2>/dev/null || echo "0")
    local db_size_kb=$(( db_size_bytes / 1024 ))

    # Single query for all counts (reduces sqlite3 invocations)
    local total_messages unread_messages read_messages archived_messages
    IFS='|' read -r total_messages unread_messages read_messages archived_messages < <(db -separator '|' "$MAIL_DB" "
        SELECT count(*),
            coalesce(sum(CASE WHEN status = 'unread' THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'read' THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'archived' THEN 1 ELSE 0 END), 0)
        FROM messages;
    ")

    # Single query for prunable + archivable counts
    local prunable archivable
    IFS='|' read -r prunable archivable < <(db -separator '|' "$MAIL_DB" "
        SELECT
            coalesce(sum(CASE WHEN status = 'archived' AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days') THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'read' AND read_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days') THEN 1 ELSE 0 END), 0)
        FROM messages;
    ")

    # Single query for date range
    local oldest_msg newest_msg
    IFS='|' read -r oldest_msg newest_msg < <(db -separator '|' "$MAIL_DB" "
        SELECT coalesce(min(created_at), 'none'), coalesce(max(created_at), 'none') FROM messages;
    ")

    # Per-type breakdown
    local type_breakdown
    type_breakdown=$(db -separator ': ' "$MAIL_DB" "
        SELECT type, count(*) FROM messages GROUP BY type ORDER BY count(*) DESC;
    ")

    echo "Mailbox Storage Report"
    echo "======================"
    echo ""
    echo "  Database:    ${db_size_kb}KB ($MAIL_DB)"
    echo "  Messages:    $total_messages total"
    echo "    Unread:    $unread_messages"
    echo "    Read:      $read_messages"
    echo "    Archived:  $archived_messages"
    echo "  Date range:  $oldest_msg → $newest_msg"
    echo ""
    echo "  By type:"
    if [[ -n "$type_breakdown" ]]; then
        echo "$type_breakdown" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        echo "    (none)"
    fi
    echo ""
    echo "  Prunable (archived >${older_than_days}d): $prunable messages"
    echo "  Archivable (read >${older_than_days}d):   $archivable messages"

    if [[ "$force" != true ]]; then
        if [[ "$prunable" -gt 0 || "$archivable" -gt 0 ]]; then
            echo ""
            echo "  To delete prunable messages:  mail-helper.sh prune --force"
            echo "  To change threshold:          mail-helper.sh prune --older-than-days 30 --force"
        else
            echo ""
            echo "  Nothing to prune. All messages are within the ${older_than_days}-day window."
        fi
        return 0
    fi

    # --force: actually delete
    log_info "Pruning with --force (${older_than_days}-day threshold)..."

    # Capture discoveries and status reports to memory before pruning
    local remembered=0
    if [[ -x "$MEMORY_HELPER" ]]; then
        local notable_messages
        notable_messages=$(db -separator '|' "$MAIL_DB" "
            SELECT type, payload FROM messages
            WHERE status = 'archived'
            AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days')
            AND type IN ('discovery', 'status_report');
        ")

        if [[ -n "$notable_messages" ]]; then
            while IFS='|' read -r msg_type payload; do
                if [[ -n "$payload" ]]; then
                    "$MEMORY_HELPER" store \
                        --content "Mailbox ($msg_type): $payload" \
                        --type CONTEXT \
                        --tags "mailbox,${msg_type},archived" 2>/dev/null && remembered=$((remembered + 1))
                fi
            done <<< "$notable_messages"
        fi
    fi

    # Archive old read messages first
    local auto_archived
    auto_archived=$(db "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE status = 'read'
        AND read_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days');
        SELECT changes();
    ")

    # Delete old archived messages
    local pruned
    pruned=$(db "$MAIL_DB" "
        DELETE FROM messages
        WHERE status = 'archived'
        AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days');
        SELECT changes();
    ")

    # Vacuum to reclaim space
    db "$MAIL_DB" "VACUUM;"

    local new_size_bytes
    new_size_bytes=$(stat -f%z "$MAIL_DB" 2>/dev/null || stat -c%s "$MAIL_DB" 2>/dev/null || echo "0")
    local new_size_kb=$(( new_size_bytes / 1024 ))
    local saved_kb=$(( db_size_kb - new_size_kb ))

    log_success "Pruned $pruned messages, archived $auto_archived read messages ($remembered captured to memory)"
    log_info "Storage: ${db_size_kb}KB → ${new_size_kb}KB (saved ${saved_kb}KB)"
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

    ensure_db

    if [[ -n "$agent_id" ]]; then
        local escaped_id
        escaped_id=$(sql_escape "$agent_id")
        local inbox_count unread_count
        inbox_count=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent='$escaped_id' AND status != 'archived';")
        unread_count=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent='$escaped_id' AND status = 'unread';")
        echo "Agent: $agent_id"
        echo "  Inbox: $inbox_count messages ($unread_count unread)"
    else
        local total_unread total_read total_archived total_agents
        total_unread=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE status = 'unread';")
        total_read=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE status = 'read';")
        total_archived=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE status = 'archived';")
        total_agents=$(db "$MAIL_DB" "SELECT count(*) FROM agents WHERE status = 'active';")

        local total_inbox=$((total_unread + total_read))

        echo "<!--TOON:mail_status{inbox,outbox,archive,agents}:"
        echo "${total_inbox},0,${total_archived},${total_agents}"
        echo "-->"
        echo ""
        echo "Mailbox Status:"
        echo "  Active:   $total_inbox messages ($total_unread unread, $total_read read)"
        echo "  Archived: $total_archived messages"
        echo "  Agents:   $total_agents active"

        local agent_list
        agent_list=$(db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, status, registered, last_seen FROM agents ORDER BY last_seen DESC;
        ")
        if [[ -n "$agent_list" ]]; then
            echo ""
            echo "Registered Agents:"
            echo "<!--TOON:agents{id,role,branch,status,registered,last_seen}:"
            echo "$agent_list"
            echo "-->"
        fi
    fi
}

#######################################
# Register an agent
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

    ensure_db

    db "$MAIL_DB" "
        INSERT INTO agents (id, role, branch, worktree, status)
        VALUES ('$(sql_escape "$agent_id")', '$(sql_escape "$role")', '$(sql_escape "$branch")', '$(sql_escape "$worktree")', 'active')
        ON CONFLICT(id) DO UPDATE SET
            role = excluded.role,
            branch = excluded.branch,
            worktree = excluded.worktree,
            status = 'active',
            last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now');
    "

    log_success "Registered agent: $agent_id (role: $role, branch: $branch)"
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

    ensure_db

    db "$MAIL_DB" "
        UPDATE agents SET status = 'inactive', last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$agent_id")';
    "

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

    ensure_db

    if [[ "$active_only" == true ]]; then
        echo "Active Agents:"
        db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, last_seen FROM agents WHERE status = 'active' ORDER BY last_seen DESC;
        " | while IFS=',' read -r id role branch last_seen; do
            echo -e "  ${CYAN}$id${NC} ($role) on $branch - last seen: $last_seen"
        done
    else
        echo "<!--TOON:agents{id,role,branch,worktree,status,registered,last_seen}:"
        db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, worktree, status, registered, last_seen FROM agents ORDER BY last_seen DESC;
        "
        echo "-->"
    fi
}

#######################################
# Migrate TOON files to SQLite
#######################################
cmd_migrate() {
    ensure_db

    local migrated=0
    local inbox_dir="$MAIL_DIR/inbox"
    local outbox_dir="$MAIL_DIR/outbox"
    local archive_dir="$MAIL_DIR/archive"

    # Migrate inbox messages
    if [[ -d "$inbox_dir" ]]; then
        while IFS= read -r msg_file; do
            [[ -f "$msg_file" ]] || continue
            local header
            header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1) || continue
            [[ -z "$header" ]] && continue

            local id from_agent to_agent msg_type priority convoy timestamp status
            IFS=',' read -r id from_agent to_agent msg_type priority convoy timestamp status <<< "$header"
            local payload
            payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

            local escaped_payload
            escaped_payload=$(sql_escape "$payload")

            db "$MAIL_DB" "
                INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload, status, created_at)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$(sql_escape "$convoy")', '$escaped_payload', '$(sql_escape "$status")', '$(sql_escape "$timestamp")');
            " 2>/dev/null && migrated=$((migrated + 1))
        done < <(find "$inbox_dir" "$outbox_dir" -name "*.toon" 2>/dev/null)
    fi

    # Migrate archived messages
    if [[ -d "$archive_dir" ]]; then
        while IFS= read -r msg_file; do
            [[ -f "$msg_file" ]] || continue
            local header
            header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1) || continue
            [[ -z "$header" ]] && continue

            local id from_agent to_agent msg_type priority convoy timestamp status
            IFS=',' read -r id from_agent to_agent msg_type priority convoy timestamp status <<< "$header"
            local payload
            payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

            local escaped_payload
            escaped_payload=$(sql_escape "$payload")

            db "$MAIL_DB" "
                INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload, status, created_at, archived_at)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$(sql_escape "$convoy")', '$escaped_payload', 'archived', '$(sql_escape "$timestamp")', strftime('%Y-%m-%dT%H:%M:%SZ','now'));
            " 2>/dev/null && migrated=$((migrated + 1))
        done < <(find "$archive_dir" -name "*.toon" 2>/dev/null)
    fi

    # Migrate registry
    local registry_file="$MAIL_DIR/registry.toon"
    local agents_migrated=0
    if [[ -f "$registry_file" ]]; then
        while IFS=',' read -r id role branch worktree status registered last_seen; do
            [[ "$id" == "<!--"* || "$id" == "-->"* || -z "$id" ]] && continue
            db "$MAIL_DB" "
                INSERT OR IGNORE INTO agents (id, role, branch, worktree, status, registered, last_seen)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$role")', '$(sql_escape "$branch")', '$(sql_escape "$worktree")', '$(sql_escape "$status")', '$(sql_escape "$registered")', '$(sql_escape "$last_seen")');
            " 2>/dev/null && agents_migrated=$((agents_migrated + 1))
        done < "$registry_file"
    fi

    log_success "Migration complete: $migrated messages, $agents_migrated agents"

    # Rename old directories as backup (don't delete)
    if [[ $migrated -gt 0 || $agents_migrated -gt 0 ]]; then
        local backup_suffix
        backup_suffix=$(date +%Y%m%d-%H%M%S)
        for dir in "$inbox_dir" "$outbox_dir" "$archive_dir"; do
            if [[ -d "$dir" ]] && find "$dir" -name "*.toon" 2>/dev/null | grep -q .; then
                mv "$dir" "${dir}.pre-sqlite-${backup_suffix}"
                mkdir -p "$dir"
                log_info "Backed up: $dir → ${dir}.pre-sqlite-${backup_suffix}"
            fi
        done
        if [[ -f "$registry_file" ]]; then
            mv "$registry_file" "${registry_file}.pre-sqlite-${backup_suffix}"
            log_info "Backed up: $registry_file"
        fi
    fi
}

#######################################
# Show usage
#######################################
show_usage() {
    cat << 'EOF'
mail-helper.sh - SQLite-backed inter-agent mailbox system

Usage:
  mail-helper.sh send --to <agent-id> --type <type> --payload "message" [options]
  mail-helper.sh check [--agent <id>] [--unread-only]
  mail-helper.sh read <message-id> [--agent <id>]
  mail-helper.sh archive <message-id> [--agent <id>]
  mail-helper.sh prune [--older-than-days 7] [--force]
  mail-helper.sh status [--agent <id>]
  mail-helper.sh register --agent <id> --role <role> [--branch <branch>]
  mail-helper.sh deregister --agent <id>
  mail-helper.sh agents [--active-only]
  mail-helper.sh migrate                          Migrate TOON files to SQLite

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
  send → check → read → archive (prune is manual with storage report)

Prune:
  mail-helper.sh prune                          Show storage report
  mail-helper.sh prune --force                  Delete archived messages >7 days old
  mail-helper.sh prune --older-than-days 30     Report with 30-day threshold
  mail-helper.sh prune --older-than-days 30 --force  Delete with 30-day threshold

Performance:
  SQLite WAL mode - <1ms queries at any scale (vs 25ms/message with files)
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
        migrate) cmd_migrate "$@" ;;
        help|--help|-h) show_usage ;;
        *) log_error "Unknown command: $command"; show_usage; return 1 ;;
    esac
}

main "$@"
