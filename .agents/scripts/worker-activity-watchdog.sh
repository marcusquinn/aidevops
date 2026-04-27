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
#   --hard-kill-seconds SECS  Total elapsed seconds before forced hard-kill on
#                             stall (default: 1500 = 25 min). When stall is
#                             detected AND total elapsed > this threshold, the
#                             watchdog writes the .watchdog_stall_killed
#                             sentinel (in addition to .watchdog_killed) so the
#                             helper can classify the result as exit code 79
#                             (watchdog_stall_killed) instead of 78
#                             (watchdog_stall_continue) — no continuation, slot
#                             freed for re-dispatch. Override env var:
#                             WORKER_STALL_HARD_KILL_SECONDS. Set to 0 to
#                             disable the hard-kill branch (legacy behaviour).
#                             Issue #21231 / supersedes #21201.
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
WORKTREE_PATH=""
STALL_TIMEOUT=300
PHASE1_TIMEOUT=30
POLL_INTERVAL=10
# t2956 / Issue #21231: Hard-kill threshold (default 1500s = 25 min).
# Env var WORKER_STALL_HARD_KILL_SECONDS overrides; --hard-kill-seconds CLI
# flag overrides the env var. Set to 0 to disable hard-kill (stall continues
# indefinitely up to the runtime's wall-clock cap — legacy behaviour).
HARD_KILL_SECONDS="${WORKER_STALL_HARD_KILL_SECONDS:-1500}"

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
		--worktree-path)
			WORKTREE_PATH="$2"
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
		--hard-kill-seconds)
			# t2956: assign via `local` so the bare-positional ratchet
			# (linters-local.sh::_ratchet_count_bare_positional) excludes
			# this line. The other case branches predate the ratchet and
			# remain in the pre-existing baseline.
			local _hard_kill_arg="$2"
			HARD_KILL_SECONDS="$_hard_kill_arg"
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
	# t2956: HARD_KILL_SECONDS=0 disables the hard-kill branch (allowed).
	[[ "$HARD_KILL_SECONDS" =~ ^[0-9]+$ ]] || HARD_KILL_SECONDS=1500
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
# Push any local-only WIP commits to origin before killing the worker.
# Best-effort, fail-open — never blocks the kill sequence.
#
# t2923: Ensures commits made before the stall are reachable on origin
# so the next worker dispatch can continue from the branch instead of
# rewriting the same code from scratch.
#
# Globals consumed:
#   WORKTREE_PATH        — set via --worktree-path arg
#   WORKER_NO_EXIT_PUSH  — escape hatch: set to "1" to disable push
#######################################
_push_wip_before_kill() {
	# Escape hatch
	[[ "${WORKER_NO_EXIT_PUSH:-0}" == "1" ]] && return 0

	local work_dir="$WORKTREE_PATH"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	# Get branch name — skip if detached HEAD or default branch
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	case "$branch_name" in
	HEAD | main | master | "")
		return 0
		;;
	esac

	# Count commits ahead of origin/main (or origin/master)
	local ahead_count=0
	ahead_count=$(git -C "$work_dir" rev-list --count "origin/main..HEAD" 2>/dev/null || true)
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	if [[ "$ahead_count" -eq 0 ]]; then
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || true)
		[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	fi
	if [[ "$ahead_count" -eq 0 ]]; then
		return 0
	fi

	# Push best-effort — never block the kill sequence on push failure
	printf '[WATCHDOG_WIP_PUSH] timestamp=%s branch=%s ahead=%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch_name" "$ahead_count" \
		>>"$OUTPUT_FILE" 2>/dev/null || true
	git -C "$work_dir" push -u origin "$branch_name" 2>/dev/null || true
	printf '[WATCHDOG_WIP_PUSHED] branch=%s ahead=%s\n' \
		"$branch_name" "$ahead_count" \
		>>"$OUTPUT_FILE" 2>/dev/null || true
	return 0
}

