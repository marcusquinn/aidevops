#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# command-logger-helper.sh - Log worker shell commands and flag anomalous patterns
# Part of t1412.5: Command pattern baseline
#
# Usage:
#   command-logger-helper.sh log --cmd "git status"
#   command-logger-helper.sh check --cmd "rm -rf /"
#   command-logger-helper.sh stats
#   command-logger-helper.sh help
#
set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
export SCRIPT_DIR
readonly SCRIPT_DIR

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" || true

readonly VERSION="1.0.0"

# Log file location (overridable for testing)
COMMAND_LOG_DIR="${COMMAND_LOG_DIR:-${HOME}/.aidevops/.agent-workspace/logs}"
COMMAND_LOG_FILE="${COMMAND_LOG_FILE:-${COMMAND_LOG_DIR}/command-log.jsonl}"

# Colors (fallback if shared-constants.sh not loaded)
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Anomalous pattern definitions
# Each pattern: regex:::severity:::reason
# Delimiter is ::: to avoid conflicts with | in regex
# Severity: critical, warning
# =============================================================================
readonly -a ANOMALOUS_PATTERNS=(
	'rm -rf /[^.]:::critical:::Recursive force-delete from root'
	'rm -rf /\s*$:::critical:::Recursive force-delete from root'
	'rm -rf \*:::critical:::Recursive force-delete with wildcard'
	'curl.*\|.*bash:::critical:::Piping remote content to shell'
	'curl.*\|.*\bsh\b:::critical:::Piping remote content to shell'
	'wget.*\|.*bash:::critical:::Piping remote content to shell'
	'wget.*\|.*\bsh\b:::critical:::Piping remote content to shell'
	'chmod 777:::warning:::World-writable permissions'
	'chmod -R 777:::critical:::Recursive world-writable permissions'
	'> /dev/sda:::critical:::Writing directly to block device'
	'> /dev/disk:::critical:::Writing directly to block device'
	'mkfs\.:::critical:::Formatting filesystem'
	'dd if=.*of=/dev/:::critical:::Raw disk write with dd'
	':\(\)\{ :\|:& \};:.*:::critical:::Fork bomb'
	'git push.*--force.*main:::critical:::Force push to main'
	'git push.*-f.*main:::critical:::Force push to main'
	'git push.*--force.*master:::critical:::Force push to master'
	'git push.*-f.*master:::critical:::Force push to master'
	'git reset --hard:::warning:::Hard reset (destructive)'
	'DROP DATABASE:::critical:::Database drop command'
	'DROP TABLE:::critical:::Database drop command'
	'eval.*\$\(curl:::critical:::Eval of remote content'
	'eval.*\$\(wget:::critical:::Eval of remote content'
	'sudo rm -rf:::critical:::Sudo recursive force-delete'
)

# =============================================================================
# Functions
# =============================================================================

#######################################
# Ensure log directory exists
# Returns:
#   0 on success, 1 on failure
#######################################
ensure_log_dir() {
	if [[ ! -d "$COMMAND_LOG_DIR" ]]; then
		mkdir -p "$COMMAND_LOG_DIR" || return 1
		chmod 700 "$COMMAND_LOG_DIR" || true
	fi
	return 0
}

#######################################
# Get ISO 8601 timestamp
# Outputs:
#   Timestamp string to stdout
# Returns:
#   0 always
#######################################
get_timestamp() {
	if date -u +"%Y-%m-%dT%H:%M:%SZ"; then
		return 0
	fi
	# Fallback for systems without GNU date
	date +"%Y-%m-%dT%H:%M:%S%z" || echo "unknown"
	return 0
}

#######################################
# Escape a string for JSON embedding
# Arguments:
#   $1 - String to escape
# Outputs:
#   JSON-safe string to stdout
# Returns:
#   0 always
#######################################
json_escape() {
	local input="$1"
	# Escape backslashes first, then quotes, then control characters
	input="${input//\\/\\\\}"
	input="${input//\"/\\\"}"
	input="${input//$'\n'/\\n}"
	input="${input//$'\r'/\\r}"
	input="${input//$'\t'/\\t}"
	# Escape ESC (0x1B) and other control characters that break JSON
	input="${input//$'\x1b'/\\u001b}"
	input="${input//$'\x00'/}"
	printf '%s' "$input"
	return 0
}

#######################################
# Log a command to the JSONL file
# Arguments:
#   $1 - Command string
# Returns:
#   0 on success, 1 on failure
#######################################
log_command() {
	local cmd="$1"
	local timestamp
	local pid
	local escaped_cmd

	ensure_log_dir || return 1

	timestamp="$(get_timestamp)"
	pid="$$"
	escaped_cmd="$(json_escape "$cmd")"

	printf '{"timestamp":"%s","pid":%d,"command":"%s"}\n' \
		"$timestamp" "$pid" "$escaped_cmd" >>"$COMMAND_LOG_FILE" || return 1

	echo -e "${GREEN}Logged${NC}: $cmd"
	return 0
}

