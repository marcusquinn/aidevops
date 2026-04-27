#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2016
# SC2016: jq filters in single quotes use $var as jq variables (bound by --arg), not shell vars
set -euo pipefail

# =============================================================================
# Case Alarm Helper (t2853 — P4c: case milestone + deadline alarming routine)
# =============================================================================
# Pulse-driven routine that scans open cases for upcoming deadlines,
# classifies each by urgency stage, and fires alarms via configured channels.
#
# Usage:
#   case-alarm-helper.sh tick [<repo-path>]         Pulse routine: scan all open cases
#   case-alarm-helper.sh alarm-test <case-id> [<repo-path>]  Force-fire alarms for a case
#   case-alarm-helper.sh help
#
# Config:   <repo>/_config/case-alarms.json  (created from template on first run)
# State:    <repo>/_cases/.alarm-state.json  (tracks last-alarmed stage per case+deadline)
# Channels: gh-issue, ntfy, email (stub for MVP)
#
# Stage classification (default config):
#   red    — deadline within 7 days
#   amber  — deadline within 30 days (but > 7)
#   green  — deadline > 30 days away (no alarm)
#
# Part of the cases plane (t2851/t2852/t2853).
# Parent: t2840 / GH#20892
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
if [[ -f "${SCRIPT_DIR}/shared-gh-wrappers.sh" ]]; then
	source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
fi

init_log_file

readonly LOG_PREFIX="ALARM"
readonly CASES_DIR_NAME="_cases"
readonly ALARM_STATE_FILE=".alarm-state.json"
readonly DEFAULT_CONFIG_NAME="_config/case-alarms.json"
readonly ALARM_ISSUE_TITLE_PREFIX="Case alarm:"
readonly ALARM_ISSUE_LABEL="kind:case-alarm"

# Stage name constants (avoid repeated string literals — S1192 ratchet)
readonly STAGE_GREEN="green"
readonly STAGE_AMBER="amber"
readonly STAGE_RED="red"
readonly STAGE_YELLOW="yellow"
readonly STAGE_PASSED="passed"
readonly JQ_NULL="null"

# =============================================================================
# Root resolution
# =============================================================================

_find_repo_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -d "${dir}/_cases" ]]; then
			echo "$dir"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	# Fall back to git root
	git rev-parse --show-toplevel 2>/dev/null && return 0
	return 1
}

_resolve_repo_root() {
	local candidate="${1:-}"
	if [[ -n "$candidate" ]]; then
		echo "$candidate"
		return 0
	fi
	if [[ -n "${CASES_ROOT:-}" ]]; then
		dirname "$CASES_ROOT"
		return 0
	fi
	_find_repo_root
	return 0
}

_resolve_cases_dir() {
	local repo_root="$1"
	echo "${repo_root}/${CASES_DIR_NAME}"
	return 0
}

_resolve_config_file() {
	local repo_root="$1"
	echo "${repo_root}/${DEFAULT_CONFIG_NAME}"
	return 0
}

_resolve_alarm_state() {
	local repo_root="$1"
	echo "${repo_root}/${CASES_DIR_NAME}/${ALARM_STATE_FILE}"
	return 0
}

# =============================================================================
# Config management
# =============================================================================

_load_config() {
	local config_file="$1"
	local template_file="${SCRIPT_DIR}/../templates/case-alarms-config.json"

	if [[ ! -f "$config_file" ]]; then
		local config_dir
		config_dir="$(dirname "$config_file")"
		mkdir -p "$config_dir"
		if [[ -f "$template_file" ]]; then
			cp "$template_file" "$config_file"
			log_info "Created default alarm config: $config_file"
		else
			# Fallback: emit minimal default
			printf '{"stages_days":[30,7],"channels":["gh-issue","ntfy"],"ntfy_topic":"aidevops-case-alarms","per_case_overrides":{}}\n' > "$config_file"
			log_info "Created minimal alarm config: $config_file"
		fi
	fi

	if ! jq . "$config_file" >/dev/null 2>&1; then
		log_error "Invalid JSON in config: $config_file"
		return 1
	fi
	cat "$config_file"
	return 0
}

