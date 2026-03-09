#!/usr/bin/env bash
# screen-time-helper.sh — Query screen time and maintain persistent history
#
# Cross-platform: macOS and Linux
#
# macOS data source: Knowledge DB (~/Library/Application Support/Knowledge/knowledgeC.db)
#   - /display/isBacklit events (screen on=1, off=0)
#   - Retains ~28 days of data
#
# Linux data source: systemd-logind session events via journalctl
#   - Session unlock/lock events from systemd-logind
#   - Retention depends on journald config (typically weeks to months)
#   - Falls back to wtmp login sessions via 'last' command
#   - Falls back to /proc/uptime for simple single-user systems
#   - Works on both X11 and Wayland (no display server dependency)
#
# Usage:
#   screen-time-helper.sh snapshot          # Append today's screen time to history
#   screen-time-helper.sh query [days]      # Query screen-on hours for last N days
#   screen-time-helper.sh history           # Show accumulated history
#   screen-time-helper.sh profile-stats     # Output stats for profile README
#
set -euo pipefail

HISTORY_DIR="${HOME}/.aidevops/.agent-workspace/observability"
HISTORY_FILE="${HISTORY_DIR}/screen-time.jsonl"
OS_TYPE="$(uname -s)"

# macOS-specific paths
KNOWLEDGE_DB="${HOME}/Library/Application Support/Knowledge/knowledgeC.db"

# ============================================================
# macOS: Knowledge DB queries
# ============================================================

