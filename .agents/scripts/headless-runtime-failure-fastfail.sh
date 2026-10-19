#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Failure - Fast-Fail Counter (GH#35101)
# =============================================================================
# Fast-fail state functions split from headless-runtime-failure.sh: lock,
# read/write counter state, and worker self-reporting with tier escalation.
#
# Usage: sourced by headless-runtime-failure.sh (do not execute directly).
#
# Dependencies: shared-constants.sh (print_warning, print_info),
#   worker-lifecycle-common.sh (escalate_issue_tier), fast-fail-release-policy.sh,
#   jq, bash 3.2+
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_HEADLESS_RUNTIME_FAILURE_FASTFAIL_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_FASTFAIL_LOADED=1

#######################################
# Acquire the fast-fail mkdir lock with retries.
#
# Args:
#   $1 - lock_dir path
#   $2 - issue_number (for warning message)
#   $3 - repo_slug (for warning message)
# Returns: 0=acquired, 1=timed out
#######################################
_fast_fail_acquire_lock() {
	local lock_dir="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			print_warning "[fast-fail] lock timeout for #${issue_number} (${repo_slug})"
			return 1
		fi
		sleep 0.1
	done
	return 0
}

#######################################
# Read existing count and backoff from fast-fail state file.
# Stale entries (older than expiry_secs) are treated as absent.
#
# Args:
#   $1 - state_file path
#   $2 - key (repo_slug/issue_number)
#   $3 - now (epoch seconds)
#   $4 - expiry_secs
# Sets globals: _FAST_FAIL_EXISTING_COUNT, _FAST_FAIL_EXISTING_BACKOFF
#######################################
_fast_fail_read_state() {
	local state_file="$1"
	local key="$2"
	local now="$3"
	local expiry_secs="$4"
	_FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=0
	if [[ ! -f "$state_file" ]]; then
		return 0
	fi
	local entry=""
	entry=$(jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null) || entry=""
	if [[ -z "$entry" ]]; then
		return 0
	fi
	local entry_ts=""
	entry_ts=$(printf '%s' "$entry" | jq -r '.ts // 0' 2>/dev/null) || entry_ts=0
	# Expire stale entries
	if [[ $((now - entry_ts)) -ge "$expiry_secs" ]]; then
		return 0
	fi
	_FAST_FAIL_EXISTING_COUNT=$(printf '%s' "$entry" | jq -r '.count // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=$(printf '%s' "$entry" | jq -r '.backoff_secs // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_BACKOFF=0
	return 0
}

#######################################
# Write updated fast-fail state atomically via tmp+mv.
#
# Args:
#   $1  - state_file path
#   $2  - state_dir path
#   $3  - key (repo_slug/issue_number)
#   $4  - new_count
#   $5  - now (epoch seconds)
#   $6  - reason
#   $7  - retry_after (epoch seconds)
#   $8  - new_backoff (seconds)
#   $9  - crash_type (may be empty)
#   $10 - set_enrichment (true|false, default false). When true, flags
#         enrichment_needed unless enrichment_done is already true.
#######################################
_fast_fail_write_state() {
	local state_file="$1"
	local state_dir="$2"
	local key="$3"
	local new_count="$4"
	local now="$5"
	local reason="$6"
	local retry_after="$7"
	local new_backoff="$8"
	local crash_type="$9"
	local set_enrichment="${10:-false}"
	local aidevops_version="${AIDEVOPS_UNKNOWN_VERSION:-unknown}"
	# shellcheck disable=SC2016 # jq variables, not shell expansion
	local jq_program='.[$k] = ((.[$k] // {}) + {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type, "aidevops_version": $aidevops_version, "release_reset_policy": $release_reset_policy})'
	if [[ "$set_enrichment" == "true" ]]; then
		# shellcheck disable=SC2016 # jq variables, not shell expansion
		jq_program+=' | if .[$k].enrichment_done != true then .[$k].enrichment_needed = true else . end'
	fi
	local release_reset_policy=""
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "${AIDEVOPS_UNKNOWN_VERSION:-unknown}")
	fi
	release_reset_policy=$(_fast_fail_release_reset_policy "$reason" "${crash_type:-}")
	local updated_state=""
	if [[ -f "$state_file" ]]; then
		updated_state=$(jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			--arg aidevops_version "$aidevops_version" \
			--arg release_reset_policy "$release_reset_policy" \
			"$jq_program" \
			"$state_file") || {
			echo "Error: Failed to update $state_file" >&2
			updated_state=""
		}
	else
		updated_state=$(printf '{}' | jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			--arg aidevops_version "$aidevops_version" \
			--arg release_reset_policy "$release_reset_policy" \
			"$jq_program" \
			2>/dev/null) || updated_state=""
	fi
	if [[ -z "$updated_state" ]]; then
		return 0
	fi
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || tmp_file=""
	if [[ -z "$tmp_file" ]]; then
		return 0
	fi
	printf '%s\n' "$updated_state" >"$tmp_file" 2>/dev/null &&
		mv "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
	return 0
}

