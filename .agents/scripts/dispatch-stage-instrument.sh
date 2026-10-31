#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# dispatch-stage-instrument.sh -- Per-stage timing for dispatch ceremony (t3034)
# =============================================================================
# Records elapsed time for each sub-stage of the dispatch_with_dedup ceremony
# so p95/p99 tail latencies can be identified and optimized. Modeled on
# gh-api-instrument.sh (t2902) — same TSV append pattern, same fail-open
# contract.
#
# Why this exists (t3034):
#   After t3026 raised the per-candidate timeout floor to 360s, fresh
#   "exceeded 360s" events still appear. Without per-stage visibility, we
#   cannot tell which ceremony sub-stage occasionally exceeds the budget.
#   This file is a minimum-overhead recorder; it adds one TSV append per
#   stage per dispatch.
#
# Usage from a sourced shell script:
#
#     source "${SCRIPT_DIR}/dispatch-stage-instrument.sh"
#     local _stage_t0
#     _stage_t0=$(_ds_now_ns)
#     # ... stage work ...
#     _ds_record "$issue_number" "$repo_slug" "stage_name" "$_stage_t0"
#
# CLI usage:
#
#     dispatch-stage-instrument.sh report [window_s]  # per-stage p50/p95/p99 in the window
#     dispatch-stage-instrument.sh trim               # rotate if oversize
#     dispatch-stage-instrument.sh clear               # wipe log
#
# Log format (TSV, append-only). The first five fields retain the historical
# completion format; newer records append event lineage:
#   <ISO8601_UTC>\t#<issue>\t<repo>\t<stage>\t<elapsed_ms>\t<event>\t<attempt>\t<cycle>\t<pid>
#
# Override env vars:
#   AIDEVOPS_DISPATCH_STAGES_LOG          — log path (default
#                                            ~/.aidevops/logs/dispatch-stages.tsv)
#   AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES — trim threshold (default 200000);
#                                            the pulse trims once per cycle
#   AIDEVOPS_DISPATCH_STAGES_DISABLE=1    — make all calls no-ops
#
# Part of aidevops framework: https://aidevops.sh
# =============================================================================

# Include guard — safe to source multiple times.
[[ -n "${_DISPATCH_STAGE_INSTRUMENT_LOADED:-}" ]] && return 0
_DISPATCH_STAGE_INSTRUMENT_LOADED=1

# Apply strict mode only when executed directly (not when sourced).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# --- Configuration --------------------------------------------------------
DS_LOG="${AIDEVOPS_DISPATCH_STAGES_LOG:-${HOME}/.aidevops/logs/dispatch-stages.tsv}"
# GH#35935: about 16 days at the observed ~12.5k records/day, so 7-day
# reports keep their data while the log stays near 20 MB.
_DS_DEFAULT_LOG_MAX_LINES=200000
DS_LOG_MAX_LINES="${AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES:-$_DS_DEFAULT_LOG_MAX_LINES}"
# Report/trim scratch files older than this are leftovers of killed runs.
_DS_STALE_TEMP_MINUTES=60
# Plain assignments stay global even when this file is first sourced inside a
# function (worktree-helper-add.sh via _dlw_restore_worktree_deps); `declare`
# would create function locals that vanish, and `declare -g` needs Bash 4.2.
_DS_ATTEMPT_KEYS=()
_DS_ATTEMPT_IDS=()
_DS_ATTEMPT_COMPLETED=()

# --- _ds_now_ns -----------------------------------------------------------
# Return current time in nanoseconds. Uses bash 5+ %N when available,
# falls back to seconds * 1e9 on macOS/bash 3.2 (no %N support).
# Stdout: integer nanoseconds
_ds_now_ns() {
	[[ "${AIDEVOPS_DISPATCH_STAGES_DISABLE:-0}" == "1" ]] && {
		printf '0'
		return 0
	}
	local ns
	# Try GNU date first (supports %N)
	ns=$(date +%s%N 2>/dev/null) || ns=""
	# macOS date does not support %N — it prints literal "N"
	if [[ -z "$ns" || "$ns" == *N* ]]; then
		# Fall back to seconds * 1e9 (millisecond precision lost, but
		# still useful for stages taking >100ms which is the use case)
		local s
		s=$(date +%s 2>/dev/null) || s=0
		ns=$((s * 1000000000))
	fi
	printf '%s' "$ns"
	return 0
}

_ds_attempt_id() {
	local issue_number="$1"
	local stage_name="$2"
	local start_ns="$3"
	printf '%s:%s:%s:%s' "${_PULSE_CYCLE_ID:-pid-$$}" "$issue_number" "$stage_name" "$start_ns"
	return 0
}

