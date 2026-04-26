#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-api-instrument.sh -- Lightweight gh API call instrumentation (t2902)
# =============================================================================
# Records every routed gh CLI / gh api call partitioned by path (graphql, rest,
# search-graphql, search-rest, other) and caller script. Aggregation produces
# a JSON report at ~/.aidevops/logs/gh-api-calls-by-stage.json so heavy
# GraphQL consumers can be identified and routed through the separate REST
# core pool (t2574, t2689) or the Search API bucket where applicable.
#
# Why this exists (t2902):
#   The pulse circuit breaker fires repeatedly even though REST fallback
#   covers writes (t2574) and reads (t2689). Something is still draining
#   GraphQL between resets. Without per-call-site visibility, the heavy
#   consumer is invisible. This file is a minimum-overhead recorder; it
#   adds one append to a tab-separated log per gh call.
#
# Usage from a sourced shell script:
#
#     source "${SCRIPT_DIR}/gh-api-instrument.sh"
#     # Before calling a GraphQL-backed gh command:
#     gh_record_call graphql
#     gh issue create ...
#     # After falling back to REST:
#     gh_record_call rest
#     gh api /repos/.../issues
#
# CLI usage:
#
#     gh-api-instrument.sh record <path> [caller]   # append a record
#     gh-api-instrument.sh report [out_path]        # aggregate to JSON
#     gh-api-instrument.sh trim                     # rotate log if oversize
#     gh-api-instrument.sh clear                    # wipe log + report
#
# Path values (fixed enum):
#   graphql        — gh CLI command that internally hits the GraphQL endpoint
#   rest           — gh api or REST translator that hits the core REST pool
#   search-graphql — gh search issues/prs/code/repos (GraphQL Search API)
#   search-rest    — REST per-repo iteration replacing a search call
#   other          — anything not covered above (counted but not partitioned)
#
# Log format (TSV, append-only):
#   <unix_ts>\t<caller_basename>\t<path>
#
# Override env vars:
#   AIDEVOPS_GH_API_LOG          — path to the log file (default
#                                   ~/.aidevops/logs/gh-api-calls.log)
#   AIDEVOPS_GH_API_REPORT       — path to the JSON report (default
#                                   ~/.aidevops/logs/gh-api-calls-by-stage.json)
#   AIDEVOPS_GH_API_LOG_MAX_LINES — when set and exceeded, trim() retains
#                                   the most-recent half (default 50000)
#   AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1 — make all calls no-ops
#
# Part of aidevops framework: https://aidevops.sh
# =============================================================================

# Include guard — safe to source multiple times.
[[ -n "${_GH_API_INSTRUMENT_LOADED:-}" ]] && return 0
_GH_API_INSTRUMENT_LOADED=1

# Apply strict mode only when executed directly (not when sourced).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# --- Configuration --------------------------------------------------------
GH_API_LOG="${AIDEVOPS_GH_API_LOG:-${HOME}/.aidevops/logs/gh-api-calls.log}"
GH_API_REPORT="${AIDEVOPS_GH_API_REPORT:-${HOME}/.aidevops/logs/gh-api-calls-by-stage.json}"
GH_API_LOG_MAX_LINES="${AIDEVOPS_GH_API_LOG_MAX_LINES:-50000}"

