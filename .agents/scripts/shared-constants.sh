#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2089,SC2090

# Shared Constants for AI DevOps Framework Provider Scripts
# This file contains common strings, error messages, and configuration constants
# to reduce duplication and improve maintainability across provider scripts.
#
# Usage: source .agents/scripts/shared-constants.sh
#
# Author: AI DevOps Framework
# Version: 1.6.0

# Include guard: prevent readonly errors when sourced multiple times
[[ -n "${_SHARED_CONSTANTS_LOADED:-}" ]] && return 0
_SHARED_CONSTANTS_LOADED=1

# =============================================================================
# HTTP and API Constants
# =============================================================================

readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly CONTENT_TYPE_FORM="Content-Type: application/x-www-form-urlencoded"
readonly USER_AGENT="User-Agent: AI-DevOps-Framework/1.6.0"
readonly AUTH_HEADER_PREFIX="Authorization: Bearer"

# =============================================================================
# Common Help Text Labels
# =============================================================================

readonly HELP_LABEL_COMMANDS="Commands:"
readonly HELP_LABEL_EXAMPLES="Examples:"
readonly HELP_LABEL_OPTIONS="Options:"
readonly HELP_LABEL_USAGE="Usage:"

# HTTP Status Codes
readonly HTTP_OK=200
readonly HTTP_CREATED=201
readonly HTTP_BAD_REQUEST=400
readonly HTTP_UNAUTHORIZED=401
readonly HTTP_FORBIDDEN=403
readonly HTTP_NOT_FOUND=404
readonly HTTP_INTERNAL_ERROR=500

# =============================================================================
# Common Error Messages
# =============================================================================

readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_INPUT_FILE_NOT_FOUND="Input file not found"
readonly ERROR_INPUT_FILE_REQUIRED="Input file is required"
readonly ERROR_REPO_NAME_REQUIRED="Repository name is required"
readonly ERROR_DOMAIN_NAME_REQUIRED="Domain name is required"
readonly ERROR_ACCOUNT_NAME_REQUIRED="Account name is required"
readonly ERROR_INSTANCE_NAME_REQUIRED="Instance name is required"
readonly ERROR_PROJECT_NOT_FOUND="Project not found in configuration"
readonly ERROR_UNKNOWN_COMMAND="Unknown command"
readonly ERROR_UNKNOWN_PLATFORM="Unknown platform"
readonly ERROR_PERMISSION_DENIED="Permission denied"
readonly ERROR_NETWORK_UNAVAILABLE="Network unavailable"
readonly ERROR_API_KEY_MISSING="API key is missing or invalid"
readonly ERROR_INVALID_CREDENTIALS="Invalid credentials"

# =============================================================================
# Success Messages
# =============================================================================

readonly SUCCESS_REPO_CREATED="Repository created successfully"
readonly SUCCESS_DEPLOYMENT_COMPLETE="Deployment completed successfully"
readonly SUCCESS_CONFIG_UPDATED="Configuration updated successfully"
readonly SUCCESS_BACKUP_CREATED="Backup created successfully"
readonly SUCCESS_CONNECTION_ESTABLISHED="Connection established successfully"
readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"

# =============================================================================
# Common Usage Patterns
# =============================================================================

readonly USAGE_PATTERN="Usage: \$0 [command] [options]"
readonly HELP_PATTERN="Use '\$0 help' for more information"
readonly CONFIG_PATTERN="Edit configuration file: \$CONFIG_FILE"

# =============================================================================
# File and Directory Patterns
# =============================================================================

readonly BACKUP_SUFFIX=".backup"
readonly LOG_SUFFIX=".log"
readonly CONFIG_SUFFIX=".json"
readonly TEMPLATE_SUFFIX=".txt"
readonly TEMP_PREFIX="tmp_"

# =============================================================================
# Common Validation Patterns
# =============================================================================

readonly DOMAIN_REGEX="^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$"
readonly EMAIL_REGEX="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
readonly IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
readonly PORT_REGEX="^[0-9]{1,5}$"

# =============================================================================
# Common Timeouts and Limits
# =============================================================================

readonly DEFAULT_TIMEOUT=30
readonly LONG_TIMEOUT=300
readonly SHORT_TIMEOUT=10
readonly MAX_RETRIES=3
readonly DEFAULT_PORT=80
readonly SECURE_PORT=443

# =============================================================================
# CI/CD Service Timing Constants (Evidence-Based from PR #19 Analysis)
# =============================================================================
# These timings are based on observed completion times across multiple PRs.
# Update these values as you gather more data from your CI/CD runs.

