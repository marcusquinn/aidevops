#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# routine-schedule-helper.sh — Deterministic schedule parser for routine evaluation
#
# Supports: daily(@HH:MM), weekly(day@HH:MM), monthly(N@HH:MM), cron(5-field-expr)
# Pure bash date arithmetic, no external deps beyond `date`.
#
# Commands:
#   is-due <expression> <last-run-epoch>  → exit 0 if due, exit 1 if not
#   next-run <expression>                 → prints next run ISO timestamp
#   parse <expression>                    → outputs normalised fields (debugging)

set -euo pipefail

#######################################
# Day name to cron weekday number (0=Sun, 1=Mon, ..., 6=Sat)
#######################################
_day_to_number() {
	local day="$1"
	# Bash 3.2 compat: ${var,,} (lowercase) requires Bash 4+. Use tr instead.
	day=$(printf '%s' "$day" | tr '[:upper:]' '[:lower:]')
	case "$day" in
	sun | sunday) printf '0' ;;
	mon | monday) printf '1' ;;
	tue | tuesday) printf '2' ;;
	wed | wednesday) printf '3' ;;
	thu | thursday) printf '4' ;;
	fri | friday) printf '5' ;;
	sat | saturday) printf '6' ;;
	*)
		if [[ "$day" =~ ^[0-6]$ ]]; then
			printf '%s' "$day"
		else
			printf '%s\n' "ERROR: invalid day '$day'" >&2
			return 1
		fi
		;;
	esac
	return 0
}

#######################################
# Get current epoch (UTC)
#######################################
_now_epoch() {
	date -u +%s
	return 0
}

#######################################
# Convert ISO timestamp to epoch
# Handles both GNU date and BSD date (macOS)
#######################################
_iso_to_epoch() {
	local iso="$1"
	local epoch=""
	# Try GNU date first
	epoch=$(date -d "$iso" +%s 2>/dev/null) || true
	if [[ -z "$epoch" ]]; then
		# BSD date (macOS) — try ISO format
		epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || true
	fi
	if [[ -z "$epoch" ]]; then
		printf '%s\n' "ERROR: cannot parse ISO timestamp '$iso'" >&2
		return 1
	fi
	printf '%s' "$epoch"
	return 0
}

#######################################
# Convert epoch to ISO timestamp (UTC)
#######################################
_epoch_to_iso() {
	local epoch="$1"
	# Try GNU date first
	local iso=""
	iso=$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || true
	if [[ -z "$iso" ]]; then
		# BSD date (macOS)
		iso=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || true
	fi
	if [[ -z "$iso" ]]; then
		printf '%s\n' "ERROR: cannot convert epoch '$epoch' to ISO" >&2
		return 1
	fi
	printf '%s' "$iso"
	return 0
}

