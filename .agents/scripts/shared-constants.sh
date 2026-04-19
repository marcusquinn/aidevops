#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2089,SC2090

# Shared Constants for AI DevOps Framework Provider Scripts
# This file contains common strings, error messages, and configuration constants
# to reduce duplication and improve maintainability across provider scripts.
#
# Usage: source .agents/scripts/shared-constants.sh
#
# Author: AI DevOps Framework
# Version: 1.6.0

# cool — include guard prevents readonly errors when sourced multiple times
[[ -n "${_SHARED_CONSTANTS_LOADED:-}" ]] && return 0
_SHARED_CONSTANTS_LOADED=1

# =============================================================================
# GH#18950 (t2087): Bash 3.2 → bash 4+ runtime re-exec self-heal guard.
# =============================================================================
# macOS ships /bin/bash 3.2.57 which has parser and set-e propagation bugs
# (GH#18770, GH#18784, GH#18786, GH#18804, GH#18830). If this shared file
# is sourced by a script running under bash < 4 AND a modern bash is
# available at a known location, re-exec the calling script under the
# modern bash. Transparent self-heal: the script runs from the top again
# under the new interpreter, passes this guard (now on bash 4+), and
# continues normally.
#
# Guard order matters: this MUST run before any bash 4+ constructs in
# this file. It also runs AFTER the include guard to avoid re-execing
# the same script multiple times through nested sources.
#
# Chicken-and-egg avoidance:
#   - setup.sh itself does NOT source shared-constants.sh at the top; it
#     can't, because it's the thing that installs modern bash.
#   - bash-upgrade-helper.sh does NOT source shared-constants.sh either;
#     it's the detector that this guard queries.
#   - AIDEVOPS_BASH_REEXECED=1 is set before exec to prevent infinite
#     loops if a symlink points at the wrong binary.
#   - BASH_SOURCE[1] is the immediate caller; if unset, we're being
#     executed directly (e.g., `bash shared-constants.sh`) and skip
#     the guard. The guard walks the BASH_SOURCE stack to find the
#     OUTERMOST caller (the top-level script) rather than using [1],
#     so the re-exec targets the correct entry point even when sourced
#     via intermediate helpers (GH#19632 / t2176).
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]] &&
	[[ -z "${AIDEVOPS_BASH_REEXECED:-}" ]] &&
	[[ -n "${BASH_SOURCE[1]:-}" ]]; then
	# Walk BASH_SOURCE[] to find the outermost caller, not just
	# BASH_SOURCE[1] (the immediate caller). When sourced via an
	# intermediate helper (e.g. pulse-wrapper→config-helper→shared-constants),
	# BASH_SOURCE[1] points to the intermediate, and exec-ing it would
	# replace the top-level script with a standalone run of the helper.
	# The outermost caller is the last element in the BASH_SOURCE array.
	# Bash 3.2 does not support negative indices (${arr[-1]}), so iterate.
	# (GH#19632 / t2176)
	_aidevops_top_caller=""
	for _aidevops_src in "${BASH_SOURCE[@]}"; do
		_aidevops_top_caller="$_aidevops_src"
	done
	unset _aidevops_src
	# Safety: skip if outermost caller is this file itself (direct execution
	# of shared-constants.sh, which has no useful main).
	if [[ "$_aidevops_top_caller" != "${BASH_SOURCE[0]}" ]]; then
		for _aidevops_bash_candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash "$(command -v bash 2>/dev/null || true)"; do
			if [[ -n "$_aidevops_bash_candidate" && -f "$_aidevops_bash_candidate" && -x "$_aidevops_bash_candidate" && "$_aidevops_bash_candidate" != "/bin/bash" ]]; then
				export AIDEVOPS_BASH_REEXECED=1
				exec "$_aidevops_bash_candidate" "$_aidevops_top_caller" "$@"
			fi
		done
		unset _aidevops_bash_candidate
	fi
	unset _aidevops_top_caller
	# Fall through: no modern bash found. The calling script will run
	# on bash 3.2 and may hit compat bugs. The aidevops update check
	# will surface an advisory on the next cycle (bash-upgrade-helper.sh
	# update-check, rate-limited to 24h).
fi

# t2201: Clear AIDEVOPS_BASH_REEXECED once we are stably on bash 4+. The
# re-exec guard exports this flag before `exec` to prevent its own
# infinite loop, but without this cleanup the flag persists in the
# environment of every child process. If any child is then spawned
# under /bin/bash 3.2 (e.g. an explicit `/bin/bash script.sh` call, or
# PATH mis-ordering that resolves `#!/usr/bin/env bash` to 3.2), THAT
# child's guard sees AIDEVOPS_BASH_REEXECED=1 and short-circuits the
# re-exec — leaving the grandchild running bash 3.2 and hitting any
# bash 4+ construct as a runtime error. Clearing the flag only when
# BASH_VERSINFO[0] >= 4 preserves the anti-infinite-loop property for
# the fallthrough branch (no modern bash found, still on 3.2) while
# ensuring fresh subprocess invocations get a clean guard decision.
if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
	unset AIDEVOPS_BASH_REEXECED
fi

# =============================================================================
# Tool Version Pins
# =============================================================================
# Pin a tool to a specific version to prevent auto-upgrade to a broken release.
# Set to "latest" to resume tracking upstream. Grep for the variable name to
# find all consumers that need updating when unpinning.

# OpenCode unpinned: root cause was SQLite contention (shared DB, busy_timeout=0),
# not version-specific. Fixed by DB isolation per worker (v3.6.130).
# Upstream context: https://github.com/anomalyco/opencode/issues/21215
readonly OPENCODE_PINNED_VERSION="latest"

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
# Credentials File Security
# =============================================================================
# Shared utility for ensuring credentials files have secure permissions.
# All scripts that write to credentials.sh MUST call ensure_credentials_file
# before their first write to guarantee 0600 permissions on the file and
# 0700 on the parent directory.
#
# Usage:
#   ensure_credentials_file "$CREDENTIALS_FILE"
#   echo "export KEY=\"value\"" >> "$CREDENTIALS_FILE"

readonly CREDENTIALS_DIR_PERMS="700"
readonly CREDENTIALS_FILE_PERMS="600"

# Ensure credentials file exists with secure permissions (0600).
# Creates parent directory with 0700 if missing.
# Idempotent: safe to call multiple times.
# Arguments:
#   $1 - path to credentials file (required)
ensure_credentials_file() {
	local cred_file="$1"

	if [[ -z "$cred_file" ]]; then
		print_shared_error "ensure_credentials_file: file path required"
		return 1
	fi

	local cred_dir
	cred_dir="$(dirname "$cred_file")"

	# Ensure parent directory exists with restricted permissions
	if [[ ! -d "$cred_dir" ]]; then
		mkdir -p "$cred_dir"
		chmod "$CREDENTIALS_DIR_PERMS" "$cred_dir"
	fi

	# Create file if it doesn't exist
	if [[ ! -f "$cred_file" ]]; then
		: >"$cred_file"
	fi

	# Enforce 0600 regardless of current permissions
	chmod "$CREDENTIALS_FILE_PERMS" "$cred_file" 2>/dev/null || true

	return 0
}

# =============================================================================
# Pattern Tracking Constants
# =============================================================================
# All pattern-related memory types (dedicated + supervisor-generated)
# Used by memory/_common.sh migrate_db backfill (pattern-tracker-helper.sh archived)
# TIER_DOWNGRADE_OK: evidence that a cheaper model tier succeeded on a task type (t5148)
readonly PATTERN_TYPES_SQL="'SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX','TIER_DOWNGRADE_OK'"

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
# Supervisor Task Status SQL Fragments
# =============================================================================
# Keep frequently reused status lists in one place to avoid drift between
# supervisor modules.

# Terminal states for TODO/DB reconciliation checks.
readonly TASK_RECONCILIATION_TERMINAL_STATES_SQL="'complete', 'deployed', 'verified', 'verify_failed', 'failed', 'blocked', 'cancelled'"

# States treated as non-active when checking sibling in-flight limits.
readonly TASK_SIBLING_NON_ACTIVE_STATES_SQL="'verified','cancelled','deployed','complete','failed','blocked','queued'"

# =============================================================================
# Portable timeout function (macOS + Linux)
# =============================================================================
# macOS has no native `timeout` command. This function provides a portable
# wrapper that works on Linux (coreutils timeout), macOS with Homebrew
# coreutils (gtimeout), and bare macOS (background + kill fallback).
#
# Usage: timeout_sec 5 your_command arg1 arg2
# Returns: command exit code, or 124 on timeout (matches coreutils convention)
#
# Exit code mapping (POSIX: signal exits are 128 + signal number):
#   124  — timeout (GNU coreutils convention; returned by all paths below)
#   137  — killed by SIGKILL  (128 + 9)  — hard kill, process did not exit cleanly
#   143  — killed by SIGTERM  (128 + 15) — graceful termination signal
# Callers that check for timeout should test for 124. Codes 137/143 indicate
# the process was killed externally (e.g., by the OS or a concurrent pulse).
#
# NOTE: Do NOT pipe timeout_sec to head/grep — on macOS the background
# process may not be properly cleaned up when the pipe closes early.
# Instead, redirect to a temp file and process afterward.
#
# Moved here from tool-version-check.sh (PR #2909) so all scripts that
# source shared-constants.sh get portable timeout support automatically.

