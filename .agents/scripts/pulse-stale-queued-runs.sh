#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bounded, hourly cleanup of stale queued Actions runs (GH#33602).

_sq_api() {
	local method="$1" endpoint="$2" output="$3" errors="$4"
	# Fail closed when the pulse's REST reserve or rate-limit pause applies.
	[[ ! -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]] || return 1
	if declare -F pulse_rest_core_priority_allows_next >/dev/null; then
		pulse_rest_core_priority_allows_next deferrable stale_queued_runs || return 1
	else
		return 1
	fi
	local timer="timeout"
	command -v "$timer" >/dev/null || timer="gtimeout"
	command -v "$timer" >/dev/null || return 1
	"$timer" 15 gh api --method "$method" "$endpoint" >"$output" 2>"$errors" && return 0
	return 1
}

_sq_log() {
	local message="$1"
	printf '[stale-queued-runs] %s\n' "$message"
	return 0
}

_sq_eligible() {
	local output="$1" cutoff="$2"
	jq -e --argjson cutoff "$cutoff" '.status == "queued" and ((.created_at | fromdateiso8601) < $cutoff)' "$output" >/dev/null 2>&1 && return 0
	return 1
}

_sq_process_run() {
	local repo="$1" id="$2" state="$3" work="$4" cutoff="$5" now="$6"
	local output="${work}/response.json" errors="${work}/api.err"
	local endpoint="repos/${repo}/actions/runs/${id}" marker="${state}/ghost-${id}"
	local name="" age="" cancel_conflict=0
	[[ "$id" =~ ^[0-9]+$ ]] || return 0
	[[ ! -f "$marker" || "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" == "1" ]] || return 0
	# Re-read immediately before mutation; API list filtering alone is not safety.
	_sq_api GET "$endpoint" "$output" "$errors" || return 0
	_sq_eligible "$output" "$cutoff" || return 0
	name=$(jq -r '.name // "unknown" | gsub("[\\r\\n\\t\\u001b]"; " ")' "$output")
	age=$(jq -r --argjson now "$now" '($now - (.created_at | fromdateiso8601)) / 3600 | floor' "$output")
	if _sq_api POST "${endpoint}/cancel" "$output" "$errors"; then
		_sq_log "repo=${repo} run=${id} workflow=${name} age=${age}h cancel=requested"
		# A successful request is asynchronous. Force only if still queued.
		_sq_api GET "$endpoint" "$output" "$errors" || return 0
		_sq_eligible "$output" "$cutoff" || return 0
	else
		if ! grep -q 'HTTP 409' "$errors"; then
			_sq_log "repo=${repo} run=${id} cancel=failed (API details redacted)"
			return 0
		fi
		cancel_conflict=1
	fi
	# Check age/status again before escalation in case the run started meanwhile.
	_sq_api GET "$endpoint" "$output" "$errors" || return 0
	_sq_eligible "$output" "$cutoff" || return 0
	if _sq_api POST "${endpoint}/force-cancel" "$output" "$errors"; then
		_sq_log "repo=${repo} run=${id} workflow=${name} age=${age}h force-cancel=requested"
		return 0
	fi
	if [[ "$cancel_conflict" != "1" ]] || ! grep -q 'HTTP 409' "$errors"; then
		_sq_log "repo=${repo} run=${id} force-cancel=failed (API details redacted)"
		return 0
	fi
	if [[ ! -f "$marker" ]]; then
		_sq_log "repo=${repo} run=${id} workflow=${name} age=${age}h ghost=uncancellable (409 twice); deletion requires opt-in"
		touch "$marker" || return 1
	fi
	[[ "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" == "1" ]] || return 0
	_sq_api GET "$endpoint" "$output" "$errors" || return 0
	_sq_eligible "$output" "$cutoff" || return 0
	if _sq_api DELETE "$endpoint" "$output" "$errors"; then
		_sq_log "repo=${repo} run=${id} workflow=${name} age=${age}h ghost=deleted (explicit opt-in)"
	fi
	return 0
}

_sq_repo_cleanup() {
	local work="$1" state="$2"
	if [[ -n "$work" ]]; then
		rm -f "${work}/repo.json" "${work}/runs.json" "${work}/response.json" "${work}/api.err"
		rmdir "$work" 2>/dev/null || true
	fi
	rmdir "${state}/lock" 2>/dev/null || true
	return 0
}

_sq_repo() (
	local repo="$1" root="$2" cutoff="$3" now="$4"
	local state="${root}/${repo//\//__}" work="" last=0 id="" cutoff_iso="" count=0
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
	mkdir -p "$state" || return 1
	# Check cadence under the lock, including concurrent standalone callers.
	mkdir "${state}/lock" 2>/dev/null || return 0
	trap '_sq_repo_cleanup "$work" "$state"' EXIT
	trap 'exit 1' TERM INT
	if [[ -f "${state}/last-check" ]]; then
		read -r last <"${state}/last-check" || last=0
	fi
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	[[ $((now - last)) -ge 3600 ]] || return 0
	printf '%s\n' "$now" >"${state}/last-check"
	work=$(mktemp -d "${state}/request.XXXXXX") || return 1
	cutoff_iso=$(jq -nr --argjson cutoff "$cutoff" '$cutoff | strftime("%Y-%m-%dT%H:%M:%SZ")')
	# Repository write permission is necessary; Actions-scoped token permission
	# is additionally enforced by GitHub on each mutation (403 fails closed).
	if _sq_api GET "repos/${repo}" "${work}/repo.json" "${work}/api.err" &&
		jq -e '.permissions.push == true or .permissions.admin == true or .permissions.maintain == true' "${work}/repo.json" >/dev/null 2>&1 &&
		_sq_api GET "repos/${repo}/actions/runs?status=queued&created=%3C${cutoff_iso}&per_page=100" "${work}/runs.json" "${work}/api.err"; then
		# One page and at most 20 candidates per repo per hour bound API cost.
		while IFS= read -r id; do
			[[ -f "${state}/ghost-${id}" && "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" != "1" ]] && continue
			[[ "$count" -lt 20 ]] || break
			_sq_process_run "$repo" "$id" "$state" "$work" "$cutoff" "$now" || true
			count=$((count + 1))
		done < <(jq -r --argjson cutoff "$cutoff" '.workflow_runs[] | select(.status == "queued" and ((.created_at | fromdateiso8601) < $cutoff)) | .id' "${work}/runs.json" 2>/dev/null)
	fi
	return 0
)

pulse_stale_queued_runs() {
	local hours="${AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS:-8}"
	local repos="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local root="${AIDEVOPS_STALE_QUEUED_RUN_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse/stale-queued-runs}"
	local now="" cutoff="" repo=""
	[[ "$hours" =~ ^[0-9]{1,6}$ ]] || { _sq_log 'invalid max age; skipping'; return 0; }
	hours=$((10#$hours))
	[[ "$hours" -ne 0 && "${PULSE_DRY_RUN:-0}" != "1" && -f "$repos" ]] || return 0
	now=$(date +%s)
	cutoff=$((now - hours * 3600))
	while IFS= read -r repo; do
		_sq_repo "$repo" "$root" "$cutoff" "$now" || true
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false) | .slug // empty' "$repos" 2>/dev/null)
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	LOGFILE="${LOGFILE:-/dev/null}"
	# shellcheck source=./pulse-rate-limit-circuit-breaker.sh
	source "${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh"
	pulse_stale_queued_runs
fi