#######################################
# Get current hour and minute as integers
#######################################
_current_hm() {
	local hour minute
	hour=$(date -u +%H)
	minute=$(date -u +%M)
	# Strip leading zeros for arithmetic
	hour=$((10#$hour))
	minute=$((10#$minute))
	printf '%d %d' "$hour" "$minute"
	return 0
}

#######################################
# Get current day of week (0=Sun, 1=Mon, ..., 6=Sat)
#######################################
_current_dow() {
	date -u +%w
	return 0
}

#######################################
# Get current day of month
#######################################
_current_dom() {
	local dom
	dom=$(date -u +%d)
	printf '%d' "$((10#$dom))"
	return 0
}

#######################################
# Parse a schedule expression into normalised fields
#
# Returns: type hour minute [day_of_week|day_of_month] or cron fields
#######################################
_parse_expression() {
	local expr="$1"

	if [[ "$expr" =~ ^daily\(@([0-9]{1,2}):([0-9]{2})\)$ ]]; then
		local hour="${BASH_REMATCH[1]}"
		local minute="${BASH_REMATCH[2]}"
		printf 'daily %d %d' "$((10#$hour))" "$((10#$minute))"
		return 0
	fi

	if [[ "$expr" =~ ^weekly\(([a-zA-Z0-9]+)@([0-9]{1,2}):([0-9]{2})\)$ ]]; then
		local day_name="${BASH_REMATCH[1]}"
		local hour="${BASH_REMATCH[2]}"
		local minute="${BASH_REMATCH[3]}"
		local dow
		dow=$(_day_to_number "$day_name") || return 1
		printf 'weekly %d %d %s' "$((10#$hour))" "$((10#$minute))" "$dow"
		return 0
	fi

	if [[ "$expr" =~ ^monthly\(([0-9]{1,2})@([0-9]{1,2}):([0-9]{2})\)$ ]]; then
		local dom="${BASH_REMATCH[1]}"
		local hour="${BASH_REMATCH[2]}"
		local minute="${BASH_REMATCH[3]}"
		printf 'monthly %d %d %d' "$((10#$hour))" "$((10#$minute))" "$((10#$dom))"
		return 0
	fi

	if [[ "$expr" =~ ^cron\((.+)\)$ ]]; then
		local cron_expr="${BASH_REMATCH[1]}"
		# Validate 5 fields — use a subshell array to avoid clobbering positional params
		local field_count
		local -a _cron_fields
		# shellcheck disable=SC2086
		read -ra _cron_fields <<<"$cron_expr"
		field_count=${#_cron_fields[@]}
		if [[ "$field_count" -ne 5 ]]; then
			printf '%s\n' "ERROR: cron expression must have 5 fields, got $field_count" >&2
			return 1
		fi
		printf 'cron %s' "$cron_expr"
		return 0
	fi

	printf '%s\n' "ERROR: unrecognised schedule expression '$expr'" >&2
	return 1
}

#######################################
# Check if a cron field matches a value
# Supports: *, N, N-M, */N, N,M,O
#######################################
_cron_field_matches() {
	local field="$1"
	local value="$2"

	# Wildcard
	if [[ "$field" == "*" ]]; then
		return 0
	fi

	# Step: */N
	if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
		local step="${BASH_REMATCH[1]}"
		if [[ "$step" -gt 0 ]] && [[ $((value % step)) -eq 0 ]]; then
			return 0
		fi
		return 1
	fi

	# List: N,M,O
	if [[ "$field" == *","* ]]; then
		local item
		IFS=',' read -ra items <<<"$field"
		for item in "${items[@]}"; do
			if [[ "$((10#$item))" -eq "$value" ]]; then
				return 0
			fi
		done
		return 1
	fi

	# Range: N-M
	if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
		local range_start="${BASH_REMATCH[1]}"
		local range_end="${BASH_REMATCH[2]}"
		if [[ "$value" -ge "$((10#$range_start))" ]] && [[ "$value" -le "$((10#$range_end))" ]]; then
			return 0
		fi
		return 1
	fi

	# Exact match
	if [[ "$((10#$field))" -eq "$value" ]]; then
		return 0
	fi

	return 1
}

#######################################
# Check if a cron expression matches the current time
#######################################
_cron_matches_now() {
	local cron_expr="$1"
	local cron_minute cron_hour cron_dom cron_month cron_dow
	# shellcheck disable=SC2086
	read -r cron_minute cron_hour cron_dom cron_month cron_dow <<<"$cron_expr"

	local now_hour now_minute
	read -r now_hour now_minute <<<"$(_current_hm)"
	local now_dow
	now_dow=$(_current_dow)
	local now_dom
	now_dom=$(_current_dom)
	local now_month
	now_month=$(date -u +%m)
	now_month=$((10#$now_month))

	_cron_field_matches "$cron_minute" "$now_minute" || return 1
	_cron_field_matches "$cron_hour" "$now_hour" || return 1
	_cron_field_matches "$cron_dom" "$now_dom" || return 1
	_cron_field_matches "$cron_month" "$now_month" || return 1
	_cron_field_matches "$cron_dow" "$now_dow" || return 1

	return 0
}

#######################################
# Calculate the interval in seconds for a schedule type
# Used to determine if enough time has passed since last run
#######################################
_schedule_interval_seconds() {
	local sched_type="$1"

	case "$sched_type" in
	daily) printf '%d' 86400 ;;     # 24 hours
	weekly) printf '%d' 604800 ;;   # 7 days
	monthly) printf '%d' 2592000 ;; # 30 days (approximate)
	cron) printf '%d' 60 ;;         # 1 minute (cron granularity)
	*)
		printf '%d' 86400
		;;
	esac
	return 0
}

#######################################
# is-due: Check if a routine is due for execution
#
# Arguments:
#   $1 - schedule expression (e.g., "daily(@09:00)")
#   $2 - last run epoch (0 = never run)
#
# Exit codes:
#   0 - routine is due
#   1 - routine is not due
#   2 - parse error
#######################################
cmd_is_due() {
	local expression="$1"
	local last_run_epoch="$2"

	local parsed
	parsed=$(_parse_expression "$expression") || return 2

	local sched_type
	sched_type=$(printf '%s' "$parsed" | awk '{print $1}')

	local now_epoch
	now_epoch=$(_now_epoch)

	# If never run (epoch 0), it's always due
	if [[ "$last_run_epoch" -eq 0 ]]; then
		return 0
	fi

	local interval
	interval=$(_schedule_interval_seconds "$sched_type")

	# Minimum interval check: don't re-run if less than 90% of the interval
	# has passed. This prevents double-runs when the pulse fires slightly
	# before and after the scheduled time.
	local min_elapsed=$((interval * 90 / 100))
	local elapsed=$((now_epoch - last_run_epoch))
	if [[ "$elapsed" -lt "$min_elapsed" ]]; then
		return 1
	fi

	case "$sched_type" in
	daily)
		local sched_hour sched_minute
		sched_hour=$(printf '%s' "$parsed" | awk '{print $2}')
		sched_minute=$(printf '%s' "$parsed" | awk '{print $3}')
		local now_hour now_minute
		read -r now_hour now_minute <<<"$(_current_hm)"
		# Due if current time is at or past the scheduled time
		if [[ "$now_hour" -gt "$sched_hour" ]] ||
			{ [[ "$now_hour" -eq "$sched_hour" ]] && [[ "$now_minute" -ge "$sched_minute" ]]; }; then
			return 0
		fi
		return 1
		;;
	weekly)
		local sched_hour sched_minute sched_dow
		sched_hour=$(printf '%s' "$parsed" | awk '{print $2}')
		sched_minute=$(printf '%s' "$parsed" | awk '{print $3}')
		sched_dow=$(printf '%s' "$parsed" | awk '{print $4}')
		local now_dow
		now_dow=$(_current_dow)
		local now_hour now_minute
		read -r now_hour now_minute <<<"$(_current_hm)"
		if [[ "$now_dow" -eq "$sched_dow" ]]; then
			if [[ "$now_hour" -gt "$sched_hour" ]] ||
				{ [[ "$now_hour" -eq "$sched_hour" ]] && [[ "$now_minute" -ge "$sched_minute" ]]; }; then
				return 0
			fi
		fi
		return 1
		;;
	monthly)
		local sched_hour sched_minute sched_dom
		sched_hour=$(printf '%s' "$parsed" | awk '{print $2}')
		sched_minute=$(printf '%s' "$parsed" | awk '{print $3}')
		sched_dom=$(printf '%s' "$parsed" | awk '{print $4}')
		local now_dom
		now_dom=$(_current_dom)
		local now_hour now_minute
		read -r now_hour now_minute <<<"$(_current_hm)"
		if [[ "$now_dom" -eq "$sched_dom" ]]; then
			if [[ "$now_hour" -gt "$sched_hour" ]] ||
				{ [[ "$now_hour" -eq "$sched_hour" ]] && [[ "$now_minute" -ge "$sched_minute" ]]; }; then
				return 0
			fi
		fi
		return 1
		;;
	cron)
		local cron_expr
		cron_expr=$(printf '%s' "$parsed" | sed 's/^cron //')
		if _cron_matches_now "$cron_expr"; then
			return 0
		fi
		return 1
		;;
	*)
		printf '%s\n' "ERROR: unknown schedule type '$sched_type'" >&2
		return 2
		;;
	esac
}