timeout_sec() {
	local secs="$1"
	shift

	if command -v timeout &>/dev/null; then
		# Linux has native timeout — returns 124 on timeout
		timeout "$secs" "$@"
		return $?
	elif command -v gtimeout &>/dev/null; then
		# macOS with coreutils — returns 124 on timeout
		gtimeout "$secs" "$@"
		return $?
	else
		# macOS fallback: background the command in a new process group and kill
		# the entire group after the deadline. Using set -m puts each background
		# job in its own process group (PGID == child PID), so kill -- -PGID
		# terminates the child and all its descendants — not just the direct child.
		#
		# GH#5530: the previous implementation used kill "$cmd_pid" which only
		# killed the direct child. Wrapper processes (e.g., bash sandbox-exec-helper.sh)
		# survived because they are parents of the killed process, not children.
		#
		# Save whether monitor mode was already active before enabling it, so we
		# can restore the original shell state rather than unconditionally disabling it.
		local monitor_was_enabled=false
		[[ $- == *m* ]] && monitor_was_enabled=true
		set -m
		"$@" &
		local cmd_pid=$!
		# Restore monitor mode to its original state (set -m or set +m as appropriate)
		$monitor_was_enabled && set -m || set +m
		# PGID equals the PID of the process group leader (the background job)
		local cmd_pgid="$cmd_pid"
		# Poll every 0.5s; count half-seconds to avoid floating-point math
		local half_secs_remaining=$((secs * 2))
		while kill -0 "$cmd_pid" 2>/dev/null; do
			if ((half_secs_remaining <= 0)); then
				# Kill the entire process group: SIGTERM first, then SIGKILL
				kill -TERM -- "-${cmd_pgid}" 2>/dev/null || true # SIGTERM (15) — graceful
				sleep 0.2
				if kill -0 -- "-${cmd_pgid}" 2>/dev/null; then
					kill -KILL -- "-${cmd_pgid}" 2>/dev/null || true # SIGKILL (9) — hard kill
				fi
				wait "$cmd_pid" 2>/dev/null || true
				return 124 # Normalise to GNU timeout convention
			fi
			sleep 0.5
			((half_secs_remaining--)) || true
		done
		wait "$cmd_pid" 2>/dev/null
		return $?
	fi
}

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
readonly CI_TIMEOUT_FAST=60    # 1 minute for fast checks
readonly CI_TIMEOUT_MEDIUM=180 # 3 minutes for medium checks
readonly CI_TIMEOUT_SLOW=600   # 10 minutes for slow checks (CodeRabbit)

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
# Writes to stderr so ANSI codes are not captured in $() subshells
print_shared_success() {
	local msg="$1"
	echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $msg" >&2
	return 0
}

# Print warning message with consistent formatting
# Writes to stderr so ANSI codes are not captured in $() subshells
print_shared_warning() {
	local msg="$1"
	echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $msg" >&2
	return 0
}

# Print info message with consistent formatting
# Writes to stderr so ANSI codes are not captured in $() subshells
print_shared_info() {
	local msg="$1"
	echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $msg" >&2
	return 0
}

# Short aliases (used by most scripts - avoids needing inline redefinitions)
print_error() {
	print_shared_error "$1"
	return $?
}
print_success() {
	print_shared_success "$1"
	return $?
}
print_warning() {
	print_shared_warning "$1"
	return $?
}
print_info() {
	print_shared_info "$1"
	return $?
}

# =============================================================================
# Shared Logging Functions (issue #2411)
# =============================================================================
# Consolidated log_info/log_error/log_success/log_warn to eliminate duplication
# across 70+ scripts. Each script can customize the prefix label by setting
# LOG_PREFIX before sourcing this file (default: "INFO"/"ERROR"/"OK"/"WARN").
#
# Usage:
#   LOG_PREFIX="CODACY"  # Optional: set before sourcing for custom labels
#   source shared-constants.sh
#   log_info "Processing..."   # Output: [CODACY] Processing...
#
# If LOG_PREFIX is not set, labels default to level names:
#   log_info  -> [INFO]
#   log_error -> [ERROR]
#   log_success -> [OK]
#   log_warn  -> [WARN]
#
# All log functions write to stderr and return 0.
# Scripts that need different behavior can still override after sourcing.

log_info() {
	local label="${LOG_PREFIX:-INFO}"
	echo -e "${BLUE}[${label}]${NC} $*" >&2
	return 0
}

log_error() {
	local label="${LOG_PREFIX:+${LOG_PREFIX}}"
	echo -e "${RED}[${label:-ERROR}]${NC} $*" >&2
	return 0
}

log_success() {
	local label="${LOG_PREFIX:-OK}"
	echo -e "${GREEN}[${label}]${NC} $*" >&2
	return 0
}

log_warn() {
	local label="${LOG_PREFIX:-WARN}"
	echo -e "${YELLOW}[${label}]${NC} $*" >&2
	return 0
}

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

	if ! command -v "$command_name" &>/dev/null; then
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
	echo "[$timestamp] [$context] Running: $*" >>"$log_target" 2>/dev/null || true
	"$@" 2>>"$log_target"
	local rc=$?
	if [[ $rc -ne 0 ]]; then
		echo "[$timestamp] [$context] Exit code: $rc" >>"$log_target" 2>/dev/null || true
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
# RETURN Trap Cleanup Stack (t196)
# =============================================================================
# Prevents RETURN trap clobbering when a function needs multiple temp files.
# In bash, setting `trap '...' RETURN` twice in the same function silently
# replaces the first trap — the first temp file leaks.
#
# IMPORTANT: `trap` applies to the function that calls it, NOT the caller's
# caller. Therefore push_cleanup cannot set the trap for you — the calling
# function must set `trap '_run_cleanups' RETURN` itself.
#
# Usage pattern (replaces raw `trap 'rm ...' RETURN`):
#
#   my_func() {
#       _save_cleanup_scope
#       trap '_run_cleanups' RETURN
#       local tmp1; tmp1=$(mktemp)
#       push_cleanup "rm -f '${tmp1}'"
#       local tmp2; tmp2=$(mktemp)
#       push_cleanup "rm -f '${tmp2}'"
#       # ... both files cleaned up on return (LIFO order)
#   }
#
# Single-file shorthand (most common case — no change needed):
#
#   my_func() {
#       local tmp; tmp=$(mktemp)
#       trap 'rm -f "${tmp:-}"' RETURN
#       # ... single file, no clobbering risk
#   }
#
# Nesting: RETURN traps are function-scoped in bash 3.2+, so nested
# function calls each get their own trap. _save_cleanup_scope saves the
# parent's cleanup list; _run_cleanups restores it after executing.
#
# Migration from raw trap (only needed for multi-cleanup functions):
#   BEFORE: trap 'rm -f "${a:-}"' RETURN  # second trap clobbers first
#           trap 'rm -f "${b:-}"' RETURN
#   AFTER:  _save_cleanup_scope
#           trap '_run_cleanups' RETURN
#           push_cleanup "rm -f '${a}'"
#           push_cleanup "rm -f '${b}'"

# Global state for the cleanup stack.
# _CLEANUP_CMDS: newline-separated list of commands for the current scope.
# _CLEANUP_SAVE_STACK: saved parent scopes (unit-separator delimited).
_CLEANUP_CMDS=""
_CLEANUP_SAVE_STACK=""

# Add a cleanup command to the current scope.
# The command runs when the calling function returns (LIFO order).
# Caller MUST have set `trap '_run_cleanups' RETURN` in their own scope.
# Arguments:
#   $1 - shell command to eval on cleanup (required)
push_cleanup() {
	local cmd="$1"
	if [[ -n "$_CLEANUP_CMDS" ]]; then
		_CLEANUP_CMDS="${_CLEANUP_CMDS}"$'\n'"${cmd}"
	else
		_CLEANUP_CMDS="${cmd}"
	fi
	return 0
}

