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
# The *_CAPACITY_* values above are effective: the lower of df and quota
# headroom. These keep the raw df numbers for the filesystem thresholds.
AIDEVOPS_DISK_FILESYSTEM_TOTAL_KB=0
AIDEVOPS_DISK_FILESYSTEM_AVAILABLE_KB=0
# filesystem: df headroom is binding; quota: account quota headroom is lower.
AIDEVOPS_DISK_CAPACITY_SOURCE="filesystem"
# GH#37922: disabled | unsupported | unavailable | none | limited | exhausted.
# Only "exhausted" and "limited" are positive evidence; the other states never
# block admission on their own, so hosts without quotas keep the df policy.
_aidevops_disk_quota_reset() {
	AIDEVOPS_DISK_QUOTA_STATE="unavailable"
	AIDEVOPS_DISK_QUOTA_HEADROOM_KB=0
	AIDEVOPS_DISK_QUOTA_LIMIT_KB=0
	return 0
}
_aidevops_disk_quota_reset

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

# GH#37922: account quotas can be exhausted while df still reports free space.
# Read the Linux quota-tools report for the mount point (user and group, raw
# 1 KiB blocks, unwrapped rows, raw grace epochs) under a bounded timeout.
# Sets AIDEVOPS_DISK_QUOTA_* and always returns 0: missing tooling, timeouts
# and unparseable or quota-disabled reports are recorded as unsupported or
# unavailable evidence, never as exhaustion. Output paths are never retained.
aidevops_disk_quota_snapshot() {
	local mount_point="$1"
	local quota_cmd="${AIDEVOPS_DISK_QUOTA_COMMAND:-quota}"
	local timeout_seconds="${AIDEVOPS_DISK_QUOTA_TIMEOUT_SECONDS:-5}"
	local timeout_cmd="" report="" quota_rc=0 parsed="" state="" headroom="" limit="" now=""

	_aidevops_disk_quota_reset
	if [[ "${AIDEVOPS_DISK_QUOTA_CHECK:-1}" == "0" ]]; then
		AIDEVOPS_DISK_QUOTA_STATE="disabled"
		return 0
	fi
	if ! command -v "$quota_cmd" >/dev/null 2>&1; then
		AIDEVOPS_DISK_QUOTA_STATE="unsupported"
		return 0
	fi
	[[ -n "$mount_point" ]] || return 0
	[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=5
	# Remote quota lookups can hang; an unbounded probe would stall admission.
	timeout_cmd=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null) || return 0
	now=$(date +%s 2>/dev/null) || now=""
	[[ "$now" =~ ^[0-9]+$ ]] || return 0
	# quota exits non-zero when a limit is exceeded, so parse rows regardless.
	report=$("$timeout_cmd" "$timeout_seconds" "$quota_cmd" -w -p -u -g -f "$mount_point" 2>/dev/null) || quota_rc=$?
	parsed=$(printf '%s\n' "$report" | awk -v now="$now" '
		function n(v) { sub(/\*$/, "", v); return v }
		function over(used, soft, hard, grace) {
			if (hard > 0 && used >= hard) return 1
			return soft > 0 && used > soft && grace > 0 && grace <= now
		}
		NF >= 9 {
			ok = 1
			for (i = NF - 7; i <= NF; i++) { v[i - NF + 7] = n($i); if (v[i - NF + 7] !~ /^[0-9]+$/) ok = 0 }
			if (!ok) next
			rows++
			if (over(v[0] + 0, v[1] + 0, v[2] + 0, v[3] + 0) || over(v[4] + 0, v[5] + 0, v[6] + 0, v[7] + 0)) exhausted = 1
			lim = ((v[2] + 0) > 0) ? v[2] + 0 : v[1] + 0
			if (lim > 0) {
				room = lim - v[0]
				if (room < 0) room = 0
				if (best_lim == 0 || room < best) { best = room; best_lim = lim }
			}
		}
		END {
			if (exhausted) print "exhausted", 0, best_lim + 0
			else if (best_lim > 0) print "limited", best + 0, best_lim
			else if (rows > 0) print "none", 0, 0
			else print "empty", 0, 0
		}') || return 0
	read -r state headroom limit <<<"$parsed"
	[[ "$headroom" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || return 0
	case "$state" in
	exhausted | limited | none) ;;
	empty)
		# A successful report without limit rows means no quota applies; a
		# failed, timed-out or quota-disabled report stays unavailable.
		[[ "$quota_rc" -eq 0 ]] || return 0
		state="none"
		;;
	*) return 0 ;;
	esac
	AIDEVOPS_DISK_QUOTA_STATE="$state"
	AIDEVOPS_DISK_QUOTA_HEADROOM_KB="$headroom"
	AIDEVOPS_DISK_QUOTA_LIMIT_KB="$limit"
	return 0
}

