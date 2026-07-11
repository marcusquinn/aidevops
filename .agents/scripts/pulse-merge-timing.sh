#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-timing.sh — Low-overhead deterministic merge timing helpers
# =============================================================================
# Provides integer-second timing aggregation for pulse-merge-process.sh.
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-timing.sh"
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_TIMING_LOADED:-}" ]] && return 0
_PULSE_MERGE_TIMING_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pmp_timing_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pmp_timing_path" == "${BASH_SOURCE[0]}" ]] && _pmp_timing_path="."
	SCRIPT_DIR="$(cd "$_pmp_timing_path" && pwd)"
	unset _pmp_timing_path
fi

_pmp_now_epoch() {
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null || printf '0')
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	printf '%s' "$now_epoch"
	return 0
}

_pmp_add_elapsed_seconds() {
	local dest_var="$1"
	local start_epoch="${2:-0}"
	local current_value="" end_epoch elapsed

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=0

	end_epoch=$(_pmp_now_epoch)
	elapsed=$((end_epoch - start_epoch))
	[[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0

	if declare -p "$dest_var" >/dev/null 2>&1; then
		current_value="${!dest_var}"
	else
		current_value=0
	fi
	[[ "$current_value" =~ ^[0-9]+$ ]] || current_value=0
	current_value=$((current_value + elapsed))
	printf -v "$dest_var" '%s' "$current_value"
	return 0
}

_pmp_log_repo_timing_summary() {
	local repo_slug="$1"
	local total_s="${2:-0}"
	local list_s="${3:-0}"
	local mergeability_s="${4:-0}"
	local ruleset_s="${5:-0}"
	local branch_protection_s="${6:-0}"
	local stuck_detector_s="${7:-0}"
	local merged="${8:-0}"
	local closed="${9:-0}"
	local failed="${10:-0}"
	local pr_count="${11:-0}"

	echo "[pulse-wrapper] deterministic_merge_pass timing: repo=${repo_slug} total_s=${total_s} list_s=${list_s} mergeability_s=${mergeability_s} ruleset_s=${ruleset_s} branch_protection_s=${branch_protection_s} stuck_detector_s=${stuck_detector_s} merged=${merged} closed=${closed} failed=${failed} prs=${pr_count}" >>"$LOGFILE"
	return 0
}