# Run all cleanup commands for the current scope (reverse order),
# then restore the parent scope's cleanup list.
# This is the RETURN trap handler — do not call directly.
_run_cleanups() {
	if [[ -n "$_CLEANUP_CMDS" ]]; then
		# Reverse the command list (LIFO) and execute each
		local reversed
		# tail -r is macOS, tac is GNU — try both
		reversed=$(echo "$_CLEANUP_CMDS" | tail -r 2>/dev/null) ||
			reversed=$(echo "$_CLEANUP_CMDS" | tac 2>/dev/null) ||
			reversed="$_CLEANUP_CMDS"
		local line
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			bash -c "$line" 2>/dev/null || true
		done <<<"$reversed"
	fi
	# Restore parent scope (pop from save stack)
	local sep=$'\x1F'
	if [[ -n "$_CLEANUP_SAVE_STACK" ]]; then
		_CLEANUP_CMDS="${_CLEANUP_SAVE_STACK%%"${sep}"*}"
		_CLEANUP_SAVE_STACK="${_CLEANUP_SAVE_STACK#*"${sep}"}"
	else
		_CLEANUP_CMDS=""
	fi
	return 0
}

# Save the current cleanup scope and start a fresh one.
# Call at the top of any function that uses push_cleanup, BEFORE setting
# `trap '_run_cleanups' RETURN`. This preserves the parent function's
# cleanup list so nested calls don't interfere.
_save_cleanup_scope() {
	local sep=$'\x1F'
	_CLEANUP_SAVE_STACK="${_CLEANUP_CMDS}${sep}${_CLEANUP_SAVE_STACK}"
	_CLEANUP_CMDS=""
	return 0
}

# =============================================================================
# GitHub Token Workflow Scope Check (t1540)
# =============================================================================
# Reusable function to check if the current gh token has the `workflow` scope.
# Without this scope, git push and gh pr merge fail for branches that modify
# .github/workflows/ files. The error is:
#   "refusing to allow an OAuth App to create or update workflow without workflow scope"
#
# Usage:
#   if ! gh_token_has_workflow_scope; then
#       echo "Missing workflow scope — run: gh auth refresh -s workflow"
#   fi
#
# Returns: 0 if token has workflow scope, 1 if missing, 2 if unable to check

gh_token_has_workflow_scope() {
	if ! command -v gh &>/dev/null; then
		return 2
	fi

	local auth_output
	auth_output=$(gh auth status 2>&1) || return 2

	# gh auth status outputs scopes in various formats depending on version:
	#   Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo', 'workflow'
	#   Token scopes: admin:public_key, gist, read:org, repo, workflow
	if echo "$auth_output" | grep -q "'workflow'"; then
		return 0
	fi
	if echo "$auth_output" | grep -qiE 'Token scopes:.*workflow'; then
		return 0
	fi

	return 1
}