# --- gh_record_call <path> [caller] ---------------------------------------
# Append a record to the log. Cheapest possible: one open+append.
# Failure is silent — instrumentation must never break the host script.
#
# Args:
#   $1 path   — one of: graphql | rest | search-graphql | search-rest | other
#   $2 caller — optional; defaults to BASH_SOURCE[1] basename. Pass an
#               explicit caller when wrapping is multiple frames deep.
#
# Returns: 0 always.
gh_record_call() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local path="${1:-other}"
	local caller="${2:-}"
	if [[ -z "$caller" ]]; then
		# Default: name of the script that called us. Walk up until we find
		# a frame outside this file (tests sometimes source us; we want the
		# real caller, not gh-api-instrument.sh itself).
		local i=1 src
		while [[ $i -lt ${#BASH_SOURCE[@]} ]]; do
			src="${BASH_SOURCE[$i]}"
			if [[ -n "$src" && "${src##*/}" != "gh-api-instrument.sh" ]]; then
				caller="${src##*/}"
				break
			fi
			i=$((i + 1))
		done
		[[ -z "$caller" ]] && caller="${0##*/}"
		[[ -z "$caller" || "$caller" == "-bash" || "$caller" == "bash" ]] && caller="unknown"
	fi
	local ts
	ts=$(date +%s 2>/dev/null) || return 0
	mkdir -p "${GH_API_LOG%/*}" 2>/dev/null || true
	# Tab-separated; printf is atomic for short lines on POSIX file systems.
	printf '%s\t%s\t%s\n' "$ts" "$caller" "$path" >>"$GH_API_LOG" 2>/dev/null || true
	return 0
}

# --- gh_aggregate_calls [out_path] [window_secs] -------------------------
# Read the log, write a JSON report keyed by caller. Counts entries newer
# than `now - window_secs` (default 86400 = 24h). awk-only aggregation
# keeps this independent of jq for the hot path; jq is used only if a
# downstream caller decides to post-process the file.
#
# Output JSON shape:
#   {
#     "_meta": {
#       "generated_at_ts": 1730000000,
#       "since_ts":        1729913600,
#       "window_seconds":  86400,
#       "total_calls":     123
#     },
#     "by_caller": {
#       "pulse-batch-prefetch-helper.sh": {
#         "graphql_calls":        0,
#         "rest_calls":           48,
#         "search_graphql_calls": 0,
#         "search_rest_calls":    24,
#         "other_calls":          0,
#         "total":                72
#       }
#     }
#   }
#
# Args:
#   $1 out_path    — defaults to $GH_API_REPORT
#   $2 window_secs — defaults to 86400 (24 hours)
#
# Returns: 0 on success, 1 if log missing.
gh_aggregate_calls() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local out="${1:-$GH_API_REPORT}"
	local window="${2:-86400}"
	local now cutoff
	now=$(date +%s)
	cutoff=$((now - window))
	mkdir -p "${out%/*}" 2>/dev/null || true
	if [[ ! -f "$GH_API_LOG" ]]; then
		printf '{"_meta":{"error":"no-log","window_seconds":%d},"by_caller":{}}\n' \
			"$window" >"$out" 2>/dev/null || true
		return 1
	fi
	# The awk aggregator lives in a sibling file so the line-based
	# pre-commit positional-param validator does not flag awk's `$1` field
	# references as bash positional params (they live inside multi-line
	# single-quoted blocks the validator can't see).
	local awk_script
	awk_script="$(dirname "${BASH_SOURCE[0]}")/gh-api-aggregate.awk"
	if [[ ! -f "$awk_script" ]]; then
		printf '{"_meta":{"error":"missing-awk-script","path":"%s"},"by_caller":{}}\n' \
			"$awk_script" >"$out" 2>/dev/null || true
		return 1
	fi
	awk -F'\t' -v now="$now" -v cutoff="$cutoff" -v window="$window" \
		-f "$awk_script" "$GH_API_LOG" >"$out" 2>/dev/null || return 1
	return 0
}

# --- gh_trim_log ----------------------------------------------------------
# Rotate the log if it exceeds GH_API_LOG_MAX_LINES, retaining the most
# recent half. Cheap: one wc, one tail. Safe to call frequently.
gh_trim_log() {
	[[ -f "$GH_API_LOG" ]] || return 0
	local lines
	lines=$(wc -l <"$GH_API_LOG" 2>/dev/null | tr -d ' ')
	[[ "$lines" =~ ^[0-9]+$ ]] || return 0
	if [[ "$lines" -gt "$GH_API_LOG_MAX_LINES" ]]; then
		local keep=$((GH_API_LOG_MAX_LINES / 2))
		local tmp
		tmp=$(mktemp "${GH_API_LOG}.XXXXXX") || return 0
		tail -n "$keep" "$GH_API_LOG" >"$tmp" 2>/dev/null && mv "$tmp" "$GH_API_LOG"
	fi
	return 0
}

# --- gh_clear_log ---------------------------------------------------------
# Remove the log + report. Used by tests and by the `clear` subcommand.
gh_clear_log() {
	rm -f "$GH_API_LOG" "$GH_API_REPORT" 2>/dev/null
	return 0
}

# --- CLI dispatch ---------------------------------------------------------
# Only runs when executed directly (not when sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	cmd="${1:-help}"
	shift || true
	case "$cmd" in
	record)
		gh_record_call "$@"
		;;
	report | aggregate)
		gh_aggregate_calls "$@"
		printf 'Wrote %s\n' "$GH_API_REPORT" >&2
		;;
	trim)
		gh_trim_log
		;;
	clear)
		gh_clear_log
		;;
	help | --help | -h)
		cat <<EOF
gh-api-instrument.sh — gh API call instrumentation (t2902)

Subcommands:
  record <path> [caller]   Append one record to ${GH_API_LOG##*/}
  report [out] [window_s]  Aggregate to JSON (default ${GH_API_REPORT##*/}, 24h)
  trim                     Rotate log if larger than \$AIDEVOPS_GH_API_LOG_MAX_LINES
  clear                    Remove log + report

Path values:
  graphql | rest | search-graphql | search-rest | other

See header comments for full env-var reference.
EOF
		;;
	*)
		printf 'Unknown subcommand: %s\n' "$cmd" >&2
		printf 'Run "%s help" for usage.\n' "${0##*/}" >&2
		exit 2
		;;
	esac
fi