#######################################
# next-run: Calculate the next run time for a schedule expression
#
# Arguments:
#   $1 - schedule expression
#
# Output: ISO timestamp of next scheduled run
#######################################
_next_run_daily() {
	local parsed="$1"
	local now_epoch="$2"
	local sched_hour sched_minute
	sched_hour=$(printf '%s' "$parsed" | awk '{print $2}')
	sched_minute=$(printf '%s' "$parsed" | awk '{print $3}')

	local today_date
	today_date=$(date -u +%Y-%m-%d)
	local sched_iso
	sched_iso="${today_date}T$(printf '%02d:%02d:00Z' "$sched_hour" "$sched_minute")"
	local sched_epoch
	sched_epoch=$(_iso_to_epoch "$sched_iso") || return 2

	if [[ "$now_epoch" -lt "$sched_epoch" ]]; then
		_epoch_to_iso "$sched_epoch"
	else
		_epoch_to_iso $((sched_epoch + 86400))
	fi
	printf '\n'
	return 0
}

_next_run_weekly() {
	local parsed="$1"
	local now_epoch="$2"
	local sched_hour sched_minute sched_dow
	sched_hour=$(printf '%s' "$parsed" | awk '{print $2}')
	sched_minute=$(printf '%s' "$parsed" | awk '{print $3}')
	sched_dow=$(printf '%s' "$parsed" | awk '{print $4}')
	local now_dow
	now_dow=$(_current_dow)

	local days_ahead=$(((sched_dow - now_dow + 7) % 7))
	if [[ "$days_ahead" -eq 0 ]]; then
		local now_hour now_minute
		read -r now_hour now_minute <<<"$(_current_hm)"
		if [[ "$now_hour" -gt "$sched_hour" ]] ||
			{ [[ "$now_hour" -eq "$sched_hour" ]] && [[ "$now_minute" -ge "$sched_minute" ]]; }; then
			days_ahead=7
		fi
	fi

	local next_epoch=$((now_epoch + days_ahead * 86400))
	local next_date
	next_date=$(_epoch_to_iso "$next_epoch") || return 2
	next_date="${next_date%%T*}"
	local next_iso
	next_iso="${next_date}T$(printf '%02d:%02d:00Z' "$sched_hour" "$sched_minute")"
	printf '%s\n' "$next_iso"
	return 0
}