# Check if a set of file paths includes .github/workflows/ changes.
# Accepts file paths on stdin (one per line) or as arguments.
#
# Usage:
#   git diff --name-only HEAD~1 | files_include_workflow_changes
#   files_include_workflow_changes ".github/workflows/ci.yml" "src/main.sh"
#
# Returns: 0 if workflow files found, 1 if not
files_include_workflow_changes() {
	if [[ $# -gt 0 ]]; then
		# Check arguments
		local f
		for f in "$@"; do
			if [[ "$f" == .github/workflows/* ]]; then
				return 0
			fi
		done
		return 1
	fi

	# Check stdin
	local line
	while IFS= read -r line; do
		if [[ "$line" == .github/workflows/* ]]; then
			return 0
		fi
	done
	return 1
}

# =============================================================================
# Session Origin Detection
# =============================================================================
# Detects whether the current session is a headless worker or interactive user.
# Used to tag issues, TODOs, and PRs with origin:worker or origin:interactive.
#
# Design: inverted logic — detect known headless signals, default to interactive.
# AI coding tools (OpenCode, Claude Code, Cursor, Kiro, Codex, Windsurf, etc.)
# all run bash tools without a TTY, so TTY presence is not a reliable signal.
# The headless dispatch infrastructure sets explicit env vars; everything else
# is a user session.
#
# Known headless signals (exhaustive — add new ones here as dispatch infra grows):
#   FULL_LOOP_HEADLESS=true   — pulse supervisor dispatch
#   AIDEVOPS_HEADLESS=true    — headless-runtime-helper.sh
#   OPENCODE_HEADLESS=true    — OpenCode headless mode
#   GITHUB_ACTIONS=true       — CI environment
#
# Default: interactive — covers all AI coding tools without runtime-specific checks.
#
# Usage:
#   local origin; origin=$(detect_session_origin)
#   # Returns: "worker" or "interactive"
#
#   local label; label=$(session_origin_label)
#   # Returns: "origin:worker" or "origin:interactive"

detect_session_origin() {
	# t1984: Explicit override via AIDEVOPS_SESSION_ORIGIN takes precedence
	# over the headless auto-detection. Used by the sync-todo-to-issues
	# workflow to mark issues created from human-triggered TODO.md pushes
	# as origin:interactive rather than origin:worker, so the t1970 auto-
	# assign path fires and the Maintainer Gate doesn't block downstream PRs.
	case "${AIDEVOPS_SESSION_ORIGIN:-}" in
	interactive)
		echo "interactive"
		return 0
		;;
	worker)
		echo "worker"
		return 0
		;;
	esac

	# Known headless signals — set by dispatch infrastructure only.
	# If none of these are set, the session is interactive by default.
	if [[ "${FULL_LOOP_HEADLESS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	if [[ "${AIDEVOPS_HEADLESS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	if [[ "${OPENCODE_HEADLESS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	# Default: interactive.
	# Covers all AI coding tools (OpenCode, Claude Code, Cursor, Kiro, Codex,
	# Windsurf, Gemini CLI, Kimi CLI, etc.) without needing runtime-specific
	# env var checks. TTY presence is NOT checked — it is unreliable for all
	# AI coding tools which run bash tools without a TTY.
	echo "interactive"
	return 0
}

# Returns the GitHub label string for the current session origin.
# Usage: local label; label=$(session_origin_label)
session_origin_label() {
	local origin
	origin=$(detect_session_origin)
	echo "origin:${origin}"
	return 0
}

# =============================================================================
# Origin-Label-Aware gh Wrappers (t1756)
# =============================================================================
# Every gh issue/pr create call MUST use these wrappers to ensure the session
# origin label (origin:worker or origin:interactive) is always applied.
# GitHub deduplicates labels, so callers that already pass --label origin:*
# will not get duplicates.
#
# Usage (drop-in replacement for gh issue create / gh pr create):
#   gh_create_issue --repo owner/repo --title "..." --label "bug" --body "..."
#   gh_create_pr --head branch --base main --title "..." --body "..."
#
# These forward all arguments to gh and append --label <origin>.

# t2028: Internal — check if argv already contains an --assignee flag.
# Used by gh_create_issue to avoid overriding caller-supplied assignees.
_gh_wrapper_args_have_assignee() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--assignee | --assignee=*)
			return 0
			;;
		*)
			shift
			;;
		esac
	done
	return 1
}

# t2028: Internal — determine the auto-assignee for a newly-created issue.
# Returns empty string when the session is worker-origin, when the user
# lookup fails, or when there is otherwise nothing to assign. Callers must
# treat empty as "skip assignment". Non-fatal: all failure modes echo empty.
#
# Mirrors the _auto_assign_issue logic at claim-task-id.sh:607 (t1970) so
# the direct gh_create_issue path reaches assignee-gate parity with the
# claim-task-id.sh path.
_gh_wrapper_auto_assignee() {
	local origin
	origin=$(detect_session_origin)
	if [[ "$origin" != "interactive" ]]; then
		return 0
	fi
	# t1984 override: sync-todo-to-issues workflow sets AIDEVOPS_SESSION_USER
	# to github.actor when the commit author is human. Prefer that explicit
	# signal over `gh api user`, which would return github-actions[bot]
	# inside a workflow run.
	if [[ -n "${AIDEVOPS_SESSION_USER:-}" ]]; then
		printf '%s' "$AIDEVOPS_SESSION_USER"
		return 0
	fi
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || true)
	if [[ -z "$current_user" ]] || [[ "$current_user" == "null" ]]; then
		return 0
	fi
	printf '%s' "$current_user"
	return 0
}

# t2115: Auto-append signature footer to --body/--body-file when missing.
# Populates global _GH_WRAPPER_SIG_MODIFIED_ARGS with the (possibly modified) args.
# Callers should invoke _gh_wrapper_auto_sig "$@" then
#   set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
# Non-fatal: if signature generation fails, original args are preserved.
_GH_WRAPPER_SIG_MODIFIED_ARGS=()
_gh_wrapper_auto_sig() {
	_GH_WRAPPER_SIG_MODIFIED_ARGS=("$@")
	local sig_helper
	sig_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-signature-helper.sh"
	[[ -x "$sig_helper" ]] || return 0

	local i=0 body_val="" body_idx=-1 is_eq_form=0
	local body_file_val="" body_file_idx=-1 bf_is_eq=0
	while [[ $i -lt ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]} ]]; do
		case "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" in
		--body)
			body_idx=$i
			body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]:-}"
			is_eq_form=0
			;;
		--body=*)
			body_idx=$i
			body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]#--body=}"
			is_eq_form=1
			;;
		--body-file)
			body_file_idx=$i
			body_file_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]:-}"
			bf_is_eq=0
			;;
		--body-file=*)
			body_file_idx=$i
			body_file_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]#--body-file=}"
			bf_is_eq=1
			;;
		esac
		i=$((i + 1))
	done

	# Handle --body case
	if [[ $body_idx -ge 0 && -n "$body_val" ]]; then
		# Already signed — skip
		[[ "$body_val" == *"<!-- aidevops:sig -->"* ]] && return 0
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body_val" 2>/dev/null || echo "")
		[[ -z "$sig_footer" ]] && return 0
		local new_body="${body_val}${sig_footer}"
		if [[ "$is_eq_form" -eq 1 ]]; then
			_GH_WRAPPER_SIG_MODIFIED_ARGS[body_idx]="--body=${new_body}"
		else
			_GH_WRAPPER_SIG_MODIFIED_ARGS[body_idx + 1]="$new_body"
		fi
		return 0
	fi

	# Handle --body-file case
	if [[ $body_file_idx -ge 0 && -n "$body_file_val" && -f "$body_file_val" ]]; then
		local file_content
		file_content=$(<"$body_file_val") || return 0
		[[ "$file_content" == *"<!-- aidevops:sig -->"* ]] && return 0
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$file_content" 2>/dev/null || echo "")
		[[ -z "$sig_footer" ]] && return 0
		printf '%s' "$sig_footer" >>"$body_file_val"
		return 0
	fi

	return 0
}

gh_create_issue() {
	# GH#19857: validate title/body before creating (same invariant as edit wrappers)
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi

	local origin_label
	origin_label=$(session_origin_label)
	# Ensure labels exist on the target repo (once per repo per process)
	_ensure_origin_labels_for_args "$@"

	# t2115: auto-append signature footer when body lacks one
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"

	# t2028: auto-assign to the current user when the session is interactive
	# and the caller did not pass an explicit --assignee. Reaches parity with
	# the t1970 auto-assign already applied on the claim-task-id.sh path so
	# the maintainer gate's assignee check passes on first PR open for
	# interactively-created issues.
	local issue_output
	if ! _gh_wrapper_args_have_assignee "$@"; then
		local auto_assignee
		auto_assignee=$(_gh_wrapper_auto_assignee)
		if [[ -n "$auto_assignee" ]]; then
			issue_output=$(gh issue create "$@" --label "$origin_label" --assignee "$auto_assignee")
			local rc=$?
			echo "$issue_output"
			[[ $rc -eq 0 ]] && _gh_auto_link_sub_issue "$issue_output" "$@"
			return $rc
		fi
	fi

	issue_output=$(gh issue create "$@" --label "$origin_label")
	local rc=$?
	echo "$issue_output"
	[[ $rc -eq 0 ]] && _gh_auto_link_sub_issue "$issue_output" "$@"
	return $rc
}

# GH#18735: auto-link newly created issues as sub-issues of their parent
# when the title matches tNNN.M (dot-notation subtask pattern).
# Non-blocking — errors are silently ignored so issue creation is never affected.
# Arguments:
#   $1 - issue URL output from gh issue create
#   $2... - original args passed to gh issue create (to extract --title and --repo)
_gh_auto_link_sub_issue() {
	local issue_url="$1"
	shift

	# Extract --title from the original args
	local title="" repo=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			title="${2:-}"
			shift
			;;
		--title=*) title="${1#--title=}" ;;
		--repo)
			repo="${2:-}"
			shift
			;;
		--repo=*) repo="${1#--repo=}" ;;
		*) ;;
		esac
		shift
	done
	[[ -z "$title" ]] && return 0

	# Check if title starts with a dot-notation task ID (tNNN.M)
	local child_task_id=""
	if [[ "$title" =~ ^(t[0-9]+\.[0-9]+[a-z]?) ]]; then
		child_task_id="${BASH_REMATCH[1]}"
	else
		return 0
	fi

	# Derive the parent task ID (strip last .segment)
	local parent_task_id="${child_task_id%.*}"
	[[ -z "$parent_task_id" || "$parent_task_id" == "$child_task_id" ]] && return 0

	# Extract the child issue number from the URL
	local child_num
	child_num=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
	[[ -z "$child_num" ]] && return 0

	# Resolve repo slug (from --repo arg or current repo)
	[[ -z "$repo" ]] && repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	[[ -z "$repo" ]] && return 0

	local owner="${repo%%/*}" name="${repo##*/}"

	# Find the parent issue by searching for the task ID prefix in the title
	local parent_num
	parent_num=$(gh issue list --repo "$repo" --state all \
		--search "${parent_task_id}: in:title" --json number,title --limit 5 2>/dev/null |
		jq -r --arg prefix "${parent_task_id}: " \
			'.[] | select(.title | startswith($prefix)) | .number // ""' 2>/dev/null |
		head -1)
	[[ -z "$parent_num" ]] && return 0

	# Resolve both to node IDs and link
	local parent_node child_node
	parent_node=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
		-f o="$owner" -f n="$name" -F num="$parent_num" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	child_node=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
		-f o="$owner" -f n="$name" -F num="$child_num" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	[[ -z "$parent_node" || -z "$child_node" ]] && return 0

	# Fire and forget — suppress all errors
	gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
		-f p="$parent_node" -f c="$child_node" >/dev/null 2>&1 || true
	return 0
}

gh_create_pr() {
	# GH#19857: validate title/body before creating (same invariant as edit wrappers)
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi

	local origin_label
	origin_label=$(session_origin_label)
	_ensure_origin_labels_for_args "$@"

	# t2115: auto-append signature footer when body lacks one
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"

	gh pr create "$@" --label "$origin_label"
}

# t2393: auto-append signature footer on all `gh issue comment` posts.
# Thin wrapper mirroring gh_create_issue/gh_create_pr — invokes
# _gh_wrapper_auto_sig on --body/--body-file before delegating to the
# underlying gh command. No origin-label or assignee logic (creation-only
# concerns); comments just need the runtime/version/model/token sig so
# operators and pulse readers can diagnose which session posted them.
# Dedup: _gh_wrapper_auto_sig skips bodies already containing the
# <!-- aidevops:sig --> marker, so callers that build their own footer
# are not double-signed.
gh_issue_comment() {
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	gh issue comment "$@"
	return $?
}

gh_pr_comment() {
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	gh pr comment "$@"
	return $?
}

# Internal: extract --repo from args and ensure labels exist (cached per repo).
_ORIGIN_LABELS_ENSURED=""
_ensure_origin_labels_for_args() {
	local repo=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="${2:-}"
			break
			;;
		--repo=*)
			repo="${1#--repo=}"
			break
			;;
		*) shift ;;
		esac
	done
	[[ -z "$repo" ]] && return 0
	# Skip if already ensured for this repo in this process
	case ",$_ORIGIN_LABELS_ENSURED," in
	*",$repo,"*) return 0 ;;
	esac
	ensure_origin_labels_exist "$repo"
	_ORIGIN_LABELS_ENSURED="${_ORIGIN_LABELS_ENSURED:+$_ORIGIN_LABELS_ENSURED,}$repo"
	return 0
}

# Ensure origin labels exist on a repo (idempotent).
# Usage: ensure_origin_labels_exist "owner/repo"
ensure_origin_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	gh label create "origin:worker" --repo "$repo" \
		--description "Created by headless/pulse worker session" \
		--color "C5DEF5" 2>/dev/null || true
	gh label create "origin:interactive" --repo "$repo" \
		--description "Created by interactive user session" \
		--color "BFD4F2" 2>/dev/null || true
	gh label create "origin:worker-takeover" --repo "$repo" \
		--description "Worker took over from interactive session" \
		--color "D4C5F9" 2>/dev/null || true
	return 0
}

# =============================================================================
# Safe gh Edit Wrappers (GH#19857)
# =============================================================================
# Framework-wide safety invariant: no code path may invoke gh issue edit or
# gh pr edit with an empty title or empty body — under any condition, including
# FORCE_* override flags. The check lives here so ALL call sites go through it.
#
# This mirrors the gh_create_issue / gh_create_pr pattern (origin labelling +
# signing) but for DESTRUCTIVE edits rather than creation.
#
# Validation rules:
#   Title: MUST be non-empty after trimming whitespace. Bare task-ID stubs
#          like "tNNN: " or "GH#NNN: " (nothing after the prefix) are rejected.
#   Body:  MUST be non-empty after trimming when --body is present.
#          --body-file /dev/null and --body "" are rejected.
#   Override: NO env var bypasses this. This is the hard invariant.
#
# Usage (drop-in replacements for gh issue edit / gh pr edit):
#   gh_issue_edit_safe 123 --repo owner/repo --title "t001: Fix bug" --body "..."
#   gh_pr_edit_safe 456 --repo owner/repo --title "t001: Fix bug"

