#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bounded, hourly stale Actions queue maintenance (GH#33602).
# Sourced by pulse; can also be run with bash for standalone verification.

_sqr_log() {
	local message="$1"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[pulse-stale-queued-runs] %s\n' "$message" >>"$LOGFILE" || return 1
	else
		printf '[pulse-stale-queued-runs] %s\n' "$message" || return 1
	fi
	return 0
}

# Never expose raw API errors, which can contain private URLs or credentials.
# All calls are bounded and admitted through pulse's REST reserve when sourced.
_sqr_api() {
	local method="$1"
	local endpoint="$2"
	local output="$3"
	local error_file="$4"
	local timeout_command="timeout"
	command -v "$timeout_command" >/dev/null || timeout_command="gtimeout"
	command -v "$timeout_command" >/dev/null || return 1
	if declare -F pulse_rest_core_priority_allows_next >/dev/null; then
		pulse_rest_core_priority_allows_next deferrable stale-queued-runs || return 1
	fi
	if "$timeout_command" --kill-after=2 15 gh api --method "$method" "$endpoint" >"$output" 2>"$error_file"; then
		return 0
	fi
	if grep -q 'HTTP 409' "$error_file"; then
		return 9
	fi
	return 1
}

_sqr_process_run() {
	local repo="$1"
	local run="$2"
	local dir="$3"
	local now="$4"
	local cutoff="$5"
	local dry_run="$6"
	local id created name age status cancel_rc=0 force_rc=0
	id=$(jq -r '.id' <<<"$run")
	[[ "$id" =~ ^[0-9]+$ ]] || return 0
	created=$(jq -r '.created_at | fromdateiso8601' <<<"$run" 2>/dev/null) || return 0
	((created < cutoff)) || return 0
	name=$(jq -r '(.name // "unknown") | gsub("[[:cntrl:]]"; " ")' <<<"$run")
	age=$(((now - created) / 3600))
	local endpoint="repos/${repo}/actions/runs/${id}"
	local output="${dir}/response.json" error_file="${dir}/api.err"
	local ghost="${dir}/ghost-${id}"
	if [[ "$dry_run" == 1 ]]; then
		_sqr_log "dry-run: stale run=${id} workflow=${name} age_hours=${age}"
		return 0
	fi
	# Re-read before every mutation: never cancel a run that started meanwhile.
	_sqr_api GET "$endpoint" "$output" "$error_file" || return 1
	status=$(jq -r '.status' "$output")
	[[ "$status" == queued ]] || return 0
	# Previously confirmed ghosts need no repeated cancellation attempts.
	if [[ ! -f "$ghost" ]]; then
		_sqr_api POST "${endpoint}/cancel" "$output" "$error_file" || cancel_rc=$?
		if [[ "$cancel_rc" -eq 0 ]]; then
			_sqr_api GET "$endpoint" "$output" "$error_file" || return 1
			status=$(jq -r '.status' "$output")
			if [[ "$status" != queued ]]; then
				_sqr_log "cancel accepted run=${id} workflow=${name} age_hours=${age} observed_status=${status}"
				return 0
			fi
		elif [[ "$cancel_rc" -ne 9 ]]; then
			_sqr_log "cancel failed run=${id} (API unavailable or access denied)"
			return 1
		fi
		_sqr_api GET "$endpoint" "$output" "$error_file" || return 1
		[[ "$(jq -r '.status' "$output")" == queued ]] || return 0
		_sqr_api POST "${endpoint}/force-cancel" "$output" "$error_file" || force_rc=$?
		if [[ "$cancel_rc" -eq 9 && "$force_rc" -eq 9 ]]; then
			_sqr_log "ghost run=${id} workflow=${name} age_hours=${age}: cancel and force-cancel returned 409; retaining unless delete opt-in is enabled"
			printf '%s\n' "$now" >"$ghost"
		elif [[ "$force_rc" -eq 0 ]]; then
			_sqr_log "force-cancel accepted run=${id} workflow=${name} age_hours=${age}"
			return 0
		else
			_sqr_log "force-cancel failed run=${id} (API unavailable or access denied)"
			return 1
		fi
	fi
	if [[ "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" == 1 ]]; then
		_sqr_api GET "$endpoint" "$output" "$error_file" || return 1
		[[ "$(jq -r '.status' "$output")" == queued ]] || return 0
		_sqr_api DELETE "$endpoint" "$output" "$error_file" || return 1
		_sqr_log "deleted ghost run=${id} workflow=${name} age_hours=${age}"
	fi
	return 0
}