#######################################
# Kill the worker process tree and write markers
#
# Args:
#   $1 - reason string (logged in output file)
#   $2 - kill kind: "stall_killed" for hard-kill (writes additional
#        .watchdog_stall_killed sentinel), anything else (or empty) for the
#        legacy passive watchdog kill that classifies as 78
#        (watchdog_stall_continue) downstream. (t2956 / Issue #21231)
#######################################
_kill_worker() {
	local reason="$1"
	local kill_kind="${2:-}"

	# t2923: Push WIP commits before killing so the work is reachable on origin.
	# Must happen before SIGTERM so git operations complete cleanly.
	_push_wip_before_kill

	# Write the .watchdog_killed sentinel BEFORE killing. The dying
	# subshell may overwrite exit_code_file with its own exit code
	# (race condition). The sentinel is authoritative.
	touch "${EXIT_CODE_FILE}.watchdog_killed"

	# t2956 / Issue #21231: Hard-kill sentinel — distinguishes proactive
	# elapsed-time kills from passive no-output stall kills. The helper
	# (`headless-runtime-helper.sh::_handle_run_result`) reads this sentinel
	# and returns exit 79 (watchdog_stall_killed) instead of 78
	# (watchdog_stall_continue), short-circuiting the per-attempt
	# continuation loop and freeing the slot for re-dispatch. Without this
	# sentinel, exit 78 still fires (legacy continuation behaviour).
	if [[ "$kill_kind" == "stall_killed" ]]; then
		touch "${EXIT_CODE_FILE}.watchdog_stall_killed"
	fi

	# Kill child processes first (pipeline members: opencode, tee),
	# then the subshell itself. pkill -P walks the process tree by PPID.
	# GH#20681: SIGTERM → 10s grace → SIGKILL (raised from 2s to give the
	# runtime a chance to flush buffers and release locks cleanly).
	pkill -P "$WORKER_PID" 2>/dev/null || true
	kill "$WORKER_PID" 2>/dev/null || true
	sleep 10
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
#
# t2956 / Issue #21231: Total elapsed time is also tracked. When a stall is
# detected AND HARD_KILL_SECONDS is non-zero AND total elapsed has crossed
# that threshold, the watchdog escalates to a hard-kill that emits the
# `.watchdog_stall_killed` sentinel — telling the helper to classify as
# exit 79 (watchdog_stall_killed) instead of 78 (watchdog_stall_continue).
# This caps the per-attempt cost of a single stall and frees the dispatch
# slot for re-dispatch instead of holding it through repeated continuations.
#######################################
_monitor() {
	local phase1_passed=0
	local phase1_elapsed=0
	local last_size=0
	local stall_seconds=0
	# t2956: Wall-clock start so HARD_KILL_SECONDS is measured against the
	# total time the watchdog has been monitoring this worker — not just the
	# duration of the current stall window. A worker that's been alternately
	# producing output and stalling for >25 min is just as wasteful as one
	# that's been silent the whole time.
	local start_epoch
	start_epoch=$(date +%s)

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
			# t2956: When a stall is confirmed, decide whether to do a
			# passive kill (legacy → exit 78 → continuation attempt) or a
			# proactive hard-kill (new → exit 79 → no continuation, slot
			# freed). The threshold is total elapsed time since the watchdog
			# started monitoring. HARD_KILL_SECONDS=0 disables the branch.
			local now_epoch elapsed_total
			now_epoch=$(date +%s)
			elapsed_total=$((now_epoch - start_epoch))
			if [[ "$HARD_KILL_SECONDS" -gt 0 && "$elapsed_total" -ge "$HARD_KILL_SECONDS" ]]; then
				_kill_worker \
					"hard_kill: stall confirmed and total elapsed ${elapsed_total}s ≥ hard-kill threshold ${HARD_KILL_SECONDS}s (stuck at ${current_size}b) — slot freed for re-dispatch" \
					"stall_killed"
				return 0
			fi
			_kill_worker "stall: no output growth for ${STALL_TIMEOUT}s (stuck at ${current_size}b, total elapsed ${elapsed_total}s)"
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
