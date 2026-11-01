#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Cleanup Worktree Removal Library
# =============================================================================
# Stable entry point for pulse-cleanup.sh. Dependencies and configuration are
# provided by the pulse-wrapper orchestrator; sourcing this file only loads APIs.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED=1

# Keep the cleanup-specific directory: callers may use SCRIPT_DIR themselves.
if [[ -z "${_PULSE_CLEANUP_SCRIPT_DIR:-}" ]]; then
	_pulse_cleanup_worktree_removal_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pulse_cleanup_worktree_removal_path" == "${BASH_SOURCE[0]}" ]] && _pulse_cleanup_worktree_removal_path="."
	_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$_pulse_cleanup_worktree_removal_path" && pwd)"
	unset _pulse_cleanup_worktree_removal_path
fi

# Explicitly clearing the public guard has historically reloaded every function
# and reset library state (including fixture overrides). Keep that contract;
# ordinary repeated sourcing still returns at the public guard above.
unset _PULSE_CLEANUP_WORKTREE_REMOVAL_LIFECYCLE_LOADED \
	_PULSE_CLEANUP_WORKTREE_REMOVAL_CENTRAL_LOADED \
	_PULSE_CLEANUP_WORKTREE_REMOVAL_PROFILE_LOADED

# Lifecycle operations initialize the shared removal/archive constants first.
# shellcheck source=./pulse-cleanup-worktree-removal-lifecycle.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-lifecycle.sh"

# shellcheck source=./pulse-cleanup-worktree-removal-central.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-central.sh"

# shellcheck source=./pulse-cleanup-worktree-removal-profile.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-profile.sh"

# Temporary backlog pass; remove together with worker-legacy-cleanup.py.
# This consumes observation-era bindings, not legacy owner JSON or fake admissions.
_cleanup_observation_era_worktrees() {
	local state_dir="$1"
	local python="$2"
	local budget="$3"
	local result="" retired="" retained=""
	if ! result=$("$python" -E -s -B "${_PULSE_CLEANUP_SCRIPT_DIR}/../worker-lifecycle/worker-legacy-cleanup.py" \
		--state-dir "$state_dir" --repos-config "${HOME}/.config/aidevops/repos.json" \
		--output-root "${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}" \
		--apply --budget-seconds "$budget" 2>>"$LOGFILE"); then
		printf '[pulse-wrapper] Observation-era cleanup unavailable: %s\n' "$result" >>"$LOGFILE"
		return 0
	fi
	retired=$(jq -er '.retired | numbers' <<<"$result") || return 0
	retained=$(jq -c '[.results[] | select(.status == "retained")] | group_by(.reason) | map({reason: .[0].reason, count: length})' <<<"$result") || return 0
	CLEANUP_WORKTREES_REMOVED_COUNT="$retired"
	CLEANUP_WORKTREES_ARCHIVED_COUNT="$retired"
	# Only the admission pass may acknowledge completion of the scheduled run.
	printf '[pulse-wrapper] Observation-era cleanup: retired=%s retained=%s\n' "$retired" "$retained" >>"$LOGFILE"
	return 0
}

# Retain the public pass orchestrator here for source-location contract checks.
cleanup_worktrees() {
	local cleanup_budget="${1:-120}"
	local state_dir="" python="" result="" retired="" pass_budget=0
	CLEANUP_WORKTREES_SKIPPED=1
	CLEANUP_WORKTREES_REMOVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT=0
	[[ "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" != 1 ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	python=$(type -P python3) || return 0
	# shellcheck source=./worker-lifecycle-state.sh
	source "${_PULSE_CLEANUP_SCRIPT_DIR}/worker-lifecycle-state.sh" || return 0
	state_dir=$(worker_lifecycle_state_dir) || return 0
	[[ -n "$state_dir" && -d "$state_dir" ]] || return 0
	[[ "$cleanup_budget" =~ ^[0-9]+$ && "$cleanup_budget" -ge 2 ]] || return 0
	pass_budget=$((cleanup_budget / 2))
	_cleanup_observation_era_worktrees "$state_dir" "$python" "$pass_budget"
	# Neither pass initializes/migrates state or consults old owner files.
	# Each gets half the budget; the scheduler retains its hard watchdog.
	if ! result=$("$python" -E -s -B "${_PULSE_CLEANUP_SCRIPT_DIR}/../worker-lifecycle/worker-registry.py" \
		--state-dir "$state_dir" cleanup --repos-config "${HOME}/.config/aidevops/repos.json" \
		--output-root "${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}" \
		--budget-seconds "$pass_budget" 2>>"$LOGFILE"); then
		printf '[pulse-wrapper] Admission cleanup unavailable; backlog pass reported separately\n' >>"$LOGFILE"
		return 0
	fi
	retired=$(jq -er '.retired | numbers' <<<"$result") || return 0
	CLEANUP_WORKTREES_REMOVED_COUNT=$((CLEANUP_WORKTREES_REMOVED_COUNT + retired))
	CLEANUP_WORKTREES_ARCHIVED_COUNT="$CLEANUP_WORKTREES_REMOVED_COUNT"
	CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT=$(jq -er '.failed | numbers' <<<"$result") || return 0
	CLEANUP_WORKTREES_SKIPPED=0
	printf '[pulse-wrapper] Lifecycle cleanup: retired=%s failed=%s\n' \
		"$retired" "$CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT" >>"$LOGFILE"
	return 0
}
