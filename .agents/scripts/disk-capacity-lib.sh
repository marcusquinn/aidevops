#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared filesystem-capacity checks for worktree creation and dispatch.

[[ -n "${_AIDEVOPS_DISK_CAPACITY_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_DISK_CAPACITY_LIB_LOADED=1

AIDEVOPS_DISK_CAPACITY_TOTAL_KB=0
AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=0
AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
AIDEVOPS_DISK_CAPACITY_PROBE_PATH=""
AIDEVOPS_DISK_CAPACITY_REASON="unknown"

aidevops_disk_capacity_existing_path() {
	local candidate="${1:-${HOME:-/}}"
	[[ -n "$candidate" ]] || candidate="/"
	while [[ ! -e "$candidate" ]]; do
		local parent=""
		parent=$(dirname "$candidate") || return 1
		[[ -n "$parent" && "$parent" != "$candidate" ]] || return 1
		candidate="$parent"
	done
	printf '%s\n' "$candidate"
	return 0
}

aidevops_disk_capacity_snapshot() {
	local target_path="${1:-${HOME:-/}}"
	local capacity_line=""
	local total_kb=""
	local available_kb=""

	AIDEVOPS_DISK_CAPACITY_TOTAL_KB=0
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=0
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
	AIDEVOPS_DISK_CAPACITY_PROBE_PATH=""
	AIDEVOPS_DISK_CAPACITY_REASON="unknown"

	AIDEVOPS_DISK_CAPACITY_PROBE_PATH=$(aidevops_disk_capacity_existing_path "$target_path") || return 1
	capacity_line=$(df -Pk "$AIDEVOPS_DISK_CAPACITY_PROBE_PATH" 2>/dev/null | awk 'NR == 2 { print $2, $4; exit }') || return 1
	read -r total_kb available_kb <<<"$capacity_line"
	[[ "$total_kb" =~ ^[0-9]+$ && "$available_kb" =~ ^[0-9]+$ && "$total_kb" -gt 0 ]] || return 1

	AIDEVOPS_DISK_CAPACITY_TOTAL_KB="$total_kb"
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB="$available_kb"
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=$(((available_kb * 100) / total_kb))
	AIDEVOPS_DISK_CAPACITY_REASON="available"
	return 0
}

# Return 0 when a new worktree may be created, 1 when a threshold blocks it,
# and 2 when capacity cannot be established. Callers fail closed on 1 or 2.
aidevops_worktree_capacity_check() {
	local target_path="${1:-${HOME:-/}}"
	local minimum_kb="${AIDEVOPS_MIN_WORKTREE_FREE_KB:-5242880}"
	local minimum_percent="${AIDEVOPS_MIN_WORKTREE_FREE_PERCENT:-5}"

	[[ "$minimum_kb" =~ ^[0-9]+$ ]] || minimum_kb=5242880
	[[ "$minimum_percent" =~ ^[0-9]+$ && "$minimum_percent" -le 100 ]] || minimum_percent=5
	if ! aidevops_disk_capacity_snapshot "$target_path"; then
		AIDEVOPS_DISK_CAPACITY_REASON="capacity-unknown"
		return 2
	fi
	if [[ "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" -lt "$minimum_kb" ]]; then
		AIDEVOPS_DISK_CAPACITY_REASON="below-minimum-kb"
		return 1
	fi
	if [[ $((AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB * 100)) -lt $((AIDEVOPS_DISK_CAPACITY_TOTAL_KB * minimum_percent)) ]]; then
		AIDEVOPS_DISK_CAPACITY_REASON="below-minimum-percent"
		return 1
	fi
	AIDEVOPS_DISK_CAPACITY_REASON="available"
	return 0
}

# Evaluate the successful capacity snapshot without another filesystem probe.
aidevops_worktree_cleanup_headroom_low() {
	local minimum_kb="${AIDEVOPS_MIN_WORKTREE_FREE_KB:-5242880}"
	local cleanup_kb="${AIDEVOPS_WORKTREE_CLEANUP_FREE_KB:-}"
	local cleanup_percent="${AIDEVOPS_WORKTREE_CLEANUP_FREE_PERCENT:-15}"
	[[ "$minimum_kb" =~ ^[0-9]+$ ]] || minimum_kb=5242880
	[[ "$cleanup_kb" =~ ^[0-9]+$ ]] || cleanup_kb=$((minimum_kb * 4))
	[[ "$cleanup_percent" =~ ^[0-9]+$ && "$cleanup_percent" -le 100 ]] || cleanup_percent=15
	[[ "$AIDEVOPS_DISK_CAPACITY_REASON" == available ]] || return 1
	[[ "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" -lt "$cleanup_kb" ]] && return 0
	[[ $((AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB * 100)) -lt $((AIDEVOPS_DISK_CAPACITY_TOTAL_KB * cleanup_percent)) ]] && return 0
	return 1
}

# Per-repo registered-worktree admission cap. Disk thresholds above are the
# resource guard; this count cap is only a runaway backstop. GH#18987 used 200
# as an illustrative value, which throttled real work while merged worktrees
# waited for cleanup. Prefer cleanup over lowering this value.
AIDEVOPS_DEFAULT_MAX_WORKTREES=1000
AIDEVOPS_DEFAULT_WORKTREE_CLEANUP_THRESHOLD=150

aidevops_worktree_count_cap() {
	local cap="${AIDEVOPS_MAX_WORKTREES:-$AIDEVOPS_DEFAULT_MAX_WORKTREES}"
	[[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap="$AIDEVOPS_DEFAULT_MAX_WORKTREES"
	printf '%s\n' "$cap"
	return 0
}

# Count at which pressure cleanup starts: the lower of 80% of the cap and an
# absolute threshold, so raising the cap never delays redundant-tree cleanup.
aidevops_worktree_cleanup_threshold() {
	local cap="${1:-}"
	local threshold="${AIDEVOPS_WORKTREE_CLEANUP_THRESHOLD:-$AIDEVOPS_DEFAULT_WORKTREE_CLEANUP_THRESHOLD}"
	local proportional=0
	[[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=$(aidevops_worktree_count_cap)
	[[ "$threshold" =~ ^[1-9][0-9]*$ ]] || threshold="$AIDEVOPS_DEFAULT_WORKTREE_CLEANUP_THRESHOLD"
	proportional=$(((cap * 80 + 99) / 100))
	[[ "$proportional" -ge "$threshold" ]] || threshold="$proportional"
	printf '%s\n' "$threshold"
	return 0
}
