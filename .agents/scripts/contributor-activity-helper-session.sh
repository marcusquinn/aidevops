#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Contributor Activity — observed AI session time interface

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_CONTRIBUTOR_ACTIVITY_SESSION_LIB_LOADED:-}" ]] && return 0
_CONTRIBUTOR_ACTIVITY_SESSION_LIB_LOADED=1

_SESSION_TIME_LIB_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
SESSION_TIME_INTERVAL_ENGINE="${_SESSION_TIME_LIB_DIR}/session-time-interval-engine.py"
unset _SESSION_TIME_LIB_DIR
SESSION_FORMAT_JSON="json"
SESSION_STATUS_UNAVAILABLE="unavailable"
SESSION_TOTAL_HUMAN_FIELD="total_human_hours"
SESSION_TOTAL_MACHINE_FIELD="total_machine_hours"
SESSION_TOTAL_SESSIONS_FIELD="total_sessions"
SESSION_WORKER_SESSIONS_FIELD="worker_sessions"

#######################################
# Format one session-stat object as Markdown.
# Arguments:
#   $1 - stats JSON
#   $2 - period label
#######################################
_session_time_format_markdown() {
	local stats_json="$1"
	local period="$2"
	printf '%s\n' "$stats_json" | python3 -c '
import json
import sys
period = sys.argv[1]
unavailable = sys.argv[2]
total_sessions_field = sys.argv[3]
total_human_field = sys.argv[4]
total_machine_field = sys.argv[5]
data = json.load(sys.stdin)
if data.get("status") == unavailable:
    print(f"_Session data unavailable for {period}._")
elif data.get(total_sessions_field, 0) == 0:
    print(f"_No observed sessions for {period}._")
else:
    print("| Type | Human attention | AI generation | Additive work | Sessions |")
    print("| --- | ---: | ---: | ---: | ---: |")
    for label, prefix in (("Interactive", "interactive"), ("Workers/Runners", "worker")):
        human = data.get(f"{prefix}_human_hours", 0)
        machine = data.get(f"{prefix}_machine_hours", 0)
        count = data.get(f"{prefix}_sessions", 0)
        print(f"| {label} | {human}h | {machine}h | {round(human + machine, 1)}h | {count} |")
    human = data.get(total_human_field, 0)
    machine = data.get(total_machine_field, 0)
    print(f"| **Total** | **{human}h** | **{machine}h** | **{round(human + machine, 1)}h** | **{data.get(total_sessions_field, 0)}** |")
' "$period" "$SESSION_STATUS_UNAVAILABLE" "$SESSION_TOTAL_SESSIONS_FIELD" "$SESSION_TOTAL_HUMAN_FIELD" "$SESSION_TOTAL_MACHINE_FIELD"
	return 0
}

#######################################
# Format a period map as Markdown.
# Arguments:
#   $1 - period map JSON
#######################################
_session_time_format_period_map() {
	local stats_json="$1"
	printf '%s\n' "$stats_json" | python3 -c '
import json
import sys
total_sessions_field = sys.argv[1]
total_human_field = sys.argv[2]
total_machine_field = sys.argv[3]
worker_sessions_field = sys.argv[4]
data = json.load(sys.stdin)
if not data or all(item.get(total_sessions_field, 0) == 0 for item in data.values()):
    print("_No session data available._")
else:
    print("| Period | Human attention | AI generation | Additive work | Sessions | Workers |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for period, item in data.items():
        human = item.get(total_human_field, 0)
        machine = item.get(total_machine_field, 0)
        print(f"| {period.capitalize()} | {human}h | {machine}h | {round(human + machine, 1)}h | {item.get(total_sessions_field, 0)} | {item.get(worker_sessions_field, 0)} |")
' "$SESSION_TOTAL_SESSIONS_FIELD" "$SESSION_TOTAL_HUMAN_FIELD" "$SESSION_TOTAL_MACHINE_FIELD" "$SESSION_WORKER_SESSIONS_FIELD"
	return 0
}

#######################################
# Validate that a value-taking option has a following argument.
# Arguments:
#   option name and remaining argument count
#######################################
_session_require_option_value() {
	local option_name="$1"
	local remaining_count="$2"
	if [[ "$remaining_count" -lt 2 ]]; then
		echo "Error: ${option_name} requires an argument" >&2
		return 1
	fi
	return 0
}

#######################################
# Compute observed AI session time.
# Arguments:
#   repo path and --period/--format/--db-path/--all-dirs options
#######################################
session_time() {
	local repo_path=""
	local period="month"
	local format="markdown"
	local db_path=""
	local all_dirs="false"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--period)
			_session_require_option_value "$1" "$#" || return 1
			period="${2:-}"
			shift 2
			;;
		--format)
			_session_require_option_value "$1" "$#" || return 1
			format="${2:-}"
			shift 2
			;;
		--db-path)
			_session_require_option_value "$1" "$#" || return 1
			db_path="${2:-}"
			shift 2
			;;
		--all-dirs)
			all_dirs="true"
			shift
			;;
		*)
			[[ -z "$repo_path" ]] && repo_path="$1"
			shift
			;;
		esac
	done
	case "$period" in
	day | week | 28d | month | quarter | year | profile | all) ;;
	*)
		echo "Error: invalid session period: ${period}" >&2
		return 1
		;;
	esac
	case "$format" in
	"$SESSION_FORMAT_JSON" | markdown) ;;
	*)
		echo "Error: invalid session format: ${format}" >&2
		return 1
		;;
	esac

	local -a engine_args=(--period "$period")
	if [[ "$all_dirs" == "true" ]]; then
		engine_args+=(--all-dirs)
	else
		repo_path="${repo_path:-.}"
		engine_args+=(--repo "$repo_path")
	fi
	[[ -n "$db_path" ]] && engine_args+=(--db-path "$db_path")
	local result
	if ! result=$(python3 "$SESSION_TIME_INTERVAL_ENGINE" "${engine_args[@]}"); then
		echo "Error: session aggregation failed" >&2
		return 1
	fi
	if [[ "$format" == "$SESSION_FORMAT_JSON" ]]; then
		printf '%s\n' "$result"
	elif [[ "$period" == "all" || "$period" == "profile" ]]; then
		_session_time_format_period_map "$result"
	else
		_session_time_format_markdown "$result" "$period"
	fi
	return 0
}

