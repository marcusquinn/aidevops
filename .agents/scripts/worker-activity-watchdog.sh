#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-activity-watchdog.sh — Standalone activity watchdog for headless workers (GH#17648)
#
# Monitors a worker's output file for growth. Kills the worker if output
# stalls, indicating a dropped API stream or hung runtime.
#
# This script runs as an INDEPENDENT process (launched via nohup) so it
# survives the worker subshell's lifecycle changes. The previous design
# used a backgrounded bash function inside the subshell — that watchdog
# died silently when nohup changed the process group context.
#
# Two-phase monitoring:
#   Phase 1 (fast, 0-30s): Any output at all. Zero bytes = dead runtime.
#   Phase 2 (continuous):   File growth. No growth for stall_timeout = stalled.
#
# On stall:
#   - Writes WATCHDOG_KILL marker to output file
#   - Creates .watchdog_killed sentinel (parent reads this)
#   - Kills worker process tree (TERM, then KILL after 2s)
#   - Writes exit code 124 to exit_code_file
#   - Posts CLAIM_RELEASED on GitHub issue (if session_key provided)
#
# On normal worker exit:
#   - Detects worker PID gone, exits cleanly
#
# Args:
#   --output-file PATH        Worker output file to monitor
#   --worker-pid PID          Worker PID to kill on stall
#   --exit-code-file PATH     File to write exit code 124 into
#   --session-key KEY         Session key for claim release (optional)
#   --repo-slug OWNER/REPO    GitHub repo slug for claim release (optional)
#   --stall-timeout SECS      Seconds without growth before kill (default: 300)
#   --phase1-timeout SECS     Seconds for initial output (default: 30)
#   --poll-interval SECS      Seconds between checks (default: 10)
#
# Usage:
#   nohup worker-activity-watchdog.sh \
#     --output-file /tmp/worker.out \
#     --worker-pid 12345 \
#     --exit-code-file /tmp/worker.exit \
#     --session-key "issue-marcusquinn-aidevops-17648" \
#     --repo-slug "marcusquinn/aidevops" \
#     </dev/null >/dev/null 2>&1 &

set -euo pipefail

#######################################
# Configuration (from args, with defaults)
#######################################
OUTPUT_FILE=""
WORKER_PID=""
EXIT_CODE_FILE=""
SESSION_KEY=""
REPO_SLUG=""
STALL_TIMEOUT=300
PHASE1_TIMEOUT=30
POLL_INTERVAL=10