_config_stages() {
	local config="$1" case_id="${2:-}"
	# Per-case override wins if present
	if [[ -n "$case_id" ]]; then
		local override
		override="$(echo "$config" | jq -r --arg id "$case_id" \
			'.per_case_overrides[$id].stages_days // empty' 2>/dev/null || true)"
		if [[ -n "$override" && "$override" != "$JQ_NULL" ]]; then
			echo "$override"
			return 0
		fi
	fi
	echo "$config" | jq -r '.stages_days'
	return 0
}

_config_channels() {
	local config="$1"
	echo "$config" | jq -r '.channels[]'
	return 0
}

_config_ntfy_topic() {
	local config="$1"
	echo "$config" | jq -r '.ntfy_topic // "aidevops-case-alarms"'
	return 0
}

# =============================================================================
# Stage classification
# =============================================================================

# _days_until <iso-date> — returns integer days until the date (negative if past)
_days_until() {
	local target_date="$1"
	local now_epoch target_epoch
	now_epoch="$(date -u +%s)"
	# Parse ISO date: accept YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ
	local date_part
	date_part="${target_date:0:10}"
	if command -v python3 >/dev/null 2>&1; then
		target_epoch="$(python3 -c "import time, datetime; d=datetime.date.fromisoformat('${date_part}'); t=time.mktime(d.timetuple()); print(int(t))" 2>/dev/null || echo "")"
	fi
	if [[ -z "${target_epoch:-}" ]]; then
		# Fallback: date -d on Linux, date -j on macOS
		if date --version >/dev/null 2>&1; then
			# GNU date
			target_epoch="$(date -d "${date_part}" +%s 2>/dev/null || echo "")"
		else
			# BSD/macOS date
			target_epoch="$(date -j -f "%Y-%m-%d" "${date_part}" +%s 2>/dev/null || echo "")"
		fi
	fi
	if [[ -z "${target_epoch:-}" ]]; then
		log_error "Cannot parse date: $target_date"
		echo "-999"
		return 0
	fi
	local diff_secs=$(( target_epoch - now_epoch ))
	local days=$(( diff_secs / 86400 ))
	echo "$days"
	return 0
}

# _classify_stage <days> <stages_json>
# stages_json is an array of day-thresholds like [30,7] or [60,14,3].
# Thresholds are sorted ascending internally; smallest = most urgent.
# Example: [30, 7] → green>30d, amber 8-30d, red ≤7d
# Returns: "red", "amber", "yellow", "green", or "passed"
_classify_stage() {
	local days="$1"
	local stages_json="$2"

	if [[ "$days" -lt 0 ]]; then
		echo "$STAGE_PASSED"
		return 0
	fi

	local num_stages
	num_stages="$(echo "$stages_json" | jq 'length')"

	if [[ "$num_stages" -eq 0 ]]; then
		echo "$STAGE_GREEN"
		return 0
	fi

	# Sort ascending: smallest threshold = most urgent = STAGE_RED
	# Scan from smallest to largest; first threshold that days <= to is the stage.
	# i=0 → red, i=1 → amber, i=2 → yellow, no match → green
	local sorted_stages
	sorted_stages="$(echo "$stages_json" | jq 'sort')"

	local i=0
	while [[ $i -lt "$num_stages" ]]; do
		local threshold
		threshold="$(echo "$sorted_stages" | jq --argjson i "$i" '.[$i]')"
		if [[ "$days" -le "$threshold" ]]; then
			case "$i" in
			0) echo "$STAGE_RED"    ;;
			1) echo "$STAGE_AMBER"  ;;
			*) echo "$STAGE_YELLOW" ;;
			esac
			return 0
		fi
		i=$(( i + 1 ))
	done

	echo "$STAGE_GREEN"
	return 0
}

# Stage severity index: higher = more urgent. Used to detect escalation.
_stage_index() {
	local stage="$1"
	case "$stage" in
	green)  echo "0" ;;
	yellow) echo "1" ;;
	amber)  echo "2" ;;
	red)    echo "3" ;;
	passed) echo "4" ;;
	*)      echo "0" ;;
	esac
	return 0
}

# =============================================================================
# Alarm state management
# =============================================================================

_load_alarm_state() {
	local state_file="$1"
	if [[ ! -f "$state_file" ]]; then
		echo "{}"
		return 0
	fi
	if ! jq . "$state_file" >/dev/null 2>&1; then
		log_error "Corrupt alarm state: $state_file — resetting"
		echo "{}"
		return 0
	fi
	cat "$state_file"
	return 0
}