# Internal: rejection reason for the most recent _gh_validate_edit_args call.
_GH_EDIT_REJECTION_REASON=""

#######################################
# Internal: validate --title and --body/--body-file args.
# Returns 0 if valid, 1 if rejected (with stderr message + _GH_EDIT_REJECTION_REASON).
# Args: the full argument list that would be passed to gh issue/pr edit.
#######################################
_gh_validate_edit_args() {
	_GH_EDIT_REJECTION_REASON=""
	local i=0 title_val="" has_title=0 body_val="" has_body=0
	local body_file_val="" has_body_file=0
	local -a args=("$@")

	while [[ $i -lt ${#args[@]} ]]; do
		case "${args[i]}" in
		--title)
			has_title=1
			title_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--title=*)
			has_title=1
			title_val="${args[i]#--title=}"
			;;
		--body)
			has_body=1
			body_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--body=*)
			has_body=1
			body_val="${args[i]#--body=}"
			;;
		--body-file)
			has_body_file=1
			body_file_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--body-file=*)
			has_body_file=1
			body_file_val="${args[i]#--body-file=}"
			;;
		*) ;;
		esac
		i=$((i + 1))
	done

	# Validate title if present
	if [[ "$has_title" -eq 1 ]]; then
		local trimmed_title
		trimmed_title="${title_val#"${title_val%%[![:space:]]*}"}"
		trimmed_title="${trimmed_title%"${trimmed_title##*[![:space:]]}"}"
		if [[ -z "$trimmed_title" ]]; then
			_GH_EDIT_REJECTION_REASON="empty title (after trimming whitespace)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		# Reject bare task-ID stubs: "tNNN: " or "GH#NNN: " with nothing after
		if [[ "$trimmed_title" =~ ^(t[0-9]+|GH#[0-9]+):[[:space:]]*$ ]]; then
			_GH_EDIT_REJECTION_REASON="stub title '${trimmed_title}' (task-ID prefix with no description)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
	fi

	# Validate body if present
	if [[ "$has_body" -eq 1 ]]; then
		local trimmed_body
		trimmed_body="${body_val#"${body_val%%[![:space:]]*}"}"
		trimmed_body="${trimmed_body%"${trimmed_body##*[![:space:]]}"}"
		if [[ -z "$trimmed_body" ]]; then
			_GH_EDIT_REJECTION_REASON="empty body (after trimming whitespace)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
	fi

	# Validate body-file if present
	if [[ "$has_body_file" -eq 1 ]]; then
		if [[ "$body_file_val" == "/dev/null" ]]; then
			_GH_EDIT_REJECTION_REASON="body-file is /dev/null (would clear body)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		if [[ -f "$body_file_val" ]]; then
			local file_size
			file_size=$(wc -c <"$body_file_val" 2>/dev/null || echo "0")
			file_size=$(echo "$file_size" | tr -d '[:space:]')
			if [[ "$file_size" -eq 0 ]]; then
				_GH_EDIT_REJECTION_REASON="body-file '${body_file_val}' is empty"
				printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
				return 1
			fi
		fi
	fi

	return 0
}

#######################################
# Internal: audit-log a safety rejection.
# Non-fatal — if audit-log-helper.sh is unavailable, the stderr message
# from _gh_validate_edit_args is still emitted.
# Args:
#   $1 — operation name (e.g. "gh issue edit")
#   $2 — rejection reason
#   $3..N — original command args (truncated to 500 chars for the log)
#######################################
_gh_edit_audit_rejection() {
	local operation="$1"
	local reason="$2"
	shift 2
	local context
	context=$(printf '%q ' "$@" | head -c 500)
	local audit_helper
	audit_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]]; then
		"$audit_helper" log operation.block \
			"gh_edit_safety: ${operation} rejected — ${reason}. Context: ${context}" \
			2>/dev/null || true
	fi
	return 0
}

#######################################
# gh_issue_edit_safe — drop-in replacement for gh issue edit.
# Validates --title/--body before delegating. Rejects empty/stub values.
# All arguments are forwarded to gh issue edit on success.
# Returns 1 with stderr message on validation failure.
#######################################
gh_issue_edit_safe() {
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	gh issue edit "$@"
}

#######################################
# gh_pr_edit_safe — drop-in replacement for gh pr edit.
# Validates --title/--body before delegating. Rejects empty/stub values.
# All arguments are forwarded to gh pr edit on success.
# Returns 1 with stderr message on validation failure.
#######################################
gh_pr_edit_safe() {
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	gh pr edit "$@"
}

# =============================================================================
# Origin Label Mutual Exclusion (t2200)
# =============================================================================
# origin:interactive, origin:worker, and origin:worker-takeover are mutually
# exclusive — an issue was created by exactly one session type. Setting one
# must atomically remove the other two so downstream consumers
# (dispatch-dedup, maintainer gate, pulse-merge routing) can rely on
# single-label semantics without checking for impossible combinations.
#
# Background: #19638 accumulated BOTH origin:interactive AND origin:worker
# because edit sites added one without removing the other. The status-label
# state machine (set_issue_status, t2033) solved the identical problem for
# status:* labels — this mirrors that pattern for origin:* labels.

# Canonical list of mutually-exclusive origin:* labels.
ORIGIN_LABELS=("interactive" "worker" "worker-takeover")

#######################################
# Transition an issue or PR to an origin:* label atomically (t2200).
#
# Removes every sibling origin:* label in a single `gh issue edit` call,
# then adds the target. This is the ONLY sanctioned way to change an
# existing issue/PR's origin label — ad-hoc --add-label/--remove-label
# calls must go through this helper so the mutual-exclusion invariant
# is enforced centrally.
#
# For new issues/PRs (gh_create_issue, gh_create_pr), the wrappers pass
# a single --label origin:* at creation time, so there is nothing to
# remove. This helper is for post-creation edits only.
#
# Args:
#   $1 — issue/PR number
#   $2 — repo slug (owner/repo)
#   $3 — new origin: one of interactive|worker|worker-takeover
#   $4 — (optional) --pr to edit a PR instead of an issue (default: issue)
#   $@ — additional gh edit flags passed through verbatim (e.g.,
#        --add-assignee, --remove-assignee, --add-label "other-label")
#
# Returns:
#   0 on gh success
#   1 on gh failure
#   2 on invalid origin argument (caller bug)
#
# Example:
#   set_origin_label 19638 owner/repo worker
#   set_origin_label 19638 owner/repo interactive --pr
#   set_origin_label 19638 owner/repo worker \
#       --add-assignee "$worker_login"
#######################################
set_origin_label() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_origin="$3"
	shift 3

	# Validate inputs
	if [[ -z "$issue_num" || -z "$repo_slug" || -z "$new_origin" ]]; then
		printf 'set_origin_label: issue_num, repo_slug, and new_origin are required\n' >&2
		return 2
	fi

	# Check for --pr flag in remaining args
	local gh_cmd="issue"
	local -a extra_flags=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			gh_cmd="pr"
			shift
			;;
		*)
			extra_flags+=("$1")
			shift
			;;
		esac
	done

	# Validate target origin
	local _valid=0
	local _origin
	for _origin in "${ORIGIN_LABELS[@]}"; do
		[[ "$_origin" == "$new_origin" ]] && {
			_valid=1
			break
		}
	done
	if [[ "$_valid" -eq 0 ]]; then
		printf 'set_origin_label: invalid origin "%s" (valid: %s)\n' \
			"$new_origin" "${ORIGIN_LABELS[*]}" >&2
		return 2
	fi

	# Ensure labels exist (cached per-process per-repo so this is cheap)
	ensure_origin_labels_exist "$repo_slug" || true

	# Build flag list: add target, remove all siblings.
	local -a _flags=()
	local _label
	for _label in "${ORIGIN_LABELS[@]}"; do
		if [[ "$_label" == "$new_origin" ]]; then
			_flags+=(--add-label "origin:${_label}")
		else
			_flags+=(--remove-label "origin:${_label}")
		fi
	done

	# Pass through any extra flags the caller wants to apply in the same edit
	if [[ ${#extra_flags[@]} -gt 0 ]]; then
		_flags+=("${extra_flags[@]}")
	fi

	gh "$gh_cmd" edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
}

# =============================================================================
# Issue Status Label State Machine (t2033)
# =============================================================================
# aidevops models issue lifecycle as a set of mutually-exclusive `status:*`
# labels. Every transition must atomically remove siblings so the state is
# always consistent — audit queries like `gh issue list --label status:*`
# can only be trusted if no issue ever carries two status labels at once.
#
# Background: #18444, #18454, #18455 all accumulated both `status:available`
# and `status:queued` because `_dispatch_launch_worker` added `queued` without
# removing `available`. t2008 stale-recovery escalation failed to fire as a
# result. Root cause: 8+ call sites constructed their own --add-label /
# --remove-label flags, with several forgetting one or more siblings.
#
# Canonical core lifecycle (managed here):
#   available → queued → claimed → in-progress → in-review → done
#                                   ↓
#                                blocked (waiting on dependency)
#
# Exception labels (NOT managed here — out-of-band signals):
#   status:needs-info, status:verify-failed, status:stale,
#   status:needs-testing, status:orphaned
# These are set/cleared by separate workflows and do not participate in
# the core dispatch lifecycle enforced by this helper.

# Canonical ordered list of mutually-exclusive core status:* labels.
# When transitioning, all siblings of the target must be removed atomically.
# Order matches the lifecycle flow for human readability; the helper treats
# them as an unordered set. Elements are quoted because "done" is a bash
# reserved word (SC1010).
ISSUE_STATUS_LABELS=("available" "queued" "claimed" "in-progress" "in-review" "done" "blocked")

# t2040: precedence order for label-invariant reconciliation. First match wins
# when picking the survivor from a multi-label pollution event. `done` is
# terminal — always preserved if present. This guards against data loss in any
# future code path that isn't fully atomic: if an issue transiently ends up
# with both `in-review` and `done`, the reconciler MUST keep `done`.
# Consumed by `_normalize_label_invariants` in pulse-issue-reconcile.sh.
ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")

# t2040: tier label rank for invariant reconciliation. Must match the rank
# order in .github/workflows/dedup-tier-labels.yml — reconciler and GH Action
# must pick the same survivor so they're idempotent with each other.
ISSUE_TIER_LABEL_RANK=("thinking" "standard" "simple")

# Ensure all core status:* labels exist on a repo (idempotent, cached per-process).
# The helper relies on --remove-label being idempotent for *unset* labels (gh
# returns exit 0 when a label exists in the repo but isn't applied to the issue),
# but fails hard when a label doesn't exist in the repo at all. Pre-creating
# them once per repo per process closes that gap.
#
# Usage: ensure_status_labels_exist "owner/repo"
_STATUS_LABELS_ENSURED=""
ensure_status_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	# Skip if already ensured for this repo in this process
	case ",${_STATUS_LABELS_ENSURED}," in
	*",${repo},"*) return 0 ;;
	esac

	# Colors roughly follow GitHub's default palette for lifecycle states.
	gh label create "status:available" --repo "$repo" \
		--description "Task is available for claiming" --color "0E8A16" --force 2>/dev/null || true
	gh label create "status:queued" --repo "$repo" \
		--description "Worker dispatched, not yet started" --color "FBCA04" --force 2>/dev/null || true
	gh label create "status:claimed" --repo "$repo" \
		--description "Interactive session claimed this task" --color "F9D0C4" --force 2>/dev/null || true
	gh label create "status:in-progress" --repo "$repo" \
		--description "Worker actively running" --color "1D76DB" --force 2>/dev/null || true
	gh label create "status:in-review" --repo "$repo" \
		--description "PR open, awaiting review/merge" --color "5319E7" --force 2>/dev/null || true
	gh label create "status:done" --repo "$repo" \
		--description "Task is complete" --color "6F42C1" --force 2>/dev/null || true
	gh label create "status:blocked" --repo "$repo" \
		--description "Waiting on blocker task" --color "D93F0B" --force 2>/dev/null || true

	_STATUS_LABELS_ENSURED="${_STATUS_LABELS_ENSURED:+${_STATUS_LABELS_ENSURED},}${repo}"
	return 0
}

#######################################
# Transition an issue to a status:* label atomically (t2033).
#
# Removes every sibling core status:* label in a single `gh issue edit` call,
# then adds the target. This is the ONLY sanctioned way to change an issue's
# status label — ad-hoc --add-label/--remove-label calls must go through
# this helper so the status state machine is enforced centrally.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — new status: one of available|queued|claimed|in-progress|in-review|done|blocked
#        OR empty string to clear all core status labels without adding one
#        (used by stale-recovery escalation which applies needs-maintainer-review
#        instead of a core status)
#   $@ — additional gh issue edit flags passed through verbatim (e.g.,
#        --add-assignee, --remove-assignee, --add-label "other-non-status-label")
#
# Returns:
#   0 on gh success (including idempotent no-op cases)
#   1 on gh failure (logged; callers typically ignore with || true to match
#     the existing convention for best-effort label operations)
#   2 on invalid status argument (caller bug — not suppressed)
#
# Example:
#   set_issue_status 18444 owner/repo queued \
#       --add-assignee "$worker_login" \
#       --add-label "origin:worker"
#
#   set_issue_status 18444 owner/repo "" \
#       --add-label "needs-maintainer-review"
#######################################
set_issue_status() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_status="$3"
	shift 3

	# Validate inputs
	if [[ -z "$issue_num" || -z "$repo_slug" ]]; then
		printf 'set_issue_status: issue_num and repo_slug are required\n' >&2
		return 2
	fi

	# Validate target status (empty is allowed = clear only)
	if [[ -n "$new_status" ]]; then
		local _valid=0
		local _status
		for _status in "${ISSUE_STATUS_LABELS[@]}"; do
			[[ "$_status" == "$new_status" ]] && {
				_valid=1
				break
			}
		done
		if [[ "$_valid" -eq 0 ]]; then
			printf 'set_issue_status: invalid status "%s" (valid: %s)\n' \
				"$new_status" "${ISSUE_STATUS_LABELS[*]}" >&2
			return 2
		fi
	fi

	# Ensure labels exist (cached per-process per-repo so this is cheap)
	ensure_status_labels_exist "$repo_slug" || true

	# Build flag list: remove all core status labels, add target if non-empty.
	local -a _flags=()
	local _label
	for _label in "${ISSUE_STATUS_LABELS[@]}"; do
		if [[ "$_label" == "$new_status" ]]; then
			_flags+=(--add-label "status:${_label}")
		else
			_flags+=(--remove-label "status:${_label}")
		fi
	done

	# Pass through any extra flags the caller wants to apply in the same edit
	_flags+=("$@")

	gh issue edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
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

# good stuff — portable atomic lock using mkdir (works on macOS + Linux).
# mkdir is atomic on all POSIX systems -- only one process succeeds.
_todo_acquire_lock() {
	local log_target="${1:-/dev/null}"
	local waited=0

	while [[ $waited -lt $TODO_LOCK_TIMEOUT ]]; do
		if mkdir "$TODO_LOCK_PATH" 2>/dev/null; then
			echo $$ >"$TODO_LOCK_PATH/pid"
			return 0
		fi

		# Check for stale lock (owner process died)
		if [[ -f "$TODO_LOCK_PATH/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$TODO_LOCK_PATH/pid" 2>/dev/null || echo "")
			if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
				echo "[todo_lock] Removing stale lock (PID $lock_pid dead)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$TODO_LOCK_PATH" ]]; then
			local lock_age
			if [[ "$(uname)" == "Darwin" ]]; then
				lock_age=$(($(date +%s) - $(stat -f %m "$TODO_LOCK_PATH" 2>/dev/null || echo "0")))
			else
				lock_age=$(($(date +%s) - $(stat -c %Y "$TODO_LOCK_PATH" 2>/dev/null || echo "0")))
			fi
			if [[ $lock_age -gt $TODO_STALE_LOCK_AGE ]]; then
				echo "[todo_lock] Removing stale lock (age ${lock_age}s > ${TODO_STALE_LOCK_AGE}s)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	echo "[todo_lock] Failed to acquire lock after ${TODO_LOCK_TIMEOUT}s" >>"$log_target"
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
				echo "[todo_commit_push] Pull --rebase failed (attempt $attempt/$TODO_MAX_RETRIES)" >>"$log_target"
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
			echo "[todo_commit_push] No changes staged" >>"$log_target"
			return 0
		fi

		# Commit
		if ! git -C "$repo_path" commit -m "$commit_msg" --no-verify 2>>"$log_target"; then
			echo "[todo_commit_push] Commit failed (attempt $attempt/$TODO_MAX_RETRIES)" >>"$log_target"
			continue
		fi

		# Push
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success on attempt $attempt" >>"$log_target"
			return 0
		fi

		echo "[todo_commit_push] Push failed (attempt $attempt/$TODO_MAX_RETRIES), retrying..." >>"$log_target"

		# Push failed: pull --rebase to incorporate remote changes, then retry push
		git -C "$repo_path" pull --rebase origin "$current_branch" 2>>"$log_target" || {
			git -C "$repo_path" rebase --abort 2>/dev/null || true
			sleep 1
			continue
		}

		# Retry push after rebase
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success after rebase on attempt $attempt" >>"$log_target"
			return 0
		fi

		sleep $((attempt))
	done

	echo "[todo_commit_push] Failed after $TODO_MAX_RETRIES attempts" >>"$log_target"
	return 1
}