#######################################
# [macOS] Compute screen-on hours from Knowledge DB for a given number of past days
# Arguments:
#   $1 - number of days to look back
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_macos_query_screen_hours() {
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
# [macOS] Compute screen-on hours for a specific date (YYYY-MM-DD)
# Arguments:
#   $1 - date string (YYYY-MM-DD)
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_macos_query_screen_hours_for_date() {
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
# [macOS] Get earliest date available in Knowledge DB
# Returns: 0
# Outputs: YYYY-MM-DD or empty string
#######################################
_macos_earliest_date() {
	if [[ ! -f "$KNOWLEDGE_DB" ]]; then
		echo ""
		return 0
	fi

	sqlite3 "$KNOWLEDGE_DB" "
		SELECT date(MIN(ZCREATIONDATE + 978307200), 'unixepoch', 'localtime')
		FROM ZOBJECT WHERE ZSTREAMNAME = '/display/isBacklit';" 2>/dev/null || echo ""
	return 0
}

# ============================================================
# Linux: systemd-logind session tracking
# ============================================================

#######################################
# [Linux] Compute screen-on hours from logind session events for last N days
#
# Three methods tried in order:
#   1. systemd-logind session events via journalctl (most accurate)
#   2. wtmp login sessions via 'last' command (widely available)
#   3. /proc/uptime fallback (crude — assumes screen on = system on)
#
# Arguments:
#   $1 - number of days to look back
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_linux_query_screen_hours() {
	local days="$1"

	# Method 1: journalctl logind session events
	if command -v journalctl >/dev/null 2>&1; then
		local hours
		hours=$(_linux_logind_hours "$days")
		if [[ "$hours" != "0" && "$hours" != "0.0" ]]; then
			echo "$hours"
			return 0
		fi
	fi

	# Method 2: wtmp login sessions via 'last'
	if command -v last >/dev/null 2>&1; then
		local hours
		hours=$(_linux_last_hours "$days")
		if [[ "$hours" != "0" && "$hours" != "0.0" ]]; then
			echo "$hours"
			return 0
		fi
	fi

	# Method 3: /proc/uptime fallback (system uptime as proxy)
	# Only useful for "today" or short periods on single-user machines
	if [[ -f /proc/uptime && "$days" -le 1 ]]; then
		local uptime_secs
		uptime_secs=$(awk '{printf "%.0f", $1}' /proc/uptime)
		local uptime_hours
		uptime_hours=$(awk "BEGIN {printf \"%.1f\", ${uptime_secs} / 3600}")
		# Cap at 24h for a single day
		if awk "BEGIN {exit ($uptime_hours > 24) ? 0 : 1}" 2>/dev/null; then
			uptime_hours="24.0"
		fi
		echo "$uptime_hours"
		return 0
	fi

	echo "0"
	return 0
}

#######################################
# [Linux] Parse logind session events from journalctl
#
# Looks for session start/stop and lid open/close events from systemd-logind.
# Session active time = time between session start and session stop/lock.
#
# Arguments:
#   $1 - number of days to look back
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_linux_logind_hours() {
	local days="$1"
	local since_date
	since_date=$(date -d "${days} days ago" "+%Y-%m-%d" 2>/dev/null || echo "")

	if [[ -z "$since_date" ]]; then
		echo "0"
		return 0
	fi

	local current_user
	current_user=$(whoami)

	# Extract timestamped session events for the current user
	local events_file
	events_file=$(mktemp)

	journalctl --since "$since_date" -u systemd-logind.service --no-pager -o short-iso 2>/dev/null |
		grep -iE "(New session|Removed session|Session .* logged out|Lid closed|Lid opened)" |
		grep -i "$current_user" |
		while IFS= read -r line; do
			local ts
			local event_type
			ts=$(echo "$line" | awk '{print $1}')
			if echo "$line" | grep -qi "New session\|Lid opened"; then
				event_type="ON"
			else
				event_type="OFF"
			fi
			echo "${ts} ${event_type}"
		done >"$events_file" 2>/dev/null

	local total_seconds=0

	if [[ -s "$events_file" ]]; then
		# Parse ON/OFF event pairs
		local last_on_epoch=0
		while IFS=' ' read -r ts event_type; do
			local epoch
			epoch=$(date -d "$ts" "+%s" 2>/dev/null || echo "0")
			if [[ "$event_type" == "ON" && "$last_on_epoch" -eq 0 ]]; then
				last_on_epoch=$epoch
			elif [[ "$event_type" == "OFF" && "$last_on_epoch" -gt 0 ]]; then
				local duration=$((epoch - last_on_epoch))
				# Cap individual sessions at 24h (sanity check)
				if [[ "$duration" -gt 86400 ]]; then
					duration=86400
				fi
				total_seconds=$((total_seconds + duration))
				last_on_epoch=0
			fi
		done <"$events_file"

		# If last event was ON (still active), count time until now
		if [[ "$last_on_epoch" -gt 0 ]]; then
			local now_epoch
			now_epoch=$(date "+%s")
			local remaining=$((now_epoch - last_on_epoch))
			if [[ "$remaining" -gt 86400 ]]; then
				remaining=86400
			fi
			total_seconds=$((total_seconds + remaining))
		fi
	fi

	rm -f "$events_file"

	local hours
	hours=$(awk "BEGIN {printf \"%.1f\", ${total_seconds} / 3600}")
	echo "$hours"
	return 0
}

#######################################
# [Linux] Parse login sessions from 'last' command
#
# Uses wtmp records to compute total logged-in time.
# Less accurate than logind (doesn't track screen lock) but widely available.
#
# Arguments:
#   $1 - number of days to look back
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_linux_last_hours() {
	local days="$1"
	local current_user
	current_user=$(whoami)
	local total_seconds=0

	# Parse completed sessions with duration
	while IFS= read -r line; do
		local duration
		duration=$(echo "$line" | grep -oE '\(([0-9]+:[0-9]+)\)' | tr -d '()' || echo "")
		if [[ -n "$duration" ]]; then
			local dur_hours
			local dur_mins
			dur_hours=$(echo "$duration" | cut -d: -f1)
			dur_mins=$(echo "$duration" | cut -d: -f2)
			local dur_secs=$(((dur_hours * 3600) + (dur_mins * 60)))
			total_seconds=$((total_seconds + dur_secs))
		fi
	done < <(last -s "-${days}days" "$current_user" 2>/dev/null |
		grep -v "^$\|wtmp begins\|still logged in\|reboot\|shutdown" || true)

	# Count "still logged in" sessions
	local still_logged
	still_logged=$(last -s "-${days}days" "$current_user" 2>/dev/null |
		grep -c "still logged in" || echo "0")
	if [[ "$still_logged" -gt 0 ]]; then
		# Estimate current session duration from loginctl
		local current_session_secs=0
		if command -v loginctl >/dev/null 2>&1; then
			local session_id
			session_id=$(loginctl show-user "$current_user" -p Sessions --value 2>/dev/null | awk '{print $1}')
			if [[ -n "$session_id" ]]; then
				local session_since
				session_since=$(loginctl show-session "$session_id" -p Timestamp --value 2>/dev/null || echo "")
				if [[ -n "$session_since" ]]; then
					local session_epoch
					session_epoch=$(date -d "$session_since" "+%s" 2>/dev/null || echo "0")
					local now_epoch
					now_epoch=$(date "+%s")
					current_session_secs=$((now_epoch - session_epoch))
				fi
			fi
		fi
		total_seconds=$((total_seconds + current_session_secs))
	fi

	local hours
	hours=$(awk "BEGIN {printf \"%.1f\", ${total_seconds} / 3600}")
	echo "$hours"
	return 0
}

#######################################
# [Linux] Compute screen-on hours for a specific date (YYYY-MM-DD)
# Arguments:
#   $1 - date string (YYYY-MM-DD)
# Returns: 0
# Outputs: hours as decimal to stdout
#######################################
_linux_query_screen_hours_for_date() {
	local target_date="$1"
	local current_user
	current_user=$(whoami)
	local total_seconds=0

	# Method 1: journalctl for the specific date
	if command -v journalctl >/dev/null 2>&1; then
		local next_date
		next_date=$(date -d "${target_date} + 1 day" "+%Y-%m-%d" 2>/dev/null || echo "")

		if [[ -n "$next_date" ]]; then
			local events_file
			events_file=$(mktemp)

			journalctl --since "$target_date" --until "$next_date" \
				-u systemd-logind.service --no-pager -o short-iso 2>/dev/null |
				grep -iE "(New session|Removed session|Session .* logged out|Lid closed|Lid opened)" |
				grep -i "$current_user" |
				while IFS= read -r line; do
					local ts
					local event_type
					ts=$(echo "$line" | awk '{print $1}')
					if echo "$line" | grep -qi "New session\|Lid opened"; then
						event_type="ON"
					else
						event_type="OFF"
					fi
					echo "${ts} ${event_type}"
				done >"$events_file" 2>/dev/null

			if [[ -s "$events_file" ]]; then
				local last_on_epoch=0
				local day_end
				day_end=$(date -d "${next_date} 00:00:00" "+%s" 2>/dev/null || echo "0")

				while IFS=' ' read -r ts event_type; do
					local epoch
					epoch=$(date -d "$ts" "+%s" 2>/dev/null || echo "0")
					if [[ "$event_type" == "ON" && "$last_on_epoch" -eq 0 ]]; then
						last_on_epoch=$epoch
					elif [[ "$event_type" == "OFF" && "$last_on_epoch" -gt 0 ]]; then
						local duration=$((epoch - last_on_epoch))
						total_seconds=$((total_seconds + duration))
						last_on_epoch=0
					fi
				done <"$events_file"

				# If still on at end of day, count until midnight
				if [[ "$last_on_epoch" -gt 0 && "$day_end" -gt 0 ]]; then
					local remaining=$((day_end - last_on_epoch))
					total_seconds=$((total_seconds + remaining))
				fi
			fi

			rm -f "$events_file"
		fi
	fi

	# Method 2: fallback to 'last' command for the specific date
	if [[ "$total_seconds" -eq 0 ]] && command -v last >/dev/null 2>&1; then
		# Match date in 'last' output format (e.g., "Mon Mar  9")
		local date_pattern
		date_pattern=$(date -d "$target_date" "+%b %e" 2>/dev/null || echo "NOMATCH")

		while IFS= read -r line; do
			local duration
			duration=$(echo "$line" | grep -oE '\(([0-9]+:[0-9]+)\)' | tr -d '()' || echo "")
			if [[ -n "$duration" ]]; then
				local dur_hours
				local dur_mins
				dur_hours=$(echo "$duration" | cut -d: -f1)
				dur_mins=$(echo "$duration" | cut -d: -f2)
				local dur_secs=$(((dur_hours * 3600) + (dur_mins * 60)))
				total_seconds=$((total_seconds + dur_secs))
			fi
		done < <(last "$current_user" 2>/dev/null |
			grep "$date_pattern" |
			grep -v "^$\|wtmp begins\|reboot\|shutdown" || true)
	fi

	local hours
	hours=$(awk "BEGIN {printf \"%.1f\", ${total_seconds} / 3600}")
	echo "$hours"
	return 0
}

#######################################
# [Linux] Get earliest date available in journalctl or wtmp
# Returns: 0
# Outputs: YYYY-MM-DD or empty string
#######################################
_linux_earliest_date() {
	# Try journalctl first
	if command -v journalctl >/dev/null 2>&1; then
		local earliest
		earliest=$(journalctl -u systemd-logind.service --no-pager -o short-iso 2>/dev/null |
			head -1 | awk '{print $1}' | cut -dT -f1 || echo "")
		if [[ -n "$earliest" ]]; then
			echo "$earliest"
			return 0
		fi
	fi

	# Fallback: use wtmp via last
	if command -v last >/dev/null 2>&1; then
		local wtmp_line
		wtmp_line=$(last -R 2>/dev/null | tail -1 || echo "")
		if [[ -n "$wtmp_line" ]]; then
			# Parse "wtmp begins Mon Mar  9 00:00:00 2026" format
			local earliest
			earliest=$(echo "$wtmp_line" | grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9]{2} [0-9:]{8} [0-9]{4}' |
				xargs -I{} date -d "{}" "+%Y-%m-%d" 2>/dev/null || echo "")
			if [[ -n "$earliest" ]]; then
				echo "$earliest"
				return 0
			fi
		fi
	fi

	echo ""
	return 0
}

# ============================================================
# Platform dispatcher — routes to OS-specific implementations
# ============================================================

#######################################
# Query screen-on hours for last N days (cross-platform)
# Arguments:
#   $1 - number of days to look back
# Returns: 0
#######################################
_query_screen_hours() {
	local days="$1"
	case "$OS_TYPE" in
	Darwin) _macos_query_screen_hours "$days" ;;
	Linux) _linux_query_screen_hours "$days" ;;
	*)
		echo "0"
		return 0
		;;
	esac
}

