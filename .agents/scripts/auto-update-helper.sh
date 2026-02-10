#!/usr/bin/env bash
# auto-update-helper.sh - Automatic update polling daemon for aidevops
#
# Lightweight cron job that checks for new aidevops releases every 10 minutes
# and auto-installs them. Safe to run while AI sessions are active.
#
# Usage:
#   auto-update-helper.sh enable           Install cron job (every 10 min)
#   auto-update-helper.sh disable          Remove cron job
#   auto-update-helper.sh status           Show current state
#   auto-update-helper.sh check            One-shot: check and update if needed
#   auto-update-helper.sh logs [--tail N]  View update logs
#   auto-update-helper.sh help             Show this help
#
# Configuration:
#   AIDEVOPS_AUTO_UPDATE=true|false   Override enable/disable (env var)
#   AIDEVOPS_UPDATE_INTERVAL=10      Minutes between checks (default: 10)
#
# Logs: ~/.aidevops/logs/auto-update.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# Configuration
readonly INSTALL_DIR="$HOME/Git/aidevops"
readonly LOCK_DIR="$HOME/.aidevops/locks"
readonly LOCK_FILE="$LOCK_DIR/auto-update.lock"
readonly LOG_FILE="$HOME/.aidevops/logs/auto-update.log"
readonly STATE_FILE="$HOME/.aidevops/cache/auto-update-state.json"
readonly CRON_MARKER="# aidevops-auto-update"
readonly DEFAULT_INTERVAL=10

#######################################
# Logging
#######################################
log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" >> "$LOG_FILE"
    return 0
}

log_info() { log "INFO" "$@"; return 0; }
log_warn() { log "WARN" "$@"; return 0; }
log_error() { log "ERROR" "$@"; return 0; }

#######################################
# Ensure directories exist
#######################################
ensure_dirs() {
    mkdir -p "$LOCK_DIR" "$HOME/.aidevops/logs" "$HOME/.aidevops/cache" 2>/dev/null || true
    return 0
}

#######################################
# Lock management (prevents concurrent updates)
# Uses mkdir for atomic locking (POSIX-safe)
#######################################
acquire_lock() {
    local max_wait=30
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo $$ > "$LOCK_FILE/pid"
            return 0
        fi

        # Check for stale lock
        if [[ -f "$LOCK_FILE/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "Removing stale lock (PID $lock_pid dead)"
                rm -rf "$LOCK_FILE"
                continue
            fi
        fi

        # Check lock age (safety net for orphaned locks)
        if [[ -d "$LOCK_FILE" ]]; then
            local lock_age
            if [[ "$(uname)" == "Darwin" ]]; then
                lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo "0") ))
            else
                lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0") ))
            fi
            if [[ $lock_age -gt 300 ]]; then
                log_warn "Removing stale lock (age ${lock_age}s > 300s)"
                rm -rf "$LOCK_FILE"
                continue
            fi
        fi

        sleep 1
        waited=$((waited + 1))
    done

    log_error "Failed to acquire lock after ${max_wait}s"
    return 1
}

release_lock() {
    rm -rf "$LOCK_FILE"
    return 0
}

#######################################
# Get local version
#######################################
get_local_version() {
    local version_file="$INSTALL_DIR/VERSION"
    if [[ -r "$version_file" ]]; then
        cat "$version_file"
    else
        echo "unknown"
    fi
    return 0
}

#######################################
# Get remote version (from GitHub API)
# Uses API endpoint (not raw.githubusercontent.com) to avoid CDN cache
#######################################
get_remote_version() {
    local version=""
    if command -v jq &>/dev/null; then
        version=$(curl --proto '=https' -fsSL --max-time 10 \
            "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null \
            | jq -r '.content // empty' 2>/dev/null \
            | base64 -d 2>/dev/null \
            | tr -d '\n')
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    # Fallback to raw (CDN-cached, may be up to 5 min stale)
    curl --proto '=https' -fsSL --max-time 10 \
        "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null \
        | tr -d '\n' || echo "unknown"
    return 0
}

#######################################
# Check if setup.sh or aidevops update is already running
#######################################
is_update_running() {
    # Check for running setup.sh processes (not our own)
    if pgrep -f "setup\.sh" >/dev/null 2>&1; then
        return 0
    fi
    # Check for running aidevops update
    if pgrep -f "aidevops update" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

#######################################
# Update state file with last check/update info
#######################################
update_state() {
    local action="$1"
    local version="${2:-}"
    local status="${3:-success}"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if command -v jq &>/dev/null; then
        local tmp_state
        tmp_state=$(mktemp)
        trap 'rm -f "${tmp_state:-}"' RETURN

        if [[ -f "$STATE_FILE" ]]; then
            jq --arg action "$action" \
               --arg version "$version" \
               --arg status "$status" \
               --arg ts "$timestamp" \
               '. + {
                   last_action: $action,
                   last_version: $version,
                   last_status: $status,
                   last_timestamp: $ts
               } | if $action == "update" and $status == "success" then
                   . + {last_update: $ts, last_update_version: $version}
               else . end' "$STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
        else
            jq -n --arg action "$action" \
                  --arg version "$version" \
                  --arg status "$status" \
                  --arg ts "$timestamp" \
                  '{
                      enabled: true,
                      last_action: $action,
                      last_version: $version,
                      last_status: $status,
                      last_timestamp: $ts
                  }' > "$STATE_FILE"
        fi
    fi
    return 0
}