# =============================================================================
# Worktree Ownership Registry (t189) — extracted module
# =============================================================================
# Functions: register_worktree, claim_worktree_ownership, unregister_worktree,
#            check_worktree_owner, is_worktree_owned_by_others, prune_worktree_registry
# Extracted to shared-worktree-registry.sh to keep this file < 2000 lines.
# See shared-worktree-registry.sh for full documentation.
#
# SQLite Backup-Before-Modify Pattern (t188) — extracted module
# Functions: backup_sqlite_db, verify_sqlite_backup, rollback_sqlite_db,
#            cleanup_sqlite_backups, verify_migration_rowcounts
# Extracted to shared-sqlite-backup.sh to keep this file < 2000 lines.
# See shared-sqlite-backup.sh for full documentation.

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# shellcheck source=/dev/null
[[ -r "${_SC_SELF%/*}/shared-worktree-registry.sh" ]] && source "${_SC_SELF%/*}/shared-worktree-registry.sh"
# shellcheck source=/dev/null
[[ -r "${_SC_SELF%/*}/shared-sqlite-backup.sh" ]] && source "${_SC_SELF%/*}/shared-sqlite-backup.sh"

# =============================================================================
# Export all constants for use in other scripts
# =============================================================================

# =============================================================================
# Model tier resolution (t132.7)
# Shared function for resolving tier names to full provider/model strings.
# Used by runner-helper.sh, cron-helper.sh, cron-dispatch.sh.
# Tries: 1) fallback-chain-helper.sh (availability-aware)
#         2) Static mapping (always works)
# =============================================================================