#######################################
# Decide whether a worker-side failure reason warrants pulse enrichment.
# PR-exists reasons (post-PR handoff, closed-unmerged) are review/handoff
# problems, not missing implementation guidance, so they are not flagged.
#
# Args: $1 - failure reason
# Returns: 0=flag for enrichment, 1=do not flag
#######################################
_fast_fail_reason_wants_enrichment() {
	local reason="$1"
	case "$reason" in
	worker_noop_zero_output | watchdog_stall_killed | worker_failed | premature_exit | stale_timeout)
		return 0
		;;
	esac
	return 1
}

#######################################
# Report worker failure to the shared fast-fail counter and trigger
# tier escalation when threshold is reached.
#
# Previously, only the pulse (recover_failed_launch_state) and launchd
# watchdog wrote to the counter -- both asynchronous, discovering failures
# 10-30 minutes after the worker died. This function lets the worker
# self-report immediately on exit, so escalation fires within seconds
# instead of 60-90+ minutes. The pulse path remains as a backup for
# workers that crash hard before reaching this function.
#
# Uses the same state file and locking as pulse-wrapper.sh and
# worker-watchdog.sh (fast-fail-counter.json + mkdir lock).
#
# Args:
#   $1 - session_key (e.g., "issue-marcusquinn-aidevops-17642")
#   $2 - failure reason (premature_exit, rate_limit, etc.)
#   $3 - crash_type (optional, e.g., "overwhelmed")
#######################################
_report_failure_to_fast_fail() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local crash_type="${3:-}"

	# Extract issue number from session key (last numeric segment)
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi

	# Only report for worker role (not pulse/triage sessions)
	if [[ "$session_key" != issue-* ]]; then
		return 0
	fi
	if declare -F _objective_disposition_suppresses >/dev/null 2>&1 && \
		_objective_disposition_suppresses suppress_fast_fail "$issue_number" "$repo_slug" "${AIDEVOPS_ATTEMPT_ID:-}"; then
		print_info "[fast-fail] suppressed reconciled non-failure #${issue_number} (${repo_slug})"
		return 0
	fi

	# Launch/preflight aborts happen before a worker reaches the brief. They are
	# useful launch diagnostics, but they must not accrue as per-issue fast-fail
	# / no_work circuit-breaker evidence.
	if declare -F _worker_failure_reason_is_launch_preflight >/dev/null 2>&1; then
		if _worker_failure_reason_is_launch_preflight "$reason"; then
			print_info "[fast-fail] skipped launch/preflight failure #${issue_number} (${repo_slug}) reason=${reason}"
			return 0
		fi
	fi
	if declare -F _worker_failure_reason_is_completion_infrastructure >/dev/null 2>&1; then
		if _worker_failure_reason_is_completion_infrastructure "$reason"; then
			print_info "[fast-fail] skipped completion infrastructure failure #${issue_number} (${repo_slug}) reason=${reason}"
			return 0
		fi
	fi

	local state_file="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
	local state_dir
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || true

	# Acquire lock (shared with pulse-wrapper.sh and worker-watchdog.sh)
	local lock_dir="${state_file}.lockdir"
	_fast_fail_acquire_lock "$lock_dir" "$issue_number" "$repo_slug" || return 0

	local key now
	key="${repo_slug}/${issue_number}"
	now=$(date +%s)

	local initial_backoff="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}"
	local max_backoff="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"
	local expiry_secs="${FAST_FAIL_EXPIRY_SECS:-604800}"

	# Read current state -- sets _FAST_FAIL_EXISTING_COUNT and _FAST_FAIL_EXISTING_BACKOFF
	_fast_fail_read_state "$state_file" "$key" "$now" "$expiry_secs"
	local existing_count="$_FAST_FAIL_EXISTING_COUNT"
	local existing_backoff="$_FAST_FAIL_EXISTING_BACKOFF"

	# Non-rate-limit failures: increment + exponential backoff
	local new_count=$((existing_count + 1))
	local new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
	[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
	local retry_after=$((now + new_backoff))

	local set_enrichment="false"
	if [[ "$new_count" -eq 1 ]] && _fast_fail_reason_wants_enrichment "$reason"; then
		set_enrichment="true"
	fi

	# Write updated state atomically (tmp + mv)
	_fast_fail_write_state "$state_file" "$state_dir" "$key" "$new_count" "$now" \
		"$reason" "$retry_after" "$new_backoff" "$crash_type" "$set_enrichment"

	# Release lock
	rmdir "$lock_dir" 2>/dev/null || true

	print_info "[fast-fail] #${issue_number} (${repo_slug}) count=${new_count} backoff=${new_backoff}s reason=${reason} crash_type=${crash_type:-unclassified}"

	# Trigger tier escalation (escalate_issue_tier from worker-lifecycle-common.sh)
	# Only fires when new_count == threshold -- not on every failure.
	# Pass crash_type so escalation uses crash-type-aware thresholds:
	# "overwhelmed" escalates immediately (threshold=1).
	if [[ "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type" || true
	fi

	return 0
}
