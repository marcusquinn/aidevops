#!/usr/bin/env bash
# screen-time-helper.sh — Query macOS screen time and maintain persistent history
#
# Data source: macOS Knowledge DB (~/Library/Application Support/Knowledge/knowledgeC.db)
# The Knowledge DB retains ~28 days of /display/isBacklit events.
# This script snapshots daily totals to a JSONL file for long-term history.
#
# Usage:
#   screen-time-helper.sh snapshot          # Append today's screen time to history
#   screen-time-helper.sh query [days]      # Query screen-on hours for last N days
#   screen-time-helper.sh history           # Show accumulated history
#   screen-time-helper.sh profile-stats     # Output stats for profile README
#
set -euo pipefail

KNOWLEDGE_DB="${HOME}/Library/Application Support/Knowledge/knowledgeC.db"
HISTORY_DIR="${HOME}/.aidevops/.agent-workspace/observability"
HISTORY_FILE="${HISTORY_DIR}/screen-time.jsonl"

#######################################
# Compute screen-on hours from Knowledge DB for a given number of past days
# Arguments:
#   $1 - number of days to look back
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_query_screen_hours() {
	local days="$1"

	if [[ ! -f "$KNOWLEDGE_DB" ]]; then
		echo "0"
		return 0
	fi

	local hours
	hours=$(sqlite3 "$KNOWLEDGE_DB" "
	WITH events AS (
		SELECT
			ZCREATIONDATE + 978307200 as ts,
			ZVALUEINTEGER as state
		FROM ZOBJECT
		WHERE ZSTREAMNAME = '/display/isBacklit'
			AND ZCREATIONDATE > (strftime('%s', 'now') - 978307200 - 86400*${days})
	),
	pairs AS (
		SELECT
			e1.ts as on_time,
			MIN(e2.ts) as off_time
		FROM events e1
		JOIN events e2 ON e2.ts > e1.ts AND e2.state = 0
		WHERE e1.state = 1
		GROUP BY e1.ts
	)
	SELECT COALESCE(ROUND(SUM(off_time - on_time) / 3600.0, 1), 0) FROM pairs;" 2>/dev/null || echo "0")

	echo "$hours"
	return 0
}

#######################################
# Compute screen-on hours for a specific date (YYYY-MM-DD)
# Arguments:
#   $1 - date string (YYYY-MM-DD)
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_query_screen_hours_for_date() {
	local target_date="$1"

	if [[ ! -f "$KNOWLEDGE_DB" ]]; then
		echo "0"
		return 0
	fi

	local start_epoch
	local end_epoch
	# Convert date to epoch, subtract Core Data epoch offset (978307200)
	start_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "${target_date} 00:00:00" "+%s" 2>/dev/null || date -d "${target_date} 00:00:00" "+%s" 2>/dev/null)
	end_epoch=$((start_epoch + 86400))
	local cd_start=$((start_epoch - 978307200))
	local cd_end=$((end_epoch - 978307200))

	local hours
	hours=$(sqlite3 "$KNOWLEDGE_DB" "
	WITH events AS (
		SELECT
			ZCREATIONDATE + 978307200 as ts,
			ZVALUEINTEGER as state
		FROM ZOBJECT
		WHERE ZSTREAMNAME = '/display/isBacklit'
			AND ZCREATIONDATE >= ${cd_start}
			AND ZCREATIONDATE < ${cd_end}
	),
	pairs AS (
		SELECT
			e1.ts as on_time,
			MIN(e2.ts) as off_time
		FROM events e1
		JOIN events e2 ON e2.ts > e1.ts AND e2.state = 0
		WHERE e1.state = 1
		GROUP BY e1.ts
	)
	SELECT COALESCE(ROUND(SUM(off_time - on_time) / 3600.0, 1), 0) FROM pairs;" 2>/dev/null || echo "0")

	echo "$hours"
	return 0
}

#######################################
# Snapshot: record daily screen time totals to persistent JSONL
# Snapshots each day in the Knowledge DB that isn't already in history.
# Returns: 0
#######################################
cmd_snapshot() {
	mkdir -p "$HISTORY_DIR"

	# Get the date range available in Knowledge DB
	local earliest_date
	earliest_date=$(sqlite3 "$KNOWLEDGE_DB" "
		SELECT date(MIN(ZCREATIONDATE + 978307200), 'unixepoch', 'localtime')
		FROM ZOBJECT WHERE ZSTREAMNAME = '/display/isBacklit';" 2>/dev/null || echo "")

	if [[ -z "$earliest_date" ]]; then
		echo "No screen time data available in Knowledge DB"
		return 0
	fi

	local today
	today=$(date +%Y-%m-%d)

	# Get dates already in history
	local existing_dates=""
	if [[ -f "$HISTORY_FILE" ]]; then
		existing_dates=$(jq -r '.date' "$HISTORY_FILE" 2>/dev/null | sort -u || echo "")
	fi

	local current_date="$earliest_date"
	local added=0

	while [[ "$current_date" < "$today" ]]; do
		# Skip if already recorded
		if echo "$existing_dates" | grep -q "^${current_date}$" 2>/dev/null; then
			current_date=$(date -j -v+1d -f "%Y-%m-%d" "$current_date" "+%Y-%m-%d" 2>/dev/null || date -d "${current_date} + 1 day" "+%Y-%m-%d" 2>/dev/null)
			continue
		fi

		local hours
		hours=$(_query_screen_hours_for_date "$current_date")

		# Only record days with actual screen time
		if [[ "$hours" != "0" && "$hours" != "0.0" ]]; then
			local record
			record=$(jq -cn \
				--arg date "$current_date" \
				--arg hours "$hours" \
				--arg hostname "$(hostname -s)" \
				'{date: $date, screen_hours: ($hours | tonumber), hostname: $hostname, recorded_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}')
			echo "$record" >>"$HISTORY_FILE"
			added=$((added + 1))
		fi

		current_date=$(date -j -v+1d -f "%Y-%m-%d" "$current_date" "+%Y-%m-%d" 2>/dev/null || date -d "${current_date} + 1 day" "+%Y-%m-%d" 2>/dev/null)
	done

	echo "Snapshot complete: ${added} new day(s) added to ${HISTORY_FILE}"
	return 0
}

#######################################
# Query: show screen-on hours for last N days
# Arguments:
#   $1 - number of days (default: 1)
# Returns: 0
#######################################
cmd_query() {
	local days="${1:-1}"
	local hours
	hours=$(_query_screen_hours "$days")
	echo "${hours}h screen-on time in last ${days} day(s)"
	return 0
}

#######################################
# History: show accumulated screen time history
# Returns: 0
#######################################
cmd_history() {
	if [[ ! -f "$HISTORY_FILE" ]]; then
		echo "No history file found. Run 'snapshot' first."
		return 0
	fi

	local total_days
	local total_hours
	local earliest
	local latest
	total_days=$(wc -l <"$HISTORY_FILE" | tr -d ' ')
	total_hours=$(jq -s '[.[].screen_hours] | add | . * 10 | round / 10' "$HISTORY_FILE" 2>/dev/null || echo "0")
	earliest=$(jq -s 'min_by(.date) | .date' "$HISTORY_FILE" 2>/dev/null || echo "unknown")
	latest=$(jq -s 'max_by(.date) | .date' "$HISTORY_FILE" 2>/dev/null || echo "unknown")

	echo "Screen time history: ${total_days} days, ${total_hours}h total"
	echo "Range: ${earliest} to ${latest}"
	return 0
}

#######################################
# Profile stats: output stats for profile README in JSON
# Combines Knowledge DB (live) with history (accumulated)
# Returns: 0
#######################################
cmd_profile_stats() {
	# Live data from Knowledge DB
	local today_hours
	local week_hours
	today_hours=$(_query_screen_hours 1)
	week_hours=$(_query_screen_hours 7)

	# For 30 days: use Knowledge DB (has ~28 days)
	local month_hours
	month_hours=$(_query_screen_hours 30)

	# For 365 days: use accumulated history if available, else extrapolate
	local year_hours
	if [[ -f "$HISTORY_FILE" ]]; then
		local history_days
		local history_total
		history_days=$(wc -l <"$HISTORY_FILE" | tr -d ' ')
		history_total=$(jq -s '[.[].screen_hours] | add' "$HISTORY_FILE" 2>/dev/null || echo "0")

		if [[ "$history_days" -gt 0 ]]; then
			# Use actual accumulated data + extrapolate remaining days
			local daily_avg
			daily_avg=$(echo "scale=2; $history_total / $history_days" | bc)
			if [[ "$history_days" -ge 365 ]]; then
				# Have a full year of data — use last 365 days from history
				year_hours=$(jq -s '[.[-365:][].screen_hours] | add | . * 10 | round / 10' "$HISTORY_FILE" 2>/dev/null || echo "0")
			else
				# Extrapolate from available data
				year_hours=$(echo "scale=1; $daily_avg * 365" | bc)
			fi
		else
			year_hours=$(echo "scale=1; $month_hours / 28 * 365" | bc 2>/dev/null || echo "0")
		fi
	else
		# No history — extrapolate from 28-day Knowledge DB data
		year_hours=$(echo "scale=1; $month_hours / 28 * 365" | bc 2>/dev/null || echo "0")
	fi

	jq -n \
		--arg today "$today_hours" \
		--arg week "$week_hours" \
		--arg month "$month_hours" \
		--arg year "$year_hours" \
		'{
			today_hours: ($today | tonumber),
			week_hours: ($week | tonumber),
			month_hours: ($month | tonumber),
			year_hours: ($year | tonumber),
			month_note: "from ~28 days of macOS Knowledge DB data"
		}'

	return 0
}

# --- Main dispatch ---
case "${1:-help}" in
snapshot) cmd_snapshot ;;
query) cmd_query "${2:-1}" ;;
history) cmd_history ;;
profile-stats) cmd_profile_stats ;;
help | *)
	echo "Usage: screen-time-helper.sh {snapshot|query [days]|history|profile-stats}"
	echo ""
	echo "Commands:"
	echo "  snapshot       Record daily screen time to persistent history"
	echo "  query [days]   Query screen-on hours for last N days (default: 1)"
	echo "  history        Show accumulated history summary"
	echo "  profile-stats  Output stats for profile README (JSON)"
	return 0 2>/dev/null || exit 0
	;;
esac
