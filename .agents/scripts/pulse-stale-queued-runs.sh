#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bounded, hourly watchdog for stale queued Actions runs in Pulse-managed repos.

_sq_log() {
	local outcome="$1"
	local run="$2"
	printf '[pulse-stale-queued-runs] %s\n' "$(printf '%s' "$run" | jq -c --arg outcome "$outcome" '. + {outcome: $outcome}')"
	return 0
}

_sq_api() {
	local method="$1"
	local endpoint="$2"
	local output="$3"
	SQ_HTTP=""
	# Clear previous observations even when admission denies the next read.
	: >"$output"
	# Guard every request, not just admission of the outer Pulse stage.
	[[ ! -f "${STOP_FLAG:-${HOME}/.aidevops/logs/pulse.stop}" ]] || return 1
	[[ ! -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]] || return 1
	[[ ! -f "${_CIRCUIT_BREAKER_STATE_FILE:-${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state}" ]] || return 1
	pulse_rest_core_priority_allows_next deferrable stale-queued-runs || return 1
	if gh api --method "$method" "$endpoint" >"$output" 2>"${output}.err"; then
		return 0
	fi
	# Never relay API response bodies or raw stderr into public logs.
	if grep -q 'HTTP 409' "${output}.err"; then
		SQ_HTTP=409
	elif grep -q 'HTTP 404' "${output}.err"; then
		SQ_HTTP=404
	elif grep -q 'HTTP 410' "${output}.err"; then
		SQ_HTTP=410
	fi
	return 1
}

# Fail closed: true only when the run has zero jobs and no downloadable logs.
_sq_is_empty_ghost() {
	local repo="$1"
	local id="$2"
	_sq_api GET "repos/${repo}/actions/runs/${id}/jobs?filter=all" "${SQ_WORK}/jobs.json" || return 1
	jq -e '(.total_count == 0) and ((.jobs // []) | length == 0)' "${SQ_WORK}/jobs.json" >/dev/null 2>&1 || return 1
	_sq_still_stale "$repo" "$id" || return 1
	# Success means logs exist; only an explicit 404/410 proves none.
	if _sq_api GET "repos/${repo}/actions/runs/${id}/logs" "${SQ_WORK}/logs.out"; then
		return 1
	fi
	[[ "$SQ_HTTP" == 404 || "$SQ_HTTP" == 410 ]] || return 1
	return 0
}

