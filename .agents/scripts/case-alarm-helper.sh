#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# =============================================================================
# Case Alarm Helper (t2853 P4c)
# =============================================================================
# Pulse-driven routine that reads all open cases' deadlines, classifies each
# by urgency stage, and fires alarms via configured channels when a stage
# transition is detected.
#
# Usage:
#   case-alarm-helper.sh tick [--repo <path>]
#   case-alarm-helper.sh alarm-test <case-id> [--repo <path>]
#   case-alarm-helper.sh help
#
# Alarm channels:
#   gh-issue  — opens a GH issue tagged kind:case-alarm; closes when passed
#   ntfy      — POST to configured ntfy topic
#   email     — stub (P5 full send)
#
# Stage memory: _cases/.alarm-state.json
#   { "case-id": { "deadline-label": "amber" } }
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly CASES_DIR_NAME="_cases"
readonly ALARM_STATE_FILE=".alarm-state.json"
readonly ALARM_CONFIG_TEMPLATE="${SCRIPT_DIR}/../templates/case-alarms-config.json"
readonly ALARM_GH_LABEL="kind:case-alarm"
readonly ALARM_CHANNEL_GH_ISSUE="gh-issue"
readonly ALARM_CHANNEL_NTFY="ntfy"
readonly ALARM_CHANNEL_EMAIL="email"
readonly ALARM_STAGE_PASSED="passed"

# Default stage thresholds (days) — overridden by config stages_days
readonly DEFAULT_STAGES_DAYS=(30 7 1)

# =============================================================================
# Internal helpers
# =============================================================================

# _resolve_cases_dir <repo-path>
_resolve_cases_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${CASES_DIR_NAME}"
	return 0
}

# _require_jq
_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not found. Install: brew install jq"
		return 1
	fi
	return 0
}

# _load_alarm_config <cases-dir> — print config JSON to stdout
# Falls back to built-in defaults when no _config/case-alarms.json found.
_load_alarm_config() {
	local cases_dir="$1"
	local repo_path
	repo_path="$(dirname "$cases_dir")"
	local config_path="${repo_path}/_config/case-alarms.json"

	if [[ -f "$config_path" ]]; then
		jq '.' "$config_path"
	elif [[ -f "$ALARM_CONFIG_TEMPLATE" ]]; then
		jq '.' "$ALARM_CONFIG_TEMPLATE"
	else
		# Inline default — use --arg to avoid repeating channel name literals
		jq -n \
			--arg ch1 "${ALARM_CHANNEL_GH_ISSUE}" \
			--arg ch2 "${ALARM_CHANNEL_NTFY}" \
			'{
				"stages_days": [30, 7, 1],
				"channels": [$ch1, $ch2],
				"ntfy_topic": "aidevops-case-alarms",
				"per_case_overrides": {}
			}'
	fi
	return 0
}

# _load_alarm_state <cases-dir> — print alarm state JSON to stdout
_load_alarm_state() {
	local cases_dir="$1"
	local state_file="${cases_dir}/${ALARM_STATE_FILE}"
	if [[ -f "$state_file" ]]; then
		jq '.' "$state_file"
	else
		echo '{}'
	fi
	return 0
}

# _save_alarm_state <cases-dir> — read JSON from stdin, write to alarm state file
_save_alarm_state() {
	local cases_dir="$1"
	local state_file="${cases_dir}/${ALARM_STATE_FILE}"
	jq '.' >"$state_file"
	return 0
}