#######################################
# One-shot check and update
# This is what the cron job calls
#######################################
cmd_check() {
    ensure_dirs

    # Respect env var override
    if [[ "${AIDEVOPS_AUTO_UPDATE:-}" == "false" ]]; then
        log_info "Auto-update disabled via AIDEVOPS_AUTO_UPDATE=false"
        return 0
    fi

    # Skip if another update is already running
    if is_update_running; then
        log_info "Another update process is running, skipping"
        return 0
    fi

    # Acquire lock
    if ! acquire_lock; then
        log_warn "Could not acquire lock, skipping check"
        return 0
    fi
    trap 'release_lock' EXIT

    local current remote
    current=$(get_local_version)
    remote=$(get_remote_version)

    log_info "Version check: local=$current remote=$remote"

    if [[ "$current" == "unknown" || "$remote" == "unknown" ]]; then
        log_warn "Could not determine versions (local=$current, remote=$remote)"
        update_state "check" "$current" "version_unknown"
        release_lock
        trap - EXIT
        return 0
    fi

    if [[ "$current" == "$remote" ]]; then
        log_info "Already up to date (v$current)"
        update_state "check" "$current" "up_to_date"
        release_lock
        trap - EXIT
        return 0
    fi

    # New version available — perform update
    log_info "Update available: v$current -> v$remote"
    update_state "update_start" "$remote" "in_progress"

    # Verify install directory exists and is a git repo
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        log_error "Install directory is not a git repo: $INSTALL_DIR"
        update_state "update" "$remote" "no_git_repo"
        release_lock
        trap - EXIT
        return 1
    fi

    # Pull latest changes
    if ! git -C "$INSTALL_DIR" fetch origin main --quiet 2>>"$LOG_FILE"; then
        log_error "git fetch failed"
        update_state "update" "$remote" "fetch_failed"
        release_lock
        trap - EXIT
        return 1
    fi

    if ! git -C "$INSTALL_DIR" pull --ff-only origin main --quiet 2>>"$LOG_FILE"; then
        log_error "git pull --ff-only failed (local changes?)"
        update_state "update" "$remote" "pull_failed"
        release_lock
        trap - EXIT
        return 1
    fi

    # Run setup.sh non-interactively to deploy agents
    log_info "Running setup.sh --non-interactive..."
    if bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1; then
        local new_version
        new_version=$(get_local_version)
        log_info "Update complete: v$current -> v$new_version"
        update_state "update" "$new_version" "success"
    else
        log_error "setup.sh failed (exit code: $?)"
        update_state "update" "$remote" "setup_failed"
        release_lock
        trap - EXIT
        return 1
    fi

    release_lock
    trap - EXIT
    return 0
}

#######################################
# Enable auto-update cron job
#######################################
cmd_enable() {
    ensure_dirs

    local interval="${AIDEVOPS_UPDATE_INTERVAL:-$DEFAULT_INTERVAL}"
    local script_path="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"

    # Verify the script exists at the deployed location
    if [[ ! -x "$script_path" ]]; then
        # Fall back to repo location
        script_path="$INSTALL_DIR/.agents/scripts/auto-update-helper.sh"
        if [[ ! -x "$script_path" ]]; then
            print_error "auto-update-helper.sh not found"
            return 1
        fi
    fi

    # Build cron expression
    local cron_expr="*/${interval} * * * *"
    local cron_line="$cron_expr $script_path check >> $LOG_FILE 2>&1 $CRON_MARKER"

    # Get existing crontab (excluding our entry)
    local temp_cron
    temp_cron=$(mktemp)
    trap 'rm -f "${temp_cron:-}"' RETURN

    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$temp_cron" || true

    # Add our entry
    echo "$cron_line" >> "$temp_cron"

    # Install
    crontab "$temp_cron"
    rm -f "$temp_cron"

    # Update state
    update_state "enable" "$(get_local_version)" "enabled"

    print_success "Auto-update enabled (every ${interval} minutes)"
    echo ""
    echo "  Schedule: $cron_expr"
    echo "  Script:   $script_path"
    echo "  Logs:     $LOG_FILE"
    echo ""
    echo "  Disable with: aidevops auto-update disable"
    echo "  Check now:    aidevops auto-update check"
    return 0
}