pulse_stale_queued_runs_scan() {
	local hours="${AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS:-8}"
	[[ "$hours" =~ ^[0-9]{1,6}$ ]] || return 1
	hours=$((10#$hours))
	[[ "$hours" -gt 0 ]] || return 0
	[[ "${PULSE_CANARY_MODE:-0}" != 1 ]] || return 0
	[[ ! -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]] || return 0
	local registry="${REPOS_JSON:-${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
	[[ -f "$registry" ]] || return 0
	local state="${AIDEVOPS_STALE_QUEUED_RUN_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse/stale-queued-runs}"
	local now cutoff cutoff_iso repo dir last page page_size run id count dry_run="${PULSE_DRY_RUN:-0}"
	now=$(date -u +%s)
	cutoff=$((now - hours * 3600))
	cutoff_iso=$(jq -nr --argjson epoch "$cutoff" '$epoch | strftime("%Y-%m-%dT%H:%M:%SZ")')
	local repos
	repos=$(jq -r '.initialized_repos[]? | select(.maintenance != false and .pulse == true and .local_only != true and (.role // "maintainer") != "contributor") | .slug // empty' "$registry") || return 1
	for repo in $repos; do
		[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
		dir="${state}/${repo}"
		(umask 077; mkdir -p "$dir") || return 1
		last=0
		if [[ -f "${dir}/last-scan" ]]; then
			read -r last <"${dir}/last-scan" || last=0
		fi
		[[ "$last" =~ ^[0-9]+$ ]] || last=0
		((now - last >= 3600)) || continue
		# Claim cadence before network work, including failures and stage timeouts.
		[[ "$dry_run" == 1 ]] || printf '%s\n' "$now" >"${dir}/last-scan"
		_sqr_api GET "repos/${repo}" "${dir}/response.json" "${dir}/api.err" || return 1
		# Repo write permission is necessary; Actions-scoped denial still fails closed.
		jq -e '.permissions.push == true or .permissions.maintain == true or .permissions.admin == true' "${dir}/response.json" >/dev/null || continue
		# Rotate one page hourly so retained ghosts cannot pin the first page.
		page=1
		if [[ -f "${dir}/next-page" ]]; then
			read -r page <"${dir}/next-page" || page=1
		fi
		[[ "$page" =~ ^[1-9][0-9]{0,6}$ ]] || page=1
		_sqr_api GET "repos/${repo}/actions/runs?status=queued&created=%3C${cutoff_iso}&per_page=100&page=${page}" "${dir}/runs.json" "${dir}/api.err" || return 1
		page_size=$(jq -er '.workflow_runs | length' "${dir}/runs.json") || return 1
		if [[ "$dry_run" != 1 ]]; then
			if [[ "$page_size" -eq 100 ]]; then
				printf '%s\n' "$((page + 1))" >"${dir}/next-page"
			else
				printf '1\n' >"${dir}/next-page"
			fi
		fi
		count=0
		while IFS= read -r run; do
			id=$(jq -r '.id' <<<"$run")
			# Known retained ghosts must not consume the per-scan work allowance.
			if [[ "$dry_run" != 1 && "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" != 1 && "$id" =~ ^[0-9]+$ && -f "${dir}/ghost-${id}" ]]; then
				continue
			fi
			_sqr_process_run "$repo" "$run" "$dir" "$now" "$cutoff" "$dry_run" || return 1
			count=$((count + 1))
			[[ "$count" -lt 20 ]] || break
		done < <(jq -c --argjson cutoff "$cutoff" '.workflow_runs | sort_by(.created_at)[] | select(.status == "queued") | select((try (.created_at | fromdateiso8601) catch $cutoff) < $cutoff)' "${dir}/runs.json")
	done
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -euo pipefail
	# shellcheck source=./shared-constants.sh
	source "$(dirname "${BASH_SOURCE[0]}")/shared-constants.sh"
	pulse_stale_queued_runs_scan
fi