_sq_still_stale() {
	local repo="$1"
	local id="$2"
	_sq_api GET "repos/${repo}/actions/runs/${id}" "${SQ_WORK}/current.json" || return 1
	jq -e --argjson cutoff "$SQ_CUTOFF" --argjson id "$id" '
		.id == $id and .status == "queued" and (.run_attempt // 1) == 1 and
		((.created_at | fromdateiso8601) < $cutoff)
	' "${SQ_WORK}/current.json" >/dev/null 2>&1 || return 1
	return 0
}

_sq_log_observed() {
	local run="$1"
	local outcome=cancellation-unverified
	if jq -e '.status == "completed" and .conclusion == "cancelled"' "${SQ_WORK}/current.json" >/dev/null 2>&1; then
		outcome=cancelled
	elif jq -e '.status == "completed" or .status == "in_progress"' "${SQ_WORK}/current.json" >/dev/null 2>&1; then
		outcome=no-longer-queued
	fi
	_sq_log "$outcome" "$run"
	return 0
}

_sq_handle_run() {
	local repo="$1"
	local run="$2"
	local state="$3"
	local id run_ep cancel_conflict=0 force_conflict=0
	id=$(printf '%s' "$run" | jq -r '.id')
	run_ep="repos/${repo}/actions/runs/${id}"
	[[ "$id" =~ ^[1-9][0-9]*$ ]] || return 1
	# Listing is only a candidate set: revalidate immediately before writes.
	_sq_still_stale "$repo" "$id" || return 0
	if ! _sq_api POST "repos/${repo}/actions/runs/${id}/cancel" "${SQ_WORK}/cancel.json"; then
		[[ "$SQ_HTTP" == 409 ]] || {
			_sq_log cancel-failed "$run"
			return 0
		}
		cancel_conflict=1
	fi
	if ! _sq_still_stale "$repo" "$id"; then
		# A failed read is not evidence that cancellation succeeded.
		_sq_log_observed "$run"
		return 0
	fi
	if ! _sq_api POST "repos/${repo}/actions/runs/${id}/force-cancel" "${SQ_WORK}/force.json"; then
		[[ "$SQ_HTTP" == 409 ]] || {
			_sq_log force-cancel-failed "$run"
			return 0
		}
		force_conflict=1
	fi
	if [[ "$cancel_conflict" == 1 && "$force_conflict" == 1 ]]; then
		_sq_still_stale "$repo" "$id" || {
			_sq_log_observed "$run"
			return 0
		}
		if [[ ! -f "${state}/${id}.ghost" ]]; then
			# Persist before logging to dedupe subsequent cycles.
			printf '%s\n' "$run" >"${state}/${id}.ghost" || return 1
			_sq_log unkillable-ghost "$run"
		fi
		if [[ "${AIDEVOPS_STALE_QUEUED_RUN_DELETE_EMPTY:-1}" != 0 ]] && _sq_is_empty_ghost "$repo" "$id"; then
			# Re-check staleness immediately before the destructive call.
			_sq_still_stale "$repo" "$id" || return 0
			if _sq_api DELETE "$run_ep" "${SQ_WORK}/delete.json"; then
				_sq_log deleted-empty-ghost "$run"
			else
				_sq_log delete-failed "$run"
			fi
			return 0
		fi
		if [[ "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" == 1 ]]; then
			_sq_still_stale "$repo" "$id" || return 0
			if _sq_api DELETE "$run_ep" "${SQ_WORK}/delete.json"; then
				_sq_log deleted-ghost "$run"
			else
				_sq_log delete-failed "$run"
			fi
		fi
		return 0
	fi
	if _sq_still_stale "$repo" "$id"; then
		_sq_log cancellation-pending "$run"
	else
		_sq_log_observed "$run"
	fi
	return 0
}

_sq_scan_repo() {
	local repo="$1"
	local state="${SQ_STATE}/${repo}"
	local last=0 page=1 count run
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	mkdir -p "$state" || return 1
	if [[ -f "${state}/last-scan" ]]; then
		read -r last <"${state}/last-scan" || last=0
	fi
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	((SQ_NOW - last >= 3600)) || return 0
	# Claim cadence before network I/O, including failed/permission-denied scans.
	printf '%s\n' "$SQ_NOW" >"${state}/last-scan" || return 1
	_sq_api GET "repos/${repo}" "${SQ_WORK}/repo.json" || return 0
	jq -e '.permissions | (.admin == true or .maintain == true or .push == true)' "${SQ_WORK}/repo.json" >/dev/null 2>&1 || return 0
	# One page per repo is intentional: bound both response size and write fanout.
	if [[ -f "${state}/next-page" ]]; then
		read -r page <"${state}/next-page" || page=1
	fi
	[[ "$page" =~ ^([1-9]|10)$ ]] || page=1
	_sq_api GET "repos/${repo}/actions/runs?status=queued&created=%3C${SQ_CUTOFF_ISO}&per_page=100&page=${page}" "${SQ_WORK}/runs.json" || return 0
	count=$(jq '.workflow_runs | length' "${SQ_WORK}/runs.json") || return 1
	# Rotate before writes so a timeout or a page full of ghosts cannot starve
	# later candidates. GitHub caps filtered searches at 1,000 results.
	if [[ "$count" -eq 100 && "$page" -lt 10 ]]; then
		printf '%s\n' "$((page + 1))" >"${state}/next-page"
	else
		printf '1\n' >"${state}/next-page"
	fi
	while IFS= read -r run; do
		_sq_handle_run "$repo" "$run" "$state" || return 1
	done < <(jq -c --arg repo "$repo" --argjson now "$SQ_NOW" --argjson cutoff "$SQ_CUTOFF" '
		.workflow_runs[]? | select(.status == "queued" and (.run_attempt // 1) == 1) |
		(.created_at | fromdateiso8601?) as $created | select($created < $cutoff) |
		{repo: $repo, id, workflow: .name, age_seconds: ($now - $created)}
	' "${SQ_WORK}/runs.json")
	return 0
}

_sq_cleanup() {
	[[ -z "${_SQ_WORK_CLEANUP:-}" ]] || rm -rf "$_SQ_WORK_CLEANUP"
	_lock_release
	return 0
}

pulse_stale_queued_runs_scan() (
	local max_age="${AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS:-8}"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local helper_dir repo rc=0
	[[ "$max_age" =~ ^[0-9]{1,5}$ ]] || {
		printf '[pulse-stale-queued-runs] invalid max age\n'
		return 1
	}
	max_age=$((10#$max_age))
	[[ "$max_age" -ne 0 ]] || return 0
	[[ -f "$repos_json" ]] || return 0
	helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=./shared-constants.sh
	source "${helper_dir}/shared-constants.sh"
	# Standalone invocation uses the same REST budget policy as the wrapper.
	if ! declare -F pulse_rest_core_priority_allows_next >/dev/null; then
		# shellcheck source=./pulse-rate-limit-circuit-breaker.sh
		source "${helper_dir}/pulse-rate-limit-circuit-breaker.sh"
	fi
	local SQ_NOW SQ_CUTOFF SQ_CUTOFF_ISO SQ_STATE SQ_WORK SQ_HTTP=""
	SQ_NOW=$(date -u +%s)
	SQ_CUTOFF=$((SQ_NOW - max_age * 3600))
	SQ_CUTOFF_ISO=$(jq -nr --argjson cutoff "$SQ_CUTOFF" '$cutoff | todateiso8601')
	SQ_STATE="${HOME}/.aidevops/.agent-workspace/pulse/stale-queued-runs"
	mkdir -p "$SQ_STATE" || return 1
	LOGFILE="${LOGFILE:-${SQ_STATE}/watchdog.log}"
	# Reuse the watchdog-safe owner-PID lock, including dead-owner recovery.
	# shellcheck source=./cleanup-worktrees-lock.sh
	source "${helper_dir}/cleanup-worktrees-lock.sh"
	LOCK_DIR="${SQ_STATE}/lock"
	PID_FILE="${LOCK_DIR}/pid"
	_lock_acquire || return 0
	# Traps and their cleanup globals stay isolated in this subshell.
	_SQ_WORK_CLEANUP=""
	trap '_sq_cleanup' EXIT
	trap 'exit 1' TERM INT HUP
	SQ_WORK=$(mktemp -d "${SQ_STATE}/work.XXXXXX") || return 1
	_SQ_WORK_CLEANUP="$SQ_WORK"
	while IFS= read -r repo; do
		_sq_scan_repo "$repo" || rc=1
	done < <(jq -r '.initialized_repos[]? |
		select(.maintenance != false and .pulse == true and (.local_only // false) == false) |
		select((.role // "maintainer") != "contributor") | .slug // empty' "$repos_json")
	return "$rc"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -euo pipefail
	pulse_stale_queued_runs_scan
fi