_save_alarm_state() {
	local state_file="$1" state_json="$2"
	local state_dir
	state_dir="$(dirname "$state_file")"
	mkdir -p "$state_dir"
	printf '%s\n' "$state_json" > "$state_file"
	return 0
}

# _get_alarm_record <state_json> <case_id> <deadline_label>
_get_alarm_record() {
	local state="$1" case_id="$2" label="$3"
	echo "$state" | jq -r --arg cid "$case_id" --arg lbl "$label" \
		'.[$cid][$lbl] // empty' 2>/dev/null || true
	return 0
}

# _set_alarm_record <state_json> <case_id> <deadline_label> <stage> [<gh_issue_number>]
_set_alarm_record() {
	local state="$1" case_id="$2" label="$3" stage="$4" gh_num="${5:-}"
	local entry
	if [[ -n "$gh_num" ]]; then
		entry="$(jq -n --arg s "$stage" --arg g "$gh_num" \
			'{"stage":$s,"gh_issue":($g|tonumber)}')"
	else
		entry="$(jq -n --arg s "$stage" '{"stage":$s}')"
	fi
	echo "$state" | jq --arg cid "$case_id" --arg lbl "$label" --argjson e "$entry" \
		'.[$cid][$lbl] = $e'
	return 0
}

# _clear_alarm_record <state_json> <case_id> <deadline_label>
_clear_alarm_record() {
	local state="$1" case_id="$2" label="$3"
	echo "$state" | jq --arg cid "$case_id" --arg lbl "$label" \
		'del(.[$cid][$lbl])'
	return 0
}

# =============================================================================
# GH issue alarm channel
# =============================================================================

_gh_repo_slug() {
	git -C "${1:-$PWD}" remote get-url origin 2>/dev/null \
		| sed 's|.*github.com[:/]\(.*\)\.git|\1|; s|.*github.com[:/]\(.*\)|\1|' \
		|| true
	return 0
}

