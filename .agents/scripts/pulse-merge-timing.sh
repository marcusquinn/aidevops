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
		current_value="${!dest_var:-}"
	else
		current_value=0
	fi
	[[ "$current_value" =~ ^[0-9]+$ ]] || current_value=0
	current_value=$((current_value + elapsed))
	printf -v "$dest_var" '%s' "$current_value"
	return 0
}

#######################################
# GH#33307: accumulate one per-PR processing unit into the caller's
# <prefix>pr_s total and track the slowest PR as <prefix>slowest_pr
# ("#N:Ss"). The per-PR unit includes fresh enrichment, trust/review gates,
# mergeability/ruleset/branch-protection reads, and merge/close/comment work,
# so the existing sub-timings are a breakdown of pr_s, not additions to it.
# Args: $1=timing prefix, $2=start epoch, $3=PR number (may be empty)
#######################################
_pmp_record_pr_processing_timing() {
	local timing_prefix="$1"
	local start_epoch="${2:-0}"
	local pr_number="${3:-}"
	# Name must not collide with _pmp_add_elapsed_seconds locals (dynamic scope).
	local _pmp_pr_unit_s=0 slowest_var="" slowest="" slowest_s=0

	[[ "$timing_prefix" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_add_elapsed_seconds _pmp_pr_unit_s "$start_epoch" || return 1
	_pmp_add_counter_seconds "${timing_prefix}pr_s" "$_pmp_pr_unit_s" || return 1
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	slowest_var="${timing_prefix}slowest_pr"
	if declare -p "$slowest_var" >/dev/null 2>&1; then
		slowest="${!slowest_var:-}"
	fi
	slowest_s="${slowest##*:}"
	slowest_s="${slowest_s%s}"
	[[ "$slowest_s" =~ ^[0-9]+$ ]] || slowest_s=-1
	if [[ "$_pmp_pr_unit_s" -gt "$slowest_s" ]]; then
		printf -v "$slowest_var" '#%s:%ss' "$pr_number" "$_pmp_pr_unit_s"
	fi
	return 0
}

#######################################
# Add an integer number of seconds to a named accumulator.
# Args: $1=destination variable name, $2=seconds
#######################################
_pmp_add_counter_seconds() {
	local dest_var="$1"
	local seconds="${2:-0}"
	local current_value=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
	if declare -p "$dest_var" >/dev/null 2>&1; then
		current_value="${!dest_var:-}"
	fi
	[[ "$current_value" =~ ^[0-9]+$ ]] || current_value=0
	printf -v "$dest_var" '%s' "$((current_value + seconds))"
	return 0
}

_pmp_log_repo_timing_summary() {
	local repo_slug="$1"
	local logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
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
	local list_state="${12:-complete}"
	# GH#33307: enrichment_s + pr_s (+ list_s + stuck_detector_s) explain
	# total_s; other_s is the remaining overhead (cache setup, sorting,
	# duplicate consolidation, cursor I/O). mergeability/ruleset/branch
	# protection remain a breakdown inside pr_s.
	local enrichment_s="${13:-0}"
	local pr_s="${14:-0}"
	local slowest_pr="${15:-}"
	local other_s=0

	[[ "$total_s" =~ ^[0-9]+$ ]] || total_s=0
	[[ "$list_s" =~ ^[0-9]+$ ]] || list_s=0
	[[ "$stuck_detector_s" =~ ^[0-9]+$ ]] || stuck_detector_s=0
	[[ "$enrichment_s" =~ ^[0-9]+$ ]] || enrichment_s=0
	[[ "$pr_s" =~ ^[0-9]+$ ]] || pr_s=0
	other_s=$((total_s - list_s - stuck_detector_s - enrichment_s - pr_s))
	[[ "$other_s" -ge 0 ]] || other_s=0
	[[ -n "$slowest_pr" ]] || slowest_pr="none"

	echo "[pulse-wrapper] deterministic_merge_pass timing: repo=${repo_slug} total_s=${total_s} list_s=${list_s} list_state=${list_state} mergeability_s=${mergeability_s} ruleset_s=${ruleset_s} branch_protection_s=${branch_protection_s} stuck_detector_s=${stuck_detector_s} merged=${merged} closed=${closed} failed=${failed} prs=${pr_count} enrichment_s=${enrichment_s} pr_s=${pr_s} other_s=${other_s} slowest_pr=${slowest_pr}" >>"$logfile"
	return 0
}
