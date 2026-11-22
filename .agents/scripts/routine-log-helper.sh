#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# routine-log-helper.sh — Update routine tracking issue descriptions with
# living summary metrics after execution. Notable events as comments.
# Script-only shows $0 cost. Detailed logs stay local. (t1926)
#
# Usage:
#   routine-log-helper.sh update <routine-id> --status queued|claimed|running|success|failure|deferred|cancelled [--duration SECONDS] [--tokens N] [--cost AMOUNT] [--job-id ID] [--session-key KEY]
#   routine-log-helper.sh notable <routine-id> --event "description"
#   routine-log-helper.sh create-issue <routine-id> --repo SLUG --title "rNNN: Title" [--schedule EXPR] [--type TYPE]
#   routine-log-helper.sh ensure-anchor <key> --repo SLUG --title TITLE
#   routine-log-helper.sh ensure-pr-anchor <key> --repo SLUG --pr N --title TITLE
#   routine-log-helper.sh retire-anchor <badges-sync|sync-workflows> --repo SLUG
#   routine-log-helper.sh status
#   routine-log-helper.sh help
#
# State file: ~/.aidevops/.agent-workspace/cron/<routine-id>/routine-state.json
# Local logs: ~/.aidevops/.agent-workspace/cron/<routine-id>/

set -euo pipefail