# Fast checks (typically complete in <10s)
# - CodeFactor: ~1s
# - Framework Validation: ~4s
# - Version Consistency: ~4s
readonly CI_WAIT_FAST=10
readonly CI_POLL_FAST=5

# Medium checks (typically complete in 30-90s)
# - Codacy: ~43s
# - SonarCloud: ~44s
# - Qlty: ~57s
# - Code Review Monitoring: ~62s
readonly CI_WAIT_MEDIUM=60
readonly CI_POLL_MEDIUM=15

# Slow checks (typically complete in 120-180s)
# - CodeRabbit initial review: ~120-180s
# - CodeRabbit re-review: ~120-180s
readonly CI_WAIT_SLOW=120
readonly CI_POLL_SLOW=30

# Exponential backoff settings
readonly CI_BACKOFF_BASE=15      # Initial wait (seconds)
readonly CI_BACKOFF_MAX=120      # Maximum wait between polls
readonly CI_BACKOFF_MULTIPLIER=2 # Multiply wait by this each iteration

# Service-specific timeouts (max time to wait before giving up)
readonly CI_TIMEOUT_FAST=60      # 1 minute for fast checks
readonly CI_TIMEOUT_MEDIUM=180   # 3 minutes for medium checks
readonly CI_TIMEOUT_SLOW=600     # 10 minutes for slow checks (CodeRabbit)

# =============================================================================
# Color Constants (for consistent output formatting)
# =============================================================================

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_PURPLE='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_RESET='\033[0m'

# =============================================================================
# Color Aliases (short names used by most scripts)
# =============================================================================

readonly RED="$COLOR_RED"
readonly GREEN="$COLOR_GREEN"
readonly YELLOW="$COLOR_YELLOW"
readonly BLUE="$COLOR_BLUE"
readonly PURPLE="$COLOR_PURPLE"
readonly CYAN="$COLOR_CYAN"
readonly WHITE="$COLOR_WHITE"
readonly NC="$COLOR_RESET"

# =============================================================================
# Common Functions for Error Handling
# =============================================================================

# Print error message with consistent formatting
print_shared_error() {
    local msg="$1"
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $msg" >&2
    return 0
}

# Print success message with consistent formatting
print_shared_success() {
    local msg="$1"
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $msg"
    return 0
}

# Print warning message with consistent formatting
print_shared_warning() {
    local msg="$1"
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $msg"
    return 0
}

# Print info message with consistent formatting
print_shared_info() {
    local msg="$1"
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $msg"
    return 0
}

# Short aliases (used by most scripts - avoids needing inline redefinitions)
print_error() { print_shared_error "$1"; return $?; }
print_success() { print_shared_success "$1"; return $?; }
print_warning() { print_shared_warning "$1"; return $?; }
print_info() { print_shared_info "$1"; return $?; }

# Validate required parameter
validate_required_param() {
    local param_name="$1"
    local param_value="$2"
    
    if [[ -z "$param_value" ]]; then
        print_shared_error "$param_name is required"
        return 1
    fi
    return 0
}

# Check if file exists and is readable
validate_file_exists() {
    local file_path="$1"
    local file_description="${2:-File}"
    
    if [[ ! -f "$file_path" ]]; then
        print_shared_error "$file_description not found: $file_path"
        return 1
    fi
    
    if [[ ! -r "$file_path" ]]; then
        print_shared_error "$file_description is not readable: $file_path"
        return 1
    fi
    
    return 0
}

# Check if command exists
validate_command_exists() {
    local command_name="$1"
    
    if ! command -v "$command_name" &> /dev/null; then
        print_shared_error "Required command not found: $command_name"
        return 1
    fi
    return 0
}

# =============================================================================
# Portable sed -i wrapper (macOS vs GNU/Linux)
# macOS sed requires -i '' while GNU sed requires -i (no argument)
# Usage: sed_inplace 'pattern' file
#        sed_inplace -E 'pattern' file
# =============================================================================

sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
    return $?
}

# Portable sed append-after-line (macOS vs GNU/Linux)
# BSD sed 'a' requires a backslash-newline; GNU sed accepts inline text.
# Usage: sed_append_after <line_number> <text_to_insert> <file>
sed_append_after() {
    local line_num="$1"
    local text="$2"
    local file="$3"
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "${line_num} a\\
${text}
" "$file"
    else
        sed -i "${line_num}a\\${text}" "$file"
    fi
    return $?
}

