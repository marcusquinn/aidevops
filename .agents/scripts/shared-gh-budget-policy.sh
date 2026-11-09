#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Pure reset-aware scheduling hints. Request admission owns actual quota spend.

# Optional pulse work must leave a fixed worker reserve, independently of the
# adaptive maintainer/progress floor. This is a scheduling hint, not admission.
gh_budget_worker_reserve_allows() {
	local remaining="${1:-${AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING:-}}"
	local limit="${2:-${AIDEVOPS_PULSE_REST_CORE_BUDGET_LIMIT:-}}"
	local percent="${AIDEVOPS_PULSE_WORKER_RESERVE_PERCENT:-20}"
	# Force base 10 so values like 08/09 are not parsed as invalid octal.
	[[ "$percent" =~ ^[0-9]{1,2}$ && "$((10#$percent))" -le 90 ]] || percent=20
	percent=$((10#$percent))
	# Standalone routines have no wrapper-exported snapshot; long review loops
	# can also outlive one. Reuse the authoritative short gate cache, not a new
	# per-page quota request or indefinitely stale inherited environment.
	if [[ "$#" -eq 0 ]] && declare -F pulse_rest_core_priority_snapshot >/dev/null 2>&1; then
		local snapshot="" mode="" rest=""
		snapshot=$(pulse_rest_core_priority_snapshot 15) || snapshot=""
		read -r mode remaining limit rest <<<"$snapshot"
		# Operator-disabled quota gating reports "?" values by design; that is
		# not missing evidence, so do not defer optional work on it.
		[[ "$mode" == "disabled" ]] && return 0
		if [[ ! "$remaining" =~ ^[0-9]{1,9}$ || ! "$limit" =~ ^[1-9][0-9]{0,8}$ ]]; then
			printf '[pulse-budget] Deferring optional REST work: quota evidence unavailable\n' >&2
			return 1
		fi
	fi
	# Unknown evidence is left to the existing fail-closed quota policy.
	[[ "$remaining" =~ ^[0-9]{1,9}$ && "$limit" =~ ^[1-9][0-9]{0,8}$ ]] || return 0
	if [[ "$remaining" -le "$(((limit * percent + 99) / 100))" ]]; then
		printf '[pulse-budget] Deferring optional REST work at worker reserve (%s/%s, reserve=%s%%)\n' "$remaining" "$limit" "$percent" >&2
		return 1
	fi
	return 0
}

gh_budget_window_threshold() {
	local cap="$1"
	local reset="$2"
	local now="${3:-}"
	local window="${4:-3600}"
	[[ "$cap" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$now" ]] || now=$(date +%s)
	# Missing evidence cannot invent a reset or restore quota. Preserve the
	# configured scheduling hint until a valid snapshot replaces it.
	if [[ ! "$reset" =~ ^[0-9]{1,10}$ || ! "$now" =~ ^[0-9]{1,10}$ || ! "$window" =~ ^[1-9][0-9]{0,5}$ ]]; then
		printf '%s\n' "$cap"
		return 0
	fi
	local left=$((reset - now))
	[[ "$left" -ge 0 ]] || left=0
	[[ "$left" -le "$window" ]] || left="$window"
	# Round down: a scheduling hint must not strand the final available point.
	printf '%s\n' "$((cap * left / window))"
	return 0
}