# PATH normalisation for launchd/MCP environments
AIDEVOPS_PATH_PROFILE=daemon _aidevops_self="${BASH_SOURCE[0]:-$0}"
[[ "$_aidevops_self" == */* ]] || _aidevops_self="./${_aidevops_self}"
# shellcheck source=runtime-env.sh
[[ ! -f "${_aidevops_self%/*}/runtime-env.sh" ]] || source "${_aidevops_self%/*}/runtime-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

CRON_BASE="${HOME}/.aidevops/.agent-workspace/cron"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
PERIOD_DAYS=7
# Set before an anchor is closed; cleared only once retirement or restoration
# completes, so an interrupted step is retried in any issue state.
ANCHOR_RETIRING_LABEL="routine-anchor-retiring"
ANCHOR_OPEN_STATE="OPEN"

# =============================================================================
# Logging
# =============================================================================

_log_info() {
	local msg="$1"
	echo -e "${BLUE}[INFO]${NC} ${msg}" >&2
	return 0
}

_log_warn() {
	local msg="$1"
	echo -e "${YELLOW}[WARN]${NC} ${msg}" >&2
	return 0
}

_log_error() {
	local msg="$1"
	echo -e "${RED}[ERROR]${NC} ${msg}" >&2
	return 0
}

_log_success() {
	local msg="$1"
	echo -e "${GREEN}[OK]${NC} ${msg}" >&2
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		_log_error "gh CLI not found. Install from https://cli.github.com/"
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		_log_error "jq not found. Install with: brew install jq / apt install jq"
		return 1
	fi
	return 0
}

# =============================================================================
# State management
# =============================================================================

_state_dir() {
	local routine_id="$1"
	echo "${CRON_BASE}/${routine_id}"
}

_state_file() {
	local routine_id="$1"
	echo "$(_state_dir "$routine_id")/routine-state.json"
}

_ensure_state_dir() {
	local routine_id="$1"
	local dir
	dir="$(_state_dir "$routine_id")"
	mkdir -p "$dir" || return 1
	return 0
}

_is_valid_issue_number() {
	local issue_number="$1"
	[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] && return 0
	return 1
}

# GH#39144: state written before this fix could hold wrapper diagnostics
# merged into the issue number (e.g. "37993\n18"). The created issue's URL was
# always the last captured line, so its number is the last line of the value.
# Outputs the healed number; returns 1 when the value cannot be healed.
_heal_issue_number() {
	local raw="$1"
	local last_line="${raw##*$'\n'}"
	_is_valid_issue_number "$last_line" || return 1
	printf '%s\n' "$last_line"
	return 0
}

_read_state() {
	local routine_id="$1"
	local state_file
	state_file="$(_state_file "$routine_id")"
	if [[ ! -f "$state_file" ]]; then
		echo '{}'
		return 0
	fi

	local state raw_issue healed_issue healed_state
	state=$(cat "$state_file")
	raw_issue=$(printf '%s' "$state" | jq -r '.issue_number // empty | tostring' 2>/dev/null || true)
	if [[ -n "$raw_issue" ]] && ! _is_valid_issue_number "$raw_issue"; then
		if healed_issue=$(_heal_issue_number "$raw_issue") &&
			healed_state=$(printf '%s' "$state" | jq --arg in "$healed_issue" '.issue_number = $in'); then
			# Read-path repair stays in memory only: writing here would race
			# with unlocked state writers and could clobber their newer data.
			# The next full-state write persists the healed value.
			state="$healed_state"
			_log_warn "Healed malformed issue_number for ${routine_id} to #${healed_issue} in memory (GH#39144); persisted on next state write"
		else
			_log_warn "Malformed issue_number for ${routine_id} could not be healed; fix ${state_file} manually"
		fi
	fi
	printf '%s\n' "$state"
	return 0
}

# Write via temp file + rename so readers never see a truncated snapshot.
_write_state_atomic() {
	local routine_id="$1"
	local state_json="$2"
	local state_file tmp_file
	state_file="$(_state_file "$routine_id")"
	_ensure_state_dir "$routine_id" || return 1
	tmp_file="${state_file}.tmp.$$"
	if ! printf '%s\n' "$state_json" >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	mv -f "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
	return 0
}

_write_state() {
	local routine_id="$1"
	local state_json="$2"
	local state_file
	state_file="$(_state_file "$routine_id")"
	_ensure_state_dir "$routine_id" || return 1
	echo "$state_json" >"$state_file" || return 1
	return 0
}

_get_state_field() {
	local routine_id="$1"
	local field="$2"
	local default="${3:-}"
	local value
	value=$(_read_state "$routine_id" | jq -r ".${field} // empty")
	if [[ -z "$value" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

# =============================================================================
# Local log management
# =============================================================================

_append_local_log() {
	local routine_id="$1"
	local status="$2"
	local duration="$3"
	local tokens="${4:-0}"
	local cost="${5:-0.00}"
	local log_dir
	log_dir="$(_state_dir "$routine_id")/logs"
	mkdir -p "$log_dir"

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local log_entry
	log_entry=$(jq -n \
		--arg ts "$timestamp" \
		--arg st "$status" \
		--argjson dur "$duration" \
		--argjson tok "$tokens" \
		--arg cost "$cost" \
		'{timestamp: $ts, status: $st, duration: $dur, tokens: $tok, cost: $cost}')

	echo "$log_entry" >>"${log_dir}/executions.jsonl"
	return 0
}

_compute_period_summary() {
	local routine_id="$1"
	local log_file
	log_file="$(_state_dir "$routine_id")/logs/executions.jsonl"

	if [[ ! -f "$log_file" ]]; then
		echo '{"total":0,"successes":0,"failures":0,"total_cost":"0.00","avg_duration":0,"period_start":"","period_end":""}'
		return 0
	fi

	local cutoff_ts
	cutoff_ts=$(date -u -d "${PERIOD_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -v-${PERIOD_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		echo "1970-01-01T00:00:00Z")

	local period_start
	period_start=$(date -u -d "${PERIOD_DAYS} days ago" +%Y-%m-%d 2>/dev/null ||
		date -u -v-${PERIOD_DAYS}d +%Y-%m-%d 2>/dev/null ||
		echo "unknown")
	local period_end
	period_end=$(date -u +%Y-%m-%d)

	# Filter entries within period and compute aggregates
	local result
	result=$(jq -s --arg cutoff "$cutoff_ts" '
        [.[] | select(.timestamp >= $cutoff)] |
        {
            total: length,
            successes: [.[] | select(.status == "success")] | length,
            failures: [.[] | select(.status == "failure")] | length,
            total_cost: ([.[] | .cost | tonumber] | add // 0 | . * 100 | round / 100 | tostring),
            avg_duration: (if length > 0 then ([.[] | .duration] | add / length | round) else 0 end)
        }
    ' "$log_file" 2>/dev/null || echo '{"total":0,"successes":0,"failures":0,"total_cost":"0.00","avg_duration":0}')

	# Add period dates
	result=$(echo "$result" | jq --arg ps "$period_start" --arg pe "$period_end" \
		'. + {period_start: $ps, period_end: $pe}')

	echo "$result"
	return 0
}

# =============================================================================
# Duration formatting
# =============================================================================

_format_duration() {
	local seconds="$1"
	local mins=$((seconds / 60))
	local secs=$((seconds % 60))
	if [[ "$mins" -gt 0 ]]; then
		echo "${mins}m ${secs}s"
	else
		echo "${secs}s"
	fi
	return 0
}

# =============================================================================
# Streak tracking
# =============================================================================

_update_streak() {
	local routine_id="$1"
	local new_status="$2"
	local current_streak_count
	current_streak_count=$(_get_state_field "$routine_id" "streak_count" "0")
	local current_streak_type
	current_streak_type=$(_get_state_field "$routine_id" "streak_type" "")

	local streak_broke="false"

	if [[ "$current_streak_type" == "$new_status" ]]; then
		current_streak_count=$((current_streak_count + 1))
	else
		if [[ -n "$current_streak_type" ]] && [[ "$current_streak_count" -ge 3 ]]; then
			streak_broke="true"
		fi
		current_streak_count=1
		current_streak_type="$new_status"
	fi

	# Update state
	local state
	state=$(_read_state "$routine_id")
	state=$(echo "$state" | jq \
		--argjson count "$current_streak_count" \
		--arg type "$current_streak_type" \
		'.streak_count = $count | .streak_type = $type')
	_write_state "$routine_id" "$state"

	echo "$streak_broke"
	return 0
}

# =============================================================================
# Next run computation
# =============================================================================

_compute_next_run() {
	local schedule="$1"
	local now_ts
	now_ts=$(date -u +%s)

	# Parse schedule expressions
	case "$schedule" in
	daily\(@*\))
		local time_part
		time_part=$(echo "$schedule" | sed -E 's/daily\(@([0-9:]+)\)/\1/')
		local hour minute
		hour=$(echo "$time_part" | cut -d: -f1)
		minute=$(echo "$time_part" | cut -d: -f2)
		# Next occurrence: tomorrow at that time
		local tomorrow
		tomorrow=$(date -u -d "tomorrow ${hour}:${minute}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
			date -u -v+1d -v"${hour}"H -v"${minute}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
			echo "unknown")
		echo "$tomorrow"
		;;
	weekly\(*\))
		echo "~7 days"
		;;
	monthly\(*\))
		echo "~30 days"
		;;
	cron\(*\))
		echo "per cron schedule"
		;;
	*)
		echo "unknown"
		;;
	esac
	return 0
}

# =============================================================================
# Issue body template
# =============================================================================

_routing_feedback_for_session() {
	local session_key="$1"
	[[ -n "$session_key" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local helper="${AIDEVOPS_ROUTING_FEEDBACK_HELPER:-${SCRIPT_DIR}/routing-feedback.mjs}"
	[[ -r "$helper" ]] || return 0
	node "$helper" --session-key "$session_key" --format markdown --heading-level 3 2>/dev/null || true
	return 0
}

_build_issue_body() {
	local routine_id="$1"
	local title="$2"
	local schedule="$3"
	local routine_type="$4"
	local status_label="$5"
	local last_run="$6"
	local last_result="$7"
	local last_duration="$8"
	local next_run="$9"
	local streak_count="${10}"
	local streak_type="${11}"
	local total_cost="${12}"
	local period_summary="${13}"
	local routing_feedback="${14:-}"

	local formatted_duration
	formatted_duration=$(_format_duration "$last_duration")

	local streak_label
	if [[ "$streak_count" -gt 0 ]] && [[ -n "$streak_type" ]]; then
		local plural="successes"
		[[ "$streak_type" == "failure" ]] && plural="failures"
		streak_label="${streak_count} consecutive ${plural}"
	else
		streak_label="—"
	fi

	# Parse period summary
	local p_total p_successes p_cost p_avg_dur p_start p_end
	p_total=$(echo "$period_summary" | jq -r '.total')
	p_successes=$(echo "$period_summary" | jq -r '.successes')
	p_cost=$(echo "$period_summary" | jq -r '.total_cost')
	p_avg_dur=$(echo "$period_summary" | jq -r '.avg_duration')
	p_start=$(echo "$period_summary" | jq -r '.period_start')
	p_end=$(echo "$period_summary" | jq -r '.period_end')

	local p_avg_formatted
	p_avg_formatted=$(_format_duration "$p_avg_dur")

	local last_result_display
	if [[ "$last_result" == "none" ]] || [[ -z "$last_result" ]]; then
		last_result_display="—"
	else
		last_result_display="${last_result} (${formatted_duration})"
	fi

	local last_run_display
	if [[ "$last_run" == "never" ]] || [[ -z "$last_run" ]]; then
		last_run_display="—"
	else
		last_run_display="$last_run"
	fi

	# Read optional description and management sections from state
	local description=""
	local management=""
	local state_dir="${CRON_BASE}/${routine_id}"
	if [[ -f "${state_dir}/routine-state.json" ]]; then
		description=$(jq -r '.description // ""' "${state_dir}/routine-state.json" 2>/dev/null || echo "")
		management=$(jq -r '.management // ""' "${state_dir}/routine-state.json" 2>/dev/null || echo "")
	fi

	cat <<EOF
## ${title}

| Field | Value |
|-------|-------|
| Schedule | ${schedule} |
| Type | ${routine_type} |
| Status | ${status_label} |
| Last run | ${last_run_display} |
| Last result | ${last_result_display} |
| Next run | ${next_run} |
| Streak | ${streak_label} |
| Total cost | \$${total_cost} |

This is the persistent tracking anchor for routine \`${routine_id}\` in TODO.md,
not a one-off implementation task. Keep it open. Routine PRs must reference this
issue with a standalone \`Ref #N\` line (using this issue's number), never a
closing keyword. The maintainer-authored routine SOP defines the work.

### Latest Period (${p_start} — ${p_end})
${p_successes}/${p_total} runs succeeded. Total cost: \$${p_cost}. Avg duration: ${p_avg_formatted}.

**Detailed logs**: \`~/.aidevops/.agent-workspace/cron/${routine_id}/\`
EOF

	if [[ -n "$routing_feedback" ]]; then
		printf '\n%s\n' "$routing_feedback"
	fi

	# Append description if present
	if [[ -n "$description" ]]; then
		cat <<EOF

---

### What this routine does

${description}
EOF
	fi

	# Append management instructions if present
	if [[ -n "$management" ]]; then
		cat <<EOF

---

${management}
EOF
	fi

	return 0
}

# =============================================================================
# Subcommand: update — helpers
# =============================================================================

# Parse and validate arguments for the update subcommand.
# Sets module-scope _UPDATE_* variables for the caller.
# Returns 1 on invalid input.
_parse_update_args() {
	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh update <routine-id> --status queued|claimed|running|success|failure|deferred|cancelled [--duration SECONDS] [--tokens N] [--cost AMOUNT] [--job-id ID] [--session-key KEY]"
		return 1
	fi
	# shellcheck disable=SC2034
	_UPDATE_ROUTINE_ID="$1"
	shift

	_UPDATE_STATUS=""
	_UPDATE_DURATION=""
	_UPDATE_TOKENS="0"
	_UPDATE_COST="0.00"
	_UPDATE_JOB_ID=""
	_UPDATE_SESSION_KEY=""
	_UPDATE_OUTCOME=""

	while [[ $# -gt 0 ]]; do
		local option="$1"
		if [[ "$option" == --* && $# -lt 2 ]]; then
			_log_error "$option requires a value"
			return 1
		fi
		case "$option" in
		--status)
			_UPDATE_STATUS="$2"
			shift 2
			;;
		--duration)
			_UPDATE_DURATION="$2"
			shift 2
			;;
		--tokens)
			_UPDATE_TOKENS="$2"
			shift 2
			;;
		--cost)
			_UPDATE_COST="$2"
			shift 2
			;;
		--job-id)
			_UPDATE_JOB_ID="$2"
			shift 2
			;;
		--session-key)
			_UPDATE_SESSION_KEY="$2"
			shift 2
			;;
		--outcome)
			_UPDATE_OUTCOME="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $option"
			return 1
			;;
		esac
	done

	if [[ -z "$_UPDATE_STATUS" ]]; then
		_log_error "--status is required"
		return 1
	fi

	case "$_UPDATE_STATUS" in
	queued | claimed | running | success | failure | deferred | cancelled) ;;
	*)
		_log_error "Status must be queued, claimed, running, success, failure, deferred, or cancelled"
		return 1
		;;
	esac

	if [[ "$_UPDATE_STATUS" == "success" || "$_UPDATE_STATUS" == "failure" ]]; then
		if [[ -z "$_UPDATE_DURATION" ]]; then
			_log_error "--duration is required for success and failure"
			return 1
		fi
	elif [[ -z "$_UPDATE_DURATION" ]]; then
		_UPDATE_DURATION="0"
	fi
	if [[ ! "$_UPDATE_DURATION" =~ ^[0-9]+$ ]] || [[ ! "$_UPDATE_TOKENS" =~ ^[0-9]+$ ]] ||
		[[ ! "$_UPDATE_COST" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		_log_error "Duration and tokens must be non-negative integers; cost must be numeric"
		return 1
	fi

	return 0
}

_append_lifecycle_log() {
	local routine_id="$1"
	local status="$2"
	local duration="$3"
	local tokens="$4"
	local cost="$5"
	local job_id="$6"
	local session_key="$7"
	local outcome="$8"
	local timestamp=""
	local lifecycle_file=""
	local record=""
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	lifecycle_file="$(_state_dir "$routine_id")/lifecycle.jsonl"
	record=$(jq -cn \
		--arg timestamp "$timestamp" --arg status "$status" \
		--argjson duration "$duration" --argjson tokens "$tokens" \
		--arg cost "$cost" --arg job_id "$job_id" \
		--arg session_key "$session_key" --arg outcome "$outcome" \
		'{timestamp:$timestamp,status:$status,duration_seconds:$duration,tokens:$tokens,cost:$cost,
		  job_id:(if $job_id == "" then null else $job_id end),
		  session_key:(if $session_key == "" then null else $session_key end),
		  outcome:(if $outcome == "" then null else $outcome end)}') || return 1
	printf '%s\n' "$record" >>"$lifecycle_file"
	chmod 600 "$lifecycle_file"
	return 0
}

# Load routine state and extract common fields needed by update.
# Validates that a tracking issue exists. Outputs JSON state to stdout.
# Returns 1 if no tracking issue is configured.
_load_routine_state() {
	local routine_id="$1"
	local state
	state=$(_read_state "$routine_id")
	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')

	if [[ -z "$issue_number" ]] || [[ -z "$repo_slug" ]]; then
		_log_error "No tracking issue found for ${routine_id}. Run 'create-issue' first."
		return 1
	fi
	if ! _is_valid_issue_number "$issue_number"; then
		_log_error "Invalid tracking issue number for ${routine_id}: ${issue_number}"
		return 1
	fi

	echo "$state"
	return 0
}

# Update state JSON with latest run metrics and persist to disk.
# Args: routine_id, state_json, status, duration, cost, schedule, session_key
# Outputs the new total_cost to stdout.
_update_state_after_run() {
	local routine_id="$1"
	local state="$2"
	local status="$3"
	local duration="$4"
	local cost="$5"
	local schedule="$6"
	local session_key="${7:-}"

	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Accumulate total cost
	local prev_total_cost
	prev_total_cost=$(echo "$state" | jq -r '.total_cost // "0.00"')
	local new_total_cost
	new_total_cost=$(echo "$prev_total_cost $cost" | awk '{printf "%.2f", $1 + $2}')

	# Compute next run
	local next_run
	next_run=$(_compute_next_run "$schedule")

	# Save updated state
	state=$(echo "$state" | jq \
		--arg lr "$now_ts" \
		--arg ls "$status" \
		--argjson ld "$duration" \
		--arg nr "$next_run" \
		--arg tc "$new_total_cost" \
		--arg sk "$session_key" \
		'if .last_success == null and .last_status == "success" then .last_success = .last_run else . end
		 | .last_run = $lr | .last_status = $ls | .last_duration = $ld | .next_run = $nr | .total_cost = $tc
		 | if $ls == "success" then .last_success = $lr else . end
		 | .last_session_key = (if $sk == "" then (.last_session_key // null) else $sk end)')
	_write_state "$routine_id" "$state"

	echo "$new_total_cost"
	return 0
}

# Build the updated issue body and push it to GitHub.
# Args: routine_id, issue_number, repo_slug, title, schedule, routine_type,
#       status_label, now_ts, status, duration, next_run, streak_count,
#       streak_type, total_cost, session_key
_update_tracking_issue() {
	local routine_id="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local title="$4"
	local schedule="$5"
	local routine_type="$6"
	local status_label="$7"
	local now_ts="$8"
	local status="$9"
	local duration="${10}"
	local next_run="${11}"
	local streak_count="${12}"
	local streak_type="${13}"
	local total_cost="${14}"
	local session_key="${15:-}"

	# Compute period summary
	local period_summary
	period_summary=$(_compute_period_summary "$routine_id")
	local routing_feedback=""
	routing_feedback=$(_routing_feedback_for_session "$session_key")

	# Build new issue body
	local new_body
	new_body=$(_build_issue_body \
		"$routine_id" \
		"$title" \
		"$schedule" \
		"$routine_type" \
		"$status_label" \
		"$now_ts" \
		"$status" \
		"$duration" \
		"$next_run" \
		"$streak_count" \
		"$streak_type" \
		"$total_cost" \
		"$period_summary" \
		"$routing_feedback")

	# Update issue description
	if gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --body "$new_body" &>/dev/null; then
		_log_success "Updated issue #${issue_number} for ${routine_id} (${status}, ${duration}s)"
	else
		_log_error "Failed to update issue #${issue_number} for ${routine_id}"
		return 1
	fi

	return 0
}

# =============================================================================
# Subcommand: update
# =============================================================================

cmd_update() {
	_parse_update_args "$@" || return 1

	local routine_id="$_UPDATE_ROUTINE_ID"
	local status="$_UPDATE_STATUS"
	local duration="$_UPDATE_DURATION"
	local tokens="$_UPDATE_TOKENS"
	local cost="$_UPDATE_COST"
	local job_id="$_UPDATE_JOB_ID"
	local session_key="$_UPDATE_SESSION_KEY"
	local outcome="$_UPDATE_OUTCOME"

	if ! command -v jq &>/dev/null; then
		_log_error "jq not found"
		return 1
	fi
	_ensure_state_dir "$routine_id"
	chmod 700 "$(_state_dir "$routine_id")"
	_append_lifecycle_log "$routine_id" "$status" "$duration" "$tokens" "$cost" "$job_id" "$session_key" "$outcome" || return 1

	# Launch and cancellation records are lifecycle evidence only. They must not
	# increment totals, streaks, costs, or completed-run summaries.
	if [[ "$status" != "success" && "$status" != "failure" ]]; then
		_log_success "Recorded ${status} lifecycle for ${routine_id}"
		return 0
	fi

	_check_prerequisites || return 1

	# Load and validate state
	local state
	state=$(_load_routine_state "$routine_id") || return 1
	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')
	local title
	title=$(echo "$state" | jq -r '.title // "Untitled Routine"')
	local schedule
	schedule=$(echo "$state" | jq -r '.schedule // "unknown"')
	local routine_type
	routine_type=$(echo "$state" | jq -r '.routine_type // "unknown"')
	local status_label
	status_label=$(echo "$state" | jq -r '.status_label // "active"')

	# Determine cost: run: routines always show $0.00
	if [[ "$routine_type" == script* ]]; then
		cost="0.00"
		tokens="0"
	fi

	# Append to local log
	_append_local_log "$routine_id" "$status" "$duration" "$tokens" "$cost"

	# Update streak
	local streak_broke
	streak_broke=$(_update_streak "$routine_id" "$status")

	# Re-read state after streak update
	state=$(_read_state "$routine_id")
	local streak_count
	streak_count=$(echo "$state" | jq -r '.streak_count // 0')
	local streak_type
	streak_type=$(echo "$state" | jq -r '.streak_type // ""')

	# Update state with run metrics
	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local new_total_cost
	new_total_cost=$(_update_state_after_run "$routine_id" "$state" "$status" "$duration" "$cost" "$schedule" "$session_key")

	local next_run
	next_run=$(_compute_next_run "$schedule")

	# Update the tracking issue on GitHub
	_update_tracking_issue \
		"$routine_id" "$issue_number" "$repo_slug" "$title" "$schedule" \
		"$routine_type" "$status_label" "$now_ts" "$status" "$duration" \
		"$next_run" "$streak_count" "$streak_type" "$new_total_cost" "$session_key" || return 1

	# Post notable event if streak broke
	if [[ "$streak_broke" == "true" ]]; then
		cmd_notable "$routine_id" --event "Streak broken: was ${streak_count} consecutive, now ${status}"
	fi

	return 0
}

# =============================================================================
# Subcommand: refresh-description
# =============================================================================

# Rebuild and push the GitHub issue body for an existing routine using the
# current state and stored description data, without recording a new run entry.
# Use this when routine description or management text has been updated and
# the GitHub issue body should reflect the changes (GH#18616).
# Args: <routine-id>
cmd_refresh_description() {
	local routine_id=""

	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh refresh-description <routine-id>"
		return 1
	fi
	routine_id="$1"

	_check_prerequisites || return 1
	_ensure_state_dir "$routine_id"

	# Load and validate state — must have a tracking issue already
	local state
	state=$(_load_routine_state "$routine_id") || return 1

	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')
	local title
	title=$(echo "$state" | jq -r '.title // "Untitled Routine"')
	local schedule
	schedule=$(echo "$state" | jq -r '.schedule // "unknown"')
	local routine_type
	routine_type=$(echo "$state" | jq -r '.routine_type // "unknown"')
	local status_label
	status_label=$(echo "$state" | jq -r '.status_label // "active"')
	local last_run
	last_run=$(echo "$state" | jq -r '.last_run // "never"')
	local last_status
	last_status=$(echo "$state" | jq -r '.last_status // "none"')
	local last_duration
	last_duration=$(echo "$state" | jq -r '.last_duration // 0')
	local next_run
	next_run=$(echo "$state" | jq -r '.next_run // "pending first run"')
	local streak_count
	streak_count=$(echo "$state" | jq -r '.streak_count // 0')
	local streak_type
	streak_type=$(echo "$state" | jq -r '.streak_type // ""')
	local total_cost
	total_cost=$(echo "$state" | jq -r '.total_cost // "0.00"')

	# Compute period summary from existing log — no new entry added
	local period_summary
	period_summary=$(_compute_period_summary "$routine_id")

	# Build issue body using current state; no metrics are modified
	local new_body
	new_body=$(_build_issue_body \
		"$routine_id" \
		"$title" \
		"$schedule" \
		"$routine_type" \
		"$status_label" \
		"$last_run" \
		"$last_status" \
		"$last_duration" \
		"$next_run" \
		"$streak_count" \
		"$streak_type" \
		"$total_cost" \
		"$period_summary")

	# Push updated body to GitHub
	if gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --body "$new_body" &>/dev/null; then
		_log_success "Refreshed description for issue #${issue_number} (${routine_id}) — no run entry recorded"
	else
		_log_error "Failed to refresh issue #${issue_number} for ${routine_id}"
		return 1
	fi

	return 0
}

# =============================================================================
# Subcommand: notable
# =============================================================================

cmd_notable() {
	local routine_id=""
	local event=""

	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh notable <routine-id> --event \"description\""
		return 1
	fi
	routine_id="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--event)
			event="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$event" ]]; then
		_log_error "--event is required"
		return 1
	fi

	_check_prerequisites || return 1

	local state
	state=$(_read_state "$routine_id")
	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')

	if [[ -z "$issue_number" ]] || [[ -z "$repo_slug" ]]; then
		_log_error "No tracking issue found for ${routine_id}. Run 'create-issue' first."
		return 1
	fi
	if ! _is_valid_issue_number "$issue_number"; then
		_log_error "Invalid tracking issue number for ${routine_id}: ${issue_number}"
		return 1
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Build comment body
	local comment_body
	comment_body="### Notable Event

**Routine:** ${routine_id}
**Time:** ${timestamp}
**Event:** ${event}"

	# Append signature footer if available
	local footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer 2>/dev/null || true)
	fi
	if [[ -n "$footer" ]]; then
		comment_body="${comment_body}

${footer}"
	fi

	if gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null; then
		_log_success "Posted notable event on issue #${issue_number}: ${event}"
	else
		_log_error "Failed to post notable event on issue #${issue_number}"
		return 1
	fi

	return 0
}

# =============================================================================
# Subcommand: create-issue — helpers
# =============================================================================

# Parse and validate arguments for the create-issue subcommand.
# Sets _CI_* variables in caller scope.
# Returns 1 on invalid input.
_parse_create_issue_args() {
	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh create-issue <routine-id> --repo SLUG --title \"rNNN: Title\" [--schedule EXPR] [--type TYPE]"
		return 1
	fi
	_CI_ROUTINE_ID="$1"
	shift

	_CI_REPO_SLUG=""
	_CI_TITLE=""
	_CI_SCHEDULE=""
	_CI_ROUTINE_TYPE=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			_CI_REPO_SLUG="$2"
			shift 2
			;;
		--title)
			_CI_TITLE="$2"
			shift 2
			;;
		--schedule)
			_CI_SCHEDULE="$2"
			shift 2
			;;
		--type)
			_CI_ROUTINE_TYPE="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$_CI_REPO_SLUG" ]] || [[ -z "$_CI_TITLE" ]]; then
		_log_error "--repo and --title are required"
		return 1
	fi

	# Set defaults
	[[ -z "$_CI_SCHEDULE" ]] && _CI_SCHEDULE="unknown"
	[[ -z "$_CI_ROUTINE_TYPE" ]] && _CI_ROUTINE_TYPE="unknown"

	return 0
}

# Provision tracking labels even in repositories that never ran routine logging.
# Existing label metadata is left unchanged. API/creation failures fail closed.
_ensure_tracking_labels() {
	local repo_slug="$1"
	_ensure_labels "$repo_slug" routines routine-tracking persistent no-auto-dispatch
	return $?
}

# _ensure_labels <repo> <label>... — create any missing label; fail closed.
_ensure_labels() {
	local repo_slug="$1"
	local label=""
	shift
	for label in "$@"; do
		if ! gh api "repos/${repo_slug}/labels/${label}" --silent 2>/dev/null; then
			if ! gh label create "$label" --repo "$repo_slug" --color BFD4F2 \
				--description "Routine tracking lifecycle: ${label}" >/dev/null 2>&1; then
				# Another setup may have created it concurrently.
				gh api "repos/${repo_slug}/labels/${label}" --silent 2>/dev/null || return 1
			fi
		fi
	done
	return 0
}

# Create a GitHub issue and extract the issue number from the returned URL.
# Args: repo_slug, title, body
# Outputs the issue number to stdout. Returns 1 on failure.
_create_github_issue() {
	local repo_slug="$1"
	local title="$2"
	local body="$3"

	_ensure_tracking_labels "$repo_slug" || return 1
	local issue_output body_file
	body_file=$(mktemp) || return 1
	printf '%s\n' "$body" >"$body_file"
	# t2115: Use gh_create_issue wrapper for origin label + signature auto-append.
	# GH#39144: capture stdout only. Wrapper diagnostics stay on stderr; merging
	# them corrupted the parsed issue number (e.g. "... per GH#37993").
	if ! issue_output=$(gh_create_issue --repo "$repo_slug" --title "$title" --body-file "$body_file" \
		--label "routines" --label "routine-tracking" \
		--label "persistent" --label "no-auto-dispatch"); then
		rm -f "$body_file"
		_log_error "Failed to create issue in ${repo_slug}: ${issue_output}"
		return 1
	fi
	rm -f "$body_file"

	# Use the last canonical issue URL line (framework-issue-helper.sh pattern).
	local issue_url="" line=""
	local url_re='^https://[^[:space:]]+/issues/[0-9]+$'
	while IFS= read -r line; do
		[[ "$line" =~ $url_re ]] && issue_url="$line"
	done <<<"$issue_output"

	local issue_number="${issue_url##*/}"
	if [[ -z "$issue_url" ]] || ! _is_valid_issue_number "$issue_number"; then
		_log_error "Could not extract issue number from: ${issue_output}"
		return 1
	fi

	echo "$issue_number"
	return 0
}