# =============================================================================
# Stderr Logging Utilities
# =============================================================================
# Replace blanket 2>/dev/null with targeted stderr handling.
# Usage:
#   log_stderr "context" command args...    # Log stderr to script log file
#   suppress_stderr command args...         # Suppress stderr (documented intent)
#   init_log_file                           # Set up AIDEVOPS_LOG_FILE for script
#
# Guidelines:
#   - command -v, kill -0, pgrep: use suppress_stderr (expected noise)
#   - sqlite3, gh, curl, git push/merge: use log_stderr (errors matter)
#   - rm, mkdir with || true: keep 2>/dev/null (race conditions)

# Initialize log file for the calling script.
# Sets AIDEVOPS_LOG_FILE to ~/.aidevops/logs/<script-name>.log
# Call once at script start after sourcing shared-constants.sh.
init_log_file() {
    local script_name
    script_name="$(basename "${BASH_SOURCE[1]:-${0:-unknown}}" .sh)"
    local log_dir="${HOME}/.aidevops/logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    AIDEVOPS_LOG_FILE="${log_dir}/${script_name}.log"
    export AIDEVOPS_LOG_FILE
    return 0
}

# Run a command, redirecting stderr to the script's log file.
# Preserves exit code. Falls back to /dev/null if no log file set.
# Usage: log_stderr "db migration" sqlite3 "$db" "ALTER TABLE..."
log_stderr() {
    local context="$1"
    shift
    local log_target="${AIDEVOPS_LOG_FILE:-/dev/null}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
    echo "[$timestamp] [$context] Running: $*" >> "$log_target" 2>/dev/null || true
    "$@" 2>> "$log_target"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "[$timestamp] [$context] Exit code: $rc" >> "$log_target" 2>/dev/null || true
    fi
    return $rc
}

# Suppress stderr with documented intent. Use for commands where stderr
# is expected noise (e.g., command -v, kill -0, pgrep, sysctl on wrong OS).
# Usage: suppress_stderr command -v jq
suppress_stderr() {
    "$@" 2>/dev/null
    return $?
}

# =============================================================================
# TODO.md Serialized Commit+Push
# =============================================================================
# Provides atomic locking and pull-rebase-retry for TODO.md operations.
# Prevents race conditions when multiple actors (supervisor, interactive sessions)
# push to TODO.md on main simultaneously.
#
# Workers (headless dispatch runners) must NOT call this function or edit TODO.md
# directly. They report status via exit code/log/mailbox; the supervisor handles
# all TODO.md updates.
#
# Usage:
#   todo_commit_push "repo_path" "commit message"
#   todo_commit_push "repo_path" "commit message" "TODO.md todo/"  # custom paths
#
# Returns 0 on success, 1 on failure after retries.

readonly TODO_LOCK_DIR="${HOME}/.aidevops/locks"
readonly TODO_LOCK_PATH="${TODO_LOCK_DIR}/todo-md.lock"
readonly TODO_MAX_RETRIES=3
readonly TODO_LOCK_TIMEOUT=30
readonly TODO_STALE_LOCK_AGE=120

