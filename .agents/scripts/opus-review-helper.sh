#!/usr/bin/env bash
# opus-review-helper.sh — Cadence control for opus strategic review (t1340)
#
# The supervisor pulse runs every 2 minutes at sonnet tier for mechanical
# dispatch. Every 4 hours, this helper gates an opus-tier strategic review
# that does what sonnet can't: meta-reasoning about queue health, resource
# utilisation, stuck chains, and systemic issues.
#
# Usage:
#   opus-review-helper.sh check       Check if review is due (exit 0=due, 1=too soon)
#   opus-review-helper.sh record      Record that a review just ran
#   opus-review-helper.sh status      Show last review time and next due
#   opus-review-helper.sh reset       Clear last-run timestamp (forces next review)
#   opus-review-helper.sh help        Show usage
#
# Called by: pulse.md Step 8 (Strategic Review)
# Pattern: follows session-miner-pulse.sh cadence control

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

# Minimum interval between reviews (seconds) — default 4 hours
OPUS_REVIEW_INTERVAL="${OPUS_REVIEW_INTERVAL:-14400}"
# Validate numeric — strip non-digits, fallback to default if empty
OPUS_REVIEW_INTERVAL="${OPUS_REVIEW_INTERVAL//[!0-9]/}"
[[ -n "$OPUS_REVIEW_INTERVAL" ]] || OPUS_REVIEW_INTERVAL=14400

# State directory
STATE_DIR="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"

# State file — stores epoch timestamp of last review
STATE_FILE="${STATE_DIR}/.opus-review-last"

# ============================================================
# COLOURS
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# FUNCTIONS
# ============================================================

_ensure_state_dir() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
	return 0
}

_get_last_run() {
	if [[ -f "$STATE_FILE" ]]; then
		cat "$STATE_FILE" 2>/dev/null || echo "0"
	else
		echo "0"
	fi
	return 0
}

_get_now() {
	date +%s
	return 0
}

_format_duration() {
	local seconds="$1"
	local hours=$((seconds / 3600))
	local minutes=$(((seconds % 3600) / 60))
	if [[ "$hours" -gt 0 ]]; then
		echo "${hours}h ${minutes}m"
	else
		echo "${minutes}m"
	fi
	return 0
}

cmd_check() {
	_ensure_state_dir

	local last_run
	last_run="$(_get_last_run)"
	local now
	now="$(_get_now)"
	local elapsed=$((now - last_run))

	if [[ "$elapsed" -ge "$OPUS_REVIEW_INTERVAL" ]]; then
		# Review is due
		if [[ "$last_run" -eq 0 ]]; then
			echo -e "${GREEN}Opus review: never run — due now${NC}" >&2
		else
			echo -e "${GREEN}Opus review: due (last run $(_format_duration "$elapsed") ago, interval $(_format_duration "$OPUS_REVIEW_INTERVAL"))${NC}" >&2
		fi
		return 0
	else
		# Too soon
		local remaining=$((OPUS_REVIEW_INTERVAL - elapsed))
		echo -e "${BLUE}Opus review: not due (next in $(_format_duration "$remaining"))${NC}" >&2
		return 1
	fi
}

cmd_record() {
	_ensure_state_dir

	local now
	now="$(_get_now)"
	echo "$now" >"$STATE_FILE"
	echo -e "${GREEN}Opus review: recorded at $(date -r "$now" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$now" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$now")${NC}" >&2
	return 0
}

cmd_status() {
	_ensure_state_dir

	local last_run
	last_run="$(_get_last_run)"
	local now
	now="$(_get_now)"
	local elapsed=$((now - last_run))
	local interval_fmt
	interval_fmt="$(_format_duration "$OPUS_REVIEW_INTERVAL")"

	echo "Opus Strategic Review Status"
	echo "============================"
	echo "Interval:    ${interval_fmt} (${OPUS_REVIEW_INTERVAL}s)"

	if [[ "$last_run" -eq 0 ]]; then
		echo "Last run:    never"
		echo "Status:      DUE NOW"
	else
		local last_fmt
		last_fmt="$(date -r "$last_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$last_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_run")"
		echo "Last run:    ${last_fmt} ($(_format_duration "$elapsed") ago)"

		if [[ "$elapsed" -ge "$OPUS_REVIEW_INTERVAL" ]]; then
			echo -e "Status:      ${GREEN}DUE NOW${NC}"
		else
			local remaining=$((OPUS_REVIEW_INTERVAL - elapsed))
			echo -e "Status:      ${BLUE}Next in $(_format_duration "$remaining")${NC}"
		fi
	fi

	echo "State file:  ${STATE_FILE}"
	return 0
}

cmd_reset() {
	_ensure_state_dir

	if [[ -f "$STATE_FILE" ]]; then
		rm -f "$STATE_FILE"
		echo -e "${YELLOW}Opus review: timestamp cleared — next pulse will trigger review${NC}" >&2
	else
		echo -e "${BLUE}Opus review: no timestamp to clear${NC}" >&2
	fi
	return 0
}

cmd_help() {
	echo "opus-review-helper.sh — Cadence control for opus strategic review"
	echo ""
	echo "Usage:"
	echo "  opus-review-helper.sh check       Check if review is due (exit 0=due, 1=too soon)"
	echo "  opus-review-helper.sh record      Record that a review just ran"
	echo "  opus-review-helper.sh status      Show last review time and next due"
	echo "  opus-review-helper.sh reset       Clear last-run timestamp (forces next review)"
	echo "  opus-review-helper.sh help        Show usage"
	echo ""
	echo "Environment:"
	echo "  OPUS_REVIEW_INTERVAL    Seconds between reviews (default: 14400 = 4h)"
	echo "  SUPERVISOR_DIR          State directory (default: ~/.aidevops/.agent-workspace/supervisor)"
	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {
	local command="${1:-help}"

	case "$command" in
	check)
		cmd_check
		;;
	record)
		cmd_record
		;;
	status)
		cmd_status
		;;
	reset)
		cmd_reset
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo "Unknown command: $command" >&2
		cmd_help >&2
		return 1
		;;
	esac
}

main "$@"