# Persist initial routine state after issue creation.
# Args: routine_id, issue_number, repo_slug, title, schedule, routine_type
_save_initial_state() {
	local routine_id="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local title="$4"
	local schedule="$5"
	local routine_type="$6"

	if ! _is_valid_issue_number "$issue_number"; then
		_log_error "Refusing to persist invalid issue number for ${routine_id}: ${issue_number}"
		return 1
	fi

	local state
	state=$(_read_state "$routine_id")
	if ! state=$(echo "$state" | jq \
		--arg in "$issue_number" \
		--arg rs "$repo_slug" \
		--arg t "$title" \
		--arg s "$schedule" \
		--arg rt "$routine_type" \
		--arg sl "active" \
		--arg tc "0.00" \
		'.issue_number = $in | .repo_slug = $rs | .title = $t | .schedule = $s | .routine_type = $rt | .status_label = $sl | .total_cost = $tc'); then
		_log_error "Could not build state for ${routine_id} (issue #${issue_number})"
		return 1
	fi
	if ! _write_state "$routine_id" "$state"; then
		_log_error "Could not persist state for ${routine_id}; issue #${issue_number} was created but is not recorded"
		return 1
	fi
	return 0
}

# =============================================================================
# Subcommand: create-issue
# =============================================================================

cmd_create_issue() {
	_parse_create_issue_args "$@" || return 1

	local routine_id="$_CI_ROUTINE_ID"
	local repo_slug="$_CI_REPO_SLUG"
	local title="$_CI_TITLE"
	local schedule="$_CI_SCHEDULE"
	local routine_type="$_CI_ROUTINE_TYPE"

	_check_prerequisites || return 1
	_ensure_state_dir "$routine_id"

	# Check if issue already exists
	local existing_issue
	existing_issue=$(_get_state_field "$routine_id" "issue_number" "")
	if [[ -n "$existing_issue" ]]; then
		# Fail closed on an unhealable value rather than creating a duplicate.
		if ! _is_valid_issue_number "$existing_issue"; then
			_log_error "Invalid tracking issue number for ${routine_id}: ${existing_issue}"
			return 1
		fi
		_log_warn "Issue #${existing_issue} already exists for ${routine_id}"
		echo "$existing_issue"
		return 0
	fi

	# Build initial issue body
	local initial_body
	initial_body=$(_build_issue_body \
		"$routine_id" \
		"$title" \
		"$schedule" \
		"$routine_type" \
		"active" \
		"never" \
		"none" \
		"0" \
		"pending first run" \
		"0" \
		"" \
		"0.00" \
		'{"total":0,"successes":0,"failures":0,"total_cost":"0.00","avg_duration":0,"period_start":"—","period_end":"—"}')

	# Create the issue on GitHub
	local issue_number
	issue_number=$(_create_github_issue "$repo_slug" "$title" "$initial_body") || return 1

	# Save state
	_save_initial_state "$routine_id" "$issue_number" "$repo_slug" "$title" "$schedule" "$routine_type" || return 1

	_log_success "Created issue #${issue_number} for ${routine_id} in ${repo_slug}"
	echo "$issue_number"
	return 0
}