# Portable atomic lock using mkdir (works on macOS + Linux).
# mkdir is atomic on all POSIX systems -- only one process succeeds.
_todo_acquire_lock() {
    local log_target="${1:-/dev/null}"
    local waited=0

    while [[ $waited -lt $TODO_LOCK_TIMEOUT ]]; do
        if mkdir "$TODO_LOCK_PATH" 2>/dev/null; then
            echo $$ > "$TODO_LOCK_PATH/pid"
            return 0
        fi

        # Check for stale lock (owner process died)
        if [[ -f "$TODO_LOCK_PATH/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "$TODO_LOCK_PATH/pid" 2>/dev/null || echo "")
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                echo "[todo_lock] Removing stale lock (PID $lock_pid dead)" >> "$log_target"
                rm -rf "$TODO_LOCK_PATH"
                continue
            fi
        fi

        # Check lock age (safety net for orphaned locks)
        if [[ -d "$TODO_LOCK_PATH" ]]; then
            local lock_age
            if [[ "$(uname)" == "Darwin" ]]; then
                lock_age=$(( $(date +%s) - $(stat -f %m "$TODO_LOCK_PATH" 2>/dev/null || echo "0") ))
            else
                lock_age=$(( $(date +%s) - $(stat -c %Y "$TODO_LOCK_PATH" 2>/dev/null || echo "0") ))
            fi
            if [[ $lock_age -gt $TODO_STALE_LOCK_AGE ]]; then
                echo "[todo_lock] Removing stale lock (age ${lock_age}s > ${TODO_STALE_LOCK_AGE}s)" >> "$log_target"
                rm -rf "$TODO_LOCK_PATH"
                continue
            fi
        fi

        sleep 1
        waited=$((waited + 1))
    done

    echo "[todo_lock] Failed to acquire lock after ${TODO_LOCK_TIMEOUT}s" >> "$log_target"
    return 1
}

_todo_release_lock() {
    rm -rf "$TODO_LOCK_PATH"
    return 0
}

todo_commit_push() {
    local repo_path="$1"
    local commit_msg="$2"
    local files="${3:-TODO.md todo/}"
    local log_target="${AIDEVOPS_LOG_FILE:-/dev/null}"

    mkdir -p "$TODO_LOCK_DIR" 2>/dev/null || true

    if ! _todo_acquire_lock "$log_target"; then
        return 1
    fi

    # Ensure lock is released on exit (including signals)
    trap '_todo_release_lock' EXIT

    local rc=0
    _todo_commit_push_inner "$repo_path" "$commit_msg" "$files" "$log_target" || rc=$?

    _todo_release_lock
    trap - EXIT

    return $rc
}

_todo_commit_push_inner() {
    local repo_path="$1"
    local commit_msg="$2"
    local files="$3"
    local log_target="$4"
    local attempt=0

    while [[ $attempt -lt $TODO_MAX_RETRIES ]]; do
        attempt=$((attempt + 1))

        # Pull latest before staging (rebase to keep linear history)
        local current_branch
        current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "main")
        if git -C "$repo_path" remote get-url origin &>/dev/null; then
            git -C "$repo_path" pull --rebase origin "$current_branch" 2>>"$log_target" || {
                echo "[todo_commit_push] Pull --rebase failed (attempt $attempt/$TODO_MAX_RETRIES)" >> "$log_target"
                # If rebase conflicts, abort and retry
                git -C "$repo_path" rebase --abort 2>/dev/null || true
                sleep 1
                continue
            }
        fi

        # Stage planning files
        local file
        for file in $files; do
            git -C "$repo_path" add "$file" 2>/dev/null || true
        done

        # Check if anything was staged
        if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
            echo "[todo_commit_push] No changes staged" >> "$log_target"
            return 0
        fi

        # Commit
        if ! git -C "$repo_path" commit -m "$commit_msg" --no-verify 2>>"$log_target"; then
            echo "[todo_commit_push] Commit failed (attempt $attempt/$TODO_MAX_RETRIES)" >> "$log_target"
            continue
        fi

        # Push
        if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
            echo "[todo_commit_push] Success on attempt $attempt" >> "$log_target"
            return 0
        fi

        echo "[todo_commit_push] Push failed (attempt $attempt/$TODO_MAX_RETRIES), retrying..." >> "$log_target"

        # Push failed: pull --rebase to incorporate remote changes, then retry push
        git -C "$repo_path" pull --rebase origin "$current_branch" 2>>"$log_target" || {
            git -C "$repo_path" rebase --abort 2>/dev/null || true
            sleep 1
            continue
        }

        # Retry push after rebase
        if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
            echo "[todo_commit_push] Success after rebase on attempt $attempt" >> "$log_target"
            return 0
        fi

        sleep $((attempt))
    done

    echo "[todo_commit_push] Failed after $TODO_MAX_RETRIES attempts" >> "$log_target"
    return 1
}

# =============================================================================
# Worktree Ownership Registry (t189)
# =============================================================================
# SQLite-backed registry that tracks which session/batch owns each worktree.
# Prevents cross-session worktree removal — the root cause of t189.
#
# Available to all scripts that source shared-constants.sh.

WORKTREE_REGISTRY_DIR="${HOME}/.aidevops/.agent-workspace"
WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"

# SQL-escape a value for SQLite (double single quotes)
_wt_sql_escape() {
    local val="$1"
    echo "${val//\'/\'\'}"
}

# Initialize the registry database
_init_registry_db() {
    mkdir -p "$WORKTREE_REGISTRY_DIR" 2>/dev/null || true
    sqlite3 "$WORKTREE_REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS worktree_owners (
            worktree_path TEXT PRIMARY KEY,
            branch        TEXT,
            owner_pid     INTEGER,
            owner_session TEXT DEFAULT '',
            owner_batch   TEXT DEFAULT '',
            task_id       TEXT DEFAULT '',
            created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
    " 2>/dev/null || true
    return 0
}

# Register ownership of a worktree
# Arguments:
#   $1 - worktree path (required)
#   $2 - branch name (required)
#   Flags: --task <id>, --batch <id>, --session <id>
register_worktree() {
    local wt_path="$1"
    local branch="$2"
    shift 2

    local task_id="" batch_id="" session_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) task_id="${2:-}"; shift 2 ;;
            --batch) batch_id="${2:-}"; shift 2 ;;
            --session) session_id="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    _init_registry_db

    sqlite3 "$WORKTREE_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, owner_batch, task_id)
        VALUES
            ('$(_wt_sql_escape "$wt_path")',
             '$(_wt_sql_escape "$branch")',
             $$,
             '$(_wt_sql_escape "$session_id")',
             '$(_wt_sql_escape "$batch_id")',
             '$(_wt_sql_escape "$task_id")');
    " 2>/dev/null || true
    return 0
}