#######################################
# Parse arguments
#######################################
_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output-file)
			OUTPUT_FILE="$2"
			shift 2
			;;
		--worker-pid)
			WORKER_PID="$2"
			shift 2
			;;
		--exit-code-file)
			EXIT_CODE_FILE="$2"
			shift 2
			;;
		--session-key)
			SESSION_KEY="$2"
			shift 2
			;;
		--repo-slug)
			REPO_SLUG="$2"
			shift 2
			;;
		--stall-timeout)
			STALL_TIMEOUT="$2"
			shift 2
			;;
		--phase1-timeout)
			PHASE1_TIMEOUT="$2"
			shift 2
			;;
		--poll-interval)
			POLL_INTERVAL="$2"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			return 1
			;;
		esac
	done

	# Validate required args
	if [[ -z "$OUTPUT_FILE" ]]; then
		echo "Error: --output-file is required" >&2
		return 1
	fi
	if [[ -z "$WORKER_PID" ]]; then
		echo "Error: --worker-pid is required" >&2
		return 1
	fi
	if [[ -z "$EXIT_CODE_FILE" ]]; then
		echo "Error: --exit-code-file is required" >&2
		return 1
	fi

	# Validate numeric args
	[[ "$STALL_TIMEOUT" =~ ^[0-9]+$ ]] || STALL_TIMEOUT=300
	[[ "$PHASE1_TIMEOUT" =~ ^[0-9]+$ ]] || PHASE1_TIMEOUT=30
	[[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || POLL_INTERVAL=10
	[[ "$WORKER_PID" =~ ^[0-9]+$ ]] || {
		echo "Error: --worker-pid must be numeric" >&2
		return 1
	}

	return 0
}

#######################################
# Check if the worker process is still alive
# Returns: 0 if alive, 1 if dead
#######################################
_worker_alive() {
	kill -0 "$WORKER_PID" 2>/dev/null
}

#######################################
# Get current size of the output file in bytes
# Output: size in bytes (0 if file doesn't exist)
#######################################
_get_output_size() {
	local size=0
	if [[ -f "$OUTPUT_FILE" ]]; then
		size=$(wc -c <"$OUTPUT_FILE" 2>/dev/null || echo "0")
		# wc -c may include leading spaces on some platforms
		size="${size##* }"
	fi
	[[ "$size" =~ ^[0-9]+$ ]] || size=0
	echo "$size"
	return 0
}

#######################################
# Kill the worker process tree and write markers
#
# Args:
#   $1 - reason string (logged in output file)
#######################################
_kill_worker() {
	local reason="$1"

	# Write the .watchdog_killed sentinel BEFORE killing. The dying
	# subshell may overwrite exit_code_file with its own exit code
	# (race condition). The sentinel is authoritative.
	touch "${EXIT_CODE_FILE}.watchdog_killed"

	# Kill child processes first (pipeline members: opencode, tee),
	# then the subshell itself. pkill -P walks the process tree by PPID.
	pkill -P "$WORKER_PID" 2>/dev/null || true
	kill "$WORKER_PID" 2>/dev/null || true
	sleep 2
	# Force kill if still alive
	pkill -9 -P "$WORKER_PID" 2>/dev/null || true
	kill -9 "$WORKER_PID" 2>/dev/null || true

	# Write exit code 124 (timeout convention)
	printf '124' >"$EXIT_CODE_FILE"

	# Write WATCHDOG_KILL marker to output file
	printf '\n[WATCHDOG_KILL] timestamp=%s worker_pid=%s reason="%s"\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKER_PID" "$reason" \
		>>"$OUTPUT_FILE" 2>/dev/null || true

	# Release the dispatch claim so the issue is immediately available
	# for re-dispatch instead of waiting for the 30-min TTL.
	_release_claim "$reason"

	return 0
}

#######################################
# Release dispatch claim on the GitHub issue
#
# Posts a CLAIM_RELEASED comment so the pulse knows the issue
# is available for re-dispatch.
#
# Args:
#   $1 - reason string
#######################################
_release_claim() {
	local reason="$1"

	if [[ -z "$SESSION_KEY" ]]; then
		return 0
	fi

	# Extract issue number from session key (last numeric segment)
	local issue_number=""
	issue_number=$(printf '%s' "$SESSION_KEY" | grep -oE '[0-9]+$' || true)

	# Use provided repo slug, or fall back to DISPATCH_REPO_SLUG env
	local repo_slug="${REPO_SLUG:-${DISPATCH_REPO_SLUG:-}}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi

	local comment_body
	comment_body="CLAIM_RELEASED reason=watchdog_kill:${reason} runner=$(whoami) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Best-effort — don't fail the watchdog if gh is unavailable
	if command -v gh >/dev/null 2>&1; then
		gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--method POST \
			--field body="$comment_body" \
			>/dev/null 2>&1 || true
	fi

	return 0
}

#######################################
# Main monitoring loop
#
# Phase 1: Wait for any output (dead runtime detection)
# Phase 2: Monitor continuous growth (stall detection)
#######################################
_monitor() {
	local phase1_passed=0
	local phase1_elapsed=0
	local last_size=0
	local stall_seconds=0

	while true; do
		# Worker exited on its own — watchdog not needed
		if ! _worker_alive; then
			return 0
		fi

		local current_size
		current_size=$(_get_output_size)

		# Phase 1: any output at all
		if [[ "$phase1_passed" -eq 0 ]]; then
			if [[ "$current_size" -gt 0 ]]; then
				phase1_passed=1
				last_size="$current_size"
				stall_seconds=0
			else
				phase1_elapsed=$((phase1_elapsed + POLL_INTERVAL))
				if [[ "$phase1_elapsed" -ge "$PHASE1_TIMEOUT" ]]; then
					_kill_worker "phase1: zero output in ${PHASE1_TIMEOUT}s — runtime failed to start"
					return 0
				fi
			fi
			sleep "$POLL_INTERVAL"
			continue
		fi

		# Phase 2: continuous growth monitoring
		if [[ "$current_size" -gt "$last_size" ]]; then
			# File is growing — worker is alive
			last_size="$current_size"
			stall_seconds=0
		else
			# No growth — increment stall counter
			stall_seconds=$((stall_seconds + POLL_INTERVAL))
		fi

		if [[ "$stall_seconds" -ge "$STALL_TIMEOUT" ]]; then
			_kill_worker "stall: no output growth for ${STALL_TIMEOUT}s (stuck at ${current_size}b)"
			return 0
		fi

		sleep "$POLL_INTERVAL"
	done
}

#######################################
# Main
#######################################
main() {
	_parse_args "$@" || return 1

	# Verify the worker PID exists at startup
	if ! _worker_alive; then
		return 0
	fi

	_monitor
	return 0
}

main "$@"
