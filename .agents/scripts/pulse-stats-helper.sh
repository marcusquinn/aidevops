#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-stats-helper.sh — Lightweight operational counter for pulse metrics (t2424, GH#20030)
#
# Persists named counters to ~/.aidevops/logs/pulse-stats.json using jq-based
# atomic updates. Each counter records per-event timestamps so 24h rolling
# windows can be computed without a separate cron sweep.
#
# Supported counters (initial set):
#   pre_dispatch_aborts — pre-dispatch eligibility gate aborted dispatch
#
# The `aidevops status` command reads this file via `pulse_stats_get_24h`
# to show operator-visible churn metrics.
#
# Usage (sourced from pre-dispatch-eligibility-helper.sh or pulse-dispatch-core.sh):
#   pulse_stats_increment <counter_name>   — add one timestamp event
#   pulse_stats_get_24h <counter_name>     — print count of events in last 24h
#
# Usage (standalone CLI):
#   pulse-stats-helper.sh increment <counter_name>
#   pulse-stats-helper.sh get-24h <counter_name>
#   pulse-stats-helper.sh status           — human-readable summary
#   pulse-stats-helper.sh reset <counter_name>  — clear a counter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared constants if available (provides color helpers etc.).
# shellcheck source=shared-constants.sh
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

PULSE_STATS_FILE="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

#######################################
# Ensure the stats file exists with a valid JSON structure.
# Idempotent — safe to call multiple times.
#######################################
_pulse_stats_ensure_file() {
	local dir
	dir="$(dirname "$PULSE_STATS_FILE")"
	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir" 2>/dev/null || return 0
	fi
	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		printf '{"counters":{}}\n' >"$PULSE_STATS_FILE" 2>/dev/null || return 0
	fi
	return 0
}

#######################################
# Increment a named counter by adding the current Unix timestamp.
# Uses jq to append to the counter's timestamp array atomically
# (single write via temp file + mv).
#
# Args:
#   $1 - counter_name (e.g. "pre_dispatch_aborts")
#
# Non-fatal: any jq/file failure is logged but does not propagate.
#######################################
pulse_stats_increment() {
	local counter_name="${1:-unknown}"
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0

	_pulse_stats_ensure_file || return 0

	local tmp_file
	tmp_file=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-XXXXXX.json") || return 0

	# Append timestamp to counter array; create counter if absent.
	# jq -e fails if the input JSON is invalid → we fall back to no-op.
	jq --arg name "$counter_name" --argjson ts "$now_epoch" \
		'.counters[$name] += [$ts]' \
		"$PULSE_STATS_FILE" >"$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 0; }

	mv "$tmp_file" "$PULSE_STATS_FILE" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

#######################################
# Return the count of events for a counter in the last 24 hours.
# Prints the count as a plain integer to stdout.
#
# Args:
#   $1 - counter_name
#
# Output: integer (0 if file missing, counter absent, or any error)
#######################################
pulse_stats_get_24h() {
	local counter_name="${1:-unknown}"

	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		printf '0\n'
		return 0
	fi

	local cutoff
	cutoff=$(( $(date +%s 2>/dev/null || printf '0') - 86400 ))

	local count
	count=$(jq -r --arg name "$counter_name" --argjson cutoff "$cutoff" \
		'(.counters[$name] // []) | [.[] | select(. > $cutoff)] | length' \
		"$PULSE_STATS_FILE" 2>/dev/null) || count=0

	printf '%s\n' "${count:-0}"
	return 0
}

#######################################
# Print a human-readable summary of all counters (last 24h).
#######################################
pulse_stats_status() {
	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		echo "  No pulse stats recorded yet."
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	local cutoff=$(( now_epoch - 86400 ))

	local names
	names=$(jq -r '.counters | keys[]' "$PULSE_STATS_FILE" 2>/dev/null) || names=""

	if [[ -z "$names" ]]; then
		echo "  No counters recorded yet."
		return 0
	fi

	local name count
	while IFS= read -r name; do
		[[ -z "$name" ]] && continue
		count=$(jq -r --arg name "$name" --argjson cutoff "$cutoff" \
			'(.counters[$name] // []) | [.[] | select(. > $cutoff)] | length' \
			"$PULSE_STATS_FILE" 2>/dev/null) || count=0
		printf '  %-40s %s (last 24h)\n' "${name}:" "${count:-0}"
	done <<<"$names"

	return 0
}

#######################################
# Reset (clear) a counter's event history.
# Args: $1 - counter_name
#######################################
pulse_stats_reset() {
	local counter_name="${1:-}"
	if [[ -z "$counter_name" ]]; then
		echo "Usage: pulse_stats_reset <counter_name>" >&2
		return 1
	fi

	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		return 0
	fi

	local tmp_file
	tmp_file=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-XXXXXX.json") || return 1

	jq --arg name "$counter_name" \
		'del(.counters[$name])' \
		"$PULSE_STATS_FILE" >"$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }

	mv "$tmp_file" "$PULSE_STATS_FILE" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
	echo "Counter '${counter_name}' reset."
	return 0
}

#######################################
# Standalone CLI entry point.
#######################################
_main() {
	local cmd="${1:-status}"
	shift || true

	case "$cmd" in
		increment)
			if [[ $# -lt 1 ]]; then
				echo "Usage: pulse-stats-helper.sh increment <counter_name>" >&2
				return 1
			fi
			local increment_counter="$1"
			pulse_stats_increment "$increment_counter"
			return 0
			;;
		get-24h)
			if [[ $# -lt 1 ]]; then
				echo "Usage: pulse-stats-helper.sh get-24h <counter_name>" >&2
				return 1
			fi
			local get24h_counter="$1"
			pulse_stats_get_24h "$get24h_counter"
			return 0
			;;
		status)
			echo "Pulse Stats (last 24h):"
			pulse_stats_status
			return 0
			;;
		reset)
			if [[ $# -lt 1 ]]; then
				echo "Usage: pulse-stats-helper.sh reset <counter_name>" >&2
				return 1
			fi
			local reset_counter="$1"
			pulse_stats_reset "$reset_counter"
			return 0
			;;
		help | --help | -h)
			echo "pulse-stats-helper.sh — Pulse operational counter (t2424)"
			echo ""
			echo "Usage:"
			echo "  pulse-stats-helper.sh increment <counter>   Add event to counter"
			echo "  pulse-stats-helper.sh get-24h <counter>     Count events last 24h"
			echo "  pulse-stats-helper.sh status                Human-readable summary"
			echo "  pulse-stats-helper.sh reset <counter>       Clear a counter"
			echo ""
			echo "Stats file: ${PULSE_STATS_FILE}"
			return 0
			;;
		*)
			echo "Unknown command: ${cmd}. Run: pulse-stats-helper.sh help" >&2
			return 1
			;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