# Unregister ownership of a worktree
# Arguments:
#   $1 - worktree path (required)
unregister_worktree() {
    local wt_path="$1"

    [[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0

    sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || true
    return 0
}

# Check who owns a worktree
# Arguments:
#   $1 - worktree path
# Output: owner info (pid|session|batch|task|created_at) or empty
# Returns: 0 if owned, 1 if not owned
check_worktree_owner() {
    local wt_path="$1"

    [[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 1

    local owner_info
    owner_info=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid, owner_session, owner_batch, task_id, created_at
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")

    if [[ -n "$owner_info" ]]; then
        echo "$owner_info"
        return 0
    fi
    return 1
}

# Check if a worktree is owned by a DIFFERENT process (still alive)
# Arguments:
#   $1 - worktree path
# Returns: 0 if owned by another live process, 1 if safe to remove
is_worktree_owned_by_others() {
    local wt_path="$1"

    [[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 1

    local owner_pid
    owner_pid=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")

    # No owner registered
    [[ -z "$owner_pid" ]] && return 1

    # We own it
    [[ "$owner_pid" == "$$" ]] && return 1

    # Owner process is dead — stale entry, safe to remove
    if ! kill -0 "$owner_pid" 2>/dev/null; then
        # Clean up stale entry
        unregister_worktree "$wt_path"
        return 1
    fi

    # Owner process is alive and it's not us — NOT safe to remove
    return 0
}

# Prune stale registry entries (dead PIDs, missing directories)
prune_worktree_registry() {
    [[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0

    local entries
    entries=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT worktree_path, owner_pid FROM worktree_owners;
    " 2>/dev/null || echo "")

    [[ -z "$entries" ]] && return 0

    while IFS='|' read -r wt_path owner_pid; do
        local should_prune=false

        # Directory no longer exists
        if [[ ! -d "$wt_path" ]]; then
            should_prune=true
        # Owner process is dead
        elif [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
            should_prune=true
        fi

        if [[ "$should_prune" == "true" ]]; then
            unregister_worktree "$wt_path"
        fi
    done <<< "$entries"
    return 0
}

# =============================================================================
# Export all constants for use in other scripts
# =============================================================================

# This ensures all constants are available when this file is sourced
export CONTENT_TYPE_JSON CONTENT_TYPE_FORM USER_AGENT
export HTTP_OK HTTP_CREATED HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_FORBIDDEN HTTP_NOT_FOUND HTTP_INTERNAL_ERROR
export ERROR_CONFIG_NOT_FOUND ERROR_INPUT_FILE_NOT_FOUND ERROR_INPUT_FILE_REQUIRED
export ERROR_REPO_NAME_REQUIRED ERROR_DOMAIN_NAME_REQUIRED ERROR_ACCOUNT_NAME_REQUIRED
export SUCCESS_REPO_CREATED SUCCESS_DEPLOYMENT_COMPLETE SUCCESS_CONFIG_UPDATED
export USAGE_PATTERN HELP_PATTERN CONFIG_PATTERN
export DEFAULT_TIMEOUT LONG_TIMEOUT SHORT_TIMEOUT MAX_RETRIES
export CI_WAIT_FAST CI_POLL_FAST CI_WAIT_MEDIUM CI_POLL_MEDIUM CI_WAIT_SLOW CI_POLL_SLOW
export CI_BACKOFF_BASE CI_BACKOFF_MAX CI_BACKOFF_MULTIPLIER
export CI_TIMEOUT_FAST CI_TIMEOUT_MEDIUM CI_TIMEOUT_SLOW
export COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_PURPLE COLOR_CYAN COLOR_WHITE COLOR_RESET
export RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC
