#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker launch validation and trusted prelaunch failure classification.
# Sourced by pulse-dispatch-engine.sh after its defaults and dependencies.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_ENGINE_LAUNCH_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_LAUNCH_LOADED=1

# t1959: Module-level variable to communicate launch failure reason to callers.
# Set by check_worker_launch before each return 1; read by dispatch loop for
# per-round no_worker_process tracking and canary cache invalidation.
_PULSE_LAST_LAUNCH_FAILURE=""

#######################################
# Extract a trusted prelaunch failure reason from a worker log.
#
# Args:
#   $1 - worker log path
# Stdout: allowlisted reason token, or blank when unavailable.
# Returns: 0 always; diagnostics must never block dispatch cleanup.
#######################################
_pulse_worker_log_prelaunch_failure_reason() {
	local log_path="$1"
	local reason=""

	[[ -f "$log_path" ]] || {
		printf '\n'
		return 0
	}

	reason=$(awk '
		/\[systemd-launch\] classification=crash_during_startup/ {
			systemd_startup_failure = 1
		}
		/\[exit-trap\] using prelaunch failure reason:/ {
			line = $0
			sub(/^.*\[exit-trap\] using prelaunch failure reason:[[:space:]]*/, "", line)
			split(line, parts, /[[:space:]]+/)
			reason = parts[1]
		}
		/\[exit-trap\] session=/ && / reason=/ && reason == "" {
			line = $0
			sub(/^.* reason=/, "", line)
			split(line, parts, /[[:space:]]+/)
			reason = parts[1]
		}
		END {
			if (systemd_startup_failure) { print "crash_during_startup" }
			else if (reason != "") { print reason }
		}
	' "$log_path" 2>/dev/null) || reason=""

	case "$reason" in
	worker_worktree_live_owner | worker_worktree_continuation_* | \
		worker_worktree_owner_concurrent_mutation | crash_during_startup)
		printf '%s\n' "$reason"
		;;
	*)
		printf '\n'
		;;
	esac
	return 0
}

#######################################
# Launch validation gate for pulse dispatches (t1453)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional grace timeout in seconds
#
# Exit codes:
#   0 - worker launch appears valid (process remains alive after stability check)
#   1 - launch invalid (no process within grace window or usage output detected)
#######################################
check_worker_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local grace_seconds="${3:-$PULSE_LAUNCH_GRACE_SECONDS}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_worker_launch: invalid arguments issue='$issue_number' repo='$repo_slug'" >>"$LOGFILE"
		return 1
	fi
	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds="$PULSE_LAUNCH_GRACE_SECONDS"
	if [[ "$grace_seconds" -lt 1 ]]; then
		grace_seconds=1
	fi

	local -a log_candidates=()
	local _candidate=""
	while IFS= read -r _candidate; do
		[[ -n "$_candidate" ]] && log_candidates+=("$_candidate")
	done < <(aidevops_pulse_worker_log_candidates "$repo_slug" "$issue_number" 2>/dev/null || true)

	local elapsed=0
	local poll_seconds=2
	local stability_seconds="${PULSE_LAUNCH_STABILITY_SECONDS:-3}"
	local candidate=""
	local prelaunch_failure_reason=""
	[[ "$stability_seconds" =~ ^[0-9]+$ ]] || stability_seconds=3
	if [[ "$stability_seconds" -lt 1 ]]; then
		stability_seconds=1
	fi
	while [[ "$elapsed" -lt "$grace_seconds" ]]; do
		for candidate in "${log_candidates[@]}"; do
			prelaunch_failure_reason=$(_pulse_worker_log_prelaunch_failure_reason "$candidate")
			if [[ -n "$prelaunch_failure_reason" ]]; then
				recover_failed_launch_state "$issue_number" "$repo_slug" "$prelaunch_failure_reason"
				echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — prelaunch failure reason=${prelaunch_failure_reason} detected in ${candidate}" >>"$LOGFILE"
				_PULSE_LAST_LAUNCH_FAILURE="$prelaunch_failure_reason"
				return 1
			fi
		done
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			for candidate in "${log_candidates[@]}"; do
				if [[ -f "$candidate" ]] && rg -q '^opencode run \[message\.\.\]|^run opencode with a message|^Options:' "$candidate"; then
					recover_failed_launch_state "$issue_number" "$repo_slug" "cli_usage_output"
					echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — CLI usage output detected in ${candidate}" >>"$LOGFILE"
					_PULSE_LAST_LAUNCH_FAILURE="cli_usage_output"
					return 1
				fi
			done
			# Launch confirmed — do NOT reset fast-fail counter here.
			# A successful launch does not mean successful completion.
			# The counter is reset only when the issue is closed or a PR
			# is confirmed. Resetting on launch defeated the counter
			# entirely — workers that launched but died during execution
			# were invisible. (GH#2076, GH#17378)
			sleep "$stability_seconds"
			elapsed=$((elapsed + stability_seconds))
			if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
				return 0
			fi
			echo "[pulse-wrapper] Launch validation transient for issue #${issue_number} (${repo_slug}) — process disappeared during ${stability_seconds}s stability check" >>"$LOGFILE"
		fi
		sleep "$poll_seconds"
		elapsed=$((elapsed + poll_seconds))
	done
	for candidate in "${log_candidates[@]}"; do
		prelaunch_failure_reason=$(_pulse_worker_log_prelaunch_failure_reason "$candidate")
		if [[ -n "$prelaunch_failure_reason" ]]; then
			recover_failed_launch_state "$issue_number" "$repo_slug" "$prelaunch_failure_reason"
			echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — prelaunch failure reason=${prelaunch_failure_reason} detected in ${candidate}" >>"$LOGFILE"
			_PULSE_LAST_LAUNCH_FAILURE="$prelaunch_failure_reason"
			return 1
		fi
	done

	recover_failed_launch_state "$issue_number" "$repo_slug" "no_worker_process"
	echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — no active worker process within ${grace_seconds}s" >>"$LOGFILE"
	_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
	return 1
}
