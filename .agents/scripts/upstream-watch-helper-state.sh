#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Upstream Watch State Management -- Logging, prerequisites, state/config I/O
# =============================================================================
# Sub-library for upstream-watch-helper.sh. Contains all state and config file
# management, logging, prerequisite checks, and ISO timestamp helpers.
#
# Usage: source "${SCRIPT_DIR}/upstream-watch-helper-state.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - Expects LOGFILE, STATE_FILE, CONFIG_FILE globals set by orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_UPSTREAM_WATCH_STATE_LIB_LOADED:-}" ]] && return 0
_UPSTREAM_WATCH_STATE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Logging (standalone -- shared-constants.sh log_* may not be available)
# =============================================================================

#######################################
# Write a timestamped log entry to the upstream-watch log file
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $@ - Log message
#######################################
_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local log_dir
	log_dir=$(dirname "$LOGFILE")
	mkdir -p "$log_dir" 2>/dev/null || true
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

#######################################
# Log an informational message
#######################################
_log_info() {
	_log "INFO" "$@"
	return 0
}

#######################################
# Log a warning message
#######################################
_log_warn() {
	_log "WARN" "$@"
	return 0
}

#######################################
# Log an error message
#######################################
_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

#######################################
# Verify required tools (gh, jq) are installed and gh is authenticated
# Returns: 0 if all prerequisites met, 1 otherwise
#######################################
_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com/${NC}" >&2
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}" >&2
		return 1
	fi
	if ! gh auth status &>/dev/null; then
		echo -e "${RED}Error: gh not authenticated. Run: gh auth login${NC}" >&2
		return 1
	fi
	return 0
}

# =============================================================================
# State file management
# =============================================================================

#######################################
# Create the state file with empty defaults if it doesn't exist
#######################################
_ensure_state_file() {
	local state_dir
	state_dir=$(dirname "$STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true

	if [[ ! -f "$STATE_FILE" ]]; then
		echo '{"last_check":"","repos":{},"non_github":{}}' >"$STATE_FILE"
		_log_info "Created new state file: $STATE_FILE"
	fi
	# Migrate existing state files that lack the non_github key
	if ! jq -e '.non_github' "$STATE_FILE" >/dev/null 2>&1; then
		local migrated
		migrated=$(jq '. + {non_github: {}}' "$STATE_FILE")
		echo "$migrated" >"$STATE_FILE"
	fi
	return 0
}

#######################################
# Read and output the current state JSON
#######################################
_read_state() {
	_ensure_state_file
	cat "$STATE_FILE"
	return 0
}

#######################################
# Write state JSON to the state file, validating JSON first
# Arguments:
#   $1 - JSON string to write
#######################################
_write_state() {
	local state="$1"
	_ensure_state_file
	local jq_err
	jq_err=$(echo "$state" | jq '.' 2>&1 >"$STATE_FILE") || {
		_log_error "Failed to write state file (invalid JSON): ${jq_err}"
		return 1
	}
	return 0
}

# =============================================================================
# Config file management
# =============================================================================

#######################################
# Create the config file with empty defaults if it doesn't exist
#######################################
_ensure_config_file() {
	local config_dir
	config_dir=$(dirname "$CONFIG_FILE")
	mkdir -p "$config_dir" 2>/dev/null || true

	if [[ ! -f "$CONFIG_FILE" ]]; then
		cat >"$CONFIG_FILE" <<'DEFAULTCONFIG'
{
  "$comment": "Upstream repos to watch for releases and significant changes. Managed by upstream-watch-helper.sh.",
  "repos": []
}
DEFAULTCONFIG
		_log_info "Created new config file: $CONFIG_FILE"
	fi
	return 0
}

#######################################
# Read and output the current config JSON
#######################################
_read_config() {
	_ensure_config_file
	cat "$CONFIG_FILE"
	return 0
}

#######################################
# Write config JSON to the config file, validating JSON first
# Arguments:
#   $1 - JSON string to write
#######################################
_write_config() {
	local config="$1"
	_ensure_config_file
	local jq_err
	jq_err=$(echo "$config" | jq '.' 2>&1 >"$CONFIG_FILE") || {
		_log_error "Failed to write config file (invalid JSON): ${jq_err}"
		return 1
	}
	return 0
}

# =============================================================================
# ISO 8601 helpers
# =============================================================================

#######################################
# Output the current UTC time in ISO 8601 format
#######################################
_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}