#######################################
# Query screen-on hours for a specific date (cross-platform)
# Arguments:
#   $1 - date string (YYYY-MM-DD)
# Returns: 0
#######################################
_query_screen_hours_for_date() {
	local target_date="$1"
	case "$OS_TYPE" in
	Darwin) _macos_query_screen_hours_for_date "$target_date" ;;
	Linux) _linux_query_screen_hours_for_date "$target_date" ;;
	*)
		echo "0"
		return 0
		;;
	esac
}

#######################################
# Get earliest available date (cross-platform)
# Returns: 0
#######################################
_earliest_date() {
	case "$OS_TYPE" in
	Darwin) _macos_earliest_date ;;
	Linux) _linux_earliest_date ;;
	*)
		echo ""
		return 0
		;;
	esac
}

# ============================================================
# Commands (platform-independent)
# ============================================================

#######################################
# Advance a date by one day (cross-platform)
# Arguments:
#   $1 - date string (YYYY-MM-DD)
# Returns: 0
# Outputs: next date as YYYY-MM-DD
#######################################
_next_date() {
	local current="$1"
	# macOS date
	date -j -v+1d -f "%Y-%m-%d" "$current" "+%Y-%m-%d" 2>/dev/null ||
		date -d "${current} + 1 day" "+%Y-%m-%d" 2>/dev/null ||
		echo "$current"
	return 0
}

