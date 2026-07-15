#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-api-instrument.sh -- Lightweight gh API call instrumentation (t2902)
# =============================================================================
# Records logical routing/cache events separately from native gh transport
# attempts. Attempts include stable logical/attempt identities, retry/page
# metadata, outcome, elapsed time, and known quota cost without recording argv,
# request bodies, headers, tokens, or query values. Aggregation produces
# a JSON report at ~/.aidevops/logs/gh-api-calls-by-stage.json so heavy
# GraphQL consumers can be identified and routed through the separate REST
# core pool (t2574, t2689) or the Search API bucket where applicable.
#
# Why this exists (t2902):
#   The pulse circuit breaker fires repeatedly even though REST fallback
#   covers writes (t2574) and reads (t2689). Something is still draining
#   GraphQL between resets. Without per-call-site visibility, the heavy
#   consumer is invisible. This file is a minimum-overhead recorder; it
#   adds one bounded append to a tab-separated log per event or attempt.
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
#     gh-api-instrument.sh record <path> [caller] [auth] [pool] [decision] [budget]
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
# Legacy log format (TSV, still readable):
#   <unix_ts>\t<caller_basename>\t<path>\t<auth_mode>\t<api_pool>\t<route_decision>\t<budget_remaining>
# Version 2 appends these privacy-safe fields after the legacy prefix:
#   v2\t<event_kind>\t<logical_id>\t<attempt_id>\t<page>\t<retry>\t<outcome>\t<http_status>\t<elapsed_ms>\t<quota_cost>
#
# Override env vars:
#   AIDEVOPS_GH_API_LOG          — path to the log file (default
#                                   ~/.aidevops/logs/gh-api-calls.log)
#   AIDEVOPS_GH_API_REPORT       — path to the JSON report (default
#                                   ~/.aidevops/logs/gh-api-calls-by-stage.json)
#   AIDEVOPS_GH_API_LOG_MAX_LINES — when set and exceeded, trim() retains
#                                   the newest bounded records (default 50000)
#   AIDEVOPS_GH_API_LOG_MAX_BYTES — maximum retained log bytes (default 16 MiB)
#   AIDEVOPS_GH_API_RETENTION_SECONDS — maximum record age (default 172800)
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
_GH_API_HOME="${HOME:-}"
if [[ -z "$_GH_API_HOME" ]]; then
	_GH_API_UID="${UID:-}"
	[[ -z "$_GH_API_UID" ]] && _GH_API_UID="$(id -u)"
	if command -v getent >/dev/null 2>&1; then
		_GH_API_HOME="$(getent passwd "$_GH_API_UID" | cut -d: -f6 || true)"
	fi
	_GH_API_HOME="${_GH_API_HOME:-${TMPDIR:-/tmp}/aidevops-${USER:-${_GH_API_UID:-shared}}}"
fi

