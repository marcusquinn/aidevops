#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-stale-queued-runs.sh — cancel GitHub Actions runs stuck in `queued`
# (GH#33602)
# =============================================================================
# Ghost runs that stay `queued` for months inflate `?status=queued` counts used
# by the Actions queue saturation check (pulse-rate-limit-circuit-breaker.sh)
# and github-runner-broker-health-helper.sh, so idle runners look backlogged.
#
# Per pulse-managed repo where the runner has write access, at most once per
# AIDEVOPS_STALE_QUEUED_RUN_INTERVAL_SECONDS:
#   1. List runs with status=queued created before now - max age.
#   2. POST cancel. A run whose earlier accepted cancel had no effect (still
#      queued a cycle later), or whose cancel returns 409, gets force-cancel.
#   3. HTTP 409 on both endpoints = unkillable ghost: logged once per run ID.
#      DELETE only when AIDEVOPS_STALE_QUEUED_RUN_DELETE=1.
# Runs younger than the max age are never touched: the API filter and a local
# created_at re-check both enforce the cutoff.
#
# Settings:
#   AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS   default 8; 0 disables the stage
#   AIDEVOPS_STALE_QUEUED_RUN_DELETE          default 0; 1 deletes 409 ghosts
#   AIDEVOPS_STALE_QUEUED_RUN_INTERVAL_SECONDS default 3600 (per repo)
#   AIDEVOPS_STALE_QUEUED_RUN_MAX_RUNS        default 20 actions per repo/cycle
#   AIDEVOPS_STALE_QUEUED_RUN_MAX_REPOS       default 50
#   AIDEVOPS_STALE_QUEUED_RUN_STATE_DIR       default <pulse workspace>/stale-queued-runs
#
# Sourced by pulse-wrapper.sh (stage `stale_queued_runs`); also runnable
# standalone: pulse-stale-queued-runs.sh scan [--dry-run] [--repo OWNER/REPO]
# =============================================================================

[[ -n "${_PULSE_STALE_QUEUED_RUNS_LOADED:-}" ]] && return 0 2>/dev/null
_PULSE_STALE_QUEUED_RUNS_LOADED=1

_PSQR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PSQR_RATE_LIMIT_RC=75
_PSQR_PERMISSION_RC=4
_PSQR_COUNT_CANCELLED=0
_PSQR_COUNT_GHOSTS=0
_PSQR_COUNT_DELETED=0
_PSQR_COUNT_FAILED=0

_psqr_log() {
	local message="$1"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[pulse-stale-queued-runs] %s\n' "$message" >>"$LOGFILE" 2>/dev/null || true
	else
		printf '[pulse-stale-queued-runs] %s\n' "$message" >&2
	fi
	return 0
}

_psqr_now() {
	local test_now="${AIDEVOPS_STALE_QUEUED_RUN_TEST_NOW:-}"
	if [[ "$test_now" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$test_now"
	else
		date -u '+%s'
	fi
	return 0
}

# Stdout: non-negative integer setting, or the default when unset/invalid.
# Args: $1=raw value, $2=default
_psqr_uint_setting() {
	local raw_value="$1"
	local default_value="$2"
	[[ "$raw_value" =~ ^[0-9]+$ ]] || raw_value="$default_value"
	printf '%s\n' "$((10#$raw_value))"
	return 0
}

_psqr_state_dir() {
	local pulse_dir="${PULSE_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	printf '%s\n' "${AIDEVOPS_STALE_QUEUED_RUN_STATE_DIR:-${pulse_dir}/stale-queued-runs}"
	return 0
}

_psqr_state_prefix() {
	local repo_slug="$1"
	local slug_key=""
	slug_key=$(printf '%s' "$repo_slug" | tr '/:' '__')
	printf '%s/%s\n' "$(_psqr_state_dir)" "$slug_key"
	return 0
}

_psqr_list_has() {
	local list_file="$1"
	local item="$2"
	[[ -f "$list_file" ]] || return 1
	grep -Fxq -- "$item" "$list_file" 2>/dev/null
	return $?
}

_psqr_list_add() {
	local list_file="$1"
	local item="$2"
	_psqr_list_has "$list_file" "$item" && return 0
	mkdir -p "$(dirname "$list_file")" 2>/dev/null || return 0
	printf '%s\n' "$item" >>"$list_file" 2>/dev/null || true
	return 0
}

# Classify gh api stderr. Stdout: rate_limit|finished|conflict|permission|error
_psqr_classify_error() {
	local error_text="$1"
	local normalized=""
	local conflict_marker="http 409"
	normalized=$(printf '%s' "$error_text" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
	*"rate limit"* | *"abuse detection"* | *"temporarily blocked"*)
		printf 'rate_limit\n'
		;;
	*"$conflict_marker"*"completed"* | *"completed"*"$conflict_marker"*)
		printf 'finished\n'
		;;
	*"$conflict_marker"*)
		printf 'conflict\n'
		;;
	*"http 403"* | *"http 404"* | *"forbidden"* | *"resource not accessible"* | *"must have admin"*)
		printf 'permission\n'
		;;
	*)
		printf 'error\n'
		;;
	esac
	return 0
}