aidevops_disk_capacity_snapshot() {
	local target_path="${1:-${HOME:-/}}"
	local capacity_line=""
	local total_kb=""
	local available_kb=""
	local mount_point=""

	AIDEVOPS_DISK_CAPACITY_TOTAL_KB=0
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=0
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
	AIDEVOPS_DISK_CAPACITY_PROBE_PATH=""
	AIDEVOPS_DISK_CAPACITY_REASON="unknown"
	AIDEVOPS_DISK_FILESYSTEM_TOTAL_KB=0
	AIDEVOPS_DISK_FILESYSTEM_AVAILABLE_KB=0
	AIDEVOPS_DISK_CAPACITY_SOURCE="filesystem"
	_aidevops_disk_quota_reset

	AIDEVOPS_DISK_CAPACITY_PROBE_PATH=$(aidevops_disk_capacity_existing_path "$target_path") || return 1
	capacity_line=$(df -Pk "$AIDEVOPS_DISK_CAPACITY_PROBE_PATH" 2>/dev/null | awk 'NR == 2 { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print $2, $4, m; exit }') || return 1
	read -r total_kb available_kb mount_point <<<"$capacity_line"
	[[ "$total_kb" =~ ^[0-9]+$ && "$available_kb" =~ ^[0-9]+$ && "$total_kb" -gt 0 ]] || return 1
	AIDEVOPS_DISK_FILESYSTEM_TOTAL_KB="$total_kb"
	AIDEVOPS_DISK_FILESYSTEM_AVAILABLE_KB="$available_kb"

	aidevops_disk_quota_snapshot "$mount_point"
	if [[ "$AIDEVOPS_DISK_QUOTA_STATE" == exhausted ]]; then
		AIDEVOPS_DISK_CAPACITY_SOURCE="quota"
		available_kb=0
		if [[ "$AIDEVOPS_DISK_QUOTA_LIMIT_KB" -gt 0 ]]; then
			total_kb="$AIDEVOPS_DISK_QUOTA_LIMIT_KB"
		fi
	elif [[ "$AIDEVOPS_DISK_QUOTA_STATE" == limited && "$AIDEVOPS_DISK_QUOTA_HEADROOM_KB" -lt "$available_kb" ]]; then
		# The account can write no more than its quota headroom on this mount.
		AIDEVOPS_DISK_CAPACITY_SOURCE="quota"
		available_kb="$AIDEVOPS_DISK_QUOTA_HEADROOM_KB"
		total_kb="$AIDEVOPS_DISK_QUOTA_LIMIT_KB"
	fi

	AIDEVOPS_DISK_CAPACITY_TOTAL_KB="$total_kb"
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB="$available_kb"
	AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=$(((available_kb * 100) / total_kb))
	AIDEVOPS_DISK_CAPACITY_REASON="available"
	return 0
}

# Return 0 when a new worktree may be created, 1 when a threshold blocks it,
# and 2 when capacity cannot be established. Callers fail closed on 1 or 2.
# GH#37922: a positively exhausted quota blocks first; a binding quota adds
# only the absolute floor ("quota-below-minimum-kb"). The percentage floor
# protects the shared filesystem, so it stays on the raw df numbers.
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
	if [[ "$AIDEVOPS_DISK_QUOTA_STATE" == exhausted ]]; then
		AIDEVOPS_DISK_CAPACITY_REASON="quota-exhausted"
		return 1
	fi
	if [[ "$AIDEVOPS_DISK_FILESYSTEM_AVAILABLE_KB" -lt "$minimum_kb" ]]; then
		AIDEVOPS_DISK_CAPACITY_REASON="below-minimum-kb"
		return 1
	fi
	if [[ $((AIDEVOPS_DISK_FILESYSTEM_AVAILABLE_KB * 100)) -lt $((AIDEVOPS_DISK_FILESYSTEM_TOTAL_KB * minimum_percent)) ]]; then
		AIDEVOPS_DISK_CAPACITY_REASON="below-minimum-percent"
		return 1
	fi
	if [[ "$AIDEVOPS_DISK_CAPACITY_SOURCE" == quota && "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" -lt "$minimum_kb" ]]; then
		AIDEVOPS_DISK_CAPACITY_REASON="quota-below-minimum-kb"
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