# _alarm_gh_issue <case_id> <deadline_label> <deadline_date> <days> <repo_root>
# Returns the GH issue number (or empty on failure)
_alarm_gh_issue() {
	local case_id="$1" label="$2" date="$3" days="$4" repo_root="$5"
	local slug
	slug="$(_gh_repo_slug "$repo_root")"
	if [[ -z "$slug" ]]; then
		log_info "gh-issue channel: no GitHub remote found, skipping"
		return 0
	fi

	local title="${ALARM_ISSUE_TITLE_PREFIX} ${case_id} deadline ${label}"
	local days_str
	if [[ "$days" -ge 0 ]]; then
		days_str="${days} days remaining"
	else
		days_str="PASSED ${days#-} days ago"
	fi

	local body
	body="$(cat <<EOF
## Case Deadline Alarm

| Field | Value |
|-------|-------|
| Case | \`${case_id}\` |
| Deadline | ${label} |
| Date | ${date} |
| Days remaining | ${days_str} |

Review the case and take action if required.

Alarm auto-closes when deadline passes or is removed from the case dossier.

<!-- aidevops:case-alarm case-id="${case_id}" deadline-label="${label}" -->
EOF
)"

	# Check for existing open alarm issue with this stable title
	# SC2016: $t is intentional — a jq variable bound by --arg t, not a shell variable
	# shellcheck disable=SC2016
	local existing_num
	existing_num="$(gh issue list --repo "$slug" \
		--label "$ALARM_ISSUE_LABEL" \
		--state open \
		--search "\"${title}\" in:title" \
		--json number,title \
		--jq --arg t "$title" '.[] | select(.title == $t) | .number' 2>/dev/null | head -1 || true)"

	local issue_num
	if [[ -n "$existing_num" ]]; then
		# Update existing issue with a comment
		gh issue comment "$existing_num" --repo "$slug" \
			--body "Alarm re-fired at $(date -u '+%Y-%m-%dT%H:%M:%SZ'): ${days_str}" \
			>/dev/null 2>&1 || true
		issue_num="$existing_num"
		log_info "Updated gh-issue #${issue_num} for ${case_id}/${label}"
	else
		# Create new alarm issue — use gh_create_issue wrapper (origin labelling)
		issue_num="$(gh_create_issue --repo "$slug" \
			--title "$title" \
			--body "$body" \
			--label "$ALARM_ISSUE_LABEL" \
			--json number \
			--jq '.number' 2>/dev/null || true)"
		log_info "Created gh-issue #${issue_num} for ${case_id}/${label}"
	fi

	echo "${issue_num:-}"
	return 0
}

# _close_gh_alarm_issue <case_id> <deadline_label> <gh_issue_num> <repo_root> <reason>
_close_gh_alarm_issue() {
	local case_id="$1" label="$2" issue_num="$3" repo_root="$4" reason="${5:-deadline passed}"
	local slug
	slug="$(_gh_repo_slug "$repo_root")"
	if [[ -z "$slug" || -z "$issue_num" ]]; then
		return 0
	fi
	gh issue comment "$issue_num" --repo "$slug" \
		--body "Alarm closed: ${reason} (${case_id} / ${label}) at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		>/dev/null 2>&1 || true
	gh issue close "$issue_num" --repo "$slug" >/dev/null 2>&1 || true
	log_info "Closed gh-issue #${issue_num} for ${case_id}/${label}: ${reason}"
	return 0
}

# =============================================================================
# ntfy alarm channel
# =============================================================================

# _alarm_ntfy <case_id> <deadline_label> <deadline_date> <days> <topic>
_alarm_ntfy() {
	local case_id="$1" label="$2" date="$3" days="$4" topic="${5:-aidevops-case-alarms}"
	local days_str
	if [[ "$days" -ge 0 ]]; then
		days_str="${days} days"
	else
		days_str="PASSED"
	fi

	local ntfy_server="${AIDEVOPS_NTFY_SERVER:-https://ntfy.sh}"
	local title="Case alarm: ${case_id}"
	local message="${label}: ${date} — ${days_str} remaining"

	if ! command -v curl >/dev/null 2>&1; then
		log_info "ntfy channel: curl not found, skipping"
		return 0
	fi

	local http_status
	http_status="$(curl -s -o /dev/null -w "%{http_code}" \
		-X POST "${ntfy_server}/${topic}" \
		-H "Title: ${title}" \
		-H "Priority: high" \
		-H "Tags: warning,calendar" \
		-d "${message}" 2>/dev/null || echo "000")"

	if [[ "$http_status" == "200" ]]; then
		log_info "ntfy notification sent to ${topic}: ${case_id}/${label}"
	else
		log_info "ntfy channel: HTTP ${http_status} (server may be unavailable)"
	fi
	return 0
}

# =============================================================================
# Email channel (stub — full send arrives in P5)
# =============================================================================

_alarm_email() {
	local case_id="$1" label="$2" date="$3" days="$4"
	log_info "email channel: stub (P5) — would alarm ${case_id}/${label} (${date}, ${days}d)"
	return 0
}

# =============================================================================
# Single-deadline alarm dispatcher
# =============================================================================

# _fire_alarm <case_id> <deadline_label> <deadline_date> <days> <stage> <config> <repo_root>
# Returns: gh_issue_number (or empty)
_fire_alarm() {
	local case_id="$1" label="$2" date="$3" days="$4" stage="$5"
	local config="$6" repo_root="$7"
	local gh_issue_num=""

	local channel
	while IFS= read -r channel; do
		case "$channel" in
		gh-issue)
			gh_issue_num="$(_alarm_gh_issue "$case_id" "$label" "$date" "$days" "$repo_root")"
			;;
		ntfy)
			local ntfy_topic
			ntfy_topic="$(_config_ntfy_topic "$config")"
			_alarm_ntfy "$case_id" "$label" "$date" "$days" "$ntfy_topic"
			;;
		email)
			_alarm_email "$case_id" "$label" "$date" "$days"
			;;
		*)
			log_info "Unknown alarm channel: $channel"
			;;
		esac
	done < <(_config_channels "$config")

	echo "${gh_issue_num:-}"
	return 0
}

# =============================================================================
# Core tick logic — scan all open cases
# =============================================================================

cmd_tick() {
	local repo_root
	repo_root="$(_resolve_repo_root "${1:-}")"
	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_root")"

	if [[ ! -d "$cases_dir" ]]; then
		log_info "No _cases/ directory found at ${repo_root} — nothing to alarm"
		return 0
	fi

	local config_file
	config_file="$(_resolve_config_file "$repo_root")"
	local config
	config="$(_load_config "$config_file")"

	local state_file
	state_file="$(_resolve_alarm_state "$repo_root")"
	local state
	state="$(_load_alarm_state "$state_file")"

	local cases_found=0
	local alarms_fired=0
	local alarms_closed=0

	# Iterate over active case directories (not archived/)
	local case_dir case_id dossier_file
	for case_dir in "${cases_dir}"/case-*/; do
		[[ -d "$case_dir" ]] || continue
		case_id="$(basename "$case_dir")"
		dossier_file="${case_dir}dossier.toon"
		[[ -f "$dossier_file" ]] || continue

		local dossier
		dossier="$(cat "$dossier_file")"

		# Skip non-open cases
		local status
		status="$(echo "$dossier" | jq -r '.status // "open"')"
		[[ "$status" == "open" ]] || continue

		cases_found=$(( cases_found + 1 ))

		# Get stages for this case (may have per-case override)
		local stages_json
		stages_json="$(_config_stages "$config" "$case_id")"

		# Iterate over deadlines in dossier
		local deadline_label deadline_date days stage

		while IFS= read -r deadline_json; do
			deadline_label="$(echo "$deadline_json" | jq -r '.label // "deadline"')"
			deadline_date="$(echo "$deadline_json" | jq -r '.date // ""')"
			[[ -n "$deadline_date" ]] || continue

			days="$(_days_until "$deadline_date")"
			stage="$(_classify_stage "$days" "$stages_json")"

			# Green stage = no alarm needed
			if [[ "$stage" == "$STAGE_GREEN" ]]; then
				continue
			fi

			# Passed stage: auto-close existing gh alarm and clear state
			if [[ "$stage" == "$STAGE_PASSED" ]]; then
				local record
				record="$(_get_alarm_record "$state" "$case_id" "$deadline_label")"
				if [[ -n "$record" ]]; then
					local existing_gh
					existing_gh="$(echo "$record" | jq -r '.gh_issue // empty' 2>/dev/null || true)"
					if [[ -n "$existing_gh" && "$existing_gh" != "$JQ_NULL" ]]; then
						_close_gh_alarm_issue "$case_id" "$deadline_label" \
							"$existing_gh" "$repo_root" "deadline passed"
						alarms_closed=$(( alarms_closed + 1 ))
					fi
					state="$(_clear_alarm_record "$state" "$case_id" "$deadline_label")"
				fi
				continue
			fi

			# For active stages (amber, red): check if we already alarmed at this stage
			local existing_record
			existing_record="$(_get_alarm_record "$state" "$case_id" "$deadline_label")"
			local existing_stage=""
			local existing_gh=""
			if [[ -n "$existing_record" ]]; then
				existing_stage="$(echo "$existing_record" | jq -r '.stage // ""' 2>/dev/null || true)"
				existing_gh="$(echo "$existing_record" | jq -r '.gh_issue // empty' 2>/dev/null || true)"
				[[ "$existing_gh" == "$JQ_NULL" ]] && existing_gh=""
			fi

			local current_idx existing_idx
			current_idx="$(_stage_index "$stage")"
			existing_idx="$(_stage_index "${existing_stage:-$STAGE_GREEN}")"

			# Only fire alarm if stage has escalated
			if [[ "$current_idx" -le "$existing_idx" ]]; then
				log_info "No escalation for ${case_id}/${deadline_label}: ${existing_stage} -> ${stage} (same or lower)"
				continue
			fi

			log_info "Firing ${stage} alarm for ${case_id}/${deadline_label} (${days}d until ${deadline_date})"
			local gh_num
			gh_num="$(_fire_alarm "$case_id" "$deadline_label" "$deadline_date" \
				"$days" "$stage" "$config" "$repo_root")"
			alarms_fired=$(( alarms_fired + 1 ))

			# Update state with new stage (and gh issue number if we have one)
			local new_gh="${gh_num:-$existing_gh}"
			state="$(_set_alarm_record "$state" "$case_id" "$deadline_label" "$stage" "${new_gh:-}")"

		done < <(echo "$dossier" | jq -c '.deadlines[]?' 2>/dev/null || true)
	done

	_save_alarm_state "$state_file" "$state"
	log_info "Tick complete: ${cases_found} open cases, ${alarms_fired} alarms fired, ${alarms_closed} closed"
	return 0
}

# =============================================================================
# alarm-test: force-fire alarms for a single case (bypass stage memory)
# =============================================================================

cmd_alarm_test() {
	local case_id="${1:-}"
	local repo_root
	repo_root="$(_resolve_repo_root "${2:-}")"

	if [[ -z "$case_id" ]]; then
		print_error "Usage: case-alarm-helper.sh alarm-test <case-id> [<repo-path>]"
		return 1
	fi

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_root")"
	local case_dir="${cases_dir}/${case_id}"

	if [[ ! -d "$case_dir" ]]; then
		print_error "Case not found: ${case_id} (looked in ${case_dir})"
		return 1
	fi

	local dossier_file="${case_dir}/dossier.toon"
	if [[ ! -f "$dossier_file" ]]; then
		print_error "No dossier.toon in ${case_dir}"
		return 1
	fi

	local config_file
	config_file="$(_resolve_config_file "$repo_root")"
	local config
	config="$(_load_config "$config_file")"

	local dossier
	dossier="$(cat "$dossier_file")"
	local stages_json
	stages_json="$(_config_stages "$config" "$case_id")"

	local deadline_count=0
	local fired_count=0

	local deadline_json deadline_label deadline_date days stage
	while IFS= read -r deadline_json; do
		deadline_label="$(echo "$deadline_json" | jq -r '.label // "deadline"')"
		deadline_date="$(echo "$deadline_json" | jq -r '.date // ""')"
		[[ -n "$deadline_date" ]] || continue
		deadline_count=$(( deadline_count + 1 ))

		days="$(_days_until "$deadline_date")"
		stage="$(_classify_stage "$days" "$stages_json")"

		# For alarm-test, fire even if stage is green (debugging)
		log_info "alarm-test: ${case_id}/${deadline_label} stage=${stage} days=${days}"
		_fire_alarm "$case_id" "$deadline_label" "$deadline_date" \
			"$days" "${stage}" "$config" "$repo_root" >/dev/null
		fired_count=$(( fired_count + 1 ))

	done < <(echo "$dossier" | jq -c '.deadlines[]?' 2>/dev/null || true)

	if [[ "$deadline_count" -eq 0 ]]; then
		print_warning "No deadlines found in dossier for ${case_id}"
	else
		print_success "alarm-test: fired ${fired_count} alarm(s) for ${case_id} (stage memory NOT updated)"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
case-alarm-helper.sh — deadline alarming for the cases plane (t2853)

Usage:
  case-alarm-helper.sh tick [<repo-path>]
      Pulse routine: scan all open cases, classify deadlines by stage,
      fire alarms for new/escalated stages. Updates alarm state.

  case-alarm-helper.sh alarm-test <case-id> [<repo-path>]
      Force-fire alarms for all deadlines in a case (bypass stage memory).
      Useful for testing channel config. Does NOT update alarm state.

  case-alarm-helper.sh help
      Show this help.

Alarm stages (default config):
  red    — <= 7 days remaining
  amber  — <= 30 days (> 7)
  green  — > 30 days (no alarm)

Channels:
  gh-issue   Open a GitHub issue tagged kind:case-alarm. Re-tick at same
             stage updates the issue comment, not a duplicate. Auto-closes
             when deadline passes.
  ntfy       POST to ntfy topic (curl). Server via AIDEVOPS_NTFY_SERVER
             env var (default: https://ntfy.sh).
  email      Stub for MVP (P5).

Config: <repo>/_config/case-alarms.json
State:  <repo>/_cases/.alarm-state.json

Env vars:
  CASES_ROOT              Override _cases/ location (use parent dir, not _cases/)
  AIDEVOPS_NTFY_SERVER    ntfy server URL (default: https://ntfy.sh)

HELP
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	tick)        cmd_tick "$@" ;;
	alarm-test)  cmd_alarm_test "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		exit 1
		;;
	esac
	return 0
}

main "$@"