# _classify_stage <days_until> <stages_json_array>
# Prints: red | amber | green | passed (value of ALARM_STAGE_PASSED)
# stages_json_array is a sorted-desc JSON array of threshold days e.g. [30,7,1]
_classify_stage() {
	local days_until="$1" stages_json="$2"
	# passed means the deadline has already been reached / exceeded
	if [[ $days_until -lt 0 ]]; then
		echo "${ALARM_STAGE_PASSED}"
		return 0
	fi
	# Iterate stages (already sorted desc by convention in config)
	local stage_count i threshold
	stage_count="$(echo "$stages_json" | jq 'length')"
	for ((i = 0; i < stage_count; i++)); do
		threshold="$(echo "$stages_json" | jq ".[$i]")"
		if [[ $days_until -le $threshold ]]; then
			# Determine name by position: first stage = "red", second = "amber", rest = "amber"
			if [[ $i -eq $((stage_count - 1)) ]]; then
				echo "red"
			elif [[ $i -eq 0 ]]; then
				echo "amber"
			else
				echo "amber"
			fi
			return 0
		fi
	done
	echo "green"
	return 0
}

# _stage_severity <stage> — numeric severity for escalation comparison
# higher = more severe
_stage_severity() {
	local stage="${1:-green}"
	case "$stage" in
	red)    echo "3" ;;
	amber)  echo "2" ;;
	green)  echo "1" ;;
	passed) echo "0" ;;
	*)      echo "0" ;;
	esac
	return 0
}

# _days_until_date <iso-date> — integer days until date (negative if past)
_days_until_date() {
	local target_date="$1"
	local now_epoch target_epoch
	now_epoch="$(date -u +%s)"
	# Portable: strip to YYYY-MM-DD, then convert
	local clean_date="${target_date:0:10}"
	if date -d "$clean_date" >/dev/null 2>&1; then
		# GNU date
		target_epoch="$(date -d "$clean_date" +%s)"
	else
		# BSD/macOS date
		target_epoch="$(date -j -f '%Y-%m-%d' "$clean_date" +%s 2>/dev/null)" || {
			print_warning "Cannot parse date: ${target_date}"
			echo "999"
			return 0
		}
	fi
	local diff=$(( (target_epoch - now_epoch) / 86400 ))
	echo "$diff"
	return 0
}

# _alarm_gh_issue_title <case-id> <deadline-label>
_alarm_gh_issue_title() {
	local case_id="$1" deadline_label="$2"
	echo "Case alarm: ${case_id} deadline ${deadline_label}"
	return 0
}

# _find_open_alarm_issue <case-id> <deadline-label> <slug>
# Prints issue number, or empty string if not found.
_find_open_alarm_issue() {
	local case_id="$1" deadline_label="$2" slug="$3"
	local title
	title="$(_alarm_gh_issue_title "$case_id" "$deadline_label")"
	if ! command -v gh >/dev/null 2>&1; then
		echo ""
		return 0
	fi
	local result
	result="$(gh issue list \
		--repo "$slug" \
		--label "${ALARM_GH_LABEL}" \
		--state open \
		--search "\"${title}\"" \
		--json number,title \
		--jq ".[] | select(.title == \"${title}\") | .number" 2>/dev/null)" || true
	echo "${result:-}"
	return 0
}