# =============================================================================
# Subcommand: ensure-anchor (GH#39696)
# =============================================================================

# Parse the anchor subcommands' <key> --repo SLUG --title TITLE [--pr N]
# arguments into _ANCHOR_KEY/_ANCHOR_REPO/_ANCHOR_TITLE/_ANCHOR_PR.
# Returns 1 for an unknown option, a missing value or an invalid key/repo/title.
_parse_anchor_args() {
	_ANCHOR_KEY="${1:-}"
	_ANCHOR_REPO=""
	_ANCHOR_TITLE=""
	_ANCHOR_PR=""
	[[ $# -gt 0 ]] && shift
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		[[ $# -ge 2 ]] || return 1
		case "$opt" in
		--repo) _ANCHOR_REPO="$val" ;;
		--title) _ANCHOR_TITLE="$val" ;;
		--pr) _ANCHOR_PR="$val" ;;
		*)
			_log_error "Unknown anchor option: ${opt}"
			return 1
			;;
		esac
		shift 2
	done
	[[ "$_ANCHOR_KEY" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
	[[ "$_ANCHOR_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && -n "$_ANCHOR_TITLE" ]] || return 1
	return 0
}

# Multi-repo framework routines (badge sync, workflow sync) publish PRs into
# many repos, so their anchors are per target repo and located by a body
# marker rather than local per-routine state. A failed lookup fails closed:
# never create a second anchor when the first could not be read.
# Args: key, --repo SLUG, --title TITLE. Outputs the open anchor issue number.
cmd_ensure_anchor() {
	if ! _parse_anchor_args "$@"; then
		_log_error "Usage: routine-log-helper.sh ensure-anchor <key> --repo SLUG --title TITLE"
		return 1
	fi
	local key="$_ANCHOR_KEY" repo_slug="$_ANCHOR_REPO" title="$_ANCHOR_TITLE"
	_check_prerequisites || return 1

	local marker="<!-- aidevops:routine-anchor:${key} -->"
	local issues="" existing="" issue_count="" list_limit=1000
	if ! issues=$(gh issue list --repo "$repo_slug" --state open --label routine-tracking \
		--limit "$list_limit" --json number,body 2>/dev/null); then
		_log_error "Cannot list routine anchors in ${repo_slug}; refusing to create a duplicate"
		return 1
	fi
	# A full page may be truncated, so the anchor could sit beyond it: fail closed.
	issue_count=$(printf '%s' "$issues" | jq -r 'length') || return 1
	if [[ ! "$issue_count" =~ ^[0-9]+$ || "$issue_count" -ge "$list_limit" ]]; then
		_log_error "Routine anchor list for ${repo_slug} is incomplete; refusing to create a duplicate"
		return 1
	fi
	existing=$(printf '%s' "$issues" | jq -r --arg m "$marker" \
		'[.[] | select((.body // "") | contains($m)) | .number] | min // empty') || return 1
	if [[ -n "$existing" ]]; then
		_is_valid_issue_number "$existing" || return 1
		echo "$existing"
		return 0
	fi

	local body issue_number
	body=$(printf '%s\n' "$marker" \
		"## ${title}" "" \
		"Persistent tracking anchor for the aidevops \`${key}\` routine in this repository." \
		"Keep it open. Routine PRs reference it with a standalone \`Ref #N\` line, never a" \
		"closing keyword, so headless runs carry a verifiable issue identity (see" \
		"\`.agents/reference/routines.md\` \"Routine PR trust and tracking anchors\").")
	issue_number=$(_create_github_issue "$repo_slug" "$title" "$body") || return 1
	_log_success "Created routine anchor #${issue_number} for ${key} in ${repo_slug}"
	echo "$issue_number"
	return 0
}

# _anchor_open_pr_reference <repo> <number> — read a fresh, complete open-PR
# list. Returns 0 when any open PR body mentions #<number> in any form (Ref,
# For, closing keywords, GH#, owner/repo#), 1 when none provably does, and 2
# when the evidence is unavailable or incomplete. Over-matching only keeps an
# anchor open; the numeric boundary stops #770 from matching #77.
_anchor_open_pr_reference() {
	local repo="$1" number="$2" prs="" rc=0
	prs=$(gh pr list --repo "$repo" --state open --limit 1000 --json body) || return 2
	jq -e 'type == "array" and length < 1000 and all(.[]; .body | type == "string")' <<<"$prs" >/dev/null || return 2
	jq -e --arg n "$number" 'any(.[]; .body | test("#" + $n + "([^0-9]|$)"))' <<<"$prs" >/dev/null || rc=$?
	case "$rc" in 0 | 1) return "$rc" ;; esac
	return 2
}

# _anchor_restore <repo> <number> — reopen the anchor unless its fresh state is
# open (never the run's snapshot, which another run may have made stale), then
# restore `persistent`; only then clear the retiring marker, so any failed step
# is retried by the next run.
_anchor_restore() {
	local repo="$1" number="$2" state=""
	state=$(gh issue view "$number" --repo "$repo" --json state --jq .state) || return 1
	if [[ "$state" != "$ANCHOR_OPEN_STATE" ]]; then
		gh issue reopen "$number" --repo "$repo" || return 1
	fi
	gh issue edit "$number" --repo "$repo" --add-label persistent || return 1
	gh issue edit "$number" --repo "$repo" --remove-label "$ANCHOR_RETIRING_LABEL" || return 1
	_log_warn "Restored routine anchor #${number} in ${repo}: open PR reference not ruled out"
	return 0
}

# _anchor_retire_one <repo> <number> <is_open> <marked> — advance one anchor.
# References are read immediately before each close and re-read after it: a
# legacy runner that adds `Ref #N` inside that window gets its anchor restored.
_anchor_retire_one() {
	local repo="$1" number="$2" is_open="$3" marked="$4" ref_rc=0
	_anchor_open_pr_reference "$repo" "$number" || ref_rc=$?
	case "$ref_rc" in
	0)
		# Referenced: keep it, finishing any interrupted retirement's restore.
		[[ "$marked" == 1 ]] || return 0
		_anchor_restore "$repo" "$number"
		return $?
		;;
	1) ;;
	*) return 1 ;;
	esac
	if [[ "$is_open" == 1 ]]; then
		# Record pending restoration before the first destructive step.
		if [[ "$marked" != 1 ]]; then
			_ensure_labels "$repo" "$ANCHOR_RETIRING_LABEL" || return 1
			gh issue edit "$number" --repo "$repo" --add-label "$ANCHOR_RETIRING_LABEL" || return 1
		fi
		printf '%s\n' 'Routine PRs are now admitted by verified diff scope; this anchor is no longer needed' |
			gh_issue_comment "$number" --repo "$repo" --body-file - || return 1
		gh issue edit "$number" --repo "$repo" --remove-label persistent || return 1
		gh issue close "$number" --repo "$repo" --reason 'not planned' || return 1
		ref_rc=0
		_anchor_open_pr_reference "$repo" "$number" || ref_rc=$?
		if [[ "$ref_rc" -ne 1 ]]; then
			_anchor_restore "$repo" "$number"
			return $?
		fi
	elif [[ "$marked" != 1 ]]; then
		return 0
	fi
	# Closed and provably unreferenced: retirement is complete.
	gh issue edit "$number" --repo "$repo" --remove-label "$ANCHOR_RETIRING_LABEL" || return 1
	return 0
}