_psqr_gh_write() {
	local method="$1"
	local endpoint="$2"
	local error_file="$3"
	AIDEVOPS_GH_ROUTE_DECISION="pulse-stale-queued-runs-rest" \
		gh api -X "$method" "$endpoint" >/dev/null 2>"$error_file"
	return $?
}

# Returns 0 when shared GitHub throttling state allows optional REST writes.
_psqr_budget_allows() {
	local phase="" rc=0
	if declare -F _gh_secondary_cooldown_active >/dev/null 2>&1 && _gh_secondary_cooldown_active; then
		_psqr_log "shared GitHub cooldown active; skipping"
		return 1
	fi
	if declare -F _gh_secondary_read_ramp_phase >/dev/null 2>&1; then
		phase=$(_gh_secondary_read_ramp_phase 2>/dev/null || true)
		if [[ -n "$phase" ]]; then
			_psqr_log "GitHub recovery ramp active; skipping"
			return 1
		fi
	fi
	if declare -F pulse_rest_core_priority_allows >/dev/null 2>&1; then
		pulse_rest_core_priority_allows deferrable || rc=$?
		if [[ "$rc" -ne 0 ]]; then
			_psqr_log "REST core budget defers optional work (rc=${rc}); skipping"
			return 1
		fi
	fi
	return 0
}

# #aidevops:trust-boundary — cancelling or deleting runs requires the
# authenticated runner to hold write (Actions write) access on the repo.
_psqr_repo_allows_actions_write() {
	local repo_slug="$1"
	local can_push=""
	if declare -F repo_allows_pulse_write_actions >/dev/null 2>&1; then
		repo_allows_pulse_write_actions "$repo_slug"
		return $?
	fi
	can_push=$(gh api "repos/${repo_slug}" --jq '.permissions.push // false' 2>/dev/null) || return 1
	[[ "$can_push" == "true" ]] || return 1
	return 0
}