_next_run_monthly() {
	local parsed="$1"
	local sched_hour sched_minute sched_dom
	sched_hour=$(printf '%s' "$parsed" | awk '{print $2}')
	sched_minute=$(printf '%s' "$parsed" | awk '{print $3}')
	sched_dom=$(printf '%s' "$parsed" | awk '{print $4}')

	local now_dom
	now_dom=$(_current_dom)
	local now_year now_month_num
	now_year=$(date -u +%Y)
	now_month_num=$(date -u +%m)
	now_month_num=$((10#$now_month_num))

	local target_year="$now_year"
	local target_month="$now_month_num"

	if [[ "$now_dom" -gt "$sched_dom" ]]; then
		target_month=$((target_month + 1))
		if [[ "$target_month" -gt 12 ]]; then
			target_month=1
			target_year=$((target_year + 1))
		fi
	elif [[ "$now_dom" -eq "$sched_dom" ]]; then
		local now_hour now_minute
		read -r now_hour now_minute <<<"$(_current_hm)"
		if [[ "$now_hour" -gt "$sched_hour" ]] ||
			{ [[ "$now_hour" -eq "$sched_hour" ]] && [[ "$now_minute" -ge "$sched_minute" ]]; }; then
			target_month=$((target_month + 1))
			if [[ "$target_month" -gt 12 ]]; then
				target_month=1
				target_year=$((target_year + 1))
			fi
		fi
	fi

	printf '%04d-%02d-%02dT%02d:%02d:00Z\n' "$target_year" "$target_month" "$sched_dom" "$sched_hour" "$sched_minute"
	return 0
}

cmd_next_run() {
	local expression="$1"

	local parsed
	parsed=$(_parse_expression "$expression") || return 2

	local sched_type
	sched_type=$(printf '%s' "$parsed" | awk '{print $1}')

	local now_epoch
	now_epoch=$(_now_epoch)

	case "$sched_type" in
	daily) _next_run_daily "$parsed" "$now_epoch" ;;
	weekly) _next_run_weekly "$parsed" "$now_epoch" ;;
	monthly) _next_run_monthly "$parsed" ;;
	cron)
		# For cron, report "next minute" as approximation
		local next_epoch=$((now_epoch + 60 - (now_epoch % 60)))
		_epoch_to_iso "$next_epoch"
		printf '\n'
		;;
	*)
		printf '%s\n' "ERROR: unknown schedule type '$sched_type'" >&2
		return 2
		;;
	esac
	return 0
}