#######################################
# Resolve a model tier name to a full provider/model string (t132.7)
# Accepts both tier names (haiku, sonnet, opus, flash, pro, grok, coding, eval, health)
# and full provider/model strings (passed through unchanged).
# Returns the resolved model string on stdout.
#######################################
resolve_model_tier() {
	local tier="${1:-coding}"

	# If already a full provider/model string (contains /), return as-is
	if [[ "$tier" == *"/"* ]]; then
		echo "$tier"
		return 0
	fi

	# Try fallback-chain-helper.sh for availability-aware resolution
	# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
	# in zsh (the MCP shell environment). The :-$0 fallback ensures SCRIPT_DIR
	# resolves correctly whether sourced from bash or zsh. See GH#4904.
	local _sc_self="${BASH_SOURCE[0]:-${0:-}}"
	local chain_helper="${_sc_self%/*}/fallback-chain-helper.sh"
	if [[ -x "$chain_helper" ]]; then
		local resolved
		resolved=$("$chain_helper" resolve "$tier" --quiet 2>/dev/null) || true
		if [[ -n "$resolved" ]]; then
			echo "$resolved"
			return 0
		fi
	fi

	# Static fallback: map tier names to concrete models
	case "$tier" in
	opus | coding)
		echo "anthropic/claude-opus-4-6"
		;;
	sonnet | eval)
		echo "anthropic/claude-sonnet-4-6"
		;;
	haiku | health)
		echo "anthropic/claude-haiku-4-5"
		;;
	flash)
		echo "google/gemini-2.5-flash"
		;;
	pro)
		echo "google/gemini-2.5-pro"
		;;
	grok)
		echo "xai/grok-3"
		;;
	*)
		# Unknown tier — return as-is (may be a model name without provider)
		echo "$tier"
		;;
	esac

	return 0
}

#######################################
# Detect available AI CLI backends (t132.7, t1665.5)
# Returns a newline-separated list of available backend runtime IDs.
# Delegates to runtime-registry.sh rt_detect_installed().
#######################################
detect_ai_backends() {
	# Use runtime registry if loaded (t1665.5)
	if type rt_detect_installed &>/dev/null; then
		local installed
		installed=$(rt_detect_installed) || true
		if [[ -z "$installed" ]]; then
			echo "none"
			return 1
		fi
		echo "$installed"
		return 0
	fi

	# Fallback: hardcoded check (registry not loaded)
	local -a backends=()
	if command -v opencode &>/dev/null; then
		backends+=("opencode")
	fi
	if command -v claude &>/dev/null; then
		backends+=("claude")
	fi
	if [[ ${#backends[@]} -eq 0 ]]; then
		echo "none"
		return 1
	fi
	printf '%s\n' "${backends[@]}"
	return 0
}

# =============================================================================
# Model Pricing & Provider Detection (consolidated from t1337.2)
# =============================================================================
# Single source of truth: .agents/configs/model-pricing.json
# Also consumed by observability.mjs (OpenCode plugin).
# Pricing: per 1M tokens — input|output|cache_read|cache_write.
# Budget-tracker uses only input|output; observability uses all four.
#
# Falls back to hardcoded case statement if jq or the JSON file is unavailable.

# Cache for JSON-loaded pricing (avoids re-reading the file on every call)
_MODEL_PRICING_JSON=""
_MODEL_PRICING_JSON_LOADED=""

# Load model-pricing.json into the cache variable.
# Called once on first get_model_pricing() invocation.
_load_model_pricing_json() {
	_MODEL_PRICING_JSON_LOADED="attempted"
	local json_file
	# Try repo-relative path first (works in dev), then deployed path
	# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
	# in zsh (the MCP shell environment). See GH#4904.
	local script_dir="${BASH_SOURCE[0]:-${0:-}}"
	script_dir="${script_dir%/*}"
	for json_file in \
		"${script_dir}/../configs/model-pricing.json" \
		"${HOME}/.aidevops/agents/configs/model-pricing.json"; do
		if [[ -r "$json_file" ]] && command -v jq &>/dev/null; then
			_MODEL_PRICING_JSON=$(cat "$json_file" 2>/dev/null) || _MODEL_PRICING_JSON=""
			if [[ -n "$_MODEL_PRICING_JSON" ]]; then
				return 0
			fi
		fi
	done
	return 1
}

get_model_pricing() {
	local model="$1"

	# Try JSON source first (single source of truth)
	if [[ -z "$_MODEL_PRICING_JSON_LOADED" ]]; then
		_load_model_pricing_json
	fi

	if [[ -n "$_MODEL_PRICING_JSON" ]]; then
		local ms="${model#*/}"
		ms="${ms%%-202*}"
		ms=$(echo "$ms" | tr '[:upper:]' '[:lower:]')
		# Search for a matching key in the JSON models object
		local result
		result=$(echo "$_MODEL_PRICING_JSON" | jq -r --arg ms "$ms" '
			.models | to_entries[] |
			select(.key as $k | $ms | contains($k)) |
			"\(.value.input)|\(.value.output)|\(.value.cache_read)|\(.value.cache_write)"
		' 2>/dev/null | head -1)
		if [[ -n "$result" ]]; then
			echo "$result"
			return 0
		fi
		# No match — return default from JSON
		result=$(echo "$_MODEL_PRICING_JSON" | jq -r '
			"\(.default.input)|\(.default.output)|\(.default.cache_read)|\(.default.cache_write)"
		' 2>/dev/null)
		if [[ -n "$result" && "$result" != "null|null|null|null" ]]; then
			echo "$result"
			return 0
		fi
	fi

	# Hardcoded fallback (no jq or JSON file unavailable)
	local ms="${model#*/}"
	ms="${ms%%-202*}"
	case "$ms" in
	*opus-4* | *claude-opus*) echo "15.0|75.0|1.50|18.75" ;;
	*sonnet-4* | *claude-sonnet*) echo "3.0|15.0|0.30|3.75" ;;
	*haiku-4* | *haiku-3* | *claude-haiku*) echo "0.80|4.0|0.08|1.0" ;;
	*gpt-4.1-mini*) echo "0.40|1.60|0.10|0.40" ;;
	*gpt-4.1*) echo "2.0|8.0|0.50|2.0" ;;
	*o3*) echo "10.0|40.0|2.50|10.0" ;;
	*o4-mini*) echo "1.10|4.40|0.275|1.10" ;;
	*gemini-2.5-pro*) echo "1.25|10.0|0.3125|2.50" ;;
	*gemini-2.5-flash*) echo "0.15|0.60|0.0375|0.15" ;;
	*gemini-3-pro*) echo "1.25|10.0|0.3125|2.50" ;;
	*gemini-3-flash*) echo "0.10|0.40|0.025|0.10" ;;
	*deepseek-r1*) echo "0.55|2.19|0.14|0.55" ;;
	*deepseek-v3*) echo "0.27|1.10|0.07|0.27" ;;
	*) echo "3.0|15.0|0.30|3.75" ;;
	esac
	return 0
}