# _alarm_gh_issue <case-id> <deadline-label> <deadline-date> <days> <stage> <slug>
# Opens or updates a GH alarm issue. Prints issue number.
_alarm_gh_issue() {
	local case_id="$1" deadline_label="$2" deadline_date="$3"
	local days="$4" stage="$5" slug="$6"

	if ! command -v gh >/dev/null 2>&1; then
		print_warning "gh not available — skipping GH issue alarm"
		echo ""
		return 0
	fi

	local title
	title="$(_alarm_gh_issue_title "$case_id" "$deadline_label")"
	local existing_num
	existing_num="$(_find_open_alarm_issue "$case_id" "$deadline_label" "$slug")"

	local stage_upper
	stage_upper="$(echo "$stage" | tr '[:lower:]' '[:upper:]')"
	local body
	body="**Case deadline alarm — ${stage_upper}**

Case: \`${case_id}\`
Deadline: \`${deadline_label}\` on \`${deadline_date}\`
Days remaining: **${days}**
Stage: **${stage}**

This alarm was filed automatically by the case alarm routine (t2853). It will auto-close when the deadline passes or the alarm is cleared.

> Do NOT close this issue manually unless the deadline has been resolved or removed from the case dossier.
"

	if [[ -n "$existing_num" ]]; then
		# Update existing issue with a comment
		local comment
		comment="Stage update: **${stage}** — ${days} days remaining (${deadline_date})."
		gh issue comment "$existing_num" --repo "$slug" --body "$comment" >/dev/null 2>&1 || true
		echo "$existing_num"
	else
		# Create new issue
		local new_num
		new_num="$(gh issue create \
			--repo "$slug" \
			--title "$title" \
			--body "$body" \
			--label "${ALARM_GH_LABEL}" \
			--json id,number \
			--jq '.number' 2>/dev/null)" || {
			print_warning "Failed to create GH alarm issue for ${case_id}/${deadline_label}"
			echo ""
			return 0
		}
		echo "$new_num"
	fi
	return 0
}

# _close_alarm_gh_issue <case-id> <deadline-label> <slug> <reason>
_close_alarm_gh_issue() {
	local case_id="$1" deadline_label="$2" slug="$3" reason="${4:-Deadline passed}"

	if ! command -v gh >/dev/null 2>&1; then
		return 0
	fi

	local existing_num
	existing_num="$(_find_open_alarm_issue "$case_id" "$deadline_label" "$slug")"
	[[ -z "$existing_num" ]] && return 0

	gh issue comment "$existing_num" --repo "$slug" \
		--body "Alarm auto-closed: ${reason}" >/dev/null 2>&1 || true
	gh issue close "$existing_num" --repo "$slug" >/dev/null 2>&1 || true
	return 0
}

# _alarm_ntfy <case-id> <deadline-label> <deadline-date> <days> <stage> <ntfy-topic>
_alarm_ntfy() {
	local case_id="$1" deadline_label="$2" deadline_date="$3"
	local days="$4" stage="$5" ntfy_topic="$6"

	[[ -z "$ntfy_topic" ]] && return 0

	if ! command -v curl >/dev/null 2>&1; then
		print_warning "curl not available — skipping ntfy alarm"
		return 0
	fi

	local priority
	case "$stage" in
	red)   priority="urgent" ;;
	amber) priority="high" ;;
	*)     priority="default" ;;
	esac

	local msg="[${stage^^}] ${case_id} — ${deadline_label} in ${days} days (${deadline_date})"
	curl -s \
		-d "$msg" \
		-H "Title: Case Deadline Alarm" \
		-H "Priority: ${priority}" \
		-H "Tags: alarm,case" \
		"https://ntfy.sh/${ntfy_topic}" >/dev/null 2>&1 || true
	return 0
}

# _alarm_email <case-id> <deadline-label> <days> <stage>
# Stub — full send arrives in P5
_alarm_email() {
	local case_id="$1" deadline_label="$2" days="$3" stage="$4"
	print_info "Email alarm stub (P5): ${case_id} / ${deadline_label} / ${stage} / ${days}d"
	return 0
}

# _timeline_append_alarm <case-dir> <deadline-label> <stage> <channels>
_timeline_append_alarm() {
	local case_dir="$1" deadline_label="$2" stage="$3" channels="$4"
	local timeline_file="${case_dir}/timeline.jsonl"
	local ts
	ts="$(date -u '+%Y%m%dT%H%M%SZ')"
	local event
	event="$(jq -cn \
		--arg ts "$ts" \
		--arg kind "alarm" \
		--arg actor "case-alarm-helper" \
		--arg content "Alarm fired: ${deadline_label} stage=${stage} channels=${channels}" \
		--arg ref "" \
		'{ts:$ts,kind:$kind,actor:$actor,content:$content,ref:$ref}')"
	echo "$event" >>"$timeline_file"
	return 0
}

# =============================================================================
# cmd_tick — main routine: scan all open cases and fire alarms as needed
# =============================================================================

cmd_tick() {
	_require_jq || return 1

	local repo_path="" dry_run=false
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		--dry-run) dry_run=true; shift ;;
		*) shift ;;
		esac
	done
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	if [[ ! -d "$cases_dir" ]]; then
		print_info "No _cases/ directory found at ${repo_path} — skipping alarm tick"
		return 0
	fi

	local config
	config="$(_load_alarm_config "$cases_dir")"
	local alarm_state
	alarm_state="$(_load_alarm_state "$cases_dir")"

	# Determine GH repo slug for alarm issues
	local slug=""
	if command -v git >/dev/null 2>&1; then
		local remote_url
		remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)" || true
		if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
			slug="${BASH_REMATCH[1]}"
		fi
	fi

	local channels
	channels="$(echo "$config" | jq -r '.channels | join(",")')"
	local ntfy_topic
	ntfy_topic="$(echo "$config" | jq -r '.ntfy_topic // ""')"

	local fired=0 skipped=0

	# Iterate active (non-archived) cases
	local case_dir
	for case_dir in "${cases_dir}"/case-*/; do
		[[ -d "$case_dir" ]] || continue
		[[ "$case_dir" == *"/archived/"* ]] && continue

		local dossier_path="${case_dir}/dossier.toon"
		[[ -f "$dossier_path" ]] || continue

		local dossier
		dossier="$(jq '.' "$dossier_path" 2>/dev/null)" || continue

		# Skip non-open cases
		local case_status
		case_status="$(echo "$dossier" | jq -r '.status')"
		[[ "$case_status" != "open" ]] && { skipped=$((skipped + 1)); continue; }

		local case_id
		case_id="$(echo "$dossier" | jq -r '.id')"

		# Determine stages for this case (honour per_case_overrides)
		local stages_json
		stages_json="$(echo "$config" | jq \
			--arg cid "$case_id" \
			'.per_case_overrides[$cid].stages_days // .stages_days | sort | reverse')"

		# Iterate deadlines
		local deadline_count i
		deadline_count="$(echo "$dossier" | jq '.deadlines | length')"
		for ((i = 0; i < deadline_count; i++)); do
			local dl_label dl_date days_until computed_stage
			dl_label="$(echo "$dossier" | jq -r ".deadlines[$i].label")"
			dl_date="$(echo "$dossier" | jq -r ".deadlines[$i].date")"
			days_until="$(_days_until_date "$dl_date")"
			computed_stage="$(_classify_stage "$days_until" "$stages_json")"

			# Get last recorded stage for this (case, deadline)
			local recorded_stage
			recorded_stage="$(echo "$alarm_state" | \
				jq -r --arg cid "$case_id" --arg lbl "$dl_label" \
				'.[$cid][$lbl] // "none"')"

			local computed_sev recorded_sev
			computed_sev="$(_stage_severity "$computed_stage")"
			recorded_sev="$(_stage_severity "$recorded_stage")"

			# Auto-close GH alarm when deadline has passed
			if [[ "$computed_stage" == "${ALARM_STAGE_PASSED}" ]]; then
				if [[ "$recorded_stage" != "none" && "$recorded_stage" != "${ALARM_STAGE_PASSED}" ]]; then
					print_info "Deadline passed: ${case_id}/${dl_label} — closing alarm"
					if [[ "$dry_run" == false && -n "$slug" ]]; then
						_close_alarm_gh_issue "$case_id" "$dl_label" "$slug" \
							"Deadline ${dl_date} has passed."
					fi
					# Update state to passed, append timeline
					if [[ "$dry_run" == false ]]; then
						alarm_state="$(echo "$alarm_state" | jq \
							--arg cid "$case_id" --arg lbl "$dl_label" \
							--arg sp "${ALARM_STAGE_PASSED}" \
							'.[$cid] //= {} | .[$cid][$lbl] = $sp')"
						_timeline_append_alarm "$case_dir" "$dl_label" \
							"${ALARM_STAGE_PASSED}" "auto-close"
					fi
				fi
				continue
			fi

			# Green stage — no alarm needed
			[[ "$computed_stage" == "green" ]] && continue

			# Fire if new stage is more severe than recorded (escalation)
			if [[ $computed_sev -gt $recorded_sev ]]; then
				print_info "Alarm: ${case_id} / ${dl_label} stage=${computed_stage} days=${days_until}"
				fired=$((fired + 1))

				if [[ "$dry_run" == false ]]; then
				local fired_channels=""
				# gh-issue channel
				if echo "$channels" | grep -q "${ALARM_CHANNEL_GH_ISSUE}" && [[ -n "$slug" ]]; then
					_alarm_gh_issue "$case_id" "$dl_label" "$dl_date" \
						"$days_until" "$computed_stage" "$slug" >/dev/null
					fired_channels="${fired_channels}${ALARM_CHANNEL_GH_ISSUE},"
				fi
				# ntfy channel
				if echo "$channels" | grep -q "${ALARM_CHANNEL_NTFY}" && [[ -n "$ntfy_topic" ]]; then
					_alarm_ntfy "$case_id" "$dl_label" "$dl_date" \
						"$days_until" "$computed_stage" "$ntfy_topic"
					fired_channels="${fired_channels}${ALARM_CHANNEL_NTFY},"
				fi
				# email channel (stub)
				if echo "$channels" | grep -q "${ALARM_CHANNEL_EMAIL}"; then
					_alarm_email "$case_id" "$dl_label" "$days_until" "$computed_stage"
					fired_channels="${fired_channels}${ALARM_CHANNEL_EMAIL},"
				fi

					# Record new stage
					alarm_state="$(echo "$alarm_state" | jq \
						--arg cid "$case_id" --arg lbl "$dl_label" --arg stage "$computed_stage" \
						'.[$cid] //= {} | .[$cid][$lbl] = $stage')"
					_timeline_append_alarm "$case_dir" "$dl_label" "$computed_stage" \
						"${fired_channels%,}"
				fi
			else
				print_info "No change: ${case_id}/${dl_label} stage=${computed_stage} (already recorded)"
			fi
		done
	done

	# Persist updated alarm state
	if [[ "$dry_run" == false ]]; then
		echo "$alarm_state" | _save_alarm_state "$cases_dir"
	fi

	print_success "Case alarm tick complete: ${fired} alarm(s) fired, ${skipped} case(s) skipped"
	return 0
}

# =============================================================================
# cmd_alarm_test — bypass stage memory, re-fire alarms for a single case
# =============================================================================

cmd_alarm_test() {
	_require_jq || return 1

	local case_id="" repo_path=""
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) print_error "Unknown option: ${_cur}"; return 1 ;;
		*) [[ -z "$case_id" ]] && { case_id="$_cur"; shift; } || shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case-alarm-helper.sh alarm-test <case-id> [--repo <path>]"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"

	# Resolve case directory (prefix / glob match)
	local case_dir
	if [[ -d "${cases_dir}/${case_id}" ]]; then
		case_dir="${cases_dir}/${case_id}"
	else
		case_dir=""
		local candidate
		for candidate in "${cases_dir}"/case-*-"${case_id}" "${cases_dir}"/case-*-*"${case_id}"*; do
			[[ -d "$candidate" ]] || continue
			[[ "$candidate" == *"/archived/"* ]] && continue
			case_dir="$candidate"
			break
		done
	fi

	if [[ -z "$case_dir" || ! -d "$case_dir" ]]; then
		print_error "Case not found: ${case_id}"
		return 1
	fi

	local dossier_path="${case_dir}/dossier.toon"
	[[ -f "$dossier_path" ]] || { print_error "Dossier not found: ${dossier_path}"; return 1; }

	local dossier
	dossier="$(jq '.' "$dossier_path")"
	local resolved_case_id
	resolved_case_id="$(echo "$dossier" | jq -r '.id')"

	local config
	config="$(_load_alarm_config "$cases_dir")"

	local slug=""
	if command -v git >/dev/null 2>&1; then
		local remote_url
		remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)" || true
		if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
			slug="${BASH_REMATCH[1]}"
		fi
	fi

	local channels
	channels="$(echo "$config" | jq -r '.channels | join(",")')"
	local ntfy_topic
	ntfy_topic="$(echo "$config" | jq -r '.ntfy_topic // ""')"

	local stages_json
	stages_json="$(echo "$config" | jq \
		--arg cid "$resolved_case_id" \
		'.per_case_overrides[$cid].stages_days // .stages_days | sort | reverse')"

	local deadline_count i
	deadline_count="$(echo "$dossier" | jq '.deadlines | length')"
	if [[ $deadline_count -eq 0 ]]; then
		print_info "No deadlines on ${resolved_case_id} — nothing to test"
		return 0
	fi

	for ((i = 0; i < deadline_count; i++)); do
		local dl_label dl_date days_until computed_stage
		dl_label="$(echo "$dossier" | jq -r ".deadlines[$i].label")"
		dl_date="$(echo "$dossier" | jq -r ".deadlines[$i].date")"
		days_until="$(_days_until_date "$dl_date")"
		computed_stage="$(_classify_stage "$days_until" "$stages_json")"

		print_info "alarm-test: ${resolved_case_id}/${dl_label} stage=${computed_stage} days=${days_until}"

		# gh-issue channel
		if echo "$channels" | grep -q "${ALARM_CHANNEL_GH_ISSUE}" && [[ -n "$slug" ]]; then
			_alarm_gh_issue "$resolved_case_id" "$dl_label" "$dl_date" \
				"$days_until" "$computed_stage" "$slug" >/dev/null
		fi
		# ntfy channel
		if echo "$channels" | grep -q "${ALARM_CHANNEL_NTFY}" && [[ -n "$ntfy_topic" ]]; then
			_alarm_ntfy "$resolved_case_id" "$dl_label" "$dl_date" \
				"$days_until" "$computed_stage" "$ntfy_topic"
		fi
		# email stub
		if echo "$channels" | grep -q "${ALARM_CHANNEL_EMAIL}"; then
			_alarm_email "$resolved_case_id" "$dl_label" "$days_until" "$computed_stage"
		fi
	done

	print_success "alarm-test complete for: ${resolved_case_id} (${deadline_count} deadline(s) tested)"
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Case Alarm Helper (t2853 P4c) — pulse-driven deadline alarming

Usage: case-alarm-helper.sh <command> [options]

Commands:
  tick [--repo <path>] [--dry-run]
      Scan all open cases, classify deadlines by urgency stage, and fire
      alarms when a stage escalation is detected. Stores state in
      _cases/.alarm-state.json to prevent duplicate alarms.

  alarm-test <case-id> [--repo <path>]
      Bypass stage memory and re-fire alarms for all deadlines on the
      specified case. For testing and debugging only.

  help
      Show this help.

Alarm stages:
  green   >30d (no alarm)
  amber   ≤30d (configurable)
  red     ≤7d  (configurable)
  passed  deadline date has been reached (auto-close GH issue)

Config file (optional): _config/case-alarms.json
  {
    "stages_days": [30, 7, 1],
    "channels":    [gh-issue, ntfy],
    "ntfy_topic":  "aidevops-case-alarms",
    "per_case_overrides": {}
  }

Alarm state: _cases/.alarm-state.json (managed automatically)

Examples:
  case-alarm-helper.sh tick
  case-alarm-helper.sh tick --dry-run
  case-alarm-helper.sh alarm-test case-2026-0001-acme-dispute
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	tick)        cmd_tick "$@" ;;
	alarm-test)  cmd_alarm_test "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