# Retire only the built-in routine covered by verified diff scope. Open anchors
# and marked anchors in any state are advanced, so an anchor whose restoration
# failed after closing is never stranded.
cmd_retire_anchor() {
	local key="${1:-}"
	[[ "$key" == "badges-sync" || "$key" == "sync-workflows" ]] || return 1
	_parse_anchor_args "$@" --title retirement || return 1
	local repo="$_ANCHOR_REPO" open="" marked="" rows="" number="" is_open="" flag=""
	local marker="<!-- aidevops:routine-anchor:${key} -->"
	local complete='type == "array" and length < 1000 and all(.[]; (.number | type == "number") and ([.body, .state] | all(type == "string")))'
	open=$(gh issue list --repo "$repo" --state open --label routine-tracking \
		--limit 1000 --json number,body,state) || return 1
	marked=$(gh issue list --repo "$repo" --state all --label routine-tracking \
		--label "$ANCHOR_RETIRING_LABEL" --limit 1000 --json number,body,state) || return 1
	jq -e "$complete" <<<"$open" >/dev/null || return 1
	jq -e "$complete" <<<"$marked" >/dev/null || return 1
	# Read both lists from stdin (not argv) so large bodies cannot hit ARG_MAX.
	# unique_by keeps the first entry, so a marked anchor's own state wins.
	rows=$(printf '%s\n%s\n' "$open" "$marked" | jq -rs --arg marker "$marker" --arg open "$ANCHOR_OPEN_STATE" '
		(.[1] | map(.number)) as $marked |
		(.[1] + .[0]) | unique_by(.number) | .[] | select(.body | contains($marker)) |
		.number as $n | [$n, (if .state == $open then 1 else 0 end),
		 (if any($marked[]; . == $n) then 1 else 0 end)] | @tsv') || return 1
	[[ -n "$rows" ]] || return 0
	if ! declare -F gh_issue_comment >/dev/null; then
		# shellcheck source=shared-gh-wrappers.sh
		source "$SCRIPT_DIR/shared-gh-wrappers.sh" || return 1
	fi
	while IFS=$'\t' read -r number is_open flag; do
		_is_valid_issue_number "$number" || return 1
		_anchor_retire_one "$repo" "$number" "$is_open" "$flag" || return 1
	done <<<"$rows"
	return 0
}

# Read an open origin:worker PR that lacks any issue identity and output its
# current body. Returns 0 when a backfill is needed, 3 when the PR is closed,
# not worker-origin or already identified, and 1 when it cannot be read.
_pr_anchor_backfill_body() {
	local pr_number="$1"
	local repo_slug="$2"
	local meta="" body=""
	meta=$(gh pr view "$pr_number" --repo "$repo_slug" --json state,labels,body 2>/dev/null) || return 1
	printf '%s' "$meta" | jq -e '.state == "OPEN"' >/dev/null || return 3
	printf '%s' "$meta" | jq -e '[.labels[].name] | index("origin:worker") != null' >/dev/null || return 3
	body=$(printf '%s' "$meta" | jq -r '.body // ""') || return 1
	# A verified-scope routine marker is its own identity (GH#39793).
	[[ "$body" != *'<!-- aidevops:routine-pr:'* ]] || return 3
	[[ -z "$(_gh_pr_body_closing_issues "$body")" && -z "$(_gh_pr_body_explicit_issues "$body")" ]] || return 3
	printf '%s' "$body"
	return 0
}

# A routine PR opened before the worker identity guard (GH#36877) carries
# origin:worker but no issue identity, so the t2449 gate never admits it and
# the routine skips the repo while it stays open. Prepend the anchor's
# `Ref #N` line through the guarded edit wrapper. Other PRs are left alone.
# The body is re-read after anchor resolution so an edit made meanwhile is
# kept; the full-body replacement itself is still not conditional.
# Args: key, --repo SLUG, --pr N, --title TITLE. Returns 1 on any failure.
cmd_ensure_pr_anchor() {
	if ! _parse_anchor_args "$@" || ! _is_valid_issue_number "$_ANCHOR_PR"; then
		_log_error "Usage: routine-log-helper.sh ensure-pr-anchor <key> --repo SLUG --pr N --title TITLE"
		return 1
	fi
	local key="$_ANCHOR_KEY" repo_slug="$_ANCHOR_REPO" title="$_ANCHOR_TITLE" pr_number="$_ANCHOR_PR"
	_check_prerequisites || return 1
	local fn
	for fn in gh_pr_edit_safe _gh_pr_body_closing_issues _gh_pr_body_explicit_issues; do
		declare -F "$fn" >/dev/null 2>&1 && continue
		_log_error "ensure-pr-anchor: ${fn} unavailable (shared-gh-wrappers.sh not loaded)"
		return 1
	done
	local body="" anchor="" read_rc=0
	body=$(_pr_anchor_backfill_body "$pr_number" "$repo_slug") || read_rc=$?
	[[ "$read_rc" -eq 3 ]] && return 0
	[[ "$read_rc" -eq 0 ]] || return 1
	anchor=$(cmd_ensure_anchor "$key" --repo "$repo_slug" --title "$title") || return 1
	body=$(_pr_anchor_backfill_body "$pr_number" "$repo_slug") || read_rc=$?
	[[ "$read_rc" -eq 3 ]] && return 0
	[[ "$read_rc" -eq 0 ]] || return 1
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}" body_file="" rc=0
	mkdir -p "$temp_root" || return 1
	body_file=$(mktemp "${temp_root%/}/routine-pr-anchor.XXXXXX") || return 1
	printf 'Ref #%s\n\n%s\n' "$anchor" "$body" >"$body_file"
	gh_pr_edit_safe "$pr_number" --repo "$repo_slug" --body-file "$body_file" >/dev/null || rc=$?
	rm -f "$body_file"
	[[ "$rc" -eq 0 ]] || return 1
	_log_success "Linked PR #${pr_number} in ${repo_slug} to routine anchor #${anchor}"
	return 0
}