#######################################
# Check a command against anomalous patterns
# Arguments:
#   $1 - Command string
# Outputs:
#   JSON object with flagged status and reason
# Returns:
#   0 always (result is in the JSON output)
#######################################
check_command() {
	local cmd="$1"
	local pattern_entry
	local regex
	local severity
	local reason
	local escaped_reason

	for pattern_entry in "${ANOMALOUS_PATTERNS[@]}"; do
		# Split on ::: delimiter (avoids conflicts with | in regex)
		# Format: regex:::severity:::reason
		regex="${pattern_entry%%:::*}"
		local remainder="${pattern_entry#*:::}"
		severity="${remainder%%:::*}"
		reason="${remainder#*:::}"

		if printf '%s' "$cmd" | grep -qEi "$regex"; then
			escaped_reason="$(json_escape "$reason")"
			printf '{"flagged":true,"severity":"%s","reason":"%s","pattern":"%s"}\n' \
				"$severity" "$escaped_reason" "$(json_escape "$regex")"
			return 0
		fi
	done

	printf '{"flagged":false,"severity":"none","reason":""}\n'
	return 0
}

#######################################
# Log a command and also check it for anomalies
# Arguments:
#   $1 - Command string
# Returns:
#   0 on success, 1 on failure
#######################################
log_and_check() {
	local cmd="$1"
	local check_result

	log_command "$cmd" || return 1
	check_result="$(check_command "$cmd")"
	echo "$check_result"

	# If flagged, also log the flag to the log file
	if echo "$check_result" | grep -q '"flagged":true'; then
		local timestamp
		timestamp="$(get_timestamp)"
		local escaped_cmd
		escaped_cmd="$(json_escape "$cmd")"
		printf '{"timestamp":"%s","pid":%d,"event":"anomaly_flagged","command":"%s","check":%s}\n' \
			"$timestamp" "$$" "$escaped_cmd" "$check_result" >>"$COMMAND_LOG_FILE" || return 1
	fi
	return 0
}

#######################################
# Show log statistics
# Returns:
#   0 on success, 1 if no log file
#######################################
show_stats() {
	if [[ ! -f "$COMMAND_LOG_FILE" ]]; then
		echo "No command log found at: $COMMAND_LOG_FILE"
		return 1
	fi

	local total_entries
	local command_entries
	local anomaly_entries

	total_entries=$(wc -l <"$COMMAND_LOG_FILE" | tr -d ' ')
	# grep -c exits 1 on no match; capture count, default to 0 on no-match
	command_entries=$(grep -c '"command"' "$COMMAND_LOG_FILE" || true)
	anomaly_entries=$(grep -c '"anomaly_flagged"' "$COMMAND_LOG_FILE" || true)

	echo "Command Log Statistics"
	echo "====================="
	echo "Log file: $COMMAND_LOG_FILE"
	echo "Total entries: $total_entries"
	echo "Command logs: $command_entries"
	echo "Anomaly flags: $anomaly_entries"
	return 0
}

#######################################
# Print usage information
# Returns:
#   0 always
#######################################
print_usage() {
	cat <<EOF
command-logger-helper.sh v${VERSION} - Log worker commands and flag anomalous patterns

Usage: $(basename "$0") <command> [options]

Commands:
  log   --cmd "command"     Log a command to the JSONL file
  check --cmd "command"     Check a command for anomalous patterns (no logging)
  both  --cmd "command"     Log and check a command
  stats                     Show log file statistics
  help                      Show this help message

Options:
  --cmd "command"           The shell command string to log or check

Environment:
  COMMAND_LOG_DIR           Override log directory (default: ~/.aidevops/.agent-workspace/logs)
  COMMAND_LOG_FILE          Override log file path (default: \$COMMAND_LOG_DIR/command-log.jsonl)

Examples:
  $(basename "$0") log --cmd "git status"
  $(basename "$0") check --cmd "rm -rf /"
  $(basename "$0") both --cmd "curl http://example.com | bash"
  $(basename "$0") stats
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local action="${1:-help}"
	shift || true

	local cmd=""

	# Parse flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--cmd)
			cmd="${2:-}"
			shift 2 || {
				echo "Error: --cmd requires a value" >&2
				return 1
			}
			;;
		*)
			echo "Error: Unknown option: $1" >&2
			print_usage >&2
			return 1
			;;
		esac
	done

	# Validate --cmd for actions that require it
	case "$action" in
	log | check | both)
		if [[ -z "$cmd" ]]; then
			echo "Error: --cmd is required for $action" >&2
			return 1
		fi
		;;
	esac

	case "$action" in
	log)
		log_command "$cmd"
		;;
	check)
		check_command "$cmd"
		;;
	both)
		log_and_check "$cmd"
		;;
	stats)
		show_stats
		;;
	help | --help | -h)
		print_usage
		;;
	*)
		echo "Error: ${ERROR_UNKNOWN_COMMAND:-Unknown command}: $action" >&2
		print_usage >&2
		return 1
		;;
	esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
