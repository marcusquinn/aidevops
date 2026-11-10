#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# screen-time-helper.sh — Cross-platform observed screen-time commands

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY_DIR="${HOME}/.aidevops/.agent-workspace/observability"
HISTORY_FILE="${HISTORY_DIR}/screen-time.jsonl"
OS_TYPE="${AIDEVOPS_SCREEN_TIME_OS_TYPE:-$(uname -s)}"
KNOWLEDGE_DB="${AIDEVOPS_KNOWLEDGE_DB:-${HOME}/Library/Application Support/Knowledge/knowledgeC.db}"
INTERVAL_ENGINE="${SCRIPT_DIR}/screen-time-interval-engine.py"

#######################################
# Invoke the interval engine with common source arguments.
# Arguments:
#   $1..N - engine command and arguments
# Returns: engine exit status
#######################################
_screen_time_engine() {
	python3 "$INTERVAL_ENGINE" "$@" \
		--os-type "$OS_TYPE" \
		--db "$KNOWLEDGE_DB" \
		--history "$HISTORY_FILE"
	return $?
}

#######################################
# Advance an ISO local date by one calendar day.
# Arguments:
#   $1 - YYYY-MM-DD
# Outputs: YYYY-MM-DD
#######################################
_next_date() {
	local current_date="$1"
	_screen_time_engine next-date --date "$current_date"
	return $?
}

#######################################
# Clamp and validate an observed daily hour value.
# Arguments:
#   $1 - candidate numeric value
# Outputs: decimal in [0,24], or unavailable
#######################################
_validated_daily_hours() {
	local candidate="$1"
	if [[ ! "$candidate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		printf '%s\n' unavailable
		return 0
	fi
	awk -v value="$candidate" 'BEGIN { if (value > 24) value=24; printf "%.1f\n", value }'
	return 0
}

#######################################
# True when a recomputed daily value exceeds the recorded one.
# Arguments:
#   $1 - recomputed hours
#   $2 - recorded hours (empty when the date is unrecorded)
# Returns: 0 when the value should be appended
#######################################
_snapshot_value_grew() {
	local hours="$1"
	local recorded="$2"
	if [[ -z "$recorded" ]]; then
		return 0
	fi
	awk -v new="$hours" -v old="$recorded" 'BEGIN { exit !(new > old + 0.05) }'
	return $?
}

#######################################
# Record each previously unseen observed local date, and raise the last few
# completed days when later evidence grew them (display spans are written when
# they end; history is append-only and the last row per date wins).
#######################################
cmd_snapshot() {
	mkdir -p "$HISTORY_DIR"
	local earliest_date today existing_dates revisable current_date added collector recorded
	earliest_date=$(_screen_time_engine earliest)
	if [[ -z "$earliest_date" ]]; then
		echo "No observed screen-time source data available"
		return 0
	fi
	today=$(date +%Y-%m-%d)
	# Only dates the current collector accepts count as recorded: on Linux,
	# legacy login-session proxy rows must not block activity-based rows.
	existing_dates=$(_screen_time_engine history-dates 2>/dev/null || true)
	revisable=$(_screen_time_engine revisable-dates 2>/dev/null || true)
	collector=$(_screen_time_engine collector)
	current_date="$earliest_date"
	added=0
	while [[ "$current_date" < "$today" ]]; do
		recorded=""
		if [[ -n "$existing_dates" ]] && grep -qxF "$current_date" <<<"$existing_dates"; then
			recorded=$(awk -v date="$current_date" '$1 == date { print $2 }' <<<"$revisable")
			if [[ -z "$recorded" ]]; then
				current_date=$(_next_date "$current_date")
				continue
			fi
		fi
		local raw_hours hours record
		raw_hours=$(_screen_time_engine date --date "$current_date")
		hours=$(_validated_daily_hours "$raw_hours")
		if [[ "$hours" != "unavailable" ]] && _snapshot_value_grew "$hours" "$recorded"; then
			record=$(jq -cn \
				--arg date "$current_date" \
				--arg hours "$hours" \
				--arg collector "$collector" \
				--arg hostname "$(hostname -s 2>/dev/null || hostname)" \
				'{date:$date,screen_hours:($hours|tonumber),status:"observed",source:"interval-engine",collector:$collector,hostname:$hostname,recorded_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}')
			printf '%s\n' "$record" >>"$HISTORY_FILE"
			added=$((added + 1))
		fi
		current_date=$(_next_date "$current_date")
	done
	echo "Snapshot complete: ${added} new or revised local-date observation(s) added to ${HISTORY_FILE}"
	return 0
}

#######################################
# Query rolling screen-on hours.
# Arguments:
#   $1 - number of days
#######################################
cmd_query() {
	local days="${1:-1}"
	local hours
	hours=$(_screen_time_engine query --days "$days")
	if [[ "$hours" == "unavailable" ]]; then
		echo "Screen-time source unavailable for last ${days} day(s)"
	else
		echo "${hours}h screen-on time in last ${days} day(s)"
	fi
	return 0
}

#######################################
# Show validated history summary and malformed-row count.
#######################################
cmd_history() {
	if [[ ! -f "$HISTORY_FILE" ]]; then
		echo "No history file found. Run 'snapshot' first."
		return 0
	fi
	local summary
	summary=$(_screen_time_engine history-summary)
	printf '%s\n' "$summary" | jq -r '"Screen time history: \(.valid_rows) valid day(s), \(.total_hours)h total\nRange: \(.earliest // "unknown") to \(.latest // "unknown")\nSkipped malformed rows: \(.skipped_rows)"'
	return 0
}

#######################################
# Emit profile statistics JSON.
#######################################
cmd_profile_stats() {
	_screen_time_engine profile
	return $?
}

#######################################
# Emit human input-activity profile JSON (time from each keyboard/mouse
# input until the idle cut-off). On Linux this is the same measure as
# profile-stats; on macOS it complements display-on screen time.
#######################################
cmd_input_stats() {
	if _screen_time_engine input-profile; then
		return 0
	fi
	return 1
}

#######################################
# Record one human-input activity sample (Linux and macOS).
# A per-minute scheduler builds the active intervals that input-stats
# (and, on Linux, profile-stats and snapshot) read.
#######################################
cmd_sample() {
	mkdir -p "$HISTORY_DIR"
	_screen_time_engine sample
	return $?
}

case "${1:-help}" in
snapshot) cmd_snapshot ;;
sample) cmd_sample ;;
query) cmd_query "${2:-1}" ;;
history) cmd_history ;;
profile-stats) cmd_profile_stats ;;
input-stats) cmd_input_stats ;;
help | *)
	echo "Usage: screen-time-helper.sh {snapshot|sample|query [days]|history|profile-stats|input-stats}"
	echo "Platform: ${OS_TYPE}"
	return 0 2>/dev/null || exit 0
	;;
esac
