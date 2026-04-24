#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-rate-limit-circuit-breaker.sh — Pulse-level circuit breaker for GraphQL rate-limit budget (t2690, GH#20310)
#
# Proactive defence: pauses worker dispatch when the GitHub GraphQL rate-limit
# budget is exhausted or nearly exhausted. Without this, the pulse keeps spawning
# workers that fail at step 1 (issue read / PR create / issue edit), burning
# $0.05–$0.25 per doomed dispatch and triggering watchdog kills.
#
# Defence-in-depth layers (all complementary):
#   - t2574: REST fallback for CREATE/EDIT operations (reactive, per-call)
#   - t2689: REST fallback for READ operations (reactive, per-call)
#   - THIS: proactive dispatch pause (prevents spawning workers that will fail)
#
# Subcommands:
#   check   — exit 0 if budget is sufficient (dispatch may proceed),
#             exit 1 if tripped (dispatch should be deferred),
#             exit 2 on API error (fail-open: dispatch proceeds with warning)
#   status  — print human-readable status to stdout (for `aidevops status`)
#   help    — usage information
#
# Environment overrides:
#   AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD — fraction of total budget below
#     which the breaker trips (default 0.30 = 30% = 1500/5000). Set to 0 to
#     disable entirely. Tuned for proactive headroom preservation (t2744):
#     the original 0.05 fired only after 95% of budget was already burned,
#     by which point in-flight reads (issue list, pr view) were already
#     failing with RATE_LIMIT_EXHAUSTED. Tripping at 30% keeps a reserve
#     for ops without REST equivalents (some GraphQL-only mutations) and
#     gives the next pulse cycle room to recover gracefully.
#   AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1 — emergency bypass (dispatch proceeds
#     unconditionally, logged)
#
# Integration:
#   Sourced by pulse-dispatch-engine.sh. The `is_graphql_budget_sufficient`
#   function is called at the top of `_dff_compute_capacity` and at the start
#   of `apply_deterministic_fill_floor` — one cheap check that gates all dispatch.
#
# Counter:
#   `pulse_dispatch_circuit_broken` in ~/.aidevops/logs/pulse-stats.json
#   (via pulse-stats-helper.sh). Surfaced by `aidevops status`.
#
# Multi-runner: Each runner polls `gh api rate_limit` independently. All runners
# share the same GitHub token and see the same budget — per-runner polling is
# correct without shared state files.
#
# Cost: `gh api rate_limit` is a free endpoint (not counted against quotas).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source pulse-stats-helper.sh for counter support (optional — fail-open if missing).
# shellcheck source=pulse-stats-helper.sh
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pulse-stats-helper.sh"
fi

# Source canonical circuit-breaker threshold from conf file (GH#20638, t2768).
# Env var takes precedence; conf supplies the default; 0.30 is the hardcoded fallback
# if the conf file is missing (graceful degradation). Sourced here so standalone
# invocations (not via pulse-wrapper.sh) also use the canonical value.
_CB_RL_CONF="${SCRIPT_DIR}/../configs/pulse-rate-limit.conf"
if [[ -z "${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD+x}" ]] && [[ -f "$_CB_RL_CONF" ]]; then
	# shellcheck disable=SC1090
	source "$_CB_RL_CONF"
fi

# LOGFILE for sourced-mode usage (caller sets it; standalone mode defines a default).
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

# State file for tracking when the breaker last tripped (for status reporting).
_CIRCUIT_BREAKER_STATE_FILE="${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state"

# Log prefix for all messages from this module.
_CB_RL_LOG_PREFIX="[circuit-breaker-rl]"

# Unknown value placeholder for status output.
_CB_RL_UNKNOWN="?"