#######################################
# Snapshot: record daily screen time totals to persistent JSONL
# Snapshots each day available that isn't already in history.
# Returns: 0
#######################################
cmd_snapshot() {
	mkdir -p "$HISTORY_DIR"

	local earliest_date
	earliest_date=$(_earliest_date)

	if [[ -z "$earliest_date" ]]; then
		echo "No screen time data available"
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
			current_date=$(_next_date "$current_date")
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
				--arg hostname "$(hostname -s 2>/dev/null || hostname)" \
				'{date: $date, screen_hours: ($hours | tonumber), hostname: $hostname, recorded_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}')
			echo "$record" >>"$HISTORY_FILE"
			added=$((added + 1))
		fi

		current_date=$(_next_date "$current_date")
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
# Combines live queries with accumulated history
# Returns: 0
#######################################
cmd_profile_stats() {
	# Live data — rolling 24h window instead of "today since midnight"
	local day_hours
	local week_hours
	day_hours=$(_query_screen_hours 1)
	week_hours=$(_query_screen_hours 7)

	# For 28 days: use live query
	local month_hours
	month_hours=$(_query_screen_hours 28)

	# Fallback to accumulated history when live queries return 0
	# This happens when the launchd job runs without Knowledge DB access
	# (TCC/Full Disk Access not granted in non-interactive context)
	local history_days=0
	local history_total=0 hist_1d=0 hist_7d=0 hist_28d=0 hist_365d=0
	if [[ -f "$HISTORY_FILE" ]]; then
		history_days=$(wc -l <"$HISTORY_FILE" | tr -d ' ')
		if [[ "$history_days" -gt 0 ]]; then
			# Single jq pass for all history stats
			local history_stats
			history_stats=$(jq -rs '
				. as $all |
				[
					([$all[].screen_hours] | add // 0),
					([$all[-1:][].screen_hours] | add // 0 | . * 10 | round / 10),
					([$all[-7:][].screen_hours] | add // 0 | . * 10 | round / 10),
					([$all[-28:][].screen_hours] | add // 0 | . * 10 | round / 10),
					([$all[-365:][].screen_hours] | add // 0 | . * 10 | round / 10)
				] | @tsv
			' "$HISTORY_FILE" 2>/dev/null) || true
			if [[ -n "$history_stats" ]]; then
				read -r history_total hist_1d hist_7d hist_28d hist_365d <<<"$history_stats"
			fi
		fi
	fi

	# If live queries returned 0 but we have history, use history instead
	if [[ "$history_days" -gt 0 ]]; then
		if [[ "$(echo "$day_hours == 0" | bc)" -eq 1 ]]; then
			day_hours="${hist_1d:-0}"
		fi
		if [[ "$(echo "$week_hours == 0" | bc)" -eq 1 ]]; then
			week_hours="${hist_7d:-0}"
		fi
		if [[ "$(echo "$month_hours == 0" | bc)" -eq 1 ]]; then
			month_hours="${hist_28d:-0}"
		fi
	fi

	# For 365 days: use accumulated history if available, else extrapolate
	local year_hours
	if [[ "$history_days" -gt 0 ]]; then
		local daily_avg
		daily_avg=$(echo "scale=2; ${history_total:-0} / $history_days" | bc)
		if [[ "$history_days" -ge 365 ]]; then
			year_hours="${hist_365d:-0}"
		else
			# Extrapolate from available data
			year_hours=$(echo "scale=1; $daily_avg * 365" | bc)
		fi
	else
		# No history — extrapolate from 28-day data
		year_hours=$(echo "scale=1; $month_hours / 28 * 365" | bc 2>/dev/null || echo "0")
	fi

	local platform_note
	case "$OS_TYPE" in
	Darwin) platform_note="from macOS Knowledge DB (~28 days retention)" ;;
	Linux) platform_note="from systemd-logind session events" ;;
	*) platform_note="unsupported platform" ;;
	esac

	jq -n \
		--arg day "$day_hours" \
		--arg week "$week_hours" \
		--arg month "$month_hours" \
		--arg year "$year_hours" \
		--arg note "$platform_note" \
		'{
			today_hours: ($day | tonumber),
			week_hours: ($week | tonumber),
			month_hours: ($month | tonumber),
			year_hours: ($year | tonumber),
			month_note: $note
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
	echo ""
	echo "Platform: ${OS_TYPE}"
	case "$OS_TYPE" in
	Darwin) echo "  Source: macOS Knowledge DB (display backlit events)" ;;
	Linux) echo "  Source: systemd-logind (session events) + wtmp (login sessions)" ;;
	*) echo "  Source: unsupported (will return 0 for all queries)" ;;
	esac
	return 0 2>/dev/null || exit 0
	;;
esac