get_provider_from_model() {
	local model="$1"
	case "$model" in
	claude-* | anthropic/*) echo "anthropic" ;;
	gpt-* | openai/*) echo "openai" ;;
	gemini-* | google/*) echo "google" ;;
	deepseek-* | deepseek/*) echo "deepseek" ;;
	grok-* | xai/*) echo "xai" ;;
	*) echo "unknown" ;;
	esac
	return 0
}

# =============================================================================
# Configuration Loader (issue #2730 — JSONC config system)
# =============================================================================
# Loads user-configurable settings from JSONC config files:
#   1. Defaults file (shipped with aidevops, overwritten on update)
#      ~/.aidevops/agents/configs/aidevops.defaults.jsonc
#   2. User overrides (~/.config/aidevops/config.jsonc)
#   3. Environment variables (highest priority)
#
# Requires jq for JSONC parsing. Falls back to legacy .conf if jq unavailable.
#
# Scripts check config via:
#   config_get <dotpath> [default]       — get any config value
#   config_enabled <dotpath>             — check boolean config
#   get_feature_toggle <key> [default]   — backward-compatible (flat key)
#   is_feature_enabled <key>             — backward-compatible (flat key)

# Source config-helper.sh (provides _jsonc_get, config_get, config_enabled, etc.)
# IMPORTANT: source=/dev/null tells ShellCheck NOT to follow this source directive.
# Without it, ShellCheck follows the cycle shared-constants.sh → config-helper.sh →
# shared-constants.sh infinitely, consuming exponential memory (7-14 GB observed).
# The include guard (_SHARED_CONSTANTS_LOADED at line 14) prevents infinite recursion
# at execution time, but ShellCheck is a static analyzer and ignores runtime guards.
# GH#3981: https://github.com/marcusquinn/aidevops/issues/3981
# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh (the MCP shell environment). Without this guard, sourcing from zsh
# with set -u (nounset) fails with "BASH_SOURCE[0]: parameter not set". See GH#4904.
_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
_CONFIG_HELPER="${_SC_SELF%/*}/config-helper.sh"
if [[ -r "$_CONFIG_HELPER" ]]; then
	# shellcheck source=/dev/null
	source "$_CONFIG_HELPER"
fi

# Source runtime registry (t1665.1) — central data source for all AI CLI runtimes
_RUNTIME_REGISTRY="${_SC_SELF%/*}/runtime-registry.sh"
if [[ -r "$_RUNTIME_REGISTRY" ]]; then
	# shellcheck source=/dev/null
	source "$_RUNTIME_REGISTRY"
fi

# Legacy paths (kept for backward compatibility and migration)
FEATURE_TOGGLES_DEFAULTS="${HOME}/.aidevops/agents/configs/feature-toggles.conf.defaults"
FEATURE_TOGGLES_USER="${HOME}/.config/aidevops/feature-toggles.conf"

# Map from legacy toggle key to environment variable name.
# Used by both the new JSONC system and the legacy fallback.
_ft_env_map() {
	local key="$1"
	case "$key" in
	auto_update) echo "AIDEVOPS_AUTO_UPDATE" ;;
	update_interval) echo "AIDEVOPS_UPDATE_INTERVAL" ;;
	skill_auto_update) echo "AIDEVOPS_SKILL_AUTO_UPDATE" ;;
	skill_freshness_hours) echo "AIDEVOPS_SKILL_FRESHNESS_HOURS" ;;
	tool_auto_update) echo "AIDEVOPS_TOOL_AUTO_UPDATE" ;;
	tool_freshness_hours) echo "AIDEVOPS_TOOL_FRESHNESS_HOURS" ;;
	tool_idle_hours) echo "AIDEVOPS_TOOL_IDLE_HOURS" ;;
	supervisor_pulse) echo "AIDEVOPS_SUPERVISOR_PULSE" ;;
	repo_sync) echo "AIDEVOPS_REPO_SYNC" ;;
	repo_aidevops_health) echo "AIDEVOPS_REPO_HEALTH" ;;
	openclaw_auto_update) echo "AIDEVOPS_OPENCLAW_AUTO_UPDATE" ;;
	openclaw_freshness_hours) echo "AIDEVOPS_OPENCLAW_FRESHNESS_HOURS" ;;
	upstream_watch) echo "AIDEVOPS_UPSTREAM_WATCH" ;;
	upstream_watch_hours) echo "AIDEVOPS_UPSTREAM_WATCH_HOURS" ;;
	max_interactive_sessions) echo "AIDEVOPS_MAX_SESSIONS" ;;
	*) echo "" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Legacy fallback: load from .conf files when jq is not available
# ---------------------------------------------------------------------------
_load_feature_toggles_legacy() {
	if [[ -r "$FEATURE_TOGGLES_DEFAULTS" ]]; then
		local line key value
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ -z "$line" || "$line" == \#* ]] && continue
			key="${line%%=*}"
			value="${line#*=}"
			[[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
			printf -v "_FT_${key}" '%s' "$value"
		done <"$FEATURE_TOGGLES_DEFAULTS"
	fi

	if [[ -r "$FEATURE_TOGGLES_USER" ]]; then
		local line key value
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ -z "$line" || "$line" == \#* ]] && continue
			key="${line%%=*}"
			value="${line#*=}"
			[[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
			printf -v "_FT_${key}" '%s' "$value"
		done <"$FEATURE_TOGGLES_USER"
	fi

	local toggle_keys="auto_update update_interval skill_auto_update skill_freshness_hours tool_auto_update tool_freshness_hours tool_idle_hours supervisor_pulse repo_sync repo_aidevops_health openclaw_auto_update openclaw_freshness_hours upstream_watch upstream_watch_hours max_interactive_sessions manage_opencode_config manage_claude_config session_greeting safety_hooks shell_aliases onboarding_prompt"
	local tk env_var env_val
	for tk in $toggle_keys; do
		env_var=$(_ft_env_map "$tk")
		if [[ -n "$env_var" ]]; then
			env_val="${!env_var:-}"
			if [[ -n "$env_val" ]]; then
				printf -v "_FT_${tk}" '%s' "$env_val"
			fi
		fi
	done

	return 0
}

# ---------------------------------------------------------------------------
# Detect which config system to use and load accordingly
# ---------------------------------------------------------------------------
_AIDEVOPS_CONFIG_MODE=""

_load_config() {
	# Prefer JSONC if jq is available, defaults file exists, AND config-helper.sh
	# functions (config_get/config_enabled) are loaded. Without the functions,
	# having jq + defaults is not enough — callers would fail at runtime.
	local jsonc_defaults="${JSONC_DEFAULTS:-${HOME}/.aidevops/agents/configs/aidevops.defaults.jsonc}"
	if command -v jq &>/dev/null && [[ -r "$jsonc_defaults" ]] &&
		type config_get &>/dev/null && type config_enabled &>/dev/null; then
		_AIDEVOPS_CONFIG_MODE="jsonc"
		# config-helper.sh functions are already available via source above
		# Auto-migrate legacy .conf if it exists and no JSONC user config yet
		local jsonc_user="${JSONC_USER:-${HOME}/.config/aidevops/config.jsonc}"
		if [[ -f "$FEATURE_TOGGLES_USER" && ! -f "$jsonc_user" ]]; then
			if type _migrate_conf_to_jsonc &>/dev/null; then
				if ! _migrate_conf_to_jsonc; then
					echo "[WARN] Auto-migration from legacy config failed. Run 'aidevops config migrate' manually." >&2
				fi
			fi
		fi
	else
		_AIDEVOPS_CONFIG_MODE="legacy"
		_load_feature_toggles_legacy
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Backward-compatible API: get_feature_toggle / is_feature_enabled
# These accept flat legacy keys (e.g. "auto_update") and route to the
# appropriate backend (JSONC or legacy .conf).
# ---------------------------------------------------------------------------

# Get a feature toggle / config value.
# Usage: get_feature_toggle <key> [default]
# Accepts both legacy flat keys and new dotpath keys.
get_feature_toggle() {
	local key="$1"
	local default="${2:-}"

	if [[ "$_AIDEVOPS_CONFIG_MODE" == "jsonc" ]]; then
		# Map legacy key to dotpath if needed
		local dotpath
		if type _legacy_key_to_dotpath &>/dev/null; then
			dotpath=$(_legacy_key_to_dotpath "$key")
		else
			dotpath="$key"
		fi
		config_get "$dotpath" "$default"
	else
		# Legacy mode: read from _FT_* variables
		local var_name="_FT_${key}"
		local value="${!var_name:-}"
		if [[ -n "$value" ]]; then
			echo "$value"
		else
			echo "$default"
		fi
	fi
	return 0
}

# Check if a feature toggle / config boolean is enabled (true).
# Usage: if is_feature_enabled auto_update; then ...
is_feature_enabled() {
	local key="$1"

	if [[ "$_AIDEVOPS_CONFIG_MODE" == "jsonc" ]]; then
		local dotpath
		if type _legacy_key_to_dotpath &>/dev/null; then
			dotpath=$(_legacy_key_to_dotpath "$key")
		else
			dotpath="$key"
		fi
		config_enabled "$dotpath"
		return $?
	else
		local value
		value="$(get_feature_toggle "$key" "true")"
		local lower
		lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
		[[ "$lower" == "true" ]]
		return $?
	fi
}

# Load config immediately when shared-constants.sh is sourced
_load_config

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