_ds_normalize_stage() {
	local stage_name="$1"
	[[ "$stage_name" == *.* ]] || stage_name="dedup.${stage_name}"
	printf '%s' "$stage_name"
	return 0
}

# Record entry separately from completion so an interrupted or slow stage is
# observable. Callers keep the start timestamp and pass it to _ds_record.
_ds_stage_start() {
	[[ "${AIDEVOPS_DISPATCH_STAGES_DISABLE:-0}" == "1" ]] && return 0
	local issue_number="$1"
	local repo_slug="$2"
	local stage_name="$3"
	local start_ns="$4"
	local output_var="${5:-}"
	local ts attempt_id cycle_id
	stage_name=$(_ds_normalize_stage "$stage_name")
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="unknown"
	_DS_ATTEMPT_SEQUENCE=$((${_DS_ATTEMPT_SEQUENCE:-0} + 1))
	attempt_id="$(_ds_attempt_id "$issue_number" "$stage_name" "$start_ns"):${_DS_ATTEMPT_SEQUENCE}"
	local attempt_index="${#_DS_ATTEMPT_KEYS[@]}"
	_DS_ATTEMPT_KEYS[$attempt_index]="${issue_number}:${stage_name}:${start_ns}"
	_DS_ATTEMPT_IDS[$attempt_index]="$attempt_id"
	_DS_ATTEMPT_COMPLETED[$attempt_index]=0
	[[ -n "$output_var" ]] && printf -v "$output_var" '%s' "$attempt_id"
	cycle_id="${_PULSE_CYCLE_ID:-pid-$$}"
	[[ "$DS_LOG" == */* ]] && mkdir -p "${DS_LOG%/*}" 2>/dev/null || true
	printf '%s\t#%s\t%s\t%s\t0\tstart\t%s\t%s\t%s\n' \
		"$ts" "$issue_number" "$repo_slug" "$stage_name" "$attempt_id" "$cycle_id" "$$" \
		>>"$DS_LOG" 2>/dev/null || true
	return 0
}

# --- _ds_record <issue_number> <repo_slug> <stage_name> <start_ns> --------
# Compute elapsed milliseconds since start_ns and append a TSV record.
# Failure is silent — instrumentation must never break the host script.
#
# Args:
#   $1 issue_number — GitHub issue number (numeric)
#   $2 repo_slug    — owner/repo
#   $3 stage_name   — short identifier (e.g., "dedup_check", "worker_spawn")
#   $4 start_ns     — value from _ds_now_ns captured before the stage ran
#
# Returns: 0 always.
_ds_record() {
	[[ "${AIDEVOPS_DISPATCH_STAGES_DISABLE:-0}" == "1" ]] && return 0
	local issue_number="$1"
	local repo_slug="$2"
	local stage_name="$3"
	local start_ns="$4"

	local supplied_attempt_id="${5:-${_ds_stage_attempt_id:-}}"
	local end_ns elapsed_ms ts attempt_id cycle_id attempt_key attempt_index=-1 index
	stage_name=$(_ds_normalize_stage "$stage_name")
	end_ns=$(_ds_now_ns)
	# Guard against non-numeric values (e.g., when disabled or date failed)
	if [[ "$start_ns" =~ ^[0-9]+$ && "$end_ns" =~ ^[0-9]+$ && "$start_ns" -gt 0 ]]; then
		elapsed_ms=$(((end_ns - start_ns) / 1000000))
	else
		elapsed_ms=0
	fi

	# ISO 8601 UTC timestamp
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="unknown"
	attempt_key="${issue_number}:${stage_name}:${start_ns}"
	if [[ -n "$supplied_attempt_id" ]]; then
		for ((index = 0; index < ${#_DS_ATTEMPT_KEYS[@]}; index++)); do
			[[ "${_DS_ATTEMPT_IDS[$index]}" == "$supplied_attempt_id" && "${_DS_ATTEMPT_KEYS[$index]}" == "$attempt_key" ]] || continue
			[[ "${_DS_ATTEMPT_COMPLETED[$index]}" == "1" ]] && return 0
			attempt_index="$index"
			break
		done
	fi
	if [[ "$attempt_index" -lt 0 ]]; then
		for ((index = 0; index < ${#_DS_ATTEMPT_KEYS[@]}; index++)); do
			if [[ "${_DS_ATTEMPT_KEYS[$index]}" == "$attempt_key" && "${_DS_ATTEMPT_COMPLETED[$index]}" == "0" ]]; then
				attempt_index="$index"
			fi
		done
	fi
	if [[ "$attempt_index" -ge 0 ]]; then
		attempt_id="${_DS_ATTEMPT_IDS[$attempt_index]}"
		_DS_ATTEMPT_COMPLETED[$attempt_index]=1
	elif [[ " ${_DS_ATTEMPT_KEYS[*]} " == *" $attempt_key "* ]]; then
		return 0
	else
		attempt_id=$(_ds_attempt_id "$issue_number" "$stage_name" "$start_ns")
	fi
	cycle_id="${_PULSE_CYCLE_ID:-pid-$$}"

	# Ensure parent dir exists
	[[ "$DS_LOG" == */* ]] && mkdir -p "${DS_LOG%/*}" 2>/dev/null || true

	# Atomic append (short line, POSIX guarantee)
	printf '%s\t#%s\t%s\t%s\t%s\tcomplete\t%s\t%s\t%s\n' \
		"$ts" "$issue_number" "$repo_slug" "$stage_name" "$elapsed_ms" "$attempt_id" "$cycle_id" "$$" \
		>>"$DS_LOG" 2>/dev/null || true
	return 0
}

