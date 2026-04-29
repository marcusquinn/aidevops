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
#     dispatch-stage-instrument.sh report [window_s]  # print per-stage p50/p95/p99
#     dispatch-stage-instrument.sh trim               # rotate if oversize
#     dispatch-stage-instrument.sh clear               # wipe log
#
# Log format (TSV, append-only):
#   <ISO8601_UTC>\t#<issue_number>\t<repo_slug>\t<stage_name>\t<elapsed_ms>
#
# Override env vars:
#   AIDEVOPS_DISPATCH_STAGES_LOG          — log path (default
#                                            ~/.aidevops/logs/dispatch-stages.tsv)
#   AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES — trim threshold (default 50000)
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
DS_LOG_MAX_LINES="${AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES:-50000}"

# --- _ds_now_ns -----------------------------------------------------------
# Return current time in nanoseconds. Uses bash 5+ %N when available,
# falls back to seconds * 1e9 on macOS/bash 3.2 (no %N support).
# Stdout: integer nanoseconds
_ds_now_ns() {
	[[ "${AIDEVOPS_DISPATCH_STAGES_DISABLE:-0}" == "1" ]] && { printf '0'; return 0; }
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

	local end_ns elapsed_ms ts
	end_ns=$(_ds_now_ns)
	# Guard against non-numeric values (e.g., when disabled or date failed)
	if [[ "$start_ns" =~ ^[0-9]+$ && "$end_ns" =~ ^[0-9]+$ && "$start_ns" -gt 0 ]]; then
		elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
	else
		elapsed_ms=0
	fi

	# ISO 8601 UTC timestamp
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="unknown"

	# Ensure parent dir exists
	[[ "$DS_LOG" == */* ]] && mkdir -p "${DS_LOG%/*}" 2>/dev/null || true

	# Atomic append (short line, POSIX guarantee)
	printf '%s\t#%s\t%s\t%s\t%s\n' "$ts" "$issue_number" "$repo_slug" "$stage_name" "$elapsed_ms" \
		>>"$DS_LOG" 2>/dev/null || true
	return 0
}

# --- _ds_report [window_secs] ---------------------------------------------
# Print per-stage p50, p95, p99 from the log. Uses awk for portability.
# Args:
#   $1 window_secs — only include records newer than now - window (default 86400)
# Returns: 0 on success, 1 if log missing
_ds_report() {
	local window="${1:-86400}"
	if [[ ! -f "$DS_LOG" ]]; then
		printf 'No dispatch stages log at %s\n' "$DS_LOG" >&2
		return 1
	fi
	local now cutoff
	now=$(date +%s)
	cutoff=$((now - window))

	# The awk aggregator lives in a sibling file so the line-based
	# pre-commit positional-param validator does not flag awk's field
	# references as bash positional params (same pattern as
	# gh-api-instrument.sh / gh-api-aggregate.awk).
	local awk_script
	awk_script="$(dirname "${BASH_SOURCE[0]}")/dispatch-stage-aggregate.awk"
	if [[ ! -f "$awk_script" ]]; then
		printf 'Missing awk script: %s\n' "$awk_script" >&2
		return 1
	fi
	awk -F'\t' -v cutoff="$cutoff" -f "$awk_script" "$DS_LOG"
	return 0
}

# --- _ds_trim_log ---------------------------------------------------------
# Rotate the log if it exceeds DS_LOG_MAX_LINES, retaining the most recent
# half. Same pattern as gh_trim_log.
_ds_trim_log() {
	[[ -f "$DS_LOG" ]] || return 0
	local lines
	lines=$(wc -l <"$DS_LOG" 2>/dev/null | tr -d ' ')
	[[ "$lines" =~ ^[0-9]+$ ]] || return 0
	if [[ "$lines" -gt "$DS_LOG_MAX_LINES" ]]; then
		local keep=$((DS_LOG_MAX_LINES / 2))
		local tmp
		tmp=$(mktemp "${DS_LOG}.XXXXXX") || return 0
		tail -n "$keep" "$DS_LOG" >"$tmp" 2>/dev/null && mv "$tmp" "$DS_LOG"
	fi
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
  report [window_s]  Print per-stage p50/p95/p99 (default 24h window)
  trim               Rotate log if larger than \$AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES
  clear              Remove log

Log file: ${DS_LOG}

Env vars:
  AIDEVOPS_DISPATCH_STAGES_LOG            Override log path
  AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES  Trim threshold (default 50000)
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