# =============================================================================
# Subcommand: status
# =============================================================================

cmd_status() {
	_check_prerequisites || return 1

	# Find all routine state files
	local found=0

	printf "%-10s %-8s %-20s %-10s %-8s %-12s %s\n" \
		"ROUTINE" "ISSUE" "LAST RUN" "RESULT" "STREAK" "COST" "REPO"
	printf "%-10s %-8s %-20s %-10s %-8s %-12s %s\n" \
		"-------" "-----" "--------" "------" "------" "----" "----"

	if [[ -d "$CRON_BASE" ]]; then
		local dir
		for dir in "${CRON_BASE}"/*/; do
			[[ -d "$dir" ]] || continue
			local rid
			rid=$(basename "$dir")
			local state_file="${dir}routine-state.json"
			[[ -f "$state_file" ]] || continue

			local state
			state=$(_read_state "$rid")
			local issue_number
			issue_number=$(echo "$state" | jq -r '.issue_number // "—"')
			local last_run
			last_run=$(echo "$state" | jq -r '.last_run // "never"')
			local last_status
			last_status=$(echo "$state" | jq -r '.last_status // "—"')
			local streak_count
			streak_count=$(echo "$state" | jq -r '.streak_count // 0')
			local streak_type
			streak_type=$(echo "$state" | jq -r '.streak_type // ""')
			local total_cost
			total_cost=$(echo "$state" | jq -r '.total_cost // "0.00"')
			local repo_slug
			repo_slug=$(echo "$state" | jq -r '.repo_slug // "—"')

			# Format last_run to short form
			local last_run_short
			if [[ "$last_run" == "never" ]]; then
				last_run_short="never"
			else
				last_run_short=$(echo "$last_run" | cut -c1-16 | tr 'T' ' ')
			fi

			local streak_display="${streak_count}${streak_type:0:1}"

			printf "%-10s %-8s %-20s %-10s %-8s %-12s %s\n" \
				"$rid" "#${issue_number}" "$last_run_short" "$last_status" "$streak_display" "\$${total_cost}" "$repo_slug"

			found=$((found + 1))
		done
	fi

	if [[ "$found" -eq 0 ]]; then
		echo "(no routines tracked yet)"
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
routine-log-helper.sh — Routine execution tracking via GitHub issue descriptions

Usage:
  routine-log-helper.sh update <routine-id> --status queued|claimed|running|success|failure|deferred|cancelled [options]
    Append lifecycle evidence locally. Only success and failure update execution
    metrics, the tracking issue, streaks, and cost totals.
    Script-only routines (run:) always show $0.00 cost.

  routine-log-helper.sh notable <routine-id> --event "description"
    Post a comment on the tracking issue for notable events only.
    Examples: streak breaks, budget thresholds, configuration changes.

  routine-log-helper.sh create-issue <routine-id> --repo SLUG --title "rNNN: Title" [--schedule EXPR] [--type TYPE]
    Create the initial tracking issue with template description.
    Returns the issue number. Stores mapping in routine-state.json.

  routine-log-helper.sh ensure-anchor <key> --repo SLUG --title TITLE
    Print the open per-repo anchor for a multi-repo routine (found by body
    marker), creating it once when absent. A failed lookup never creates one.

  routine-log-helper.sh ensure-pr-anchor <key> --repo SLUG --pr N --title TITLE
    Prepend the anchor's Ref #N line to an open origin:worker routine PR whose
    body has no issue identity (pre-guard PRs). Other PRs are left unchanged.

  routine-log-helper.sh retire-anchor <badges-sync|sync-workflows> --repo SLUG
    Close legacy badge anchors as not planned after removing persistent, only
    when a complete open-PR list read just before closing proves no Ref #N
    remains; reopen if one appears by the post-close re-read. Other keys refused.

  routine-log-helper.sh refresh-description <routine-id>
    Rebuild and push the GitHub issue body using current state and stored
    description data. Does NOT record a new run entry or modify metrics.
    Use after init-routines-helper.sh refreshes a description for an
    existing routine.

  routine-log-helper.sh status
    Print summary table of all tracked routines.

  routine-log-helper.sh help
    Show this help message.

Options:
  --status STATUS             Lifecycle state (required for update)
  --duration SECONDS          Required for success/failure; defaults to 0 otherwise
  --tokens N                  Token count (optional, default 0)
  --cost AMOUNT               Cost in dollars (optional, default 0.00)
  --job-id ID                 Optional deferred-job correlation ID
  --session-key KEY           Optional headless runtime session key
  --outcome OUTCOME           Optional structured terminal outcome
  --event "description"       Notable event description (required for notable)
  --repo SLUG                 GitHub repo slug owner/repo (required for create-issue)
  --title "rNNN: Title"       Issue title (required for create-issue)
  --schedule EXPR             Schedule expression e.g. daily(@06:00) (optional)
  --type TYPE                 Routine type e.g. script or agent (optional)

Examples:
  # After a successful script execution
  routine-log-helper.sh update r001 --status success --duration 108

  # After an agent execution with cost
  routine-log-helper.sh update r002 --status success --duration 300 --tokens 5000 --cost 0.15

  # Post a notable event
  routine-log-helper.sh notable r001 --event "5 consecutive failures — check cron config"

  # Create tracking issue for a new routine
  routine-log-helper.sh create-issue r001 --repo owner/repo --title "r001: Daily Pulse" --schedule "daily(@06:00)" --type "script (scripts/pulse-wrapper.sh)"

  # View all routine statuses
  routine-log-helper.sh status

State:
  Local logs:  ~/.aidevops/.agent-workspace/cron/<routine-id>/logs/executions.jsonl
  Lifecycle:   ~/.aidevops/.agent-workspace/cron/<routine-id>/lifecycle.jsonl
  State file:  ~/.aidevops/.agent-workspace/cron/<routine-id>/routine-state.json
HELP
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	if [[ $# -lt 1 ]]; then
		cmd_help
		return 0
	fi

	local command="$1"
	shift

	case "$command" in
	update)
		cmd_update "$@"
		;;
	notable)
		cmd_notable "$@"
		;;
	refresh-description)
		cmd_refresh_description "$@"
		;;
	create-issue)
		cmd_create_issue "$@"
		;;
	ensure-anchor)
		cmd_ensure_anchor "$@"
		;;
	ensure-pr-anchor)
		cmd_ensure_pr_anchor "$@"
		;;
	retire-anchor)
		cmd_retire_anchor "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		_log_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
	local command_status=$?
	return "$command_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
