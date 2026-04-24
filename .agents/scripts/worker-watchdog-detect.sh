#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Watchdog — Detection Functions
# =============================================================================
# Worker discovery and metadata extraction: finding headless worker processes,
# extracting issue numbers, repo slugs, and provider names from their command
# lines.
#
# Usage: source "${SCRIPT_DIR}/worker-watchdog-detect.sh"
#
# Dependencies:
#   - shared-constants.sh (sourced by orchestrator before this library)
#   - worker-lifecycle-common.sh (_get_process_age, _get_process_tree_cpu)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKER_WATCHDOG_DETECT_LOADED:-}" ]] && return 0
_WORKER_WATCHDOG_DETECT_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Worker Discovery
# =============================================================================

#######################################
# Find all headless worker processes
#
# Workers are identified by: processes matching WORKER_PROCESS_PATTERN
# running with /full-loop in their command line (headless dispatch pattern).
#
# Output: one line per worker: "PID|ELAPSED_SECS|COMMAND"
#######################################
find_workers() {
	# Match worker processes with /full-loop (headless workers)
	# Build grep pattern: bracket-trick on first char excludes grep from results
	local pattern_char="${WORKER_PROCESS_PATTERN:0:1}"
	local pattern_rest="${WORKER_PROCESS_PATTERN:1}"
	local grep_pattern="[${pattern_char}]${pattern_rest}"
	local line pid cmd elapsed_seconds

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Skip watchdog processes
		[[ "$line" == *"worker-watchdog"* ]] && continue

		# Extract PID (first field) and command (rest of line)
		pid="${line%%[[:space:]]*}"
		cmd="${line#*[[:space:]]}"
		[[ -z "$pid" ]] && continue
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ -z "$cmd" ]] && continue

		# Get elapsed time
		elapsed_seconds=$(_get_process_age "$pid")

		# Output: PID|ELAPSED|COMMAND
		echo "${pid}|${elapsed_seconds}|${cmd}"
	done < <(ps axwwo pid,command | grep "$grep_pattern" | grep '/full-loop' || true)

	return 0
}

# =============================================================================
# Metadata Extraction
# =============================================================================

#######################################
# Extract issue number from worker command line
#
# Workers are dispatched with commands like:
#   opencode run --title "Issue #42: Fix auth" "/full-loop Implement issue #42 ..."
#
# Arguments:
#   $1 - command line string
# Output: issue number or empty string
#######################################
extract_issue_number() {
	local cmd="$1"

	# Try patterns: "Issue #NNN", "issue #NNN", "#NNN:", "GH#NNN"
	if [[ "$cmd" =~ [Ii]ssue[[:space:]]+#([0-9]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$cmd" =~ GH#([0-9]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$cmd" =~ \#([0-9]+): ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo ""
	fi
	return 0
}

#######################################
# Extract repo slug from worker command line
#
# Workers are dispatched with --dir pointing to a worktree.
# We resolve the repo slug from the git remote.
#
# Arguments:
#   $1 - command line string
# Output: owner/repo slug or empty string
#######################################
extract_repo_slug() {
	local cmd="$1"

	# Extract --dir from command line
	local worktree_dir=""
	if [[ "$cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
		worktree_dir="${BASH_REMATCH[1]}"
	fi

	if [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]]; then
		echo ""
		return 0
	fi

	# Get remote URL and extract slug
	local remote_url
	remote_url=$(git -C "$worktree_dir" remote get-url origin) || true

	if [[ -z "$remote_url" ]]; then
		echo ""
		return 0
	fi

	# Parse slug from SSH or HTTPS URL
	local slug=""
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
		slug="${BASH_REMATCH[1]}"
		# Remove .git suffix if present
		slug="${slug%.git}"
	fi

	echo "$slug"
	return 0
}

#######################################
# Extract provider name from worker command line
#
# Workers are dispatched with a model like "anthropic/claude-sonnet-4-6".
# The provider is the prefix before the first slash.
#
# Arguments:
#   $1 - command line string
# Output: provider name (e.g., "anthropic") or empty string
#######################################
extract_provider_from_cmd() {
	local cmd="$1"
	local model=""

	# Try --model flag first
	if [[ "$cmd" =~ --model[[:space:]]+([^[:space:]]+) ]]; then
		model="${BASH_REMATCH[1]}"
	fi

	# Legacy fallback: AIDEVOPS_HEADLESS_MODELS env var embedded in command
	# (deprecated GH#17769 — kept for backward compat with in-flight workers)
	if [[ -z "$model" && "$cmd" =~ AIDEVOPS_HEADLESS_MODELS=([^[:space:]]+) ]]; then
		model="${BASH_REMATCH[1]}"
		# Take first model if comma-separated list
		model="${model%%,*}"
	fi

	if [[ -z "$model" ]]; then
		echo ""
		return 0
	fi

	# Extract provider prefix (before first slash)
	local provider="${model%%/*}"
	echo "$provider"
	return 0
}