_psqr_list_repos() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] || return 1
	jq -r '
		.initialized_repos[]?
		| select(.maintenance != false)
		| select((.pulse // false) == true)
		| select((.local_only // false) == false)
		| select((.role // "maintainer") != "contributor")
		| select((.slug // "") != "")
		| .slug
	' "$repos_json" 2>/dev/null
	return $?
}

# Returns 0 when the per-repo interval has elapsed (or no prior run).
_psqr_repo_due() {
	local last_run_file="$1"
	local now="$2"
	local interval="" last_run=""
	interval=$(_psqr_uint_setting "${AIDEVOPS_STALE_QUEUED_RUN_INTERVAL_SECONDS:-}" 3600)
	[[ -f "$last_run_file" ]] || return 0
	last_run=$(<"$last_run_file")
	[[ "$last_run" =~ ^[0-9]+$ ]] || return 0
	[[ $((now - last_run)) -ge "$interval" ]] && return 0
	return 1
}

# Deletes a 409 ghost only with the explicit opt-in.
# Returns: 0 handled; 75 rate limited.
_psqr_delete_ghost() {
	local repo_slug="$1"
	local run_id="$2"
	local error_file="$3"
	local outcome=""
	[[ "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" == "1" ]] || return 0
	if _psqr_gh_write DELETE "repos/${repo_slug}/actions/runs/${run_id}" "$error_file"; then
		_PSQR_COUNT_DELETED=$((_PSQR_COUNT_DELETED + 1))
		_psqr_log "deleted ghost queued run: repo=${repo_slug} run=${run_id} (AIDEVOPS_STALE_QUEUED_RUN_DELETE=1)"
		return 0
	fi
	outcome=$(_psqr_classify_error "$(<"$error_file")")
	[[ "$outcome" == "rate_limit" ]] && return "$_PSQR_RATE_LIMIT_RC"
	_PSQR_COUNT_FAILED=$((_PSQR_COUNT_FAILED + 1))
	_psqr_log "ghost delete failed: repo=${repo_slug} run=${run_id} class=${outcome}"
	return 0
}

# Stdout: cancel|force-cancel|ghost|finished|rate_limit|permission|error
# Args: $1=repo, $2=run id, $3=1 to skip plain cancel, $4=error file
_psqr_cancel_run() {
	local repo_slug="$1"
	local run_id="$2"
	local force_first="$3"
	local error_file="$4"
	local endpoint="repos/${repo_slug}/actions/runs/${run_id}"
	local outcome=""
	if [[ "$force_first" != "1" ]]; then
		if _psqr_gh_write POST "${endpoint}/cancel" "$error_file"; then
			printf 'cancel\n'
			return 0
		fi
		outcome=$(_psqr_classify_error "$(<"$error_file")")
		if [[ "$outcome" != "conflict" ]]; then
			printf '%s\n' "$outcome"
			return 0
		fi
	fi
	if _psqr_gh_write POST "${endpoint}/force-cancel" "$error_file"; then
		printf 'force-cancel\n'
		return 0
	fi
	outcome=$(_psqr_classify_error "$(<"$error_file")")
	[[ "$outcome" == "conflict" ]] && outcome="ghost"
	printf '%s\n' "$outcome"
	return 0
}

# Handle one stale run. Returns: 0 continue; 75 rate limited; 4 no permission.
# Args: $1=repo, $2=run id, $3=workflow, $4=age hours, $5=state prefix,
#       $6=next pending file, $7=error file
_psqr_handle_run() {
	local repo_slug="$1"
	local run_id="$2"
	local workflow="$3"
	local age_hours="$4"
	local state_prefix="$5"
	local pending_next="$6"
	local error_file="$7"
	local ghosts_file="${state_prefix}.ghosts"
	local force_first=0 outcome="" run_desc=""
	run_desc="repo=${repo_slug} run=${run_id} workflow=\"${workflow}\" age=${age_hours}h"
	if _psqr_list_has "$ghosts_file" "$run_id"; then
		_psqr_delete_ghost "$repo_slug" "$run_id" "$error_file"
		return $?
	fi
	# An accepted cancel that left the run queued a cycle later had no effect.
	_psqr_list_has "${state_prefix}.pending" "$run_id" && force_first=1
	outcome=$(_psqr_cancel_run "$repo_slug" "$run_id" "$force_first" "$error_file")
	case "$outcome" in
	cancel | force-cancel)
		_PSQR_COUNT_CANCELLED=$((_PSQR_COUNT_CANCELLED + 1))
		printf '%s\n' "$run_id" >>"$pending_next"
		_psqr_log "cancelled stale queued run: ${run_desc} action=${outcome}"
		;;
	ghost)
		_PSQR_COUNT_GHOSTS=$((_PSQR_COUNT_GHOSTS + 1))
		_psqr_list_add "$ghosts_file" "$run_id"
		_psqr_log "unkillable ghost queued run (HTTP 409 on cancel and force-cancel): ${run_desc}; set AIDEVOPS_STALE_QUEUED_RUN_DELETE=1 to delete"
		_psqr_delete_ghost "$repo_slug" "$run_id" "$error_file"
		return $?
		;;
	finished) ;;
	rate_limit) return "$_PSQR_RATE_LIMIT_RC" ;;
	permission)
		_psqr_log "no permission to cancel runs: repo=${repo_slug}; skipping repo"
		return "$_PSQR_PERMISSION_RC"
		;;
	*)
		_PSQR_COUNT_FAILED=$((_PSQR_COUNT_FAILED + 1))
		_psqr_log "cancel failed: ${run_desc} class=${outcome}"
		;;
	esac
	return 0
}

# Write stale runs as TSV (id, workflow, age hours) to $3.
# Returns: 0 ok; 75 rate limited; 1 other failure (logged).
_psqr_fetch_stale_runs() {
	local repo_slug="$1"
	local now="$2"
	local runs_file="$3"
	local error_file="$4"
	local max_age_hours="$5"
	local cutoff=$((now - max_age_hours * 3600))
	local cutoff_iso="" outcome=""
	local pages_file="${runs_file}.pages"
	cutoff_iso=$(jq -rn --argjson t "$cutoff" '$t | todate') || return 1
	if ! AIDEVOPS_GH_ROUTE_DECISION="pulse-stale-queued-runs-list-rest" \
		gh api --paginate --slurp "repos/${repo_slug}/actions/runs?status=queued&created=%3C${cutoff_iso}&per_page=100" \
		>"$pages_file" 2>"$error_file"; then
		outcome=$(_psqr_classify_error "$(<"$error_file")")
		[[ "$outcome" == "rate_limit" ]] && return "$_PSQR_RATE_LIMIT_RC"
		_psqr_log "listing queued runs failed: repo=${repo_slug} class=${outcome}"
		return 1
	fi
	# Re-check status and age locally so a too-young run is never touched even
	# if the API filter is ignored or changes semantics.
	jq -r --argjson cutoff "$cutoff" --argjson now "$now" '
		[ .[].workflow_runs[]? ]
		| map(select(.status == "queued" and ((.created_at // "") | length) > 0))
		| map(. + {created_epoch: (.created_at | fromdateiso8601)})
		| map(select(.created_epoch < $cutoff))
		| sort_by(.created_epoch) | unique_by(.id) | sort_by(.created_epoch)
		| .[]
		| [(.id | tostring),
		   ((.name // .display_title // "unknown") | gsub("[\\t\\r\\n]"; " ")),
		   ((($now - .created_epoch) / 3600) | floor | tostring)]
		| @tsv
	' "$pages_file" >"$runs_file" 2>"$error_file" || {
		_psqr_log "parsing queued runs failed: repo=${repo_slug}"
		return 1
	}
	return 0
}

# Act on fetched runs. Returns 0, 75 (rate limited) or 4 (no permission).
_psqr_process_runs() {
	local repo_slug="$1"
	local runs_file="$2"
	local state_prefix="$3"
	local pending_next="$4"
	local error_file="$5"
	local dry_run="$6"
	local max_runs="" acted=0 rc=0
	local run_id workflow age_hours
	max_runs=$(_psqr_uint_setting "${AIDEVOPS_STALE_QUEUED_RUN_MAX_RUNS:-}" 20)
	while IFS=$'\t' read -r run_id workflow age_hours; do
		[[ "$run_id" =~ ^[0-9]+$ ]] || continue
		if [[ "$acted" -ge "$max_runs" ]]; then
			_psqr_log "per-repo action cap reached (${max_runs}): repo=${repo_slug}; remainder next interval"
			break
		fi
		acted=$((acted + 1))
		if [[ "$dry_run" == "1" ]]; then
			_psqr_log "dry-run: would cancel stale queued run: repo=${repo_slug} run=${run_id} workflow=\"${workflow}\" age=${age_hours}h"
			continue
		fi
		rc=0
		_psqr_handle_run "$repo_slug" "$run_id" "$workflow" "$age_hours" "$state_prefix" "$pending_next" "$error_file" || rc=$?
		[[ "$rc" -eq 0 ]] || return "$rc"
	done <"$runs_file"
	return 0
}

# Persist per-repo state: pending cancels, ghosts still queued, last-run time.
_psqr_save_state() {
	local state_prefix="$1"
	local runs_file="$2"
	local pending_next="$3"
	local now="$4"
	local ids_file="${runs_file}.ids"
	local ghosts_file="${state_prefix}.ghosts"
	mkdir -p "$(dirname "$state_prefix")" 2>/dev/null || return 0
	cut -f1 "$runs_file" >"$ids_file" 2>/dev/null || : >"$ids_file"
	if [[ -f "$ghosts_file" ]]; then
		grep -Fxf "$ids_file" "$ghosts_file" >"${ghosts_file}.tmp" 2>/dev/null || true
		mv -f "${ghosts_file}.tmp" "$ghosts_file" 2>/dev/null || true
	fi
	mv -f "$pending_next" "${state_prefix}.pending" 2>/dev/null || true
	# A rate-limited pass retries next cycle instead of waiting an interval.
	[[ -n "$now" ]] && printf '%s\n' "$now" >"${state_prefix}.last-run" 2>/dev/null
	return 0
}

# Scan one repo. Returns 0 normally, 75 when rate limited.
# Args: $1=repo slug, $2=dry run (0|1), $3=force (ignore interval, 0|1)
stale_queued_runs_scan_repo() {
	local repo_slug="$1"
	local dry_run="${2:-0}"
	local force="${3:-0}"
	local max_age_hours="" now="" state_prefix="" work_dir="" rc=0
	max_age_hours=$(_psqr_uint_setting "${AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS:-}" 8)
	[[ "$max_age_hours" -gt 0 ]] || return 0
	now=$(_psqr_now)
	state_prefix=$(_psqr_state_prefix "$repo_slug")
	if [[ "$dry_run" != "1" && "$force" != "1" ]] && ! _psqr_repo_due "${state_prefix}.last-run" "$now"; then
		return 0
	fi
	if ! _psqr_repo_allows_actions_write "$repo_slug"; then
		_psqr_log "skipping ${repo_slug}: no write access for Actions runs"
		return 0
	fi
	work_dir=$(mktemp -d "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/pulse-stale-queued-runs.XXXXXX") || return 0
	_PSQR_COUNT_CANCELLED=0
	_PSQR_COUNT_GHOSTS=0
	_PSQR_COUNT_DELETED=0
	_PSQR_COUNT_FAILED=0
	: >"${work_dir}/pending-next"
	_psqr_fetch_stale_runs "$repo_slug" "$now" "${work_dir}/runs.tsv" "${work_dir}/gh.err" "$max_age_hours" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		_psqr_process_runs "$repo_slug" "${work_dir}/runs.tsv" "$state_prefix" \
			"${work_dir}/pending-next" "${work_dir}/gh.err" "$dry_run" || rc=$?
		local mark_now="$now"
		[[ "$rc" -eq "$_PSQR_RATE_LIMIT_RC" ]] && mark_now=""
		[[ "$dry_run" == "1" ]] || _psqr_save_state "$state_prefix" "${work_dir}/runs.tsv" "${work_dir}/pending-next" "$mark_now"
		_psqr_log "repo=${repo_slug} stale=$(wc -l <"${work_dir}/runs.tsv" | tr -d ' ') cancelled=${_PSQR_COUNT_CANCELLED} new_ghosts=${_PSQR_COUNT_GHOSTS} deleted=${_PSQR_COUNT_DELETED} failed=${_PSQR_COUNT_FAILED} max_age=${max_age_hours}h"
	elif [[ "$rc" -ne "$_PSQR_RATE_LIMIT_RC" && "$dry_run" != "1" ]]; then
		# Non-rate-limit listing failures wait for the next interval too.
		mkdir -p "$(dirname "$state_prefix")" 2>/dev/null && printf '%s\n' "$now" >"${state_prefix}.last-run" 2>/dev/null
	fi
	rm -rf "$work_dir" 2>/dev/null || true
	[[ "$rc" -eq "$_PSQR_RATE_LIMIT_RC" ]] && return "$_PSQR_RATE_LIMIT_RC"
	return 0
}

# Pulse stage entry point. Always returns 0 (non-fatal stage).
# Args: $1=repos.json (optional), $2=dry run (0|1), $3=force (0|1)
stale_queued_runs_scan_repos() {
	local repos_json="${1:-${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
	local dry_run="${2:-0}"
	local force="${3:-0}"
	local max_age_hours="" max_repos="" repo_rows="" repo_slug="" repo_count=0
	max_age_hours=$(_psqr_uint_setting "${AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS:-}" 8)
	[[ "$max_age_hours" -gt 0 ]] || return 0
	if [[ -n "${STOP_FLAG:-}" && -f "$STOP_FLAG" ]]; then
		return 0
	fi
	if [[ ! -f "$repos_json" ]]; then
		_psqr_log "repos.json not found at ${repos_json}; skipping"
		return 0
	fi
	repo_rows=$(_psqr_list_repos "$repos_json") || {
		_psqr_log "unable to read managed repositories from ${repos_json}; skipping"
		return 0
	}
	[[ -n "$repo_rows" ]] || return 0
	_psqr_budget_allows || return 0
	max_repos=$(_psqr_uint_setting "${AIDEVOPS_STALE_QUEUED_RUN_MAX_REPOS:-}" 50)
	while IFS= read -r repo_slug; do
		[[ -n "$repo_slug" ]] || continue
		repo_count=$((repo_count + 1))
		[[ "$repo_count" -le "$max_repos" ]] || break
		if [[ -n "${STOP_FLAG:-}" && -f "$STOP_FLAG" ]]; then
			break
		fi
		if declare -F _gh_secondary_cooldown_active >/dev/null 2>&1 && _gh_secondary_cooldown_active; then
			_psqr_log "shared GitHub cooldown started mid-scan; stopping"
			break
		fi
		if ! stale_queued_runs_scan_repo "$repo_slug" "$dry_run" "$force"; then
			_psqr_log "stopping after rate-limit response from ${repo_slug}"
			break
		fi
	done <<<"$repo_rows"
	return 0
}

_psqr_usage() {
	cat <<'EOF'
pulse-stale-queued-runs.sh — cancel GitHub Actions runs queued longer than a max age (GH#33602)

Usage:
  pulse-stale-queued-runs.sh scan [--dry-run] [--force] [--repo OWNER/REPO] [--repos-json PATH]
  pulse-stale-queued-runs.sh help

  --dry-run   list stale runs without cancelling or writing state
  --force     ignore the per-repo interval gate
  --repo      scan one repo instead of pulse-managed repos from repos.json

Settings: AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS (default 8, 0 disables),
AIDEVOPS_STALE_QUEUED_RUN_DELETE=1 (delete HTTP 409 ghosts),
AIDEVOPS_STALE_QUEUED_RUN_INTERVAL_SECONDS (default 3600).
EOF
	return 0
}

_psqr_main() {
	local command="${1:-help}"
	local repos_json="" only_repo="" dry_run=0 force=0
	shift || true
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local value="${2:-}"
		case "$arg" in
		--dry-run) dry_run=1 ;;
		--force) force=1 ;;
		--repo)
			only_repo="$value"
			shift
			;;
		--repos-json)
			repos_json="$value"
			shift
			;;
		*)
			_psqr_log "unknown argument: ${arg}"
			return 2
			;;
		esac
		shift
	done
	case "$command" in
	scan) ;;
	help | --help | -h)
		_psqr_usage
		return 0
		;;
	*)
		_psqr_usage
		return 2
		;;
	esac
	if [[ -n "$only_repo" ]]; then
		[[ "$only_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || {
			_psqr_log "invalid --repo value (expected OWNER/REPO)"
			return 2
		}
		_psqr_budget_allows || return 0
		stale_queued_runs_scan_repo "$only_repo" "$dry_run" "$force" || true
		return 0
	fi
	stale_queued_runs_scan_repos "$repos_json" "$dry_run" "$force"
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -uo pipefail
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091
	[[ -r "${_PSQR_SCRIPT_DIR}/shared-constants.sh" ]] && source "${_PSQR_SCRIPT_DIR}/shared-constants.sh" 2>/dev/null
	# shellcheck source=./shared-gh-secondary-cooldown.sh
	# shellcheck disable=SC1091
	[[ -r "${_PSQR_SCRIPT_DIR}/shared-gh-secondary-cooldown.sh" ]] && source "${_PSQR_SCRIPT_DIR}/shared-gh-secondary-cooldown.sh" 2>/dev/null
	_psqr_main "$@"
	exit $?
fi