#######################################
# Aggregate session stats across repository paths.
# Arguments:
#   repo paths plus --period and --format
#######################################
cross_repo_session_time() {
	local period="month"
	local format="markdown"
	local -a repo_paths=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--period)
			_session_require_option_value "$1" "$#" || return 1
			period="${2:-}"
			shift 2
			;;
		--format)
			_session_require_option_value "$1" "$#" || return 1
			format="${2:-}"
			shift 2
			;;
		*)
			repo_paths+=("$1")
			shift
			;;
		esac
	done
	if [[ ${#repo_paths[@]} -eq 0 ]]; then
		echo "Error: at least one repo path required" >&2
		return 1
	fi
	if [[ "$period" == "all" ]]; then
		local period_map='{}'
		local period_name
		for period_name in day week month quarter year; do
			local period_stats
			period_stats=$(cross_repo_session_time "${repo_paths[@]}" --period "$period_name" --format json) || return 1
			period_map=$(printf '%s' "$period_map" | jq --arg name "$period_name" --argjson stats "$period_stats" '. + {($name):$stats}')
		done
		if [[ "$format" == "$SESSION_FORMAT_JSON" ]]; then
			printf '%s\n' "$period_map"
		else
			_session_time_format_period_map "$period_map"
		fi
		return 0
	fi
	local collected=""
	local repo_count=0
	local repo_path
	for repo_path in "${repo_paths[@]}"; do
		if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
			continue
		fi
		local item
		item=$(session_time "$repo_path" --period "$period" --format json) || continue
		collected="${collected}${item}"$'\n'
		repo_count=$((repo_count + 1))
	done
	local aggregated
	aggregated=$(printf '%s' "$collected" | jq -s \
		--argjson repo_count "$repo_count" \
		--arg total_human_field "$SESSION_TOTAL_HUMAN_FIELD" \
		--arg total_machine_field "$SESSION_TOTAL_MACHINE_FIELD" '
        def sum_field($name): map(.[$name] // 0) | add // 0;
        {
            interactive_sessions: sum_field("interactive_sessions"),
            interactive_human_hours: sum_field("interactive_human_hours"),
            interactive_machine_hours: sum_field("interactive_machine_hours"),
            worker_sessions: sum_field("worker_sessions"),
            worker_human_hours: sum_field("worker_human_hours"),
            worker_machine_hours: sum_field("worker_machine_hours"),
            ($total_human_field): sum_field($total_human_field),
            ($total_machine_field): sum_field($total_machine_field),
            total_sessions: sum_field("total_sessions"),
            repo_count: $repo_count,
            status: (if length > 0 then "ok" else "unavailable" end)
        }
    ')
	if [[ "$format" == "$SESSION_FORMAT_JSON" ]]; then
		printf '%s\n' "$aggregated"
	else
		_session_time_format_markdown "$aggregated" "$period across ${repo_count} repos"
	fi
	return 0
}