# --- Dispatcher-owned subprocess sub-stages (GH#35602) ---------------------
# worktree-helper.sh runs as a child of the dispatcher. It records
# precreate.* sub-stages only when the dispatcher exported the attempt
# context (AIDEVOPS_DISPATCH_STAGE_ISSUE + AIDEVOPS_DISPATCH_STAGE_REPO), so
# interactive and other worktree creation never writes dispatch records.
# Locals use a _ds_ss_ prefix: wrapped functions may read caller-scoped
# variables through bash dynamic scoping and must not see shadowed names.
_ds_substage_active() {
	[[ "${AIDEVOPS_DISPATCH_STAGE_ISSUE:-}" =~ ^[0-9]+$ && -n "${AIDEVOPS_DISPATCH_STAGE_REPO:-}" ]] || return 1
	return 0
}

# Stdout: start timestamp in ns, or 0 when no dispatch context is active.
_ds_substage_start() {
	if _ds_substage_active; then
		_ds_now_ns
	else
		printf '0'
	fi
	return 0
}

# Args: stage name (e.g. precreate.base_fetch), start ns from _ds_substage_start
_ds_substage_record() {
	local _ds_ss_stage="$1" _ds_ss_t0="$2"
	[[ "$_ds_ss_t0" =~ ^[1-9][0-9]*$ ]] || return 0
	_ds_substage_active || return 0
	_ds_record "$AIDEVOPS_DISPATCH_STAGE_ISSUE" "$AIDEVOPS_DISPATCH_STAGE_REPO" "$_ds_ss_stage" "$_ds_ss_t0"
	return 0
}

# Run one command as a timed sub-stage; its exit status is returned unchanged.
# Args: stage name, command and arguments
_ds_substage_run() {
	local _ds_ss_name="$1"
	shift
	local _ds_ss_start="" _ds_ss_rc=0
	_ds_ss_start=$(_ds_substage_start)
	"$@" || _ds_ss_rc=$?
	_ds_substage_record "$_ds_ss_name" "$_ds_ss_start"
	return "$_ds_ss_rc"
}