#######################################
# Disable auto-update cron job
#######################################
cmd_disable() {
    local temp_cron
    temp_cron=$(mktemp)
    trap 'rm -f "${temp_cron:-}"' RETURN

    local had_entry=false
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        had_entry=true
    fi

    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"

    update_state "disable" "$(get_local_version)" "disabled"

    if [[ "$had_entry" == "true" ]]; then
        print_success "Auto-update disabled"
    else
        print_info "Auto-update was not enabled"
    fi
    return 0
}

#######################################
# Show status
#######################################
cmd_status() {
    ensure_dirs

    local current
    current=$(get_local_version)

    echo ""
    echo -e "${BOLD:-}Auto-Update Status${NC}"
    echo "-------------------"
    echo ""

    # Check if cron job is installed
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_MARKER")
        echo -e "  Cron job:  ${GREEN}enabled${NC}"
        echo "  Schedule:  $(echo "$cron_entry" | awk '{print $1, $2, $3, $4, $5}')"
    else
        echo -e "  Cron job:  ${YELLOW}disabled${NC}"
    fi

    echo "  Version:   v$current"

    # Show state file info
    if [[ -f "$STATE_FILE" ]] && command -v jq &>/dev/null; then
        local last_action last_ts last_status last_update last_update_ver
        last_action=$(jq -r '.last_action // "none"' "$STATE_FILE" 2>/dev/null)
        last_ts=$(jq -r '.last_timestamp // "never"' "$STATE_FILE" 2>/dev/null)
        last_status=$(jq -r '.last_status // "unknown"' "$STATE_FILE" 2>/dev/null)
        last_update=$(jq -r '.last_update // "never"' "$STATE_FILE" 2>/dev/null)
        last_update_ver=$(jq -r '.last_update_version // "n/a"' "$STATE_FILE" 2>/dev/null)

        echo ""
        echo "  Last check:   $last_ts ($last_action: $last_status)"
        if [[ "$last_update" != "never" ]]; then
            echo "  Last update:  $last_update (v$last_update_ver)"
        fi
    fi

    # Check env var override
    if [[ "${AIDEVOPS_AUTO_UPDATE:-}" == "false" ]]; then
        echo ""
        echo -e "  ${YELLOW}Note: AIDEVOPS_AUTO_UPDATE=false is set (overrides cron)${NC}"
    fi

    echo ""
    return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
    local tail_lines=50

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tail|-n) [[ $# -lt 2 ]] && { print_error "--tail requires a value"; return 1; }; tail_lines="$2"; shift 2 ;;
            --follow|-f) tail -f "$LOG_FILE" 2>/dev/null || print_info "No log file yet"; return 0 ;;
            *) shift ;;
        esac
    done

    if [[ -f "$LOG_FILE" ]]; then
        tail -n "$tail_lines" "$LOG_FILE"
    else
        print_info "No log file yet (auto-update hasn't run)"
    fi
    return 0
}

#######################################
# Help
#######################################
cmd_help() {
    cat << 'EOF'
auto-update-helper.sh - Automatic update polling for aidevops

USAGE:
    auto-update-helper.sh <command> [options]
    aidevops auto-update <command> [options]

COMMANDS:
    enable              Install cron job (checks every 10 min)
    disable             Remove cron job
    status              Show current auto-update state
    check               One-shot: check for updates and install if available
    logs [--tail N]     View update logs (default: last 50 lines)
    logs --follow       Follow log output in real-time
    help                Show this help

ENVIRONMENT:
    AIDEVOPS_AUTO_UPDATE=false      Disable auto-update (overrides cron)
    AIDEVOPS_UPDATE_INTERVAL=10     Minutes between checks (default: 10)

HOW IT WORKS:
    1. Cron runs 'auto-update-helper.sh check' every 10 minutes
    2. Checks GitHub API for latest version (no CDN cache)
    3. If newer version found:
       a. Acquires lock (prevents concurrent updates)
       b. Runs git pull --ff-only
       c. Runs setup.sh --non-interactive to deploy agents
    4. Safe to run while AI sessions are active
    5. Skips if another update is already in progress

RATE LIMITS:
    GitHub API: 60 requests/hour (unauthenticated)
    10-min interval = 6 requests/hour (well within limits)

LOGS:
    ~/.aidevops/logs/auto-update.log

EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        enable)  cmd_enable "$@" ;;
        disable) cmd_disable "$@" ;;
        status)  cmd_status "$@" ;;
        check)   cmd_check "$@" ;;
        logs)    cmd_logs "$@" ;;
        help|--help|-h) cmd_help ;;
        *) print_error "Unknown command: $command"; cmd_help; return 1 ;;
    esac
}

main "$@"