# If HOME cannot be resolved and we must fall back under a shared temporary
# parent, create/lock down a user-owned root before any nested log path exists.
# Otherwise a pre-created /tmp/aidevops-* tree can contain symlinks that make the
# later append follow attacker-controlled paths.
case "$_GH_API_HOME" in
"${TMPDIR:-/tmp}"/* | /tmp/*)
	if [[ -L "$_GH_API_HOME" ]]; then
		AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1
	elif [[ ! -e "$_GH_API_HOME" ]]; then
		mkdir -p "$_GH_API_HOME" 2>/dev/null || AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1
	fi
	if [[ -e "$_GH_API_HOME" && "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" != "1" ]]; then
		if [[ ! -O "$_GH_API_HOME" || -L "$_GH_API_HOME" ]]; then
			AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1
		else
			chmod 0700 "$_GH_API_HOME" || true
		fi
	fi
	;;
esac
GH_API_LOG="${AIDEVOPS_GH_API_LOG:-${_GH_API_HOME}/.aidevops/logs/gh-api-calls.log}"
GH_API_REPORT="${AIDEVOPS_GH_API_REPORT:-${_GH_API_HOME}/.aidevops/logs/gh-api-calls-by-stage.json}"
GH_API_LOG_MAX_LINES="${AIDEVOPS_GH_API_LOG_MAX_LINES:-50000}"
GH_API_LOG_MAX_BYTES="${AIDEVOPS_GH_API_LOG_MAX_BYTES:-16777216}"
GH_API_RETENTION_SECONDS="${AIDEVOPS_GH_API_RETENTION_SECONDS:-172800}"

_gh_now_seconds() {
	local now=""
	printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s 2>/dev/null) || return 1
	printf '%s\n' "$now"
	return 0
}

_gh_now_ms() {
	local now=""
	if command -v perl >/dev/null 2>&1; then
		now=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000' 2>/dev/null || true)
	elif command -v python3 >/dev/null 2>&1; then
		now=$(python3 -c 'import time; print(round(time.time() * 1000))' 2>/dev/null || true)
	fi
	if [[ ! "$now" =~ ^[0-9]+$ ]]; then
		now=$(_gh_now_seconds) || return 1
		now=$((now * 1000))
	fi
	printf '%s\n' "$now"
	return 0
}

_gh_safe_text() {
	local value="$1"
	local fallback="$2"
	value="${value##*/}"
	if [[ "$value" =~ ^[A-Za-z0-9_.:+-]+$ ]]; then
		printf '%s' "$value"
	else
		printf '%s' "$fallback"
	fi
	return 0
}

_gh_safe_number() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value"
	return 0
}

_gh_default_pool() {
	local path="$1"
	case "$path" in
	graphql | search-graphql) printf 'graphql' ;;
	rest) printf 'rest-core' ;;
	search-rest) printf 'rest-search' ;;
	*) printf 'other' ;;
	esac
	return 0
}

_gh_default_auth() {
	local api_pool="$1"
	case "$api_pool" in
	rest-core | rest-search)
		if command -v github_app_is_configured >/dev/null 2>&1 && github_app_is_configured; then
			printf 'github-app'
		else
			printf 'gh-pat'
		fi
		;;
	*) printf 'gh-pat' ;;
	esac
	return 0
}

