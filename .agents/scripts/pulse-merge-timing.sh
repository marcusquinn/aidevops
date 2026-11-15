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

# Bash 4.2+ reads the clock through the printf builtin (no fork/exec); Bash 3.2
# (macOS) falls back to date. Detected once at load time.
_PMP_NOW_BUILTIN=0
if printf -v _pmp_probe_epoch '%(%s)T' -1 2>/dev/null && [[ "$_pmp_probe_epoch" =~ ^[0-9]+$ ]]; then
	_PMP_NOW_BUILTIN=1
fi
unset _pmp_probe_epoch

# Set the caller's variable to integer epoch seconds without a subshell when
# the printf builtin is available. Args: $1=destination variable name.
_pmp_now_epoch_into() {
	local dest_var="$1"
	# Local name must not collide with caller destination names (dynamic scope).
	local _pmp_helper_now=""
	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	if [[ "$_PMP_NOW_BUILTIN" -eq 1 ]]; then
		printf -v _pmp_helper_now '%(%s)T' -1
	else
		_pmp_helper_now=$(date +%s 2>/dev/null || printf '0')
	fi
	[[ "$_pmp_helper_now" =~ ^[0-9]+$ ]] || _pmp_helper_now=0
	printf -v "$dest_var" '%s' "$_pmp_helper_now"
	return 0
}

_pmp_now_epoch() {
	local now_epoch=""
	_pmp_now_epoch_into now_epoch
	printf '%s' "$now_epoch"
	return 0
}