#######################################
# Check whether the GitHub GraphQL rate-limit budget is sufficient for dispatch.
#
# Queries `gh api rate_limit` (free endpoint — does not consume quota),
# extracts GraphQL remaining and limit, computes the ratio, and compares
# against the configured threshold.
#
# Exit codes:
#   0 — budget sufficient; dispatch may proceed
#   1 — budget exhausted or below threshold; dispatch should be deferred
#   2 — API error (fail-open: dispatch proceeds with warning)
#######################################
is_graphql_budget_sufficient() {
	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER:-0}" == "1" ]]; then
		echo "${_CB_RL_LOG_PREFIX} AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1 — bypassing rate-limit check" >>"$LOGFILE"
		return 0
	fi

	local threshold="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.30}"

	# Disabled if threshold is explicitly 0 (any zero representation).
	if awk -v t="$threshold" 'BEGIN { exit (t + 0 == 0) ? 0 : 1 }' 2>/dev/null; then
		return 0
	fi

	# Query rate limit (free endpoint).
	local rate_json
	rate_json=$(gh api rate_limit 2>/dev/null) || rate_json=""

	if [[ -z "$rate_json" ]]; then
		echo "${_CB_RL_LOG_PREFIX} WARNING: gh api rate_limit failed — proceeding with dispatch (fail-open)" >>"$LOGFILE"
		return 2
	fi

	local remaining limit
	remaining=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.remaining // ""') || remaining=""
	limit=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.limit // ""') || limit=""

	if [[ ! "$remaining" =~ ^[0-9]+$ ]] || [[ ! "$limit" =~ ^[0-9]+$ ]]; then
		echo "${_CB_RL_LOG_PREFIX} WARNING: could not parse GraphQL rate-limit response (remaining='${remaining}', limit='${limit}') — proceeding (fail-open)" >>"$LOGFILE"
		return 2
	fi

	# Avoid division by zero.
	if [[ "$limit" -eq 0 ]]; then
		echo "${_CB_RL_LOG_PREFIX} WARNING: GraphQL limit is 0 — proceeding (fail-open)" >>"$LOGFILE"
		return 2
	fi

	# Compute threshold as integer: threshold_count = ceil(threshold * limit).
	local threshold_count
	threshold_count=$(_compute_threshold_count "$threshold" "$limit") || threshold_count=0

	if [[ "$remaining" -le "$threshold_count" ]]; then
		# Breaker trips.
		echo "${_CB_RL_LOG_PREFIX} GraphQL budget EXHAUSTED: remaining=${remaining}/${limit} (threshold=${threshold_count}, configured=${threshold}) — deferring dispatch until next cycle" >>"$LOGFILE"

		# Record state for status reporting.
		printf '%s %s %s %s\n' "$(date +%s)" "$remaining" "$limit" "$threshold" >"$_CIRCUIT_BREAKER_STATE_FILE" 2>/dev/null || true

		# Increment stats counter.
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_dispatch_circuit_broken" 2>/dev/null || true
		fi

		return 1
	fi

	# Budget sufficient — clear state file if present (breaker recovered).
	if [[ -f "$_CIRCUIT_BREAKER_STATE_FILE" ]]; then
		echo "${_CB_RL_LOG_PREFIX} GraphQL budget recovered: remaining=${remaining}/${limit} — circuit breaker reset" >>"$LOGFILE"
		rm -f "$_CIRCUIT_BREAKER_STATE_FILE" 2>/dev/null || true
	fi

	return 0
}

#######################################
# Compute the integer threshold count from a fractional threshold and limit.
#
# Args:
#   $1 - threshold (decimal string, e.g. "0.05", "0.1", "0.025")
#   $2 - limit (integer, e.g. 5000)
#
# Stdout: integer threshold_count
#
# Uses awk for portable floating-point arithmetic (bash has no FP support).
# Ceil semantics: 0.05 * 5000 = 250, 0.03 * 5000 = 150.
#######################################
_compute_threshold_count() {
	local threshold="$1"
	local limit="$2"

	# Validate threshold is a reasonable decimal (0-1 range).
	if ! printf '%s' "$threshold" | grep -qE '^[0-9]*\.?[0-9]+$'; then
		echo "0"
		return 0
	fi

	# awk for ceil(threshold * limit).
	local result
	result=$(awk -v t="$threshold" -v l="$limit" 'BEGIN { v = t * l; printf "%d", (v == int(v)) ? v : int(v) + 1 }' 2>/dev/null) || result=0
	[[ "$result" =~ ^[0-9]+$ ]] || result=0

	printf '%s\n' "$result"
	return 0
}