# --- _ds_epoch_to_iso <epoch> ---------------------------------------------
# Format epoch seconds as the log's ISO-8601 UTC timestamp. GNU date takes
# -d @N; BSD/macOS date takes -r N.
# Stdout: YYYY-MM-DDTHH:MM:SSZ
# Returns: 0 on success, 1 when the epoch cannot be formatted
_ds_epoch_to_iso() {
	local epoch="$1"
	local iso=""
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	iso=$(date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		iso=$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 1
	[[ "$iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	printf '%s' "$iso"
	return 0
}

# --- _ds_report [window_secs] ---------------------------------------------
# Print per-stage p50, p95, p99 and max for records newer than now - window.
# GH#35935: stream the log through awk (window filter, start rows skipped) and
# a C-locale sort, so a months-long log reports in seconds and an interrupted
# run leaves no copy of the log behind. The ISO-8601 UTC timestamps compare
# correctly as strings, which avoids date parsing inside awk.
# Args:
#   $1 window_secs — only include records newer than now - window (default 86400)
# Returns: 0 on success, 1 if the log or aggregator is missing or input is invalid
_ds_report() {
	local window="${1:-86400}"
	if [[ ! "$window" =~ ^[0-9]+$ ]]; then
		printf 'Invalid report window (seconds): %s\n' "$window" >&2
		return 1
	fi
	if [[ ! -f "$DS_LOG" ]]; then
		printf 'No dispatch stages log at %s\n' "$DS_LOG" >&2
		return 1
	fi
	local now cutoff cutoff_iso
	now=$(date -u +%s)
	cutoff=$((now - window))
	[[ "$cutoff" -ge 0 ]] || cutoff=0
	if ! cutoff_iso=$(_ds_epoch_to_iso "$cutoff"); then
		printf 'Cannot compute the report window start for epoch %s\n' "$cutoff" >&2
		return 1
	fi

	# The awk program lives in a sibling file so the line-based pre-commit
	# positional-param validator does not flag awk's field references as bash
	# positional params (same pattern as gh-api-instrument.sh / gh-api-aggregate.awk).
	local awk_script report_rc=0
	awk_script="$(dirname "${BASH_SOURCE[0]}")/dispatch-stage-aggregate.awk"
	if [[ ! -f "$awk_script" ]]; then
		printf 'Missing awk script: %s\n' "$awk_script" >&2
		return 1
	fi
	LC_ALL=C awk -v mode=filter -v cutoff="$cutoff_iso" -f "$awk_script" "$DS_LOG" |
		LC_ALL=C sort -t $'\t' -k1,1 -k2,2n |
		awk -v mode=aggregate -f "$awk_script" || report_rc=$?
	return "$report_rc"
}

# --- _ds_cleanup_stale_temp -----------------------------------------------
# Remove report/trim scratch files left by killed runs. Before GH#35935 every
# report copied the whole log to ${DS_LOG}.report.*, and a timed-out report
# left a copy as large as the log.
_ds_cleanup_stale_temp() {
	local log_dir="${DS_LOG%/*}"
	local log_name="${DS_LOG##*/}"
	[[ "$DS_LOG" == */* && -n "$log_name" && -d "$log_dir" ]] || return 0
	# Name tests first, so the per-cycle scan does not stat unrelated logs.
	find "$log_dir" -maxdepth 1 \
		\( -name "${log_name}.report.*" -o -name "${log_name}.trim.*" \) \
		-type f -mmin "+${_DS_STALE_TEMP_MINUTES}" -exec rm -f {} + 2>/dev/null || true
	return 0
}

# --- _ds_trim_log ---------------------------------------------------------
# Rotate the log if it exceeds DS_LOG_MAX_LINES, retaining the most recent
# half, and remove stale scratch files. The pulse calls this once per cycle
# next to gh_trim_log (GH#35935); before that nothing bounded the log.
# Records appended between the tail and the rename are lost, which this
# fail-open instrumentation accepts.
_ds_trim_log() {
	_ds_cleanup_stale_temp
	[[ -f "$DS_LOG" ]] || return 0
	local max_lines="$DS_LOG_MAX_LINES"
	local lines="" keep=0 tmp=""
	[[ "$max_lines" =~ ^[1-9][0-9]*$ ]] || max_lines="$_DS_DEFAULT_LOG_MAX_LINES"
	lines=$(wc -l <"$DS_LOG" 2>/dev/null | tr -d ' ')
	[[ "$lines" =~ ^[0-9]+$ ]] || return 0
	[[ "$lines" -gt "$max_lines" ]] || return 0
	keep=$((max_lines / 2))
	[[ "$keep" -gt 0 ]] || keep=1
	tmp=$(mktemp "${DS_LOG}.trim.XXXXXX" 2>/dev/null) || return 0
	if tail -n "$keep" "$DS_LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$DS_LOG" 2>/dev/null; then
		return 0
	fi
	rm -f "$tmp" 2>/dev/null || true
	return 0
}

# --- _ds_clear_log --------------------------------------------------------
_ds_clear_log() {
	rm -f "$DS_LOG" 2>/dev/null
	return 0
}

# --- CLI dispatch ---------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	cmd="${1:-help}"
	shift || true
	case "$cmd" in
	report)
		_ds_report "$@"
		;;
	trim)
		_ds_trim_log
		;;
	clear)
		_ds_clear_log
		;;
	help | --help | -h)
		cat <<EOF
dispatch-stage-instrument.sh — per-stage dispatch ceremony timing (t3034)

Subcommands:
  report [window_s]  Print per-stage p50/p95/p99/max for the last window_s
                     seconds (default 86400)
  trim               Rotate log if larger than \$AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES
                     and remove stale scratch files (the pulse runs this every cycle)
  clear              Remove log

Log file: ${DS_LOG}

Env vars:
  AIDEVOPS_DISPATCH_STAGES_LOG            Override log path
  AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES  Trim threshold (default ${_DS_DEFAULT_LOG_MAX_LINES})
  AIDEVOPS_DISPATCH_STAGES_DISABLE=1      No-op all recording
EOF
		;;
	*)
		printf 'Unknown subcommand: %s\n' "$cmd" >&2
		printf 'Run "%s help" for usage.\n' "${0##*/}" >&2
		exit 2
		;;
	esac
fi