_pmp_add_elapsed_seconds() {
	local dest_var="$1"
	local start_epoch="${2:-0}"
	local current_value="" end_epoch elapsed

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=0

	_pmp_now_epoch_into end_epoch
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
# GH#38259: per-stage attribution for one PR evaluation.
#
# The evaluator usually runs as a background job under
# _gh_run_bounded_function, so caller variables written inside it never reach
# the parent. Stage records therefore go to a per-repo file that the parent
# reads after each PR:
#   @<stage> <start_epoch>                      stage started
#   <stage>:<secs> <merge> <ruleset> <bp> <tg>  stage finished, with the
#                                               evaluator's breakdown counters
# A deadline kill leaves the in-flight stage as an unmatched "@" record.
#######################################
_PMP_STAGE_TIMING_FILE="${_PMP_STAGE_TIMING_FILE:-}"
_PMP_STAGE_COUNTERS="mergeability_s ruleset_s branch_protection_s trust_gate_s"

# Truncate (creating on first use) the stage file before a PR is evaluated.
# Args: $1=timing prefix (empty disables attribution)
_pmp_stage_timing_reset() {
	local timing_prefix="${1:-}"
	[[ -n "$timing_prefix" ]] || return 0
	if [[ -z "$_PMP_STAGE_TIMING_FILE" || ! -f "$_PMP_STAGE_TIMING_FILE" ]]; then
		_PMP_STAGE_TIMING_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-pulse-merge-stages.XXXXXX" 2>/dev/null) || _PMP_STAGE_TIMING_FILE=""
		return 0
	fi
	: >"$_PMP_STAGE_TIMING_FILE" 2>/dev/null || _PMP_STAGE_TIMING_FILE=""
	return 0
}

# Remove the stage file once a repository's walk returns on any path.
_pmp_stage_timing_discard() {
	[[ -n "$_PMP_STAGE_TIMING_FILE" ]] && rm -f -- "$_PMP_STAGE_TIMING_FILE" 2>/dev/null
	_PMP_STAGE_TIMING_FILE=""
	return 0
}

#######################################
# Run one merge stage and record its wall seconds. The rc passes through
# unchanged (10 still means continue). Reads the evaluator's dynamically
# scoped timing_prefix; without one, or without a stage file, it only runs
# the stage. Local names are prefixed so stage functions that read caller
# locals (stage_rc, pr_number, ...) never see a shadowing copy.
# Args: $1=stage function, $2...=its arguments
#######################################
_pmp_run_timed_stage() {
	local _pmp_rts_fn="$1"
	shift
	local _pmp_rts_file="${_PMP_STAGE_TIMING_FILE:-}" _pmp_rts_name="" _pmp_rts_rc=0
	local _pmp_rts_start=0 _pmp_rts_s=0 _pmp_rts_counters="" _pmp_rts_counter=""
	local _pmp_rts_var=""
	if [[ -z "${timing_prefix:-}" || -z "$_pmp_rts_file" ]]; then
		"$_pmp_rts_fn" "$@" || _pmp_rts_rc=$?
		return "$_pmp_rts_rc"
	fi
	_pmp_rts_name="${_pmp_rts_fn#_pmp_stage_}"
	_pmp_rts_name="${_pmp_rts_name#_}"
	_pmp_now_epoch_into _pmp_rts_start
	printf '@%s %s\n' "$_pmp_rts_name" "$_pmp_rts_start" >>"$_pmp_rts_file" 2>/dev/null || true
	"$_pmp_rts_fn" "$@" || _pmp_rts_rc=$?
	_pmp_add_elapsed_seconds _pmp_rts_s "$_pmp_rts_start"
	for _pmp_rts_counter in $_PMP_STAGE_COUNTERS; do
		_pmp_rts_var="${timing_prefix}${_pmp_rts_counter}"
		_pmp_rts_counters="${_pmp_rts_counters} ${!_pmp_rts_var:-0}"
	done
	printf '%s:%s%s\n' "$_pmp_rts_name" "$_pmp_rts_s" "$_pmp_rts_counters" >>"$_pmp_rts_file" 2>/dev/null || true
	return "$_pmp_rts_rc"
}

#######################################
# Read the stage file for the PR just evaluated. Writes the comma-joined
# breakdown ("required_checks:12,finalize_merge:330") to $2; a stage still
# open when the evaluator stopped is reported as "<stage>:<secs>+unfinished".
# Adopts the evaluator's latest breakdown counters into <prefix><counter> when
# they exceed the parent's copy (a background evaluator's writes are lost).
# Args: $1=timing prefix, $2=destination variable name
#######################################
_pmp_collect_stage_timing() {
	local timing_prefix="$1" dest_var="$2"
	local stage_file="${_PMP_STAGE_TIMING_FILE:-}" record="" values="" breakdown=""
	local -a open_names=() open_epochs=()
	local open_count=0 open_index=0 now_epoch=0 open_s=0
	local counter="" counter_value="" counter_var="" latest_counters=""
	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	printf -v "$dest_var" '%s' ''
	[[ -n "$stage_file" && -s "$stage_file" ]] || return 0
	while read -r record values; do
		# A second =~ would overwrite BASH_REMATCH, so names come from expansion.
		if [[ "$record" =~ ^@[a-z_]+$ && "$values" =~ ^[0-9]+$ ]]; then
			open_names[open_count]="${record#@}"
			open_epochs[open_count]="$values"
			open_count=$((open_count + 1))
		elif [[ "$record" =~ ^[a-z_]+:[0-9]+$ ]]; then
			breakdown="${breakdown:+${breakdown},}${record}"
			[[ "$open_count" -gt 0 && "${open_names[open_count - 1]}" == "${record%%:*}" ]] && open_count=$((open_count - 1))
			[[ "$values" =~ ^[0-9]+( [0-9]+){3}$ ]] && latest_counters="$values"
		fi
	done <"$stage_file"
	if [[ "$open_count" -gt 0 ]]; then
		_pmp_now_epoch_into now_epoch
		# Outermost first, so a nested in-flight stage follows its parent.
		while [[ "$open_index" -lt "$open_count" ]]; do
			open_s=$((now_epoch - open_epochs[open_index]))
			[[ "$open_s" -ge 0 ]] || open_s=0
			breakdown="${breakdown:+${breakdown},}${open_names[open_index]}:${open_s}+unfinished"
			open_index=$((open_index + 1))
		done
	fi
	if [[ -n "$latest_counters" ]]; then
		for counter in $_PMP_STAGE_COUNTERS; do
			counter_value="${latest_counters%% *}"
			latest_counters="${latest_counters#* }"
			counter_var="${timing_prefix}${counter}"
			[[ "${!counter_var:-0}" =~ ^[0-9]+$ && "$counter_value" -gt "${!counter_var:-0}" ]] && printf -v "$counter_var" '%s' "$counter_value"
		done
	fi
	: >"$stage_file" 2>/dev/null || true # consumed: never attributed twice
	printf -v "$dest_var" '%s' "$breakdown"
	return 0
}

#######################################
# GH#33307: accumulate one per-PR processing unit into the caller's
# <prefix>pr_s total and track the slowest PR as <prefix>slowest_pr
# ("#N:Ss"). The per-PR unit includes fresh enrichment, trust/review gates,
# mergeability/ruleset/branch-protection reads, and merge/close/comment work,
# so the existing sub-timings are a breakdown of pr_s, not additions to it.
# GH#38259: the slowest PR's stage breakdown goes to <prefix>slowest_stages.
# Args: $1=timing prefix, $2=start epoch, $3=PR number (may be empty)
#######################################
_pmp_record_pr_processing_timing() {
	local timing_prefix="$1"
	local start_epoch="${2:-0}"
	local pr_number="${3:-}"
	# Names must not collide with _pmp_add_elapsed_seconds locals (dynamic scope).
	local _pmp_pr_unit_s=0 _pmp_pr_stages="" slowest_var="" slowest="" slowest_s=0

	[[ "$timing_prefix" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_add_elapsed_seconds _pmp_pr_unit_s "$start_epoch" || return 1
	_pmp_add_counter_seconds "${timing_prefix}pr_s" "$_pmp_pr_unit_s" || return 1
	_pmp_collect_stage_timing "$timing_prefix" _pmp_pr_stages || _pmp_pr_stages=""
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
		printf -v "${timing_prefix}slowest_stages" '%s' "$_pmp_pr_stages"
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
	# GH#37795: cumulative final-trust-gate seconds (a breakdown inside pr_s).
	local trust_gate_s="${16:-0}"
	# GH#38259: the slowest PR's per-stage seconds, in completion order.
	# handle_post_merge_actions is nested inside finalize_merge.
	local slowest_stages="${17:-}"
	local other_s=0

	[[ "$total_s" =~ ^[0-9]+$ ]] || total_s=0
	[[ "$list_s" =~ ^[0-9]+$ ]] || list_s=0
	[[ "$stuck_detector_s" =~ ^[0-9]+$ ]] || stuck_detector_s=0
	[[ "$enrichment_s" =~ ^[0-9]+$ ]] || enrichment_s=0
	[[ "$pr_s" =~ ^[0-9]+$ ]] || pr_s=0
	[[ "$trust_gate_s" =~ ^[0-9]+$ ]] || trust_gate_s=0
	other_s=$((total_s - list_s - stuck_detector_s - enrichment_s - pr_s))
	[[ "$other_s" -ge 0 ]] || other_s=0
	[[ -n "$slowest_pr" ]] || slowest_pr="none"
	[[ "$slowest_stages" =~ ^[a-z_:0-9,+]+$ ]] || slowest_stages="none"

	echo "[pulse-wrapper] deterministic_merge_pass timing: repo=${repo_slug} total_s=${total_s} list_s=${list_s} list_state=${list_state} mergeability_s=${mergeability_s} ruleset_s=${ruleset_s} branch_protection_s=${branch_protection_s} stuck_detector_s=${stuck_detector_s} merged=${merged} closed=${closed} failed=${failed} prs=${pr_count} enrichment_s=${enrichment_s} pr_s=${pr_s} trust_gate_s=${trust_gate_s} other_s=${other_s} slowest_pr=${slowest_pr} slowest_stages=${slowest_stages}" >>"$logfile"
	return 0
}