#######################################
# Print human-readable circuit breaker status.
# Used by `aidevops status` to surface breaker state.
#
# Stdout: status line (one of: "OK: ...", "TRIPPED: ...", "UNKNOWN: ...")
#######################################
_circuit_breaker_status() {
	# Check for emergency bypass.
	if [[ "${AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER:-0}" == "1" ]]; then
		printf 'BYPASSED: AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1\n'
		return 0
	fi

	local threshold="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.30}"
	if awk -v t="$threshold" 'BEGIN { exit (t + 0 == 0) ? 0 : 1 }' 2>/dev/null; then
		printf 'DISABLED: threshold=0\n'
		return 0
	fi

	# Check current rate-limit state.
	local rate_json
	rate_json=$(gh api rate_limit 2>/dev/null) || rate_json=""

	if [[ -z "$rate_json" ]]; then
		printf 'UNKNOWN: gh api rate_limit unavailable\n'
		return 0
	fi

	local remaining limit reset_epoch
	remaining=$(printf '%s' "$rate_json" | jq -r ".resources.graphql.remaining // \"${_CB_RL_UNKNOWN}\"") || remaining="$_CB_RL_UNKNOWN"
	limit=$(printf '%s' "$rate_json" | jq -r ".resources.graphql.limit // \"${_CB_RL_UNKNOWN}\"") || limit="$_CB_RL_UNKNOWN"
	reset_epoch=$(printf '%s' "$rate_json" | jq -r ".resources.graphql.reset // \"${_CB_RL_UNKNOWN}\"") || reset_epoch="$_CB_RL_UNKNOWN"

	local reset_human="$_CB_RL_UNKNOWN"
	if [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
		local now_epoch
		now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
		if [[ "$now_epoch" -gt 0 ]]; then
			local secs_until_reset=$(( reset_epoch - now_epoch ))
			if [[ "$secs_until_reset" -gt 0 ]]; then
				reset_human="${secs_until_reset}s until reset"
			else
				reset_human="reset imminent"
			fi
		fi
	fi

	local threshold_count="$_CB_RL_UNKNOWN"
	if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]]; then
		threshold_count=$(_compute_threshold_count "$threshold" "$limit") || threshold_count="$_CB_RL_UNKNOWN"
	fi

	# Report 24h trip count if stats helper is available.
	local trip_count_24h="$_CB_RL_UNKNOWN"
	if declare -F pulse_stats_get_24h >/dev/null 2>&1; then
		trip_count_24h=$(pulse_stats_get_24h "pulse_dispatch_circuit_broken" 2>/dev/null) || trip_count_24h="$_CB_RL_UNKNOWN"
	fi

	if [[ -f "$_CIRCUIT_BREAKER_STATE_FILE" ]]; then
		printf 'TRIPPED: remaining=%s/%s (threshold=%s, trips_24h=%s, %s)\n' \
			"$remaining" "$limit" "$threshold_count" "$trip_count_24h" "$reset_human"
	else
		printf 'OK: remaining=%s/%s (threshold=%s, trips_24h=%s, %s)\n' \
			"$remaining" "$limit" "$threshold_count" "$trip_count_24h" "$reset_human"
	fi
	return 0
}

#######################################
# Standalone CLI entry point.
#######################################
_main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
		check)
			is_graphql_budget_sufficient
			return $?
			;;
		status)
			_circuit_breaker_status
			return 0
			;;
		help | --help | -h)
			echo "pulse-rate-limit-circuit-breaker.sh — Pulse-level GraphQL rate-limit circuit breaker (t2690)"
			echo ""
			echo "Usage:"
			echo "  pulse-rate-limit-circuit-breaker.sh check    # exit 0=OK, 1=tripped, 2=API error"
			echo "  pulse-rate-limit-circuit-breaker.sh status   # human-readable status line"
			echo ""
			echo "Environment:"
			echo "  AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD  fraction threshold (default 0.30 = 30%)"
			echo "  AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1     emergency bypass"
			return 0
			;;
		*)
			echo "Unknown command: ${cmd}" >&2
			echo "Run: pulse-rate-limit-circuit-breaker.sh help" >&2
			return 1
			;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