#######################################
# parse: Output normalised fields for debugging
#
# Arguments:
#   $1 - schedule expression
#
# Output: type and normalised fields
#######################################
cmd_parse() {
	local expression="$1"

	local parsed
	parsed=$(_parse_expression "$expression") || return 2

	local sched_type
	sched_type=$(printf '%s' "$parsed" | awk '{print $1}')

	case "$sched_type" in
	daily)
		local hour minute
		hour=$(printf '%s' "$parsed" | awk '{print $2}')
		minute=$(printf '%s' "$parsed" | awk '{print $3}')
		printf 'type=daily hour=%d minute=%d\n' "$hour" "$minute"
		;;
	weekly)
		local hour minute dow
		hour=$(printf '%s' "$parsed" | awk '{print $2}')
		minute=$(printf '%s' "$parsed" | awk '{print $3}')
		dow=$(printf '%s' "$parsed" | awk '{print $4}')
		printf 'type=weekly hour=%d minute=%d day_of_week=%s\n' "$hour" "$minute" "$dow"
		;;
	monthly)
		local hour minute dom
		hour=$(printf '%s' "$parsed" | awk '{print $2}')
		minute=$(printf '%s' "$parsed" | awk '{print $3}')
		dom=$(printf '%s' "$parsed" | awk '{print $4}')
		printf 'type=monthly hour=%d minute=%d day_of_month=%d\n' "$hour" "$minute" "$dom"
		;;
	cron)
		local cron_fields
		cron_fields=$(printf '%s' "$parsed" | sed 's/^cron //')
		printf 'type=cron fields=%s\n' "$cron_fields"
		;;
	*)
		printf '%s\n' "ERROR: unknown type '$sched_type'" >&2
		return 2
		;;
	esac
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local command="${1:-}"
	shift || true

	case "$command" in
	is-due)
		if [[ $# -lt 2 ]]; then
			printf '%s\n' "Usage: routine-schedule-helper.sh is-due <expression> <last-run-epoch>" >&2
			return 2
		fi
		cmd_is_due "$1" "$2"
		return $?
		;;
	next-run)
		if [[ $# -lt 1 ]]; then
			printf '%s\n' "Usage: routine-schedule-helper.sh next-run <expression>" >&2
			return 2
		fi
		cmd_next_run "$1"
		return $?
		;;
	parse)
		if [[ $# -lt 1 ]]; then
			printf '%s\n' "Usage: routine-schedule-helper.sh parse <expression>" >&2
			return 2
		fi
		cmd_parse "$1"
		return $?
		;;
	*)
		printf '%s\n' "Usage: routine-schedule-helper.sh {is-due|next-run|parse} <args>" >&2
		printf '%s\n' "" >&2
		printf '%s\n' "Commands:" >&2
		printf '%s\n' "  is-due <expression> <last-run-epoch>  Check if routine is due (exit 0=due, 1=not due)" >&2
		printf '%s\n' "  next-run <expression>                 Print next run ISO timestamp" >&2
		printf '%s\n' "  parse <expression>                    Output normalised fields" >&2
		printf '%s\n' "" >&2
		printf '%s\n' "Expressions:" >&2
		printf '%s\n' "  daily(@HH:MM)           Run daily at specified time (UTC)" >&2
		printf '%s\n' "  weekly(day@HH:MM)       Run weekly on day at time (UTC)" >&2
		printf '%s\n' "  monthly(N@HH:MM)        Run monthly on day N at time (UTC)" >&2
		printf '%s\n' "  cron(min hour dom mon dow)  Standard 5-field cron expression" >&2
		return 2
		;;
	esac
}

main "$@"