_gh_resolve_caller() {
	local caller="$1"
	local i=1
	local src=""
	if [[ -z "$caller" ]]; then
		while [[ $i -lt ${#BASH_SOURCE[@]} ]]; do
			src="${BASH_SOURCE[$i]}"
			if [[ -n "$src" && "${src##*/}" != "gh-api-instrument.sh" ]]; then
				caller="${src##*/}"
				break
			fi
			i=$((i + 1))
		done
		[[ -z "$caller" ]] && caller="${0##*/}"
	fi
	case "$caller" in
	"" | -bash | bash) caller="unknown" ;;
	esac
	_gh_safe_text "$caller" unknown
	return 0
}

_gh_log_lock_acquire() {
	local lock_dir="${GH_API_LOG}.lock"
	local tries=0
	local owner=""
	local owner_pid="${BASHPID:-$$}"
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if [[ -f "$lock_dir/pid" && ! -L "$lock_dir" ]]; then
			if ! IFS= read -r owner 2>/dev/null <"$lock_dir/pid"; then
				owner=""
			fi
			if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
				rm -f "$lock_dir/pid" 2>/dev/null || true
				rmdir "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		tries=$((tries + 1))
		[[ $tries -ge 200 ]] && return 1
		sleep 0.01
	done
	if ! printf '%s\n' "$owner_pid" >"$lock_dir/pid" 2>/dev/null; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi
	return 0
}

_gh_log_lock_release() {
	local lock_dir="${GH_API_LOG}.lock"
	rm -f "$lock_dir/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_gh_append_record() {
	local record="$1"
	[[ ${#record} -le 4000 ]] || return 0
	[[ "$GH_API_LOG" == */* ]] && mkdir -p "${GH_API_LOG%/*}" 2>/dev/null || true
	_gh_log_lock_acquire || return 0
	printf '%s\n' "$record" >>"$GH_API_LOG" 2>/dev/null || true
	_gh_log_lock_release
	return 0
}

gh_new_logical_id() {
	local ts=""
	ts=$(_gh_now_seconds) || ts=0
	printf 'l%s-%s-%s\n' "$ts" "${BASHPID:-$$}" "${RANDOM:-0}"
	return 0
}

gh_new_attempt_id() {
	local logical_id="$1"
	_GH_API_ATTEMPT_SEQUENCE=$((${_GH_API_ATTEMPT_SEQUENCE:-0} + 1))
	printf '%s-a%s-%s-%s\n' "$logical_id" "${BASHPID:-$$}" "$_GH_API_ATTEMPT_SEQUENCE" "${RANDOM:-0}"
	return 0
}

gh_attempt_count_for_logical() {
	local logical_id="$1"
	[[ -f "$GH_API_LOG" ]] || {
		printf '0\n'
		return 0
	}
	awk -F'\t' -v logical_id="$logical_id" \
		'$8 == "v2" && $9 == "attempt" && $10 == logical_id { count++ } END { print count + 0 }' \
		"$GH_API_LOG" 2>/dev/null || printf '0\n'
	return 0
}

_gh_append_v2() {
	local event_kind="$1"; shift
	local caller="$1"; shift
	local path="$1"; shift
	local auth_mode="$1"; shift
	local api_pool="$1"; shift
	local route_decision="$1"; shift
	local budget_remaining="$1"; shift
	local logical_id="$1"; shift
	local attempt_id="$1"; shift
	local page="$1"; shift
	local retry="$1"; shift
	local outcome="$1"; shift
	local http_status="$1"; shift
	local elapsed_ms="$1"; shift
	local quota_cost="$1"
	local ts=""
	local record=""
	ts=$(_gh_now_seconds) || return 0
	caller=$(_gh_resolve_caller "$caller")
	path=$(_gh_safe_text "$path" other)
	auth_mode=$(_gh_safe_text "$auth_mode" unknown)
	api_pool=$(_gh_safe_text "$api_pool" other)
	route_decision=$(_gh_safe_text "$route_decision" unspecified)
	event_kind=$(_gh_safe_text "$event_kind" logical)
	logical_id=$(_gh_safe_text "$logical_id" unknown)
	attempt_id=$(_gh_safe_text "$attempt_id" unknown)
	outcome=$(_gh_safe_text "$outcome" unknown)
	budget_remaining=$(_gh_safe_number "$budget_remaining")
	page=$(_gh_safe_number "$page")
	retry=$(_gh_safe_number "$retry")
	http_status=$(_gh_safe_number "$http_status")
	elapsed_ms=$(_gh_safe_number "$elapsed_ms")
	quota_cost=$(_gh_safe_number "$quota_cost")
	printf -v record '%s\t%s\t%s\t%s\t%s\t%s\t%s\tv2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"$ts" "$caller" "$path" "$auth_mode" "$api_pool" "$route_decision" "$budget_remaining" \
		"$event_kind" "$logical_id" "$attempt_id" "$page" "$retry" "$outcome" "$http_status" "$elapsed_ms" "$quota_cost"
	_gh_append_record "$record"
	return 0
}

# --- gh_record_call <path> [caller] [auth] [pool] [decision] [budget] [kind]
# Append a logical routing or cache event. Existing six-argument callers remain
# compatible; known cache decisions are classified automatically.
# Failure is silent — instrumentation must never break the host script.
#
# Args:
#   $1 path   — one of: graphql | rest | search-graphql | search-rest | other
#   $2 caller — optional; defaults to BASH_SOURCE[1] basename. Pass an
#               explicit caller when wrapping is multiple frames deep.
#   $3 auth   — optional auth mode: github-app | gh-pat | unknown.
#   $4 pool   — optional API pool: graphql | rest-core | rest-search | other.
#   $5 route  — optional route decision string.
#   $6 budget — optional remaining budget for the route's limiting pool.
#
# Returns: 0 always.
gh_record_call() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local path="${1:-other}"
	local caller="${2:-}"
	local auth_mode="${3:-${AIDEVOPS_GH_AUTH_MODE:-}}"
	local api_pool="${4:-${AIDEVOPS_GH_API_POOL:-}}"
	local route_decision="${5:-${AIDEVOPS_GH_ROUTE_DECISION:-}}"
	local budget_remaining="${6:-${AIDEVOPS_GH_BUDGET_REMAINING:-${_GH_LAST_GRAPHQL_REMAINING:-}}}"
	local event_kind="${7:-logical}"
	local logical_id="${AIDEVOPS_GH_LOGICAL_ID:-}"
	caller=$(_gh_resolve_caller "$caller")
	if [[ -z "$api_pool" ]]; then
		api_pool=$(_gh_default_pool "$path")
	fi
	if [[ -z "$auth_mode" ]]; then
		auth_mode=$(_gh_default_auth "$api_pool")
	fi
	[[ -z "$route_decision" ]] && route_decision="${api_pool}-selected"
	case "$route_decision" in
	hit | miss | store | stale | invalid-json | bypass | bypass-disabled) event_kind="cache" ;;
	esac
	[[ -n "$logical_id" ]] || logical_id=$(gh_new_logical_id)
	_gh_append_v2 "$event_kind" "$caller" "$path" "$auth_mode" "$api_pool" "$route_decision" \
		"$budget_remaining" "$logical_id" "" "" "" "" "" "" ""
	return 0
}

# --- gh_record_attempt ---------------------------------------------------
# Record one completed native transport try/page. Arguments are metadata only;
# command argv never enters the record.
gh_record_attempt() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local path="$1"; shift
	local caller="$1"; shift
	local logical_id="$1"; shift
	local attempt_id="$1"; shift
	local page="$1"; shift
	local retry="$1"; shift
	local outcome="$1"; shift
	local http_status="$1"; shift
	local elapsed_ms="$1"; shift
	local quota_cost="$1"; shift
	local auth_mode="$1"; shift
	local api_pool="$1"; shift
	local route_decision="$1"; shift
	local budget_remaining="$1"
	[[ -n "$logical_id" ]] || logical_id=$(gh_new_logical_id)
	[[ -n "$attempt_id" ]] || attempt_id=$(gh_new_attempt_id "$logical_id")
	[[ -n "$page" ]] || page=1
	[[ -n "$retry" ]] || retry=0
	[[ -n "$api_pool" ]] || api_pool=$(_gh_default_pool "$path")
	[[ -n "$auth_mode" ]] || auth_mode="${AIDEVOPS_GH_AUTH_MODE:-$(_gh_default_auth "$api_pool")}"
	[[ -n "$route_decision" ]] || route_decision="${AIDEVOPS_GH_ROUTE_DECISION:-${api_pool}-selected}"
	_gh_append_v2 attempt "$caller" "$path" "$auth_mode" "$api_pool" "$route_decision" \
		"$budget_remaining" "$logical_id" "$attempt_id" "$page" "$retry" "$outcome" \
		"$http_status" "$elapsed_ms" "$quota_cost"
	return 0
}

# --- gh_run_transport_attempt <path> <caller> <logical> <page> <retry> -- cmd
# Execute one native transport command with unmodified stdio and status, then
# append exactly one attempt record. Telemetry failures remain fail-open.
gh_run_transport_attempt() {
	local path="$1"; shift
	local caller="$1"; shift
	local logical_id="$1"; shift
	local page="$1"; shift
	local retry="$1"; shift
	[[ "${1:-}" == "--" ]] && shift
	local start_ms=""
	local end_ms=""
	local elapsed_ms=""
	local rc=0
	local outcome="success"
	start_ms=$(_gh_now_ms) || start_ms=""
	if "$@"; then
		rc=0
	else
		rc=$?
		outcome="error"
	fi
	end_ms=$(_gh_now_ms) || end_ms=""
	if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
		elapsed_ms=$((end_ms - start_ms))
	fi
	gh_record_attempt "$path" "$caller" "$logical_id" "" "$page" "$retry" "$outcome" \
		"${AIDEVOPS_GH_HTTP_STATUS:-}" "$elapsed_ms" "${AIDEVOPS_GH_QUOTA_COST:-}" \
		"${AIDEVOPS_GH_AUTH_MODE:-}" "${AIDEVOPS_GH_API_POOL:-}" "${AIDEVOPS_GH_ROUTE_DECISION:-}" \
		"${AIDEVOPS_GH_BUDGET_REMAINING:-${_GH_LAST_GRAPHQL_REMAINING:-}}"
	return "$rc"
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
		printf '{"_meta":{"error":"no-log","schema_version":2,"requested_window_seconds":%d,"window_seconds":%d},"by_caller":{}}\n' \
			"$window" \
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
# Atomically retain only valid records within the configured age, line, and byte
# bounds. Appenders share the same short-lived lock so replacement cannot lose
# a concurrent record. The original remains untouched if filtering fails.
gh_trim_log() {
	[[ -f "$GH_API_LOG" ]] || return 0
	local now=""
	local cutoff=0
	local tmp=""
	[[ "$GH_API_LOG_MAX_LINES" =~ ^[0-9]+$ && "$GH_API_LOG_MAX_LINES" -gt 0 ]] || GH_API_LOG_MAX_LINES=50000
	[[ "$GH_API_LOG_MAX_BYTES" =~ ^[0-9]+$ && "$GH_API_LOG_MAX_BYTES" -gt 0 ]] || GH_API_LOG_MAX_BYTES=16777216
	[[ "$GH_API_RETENTION_SECONDS" =~ ^[0-9]+$ && "$GH_API_RETENTION_SECONDS" -gt 0 ]] || GH_API_RETENTION_SECONDS=172800
	now=$(_gh_now_seconds) || return 0
	cutoff=$((now - GH_API_RETENTION_SECONDS))
	_gh_log_lock_acquire || return 0
	tmp=$(mktemp "${GH_API_LOG}.trim.XXXXXX") || {
		_gh_log_lock_release
		return 0
	}
	if LC_ALL=C awk -F'\t' -v cutoff="$cutoff" -v max_lines="$GH_API_LOG_MAX_LINES" -v max_bytes="$GH_API_LOG_MAX_BYTES" '
		$1 ~ /^[0-9]+$/ && $1 >= cutoff {
			last++
			rows[last] = $0
			row_bytes[last] = length($0) + 1
			bytes += row_bytes[last]
			while (first < last && ((last - first) > max_lines || bytes > max_bytes)) {
				first++
				bytes -= row_bytes[first]
				delete rows[first]
				delete row_bytes[first]
			}
		}
		END {
			for (i = first + 1; i <= last; i++) {
				if (i in rows) print rows[i]
			}
		}
	' "$GH_API_LOG" >"$tmp" 2>/dev/null && mv "$tmp" "$GH_API_LOG" 2>/dev/null; then
		:
	else
		rm -f "$tmp" 2>/dev/null || true
	fi
	_gh_log_lock_release
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
  record <path> [caller] [auth] [pool] [decision] [budget]
                          Append one record to ${GH_API_LOG##*/}
  report [out] [window_s]  Aggregate to JSON (default ${GH_API_REPORT##*/}, 24h)
  trim                     Atomically apply age, line, and byte retention bounds
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
